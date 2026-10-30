# Sourced by the app's scripts (ci.sh, publish.sh) on the owner's machine:
#
#   source "$V15_BUILD/scripts/dispatch.sh"   # V15_BUILD: this repo's folder
#   v15_build <repo> <sha> [build id]          # sets V15_RUN; true if it passed
#   v15_build_fetch <run> <dir> <key file>     # the release's files, decrypted
#
# Each run is identified by a nonce in its name, allowing apps to dispatch
# simultaneously.

V15_BUILDER="${V15_BUILDER:-Emmet-v15/v15-build}"

v15_build() {
  local repo="$1" sha="$2" build="${3:-}" nonce
  nonce="$(date +%s)$RANDOM$RANDOM"
  gh workflow run build.yml --repo "$V15_BUILDER" -f repo="$repo" -f ref="$sha" -f build="$build" -f nonce="$nonce" || return 1
  V15_RUN=""
  for _ in $(seq 1 30); do
    V15_RUN=$(gh run list --repo "$V15_BUILDER" --workflow build.yml --limit 30 --json databaseId,displayTitle \
      -q ".[] | select(.displayTitle | endswith(\" $nonce\")) | .databaseId" | head -1 | tr -d '\r')
    [ -n "$V15_RUN" ] && break
    sleep 4
  done
  [ -n "$V15_RUN" ] || { echo "the builder's run didn't start"; return 1; }
  echo "run $V15_RUN: https://github.com/$V15_BUILDER/actions/runs/$V15_RUN"
  gh run watch "$V15_RUN" --repo "$V15_BUILDER" --interval 20 --exit-status > /dev/null && return 0
  gh run view "$V15_RUN" --repo "$V15_BUILDER" --log-failed | sed -E 's/^[^\t]*\t[^\t]*\t[^ ]+ //' | tail -40
  return 1
}

v15_build_fetch() {
  local run="$1" dir="$2" key="$3" f
  mkdir -p "$dir"
  gh run download "$run" --repo "$V15_BUILDER" -n windows -D "$dir" || return 1
  for f in "$dir"/*.enc; do
    openssl enc -d -aes-256-cbc -md sha256 -pbkdf2 -iter 100000 -in "$f" -out "${f%.enc}" -pass "file:$key" && rm "$f" || return 1
  done
}
