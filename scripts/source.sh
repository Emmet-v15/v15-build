#!/usr/bin/env bash
# The runner executes its first steps in three calls so that each step sees
# only the key it needs (a step reading every secret would leak them all):
#
#   source.sh names   checks REPO and REF, names the app's secrets
#   source.sh app     with KEY: clones the app (REPO at REF) into src/,
#                     names the secrets of its ops/build.json "deps" (≤ 4),
#                     and outputs its "dir" and "tools"
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
keys="$RUNNER_TEMP/keys"

add() {
  local repo="$1" key="$2"
  [ -n "$key" ] || { echo "no KEY_$(id "$repo") secret: scripts/add-repo.sh $repo"; exit 1; }
  mkdir -p "$keys" ~/.ssh
  [ -s ~/.ssh/known_hosts ] || curl -fsS https://api.github.com/meta | jq -r '.ssh_keys[] | "github.com " + .' | tr -d '\r' > ~/.ssh/known_hosts
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

case "${1:-}" in
  names)
    valid "$REPO" || { echo "repo: a repository name under Emmet-v15"; exit 1; }
    case "$REF" in '' | -* | *[!A-Za-z0-9._/-]*) echo "ref: a commit or branch"; exit 1 ;; esac
    { echo "key=KEY_$(id "$REPO")"; echo "artifact=ARTIFACT_$(id "$REPO")"; } >> "$GITHUB_OUTPUT"
    ;;
  app)
    add "$REPO" "$KEY"
    git clone -q --no-checkout "https://github.com/Emmet-v15/$REPO" src
    git -C src checkout -q "$REF"
    echo "$REPO at $(git -C src rev-parse --short HEAD)"
    n=0
    dir=.
    if [ -f src/ops/build.json ]; then
      dir=$(jq -r '.dir // "."' src/ops/build.json | tr -d '\r')
      case "/$dir/" in *[!A-Za-z0-9._/-]* | */../* | //*) echo "dir: a folder inside the repository"; exit 1 ;; esac
      [ -f "src/$dir/Cargo.toml" ] || { echo "dir: no Cargo.toml in $dir"; exit 1; }
      for tool in $(jq -r '.tools[]? // empty' src/ops/build.json | tr -d '\r'); do
        case "$tool" in nasm) echo "nasm=true" >> "$GITHUB_OUTPUT" ;; *) echo "tools: unknown $tool"; exit 1 ;; esac
      done
      for dep in $(jq -r '.deps[]? // empty' src/ops/build.json | tr -d '\r'); do
        valid "$dep" || { echo "deps: a repository name under Emmet-v15: $dep"; exit 1; }
        [ "$dep" != "$REPO" ] || continue
        n=$((n + 1))
        [ "$n" -le 4 ] || { echo "deps: at most 4"; exit 1; }
        { echo "d$n=$dep"; echo "k$n=KEY_$(id "$dep")"; } >> "$GITHUB_OUTPUT"
      done
    fi
    echo "dir=$dir" >> "$GITHUB_OUTPUT"
    ;;
  deps)
    for i in 1 2 3 4; do
      d="D$i" k="K$i"
      [ -n "${!d:-}" ] || continue
      add "${!d}" "${!k:-}"
    done
    ;;
  *) echo "usage: source.sh names|app|deps"; exit 1 ;;
esac
