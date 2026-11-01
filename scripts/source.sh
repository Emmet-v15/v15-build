#!/usr/bin/env bash
# The runner performs its initial steps in distinct calls, ensuring each
# step accesses only the specific secret it requires (a step reading all
# secrets would expose them):
#
#   source.sh names   checks REPO and REF, names the app's secrets
#   source.sh plan    with KEY: reads the app's ops/build.json at REF and
#                     outputs the platforms to run (PLATFORMS: only these)
#                     and their runners, as the build job's matrix
#   source.sh app     with KEY: clones the app (REPO at REF) into src/ and
#                     outputs, for PLATFORM, what the next steps need: the
#                     secrets of its "deps" (≤ 4) and "checkouts" (≤ 2), the
#                     names of its "secrets" (≤ 4), "mask" (≤ 2) and
#                     "keychain", its "dir", tools and cache folders
#   source.sh mask    with M1, M2: masks those values in the log
#   source.sh deps    with D1..D4 (repos) and K1..K4 (their keys)
#
# Each key gets its own ssh host alias, ensuring the correct key maps to
# the correct repository, whose https URL points to that alias;
# consequently, cargo fetches git dependencies as specified and Cargo.lock
# remains unchanged. fetch.sh removes all of this.
set -euo pipefail
# jq on the Windows runner terminates lines with CR LF: its output passes
# through tr

id() { echo "$1" | tr 'a-z.-' 'A-Z__'; }
valid() { case "$1" in '' | *[!A-Za-z0-9._-]*) return 1 ;; esac; }
validref() { case "$1" in '' | -* | *[!A-Za-z0-9._/-]*) return 1 ;; esac; }
secret() { case "$1" in '' | *[!A-Z0-9_]*) return 1 ;; esac; }
out() { echo "$1" >> "$GITHUB_OUTPUT"; }
keys="$RUNNER_TEMP/keys"
# Network steps are attempted three times, with intervals of at most one
# minute.
retry() {
  local n
  for n in 1 2 3; do
    "$@" && return 0
    [ "$n" = 3 ] || { echo "retrying: $1 ($n)"; sleep $((n * 20)); }
  done
  return 1
}

add() {
  local repo="$1" key="$2"
  [ -n "$key" ] || { echo "no KEY_$(id "$repo") secret: scripts/add-repo.sh $repo"; exit 1; }
  mkdir -p "$keys" ~/.ssh
  [ -s ~/.ssh/known_hosts ] || retry curl -fsS https://api.github.com/meta | jq -r '.ssh_keys[] | "github.com " + .' | tr -d '\r' > ~/.ssh/known_hosts
  printf '%s\n' "$key" > "$keys/$repo"
  chmod 600 "$keys/$repo"
  cat >> ~/.ssh/config <<EOF
Host gh-$repo
  HostName github.com
  User git
  IdentityFile $keys/$repo
  IdentitiesOnly yes
EOF
  git config --global "url.git@gh-$repo:Emmet-v15/$repo.insteadOf" "https://github.com/Emmet-v15/$repo"
}

clone() {
  add "$REPO" "$KEY"
  rm -rf src
  retry git clone -q --no-checkout ${1:+"$1"} "https://github.com/Emmet-v15/$REPO" src
  git -C src checkout -q "$REF"
}

# The `ops/build.json` file at the platform: a field within its section
platforms="windows linux macos ios android"
cfg=src/ops/build.json
q() { jq -r --arg p "$PLATFORM" "$1" "$cfg" | tr -d '\r'; }

