# Sourced by the app's scripts (ci.sh, publish.sh) on the owner's machine:
#
#   source "$V15_BUILD/scripts/dispatch.sh"   # V15_BUILD: this repo's folder
#   v15_build <repo> <sha> [build id] [platforms]
#                                   sets V15_RUN; true if every job passed
#   v15_build_fetch <run> <dir> <key file> [platform...]
#                                   the platforms' release files (default
#                                   windows), decrypted and checked against
#                                   the run's own v15-sum lines
#   v15_build_sums <run> <platform> the v15-sum lines of a platform's release
#                                   files (sha256, size, name), from the log:
#                                   nothing downloaded
#   v15_build_has <run> <platform>  true if the run still holds that
#                                   platform's files
#
# Runs are identified by a nonce in their name, enabling apps to dispatch
# simultaneously. Each run has a deadline of V15_DEADLINE minutes (default
# 120) before cancellation. Infrastructure failures—such as a lost runner,
# timeout, or network fault during setup—trigger a single rerun; failing
# checks or builds do not. V15_BUILDER_REF executes the workflow from another
# builder branch (for testing).

V15_BUILDER="${V15_BUILDER:-Emmet-v15/v15-build}"

_v15_jobs() {
  # name, conclusion, and first failed step of each job
  gh run view "$1" --repo "$V15_BUILDER" --json jobs \
    -q '.jobs[] | [.name, (.conclusion // ""), ([.steps[]? | select(.conclusion == "failure") | .name][0] // "")] | @tsv' | tr -d '\r'
}

# Steps that fail due to the app itself—such as its checks, its build, or
# encrypting its files—differ from other failures (like setup, fetching,
# or a lost runner), which may be infrastructure-related and are cheap to
# retry.
_v15_app_step() {
  case "$1" in check | release | encrypt) return 0 ;; esac
  return 1
}

# gh, up to three times: the owner's connection drops occasionally
_v15_gh() {
  local n
  for n in 1 2 3; do
    gh "$@" && return 0
    [ "$n" = 3 ] || sleep $((n * 10))
  done
  return 1
}

v15_build() {
  local repo="$1" sha="$2" build="${3:-}" platforms="${4:-}" nonce cache=false deadline started status retried=0 line name concl step infra
  nonce="$(date +%s)$RANDOM$RANDOM"
  # The build cache is saved exclusively from main's commits and
  # releases.
  [ "$(git rev-parse -q --verify origin/main 2>/dev/null)" = "$sha" ] && cache=true
  _v15_gh workflow run build.yml --repo "$V15_BUILDER" ${V15_BUILDER_REF:+--ref "$V15_BUILDER_REF"} \
    -f repo="$repo" -f ref="$sha" -f build="$build" -f platforms="$platforms" -f cache="$cache" -f nonce="$nonce" > /dev/null || return 1
  V15_RUN=""
  for _ in $(seq 1 30); do
    V15_RUN=$(gh run list --repo "$V15_BUILDER" --workflow build.yml --limit 30 --json databaseId,displayTitle \
      -q ".[] | select(.displayTitle | endswith(\" $nonce\")) | .databaseId" | head -1 | tr -d '\r')
    [ -n "$V15_RUN" ] && break
    sleep 4
  done
  [ -n "$V15_RUN" ] || { echo "the builder's run didn't start"; return 1; }
  echo "run $V15_RUN: https://github.com/$V15_BUILDER/actions/runs/$V15_RUN"
  deadline=$(($(date +%s) + ${V15_DEADLINE:-120} * 60))
  while :; do
    status=$(gh run view "$V15_RUN" --repo "$V15_BUILDER" --json status,conclusion -q '.status + " " + (.conclusion // "")' 2>/dev/null | tr -d '\r')
    case "$status" in
      "completed success") return 0 ;;
      completed*)
        # rerun once if the failure was not the app's
        infra=1
        while IFS=$'\t' read -r name concl step; do
          [ "$concl" = failure ] || continue
          _v15_app_step "$step" && infra=0
        done <<< "$(_v15_jobs "$V15_RUN")"
        if [ "$infra" = 1 ] && [ "$retried" = 0 ]; then
          retried=1
          echo "run $V15_RUN: the infrastructure failed ($status), its failed jobs once more"
          _v15_gh run rerun "$V15_RUN" --repo "$V15_BUILDER" --failed > /dev/null || return 1
          sleep 10
          continue
        fi
        _v15_jobs "$V15_RUN" | while IFS=$'\t' read -r name concl step; do
          [ "$concl" = success ] || echo "  $name: $concl${step:+ at $step}"
        done
        # the lines of the failed steps themselves, not their headers
        # (env, inputs)
        gh run view "$V15_RUN" --repo "$V15_BUILDER" --log-failed 2>/dev/null | sed -E 's/^[^\t]*\t[^\t]*\t[^ ]+ //' \
          | awk '/##\[group\]/ { skip = 1 } /##\[endgroup\]/ { skip = 0; next } !skip' | tail -40
        return 1
        ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "run $V15_RUN: past its ${V15_DEADLINE:-120} minutes, cancelled"
      gh run cancel "$V15_RUN" --repo "$V15_BUILDER" > /dev/null 2>&1
      return 1
    fi
    sleep 20
  done
}

v15_build_sums() {
  local run="$1" platform="$2" job
  job=$(_v15_gh run view "$run" --repo "$V15_BUILDER" --json jobs -q ".jobs[] | select(.name == \"$platform\") | .databaseId" | tr -d '\r' | tail -1)
  [ -n "$job" ] || return 1
  _v15_gh run view "$run" --repo "$V15_BUILDER" --job "$job" --log 2>/dev/null | grep -oE 'v15-sum [0-9a-f]{64} [0-9]+ [A-Za-z0-9._-]+$' | sed 's/^v15-sum //'
}

v15_build_has() {
  local n
  n=$(_v15_gh api "repos/$V15_BUILDER/actions/runs/$1/artifacts" -q "[.artifacts[] | select(.name == \"$2\" and (.expired | not))] | length" 2>/dev/null | tr -d '\r')
  [ "${n:-0}" -gt 0 ]
}

v15_build_fetch() {
  local run="$1" dir="$2" key="$3" p f n sums sum size name got
  shift 3
  [ $# -gt 0 ] || set -- windows
  mkdir -p "$dir"
  for p in "$@"; do
    sums=$(v15_build_sums "$run" "$p")
    [ -n "$sums" ] || { echo "$p: no v15-sum lines in run $run's log"; return 1; }
    # (a download cut short is started again from scratch)
    for n in 1 2 3; do
      rm -f "$dir"/*.enc
      gh run download "$run" --repo "$V15_BUILDER" -n "$p" -D "$dir" && break
      [ "$n" = 3 ] && return 1
      sleep $((n * 10))
    done
    for f in "$dir"/*.enc; do
      [ -e "$f" ] || continue
      openssl enc -d -aes-256-cbc -md sha256 -pbkdf2 -iter 100000 -in "$f" -out "${f%.enc}" -pass "file:$key" && rm "$f" || return 1
    done
    # each file as the run built it
    while read -r sum size name; do
      [ -n "$name" ] || continue
      got=$(sha256sum "$dir/$name" 2>/dev/null | cut -d' ' -f1)
      [ "$got" = "$sum" ] || { echo "$name: not the file the run built (sha256 $got, the run's $sum)"; return 1; }
    done <<< "$sums"
  done
}