case "${1:-}" in
  names)
    valid "$REPO" || { echo "repo: a repository name under Emmet-v15"; exit 1; }
    validref "$REF" || { echo "ref: a commit or branch"; exit 1; }
    { echo "key=KEY_$(id "$REPO")"; echo "artifact=ARTIFACT_$(id "$REPO")"; } >> "$GITHUB_OUTPUT"
    ;;

  plan)
    clone --filter=blob:none
    have=""
    if [ -f "$cfg" ]; then
      for p in $platforms; do
        [ "$(jq -r --arg p "$p" 'has($p)' "$cfg" | tr -d '\r')" = true ] && have="$have $p"
      done
    fi
    # An app without platform sections is a Windows app (the original form)
    [ -n "$have" ] || have=" windows"
    run=""
    for p in $(echo "${PLATFORMS:-}" | tr ',' ' '); do
      case " $have " in *" $p "*) run="$run $p" ;; *) echo "platforms: $p is not one of the app's:$have"; exit 1 ;; esac
    done
    [ -n "$run" ] || run="$have"
    matrix="["
    for p in $run; do
      case "$p" in
        windows) runner=windows-2025 ;;
        linux | android) runner=ubuntu-24.04 ;;
        macos | ios) runner=macos-15 ;;
      esac
      timeout=60
      if [ -f "$cfg" ]; then
        r=$(jq -r --arg p "$p" '.[$p].runner // empty' "$cfg" | tr -d '\r')
        t=$(jq -r --arg p "$p" '.[$p].timeout // empty' "$cfg" | tr -d '\r')
        [ -z "$r" ] || runner="$r"
        [ -z "$t" ] || timeout="$t"
      fi
      # pinned images only: "latest" moves under a build
      case "$runner" in windows-2025 | windows-2022 | ubuntu-24.04 | ubuntu-22.04 | macos-15 | macos-14) ;;
        *) echo "$p: runner $runner is not one of windows-2025, windows-2022, ubuntu-24.04, ubuntu-22.04, macos-15, macos-14"; exit 1 ;; esac
      case "$timeout" in '' | *[!0-9]*) echo "$p: timeout in minutes"; exit 1 ;; esac
      [ "$timeout" -ge 5 ] && [ "$timeout" -le 180 ] || { echo "$p: timeout 5 to 180 minutes"; exit 1; }
      matrix="$matrix{\"platform\":\"$p\",\"runner\":\"$runner\",\"timeout\":$timeout},"
    done
    matrix="${matrix%,}]"
    echo "$REPO at $(git -C src rev-parse --short HEAD):$run"
    out "matrix=$matrix"
    ;;

  app)
    clone
    echo "$REPO at $(git -C src rev-parse --short HEAD) ($PLATFORM)"
    n=0
    dir=.
    legacy=true
    if [ -f "$cfg" ]; then
      dir=$(q '.dir // "."')
      case "/$dir/" in *[!A-Za-z0-9._/-]* | */../* | //*) echo "dir: a folder inside the repository"; exit 1 ;; esac
      [ "$(q 'has($p)')" = true ] && legacy=false
      [ "$legacy" = false ] || [ "$PLATFORM" = windows ] || { echo "ops/build.json has no \"$PLATFORM\""; exit 1; }
      [ "$legacy" = false ] || [ -f "src/$dir/Cargo.toml" ] || { echo "dir: no Cargo.toml in $dir"; exit 1; }
      for dep in $(q '.deps[]? // empty'); do
        valid "$dep" || { echo "deps: a repository name under Emmet-v15: $dep"; exit 1; }
        [ "$dep" != "$REPO" ] || continue
        n=$((n + 1))
        [ "$n" -le 4 ] || { echo "deps: at most 4"; exit 1; }
        { echo "d$n=$dep"; echo "k$n=KEY_$(id "$dep")"; } >> "$GITHUB_OUTPUT"
      done
    fi
    out "dir=$dir"
    out "legacy=$legacy"
    app=$(id "$REPO")
    workspaces="src/$dir"

    if [ "$legacy" = true ]; then
      # the original form: top-level "tools"
      if [ -f "$cfg" ]; then
        for tool in $(jq -r '.tools[]? // empty' "$cfg" | tr -d '\r'); do
          case "$tool" in nasm) out "nasm=true" ;; *) echo "tools: unknown $tool"; exit 1 ;; esac
        done
      fi
    else
      for tool in $(q '.[$p].tools[]? // empty'); do
        case "$tool" in
          nasm) out "nasm=true" ;;
          node) out "node=22" ;;
          node:[0-9]*) out "node=${tool#node:}" ;;
          java) out "java=17" ;;
          java:[0-9]*) out "java=${tool#java:}" ;;
          android) out "android=true" ;;
          xcode:[0-9]*) out "xcode=${tool#xcode:}" ;;
          *) echo "tools: unknown $tool (nasm, node[:N], java[:N], android, xcode:N)"; exit 1 ;;
        esac
      done
      case "$(q '.[$p].tools // [] | join(" ")')" in *[!A-Za-z0-9.:\ ]*) echo "tools: names and versions"; exit 1 ;; esac
      list() {
        local v
        v=$(q "$1 // [] | join(\" \")")
        case "$v" in *[!A-Za-z0-9._+@\ -]*) echo "$2: names"; exit 1 ;; esac
        out "$2=$v"
      }
      list '.[$p].targets' targets
      list '.[$p].apt' apt
      list '.[$p].brew' brew

      # Other private repositories, beside `src/`, are specified as
      # `{"repo": "name"}` using its `KEY_<NAME>`, or as `{"secret":
      # "NAME"}`, where the repository and key are the app's secrets
      # `NAME_REPO_<APP>` and `NAME_KEY_<APP>` (a name that stays out of
      # the public log).
      i=0
      count=$(q '.[$p].checkouts // [] | length')
      [ "$count" -le 2 ] || { echo "checkouts: at most 2"; exit 1; }
      while [ "$i" -lt "$count" ]; do
        i=$((i + 1))
        path=$(q ".[\$p].checkouts[$((i - 1))].path // empty")
        ref=$(q ".[\$p].checkouts[$((i - 1))].ref // \"main\"")
        repo=$(q ".[\$p].checkouts[$((i - 1))].repo // empty")
        name=$(q ".[\$p].checkouts[$((i - 1))].secret // empty")
        valid "$path" || { echo "checkouts: path, a folder name beside the app"; exit 1; }
        case "$path" in src | builder | out) echo "checkouts: $path is the builder's"; exit 1 ;; esac
        validref "$ref" || { echo "checkouts: ref, a commit or branch"; exit 1; }
        out "c${i}_path=$path"
        out "c${i}_ref=$ref"
        if [ -n "$repo" ]; then
          valid "$repo" || { echo "checkouts: repo, a repository name under Emmet-v15"; exit 1; }
          out "c${i}_repo=Emmet-v15/$repo"
          out "c${i}_key=KEY_$(id "$repo")"
        else
          secret "$name" || { echo "checkouts: \"repo\" or \"secret\" (A-Z, 0-9, _)"; exit 1; }
          out "c${i}_repo_secret=${name}_REPO_$app"
          out "c${i}_key=${name}_KEY_$app"
        fi
      done

      # the app's own secrets, NAME_<APP>, each read by one step
      i=0
      for name in $(q '.[$p].secrets[]? // empty'); do
        secret "$name" || { echo "secrets: names (A-Z, 0-9, _)"; exit 1; }
        i=$((i + 1))
        [ "$i" -le 4 ] || { echo "secrets: at most 4"; exit 1; }
        { echo "n$i=$name"; echo "s$i=${name}_$app"; } >> "$GITHUB_OUTPUT"
      done
      i=0
      for name in $(q '.[$p].mask[]? // empty'); do
        secret "$name" || { echo "mask: secret names (A-Z, 0-9, _)"; exit 1; }
        i=$((i + 1))
        [ "$i" -le 2 ] || { echo "mask: at most 2"; exit 1; }
        out "m$i=${name}_$app"
      done
      cert=$(q '.[$p].keychain.cert // empty')
      if [ -n "$cert" ]; then
        pw=$(q '.[$p].keychain.password // empty')
        identity=$(q '.[$p].keychain.identity // empty')
        secret "$cert" && secret "$pw" || { echo "keychain: cert and password, secret names"; exit 1; }
        case "$identity" in *[!A-Za-z0-9\ ._\(\)-]*) echo "keychain: identity, a certificate's name"; exit 1 ;; esac
        out "kc_cert=${cert}_$app"
        out "kc_password=${pw}_$app"
        out "kc_identity=$identity"
      fi
      for c in $(q '.[$p].cache[]? // empty'); do
        case "/$c/" in *[!A-Za-z0-9._/-]* | */../* | //*) echo "cache: folders in the workspace"; exit 1 ;; esac
        workspaces="$workspaces
$c"
      done
    fi
    { echo "workspaces<<V15_EOF"; echo "$workspaces"; echo "V15_EOF"; } >> "$GITHUB_OUTPUT"
    ;;

  mask)
    # as written, Capitalised and UPPER CASE
    for v in "${M1:-}" "${M2:-}"; do
      [ -n "$v" ] || continue
      for w in "$v" "$(echo "$v" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')" "$(echo "$v" | tr a-z A-Z)"; do
        echo "::add-mask::$w"
      done
    done
    ;;

  deps)
    for i in 1 2 3 4; do
      d="D$i" k="K$i"
      [ -n "${!d:-}" ] || continue
      add "${!d}" "${!k:-}"
    done
    ;;
  *) echo "usage: source.sh names|plan|app|mask|deps"; exit 1 ;;
esac
