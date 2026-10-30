#!/usr/bin/env bash
# The runner's initial step clones the app (REPO at REF) into src/ and
# configures a read-only deploy key for each required private repository
# (itself and its ops/build.json "deps"). Each key is isolated behind its
# own ssh host to ensure the correct key matches the correct repository.
# The https URLs are directed to these hosts, allowing cargo to fetch git
# dependencies as written and keeping Cargo.lock unchanged. fetch.sh
# removes all of this.
set -euo pipefail
# jq on the Windows runner ends lines with CR LF: its output goes through tr

case "$REPO" in '' | *[!A-Za-z0-9._-]*) echo "repo: a repository name under Emmet-v15"; exit 1 ;; esac
case "$REF" in '' | -* | *[!A-Za-z0-9._/-]*) echo "ref: a commit or branch"; exit 1 ;; esac

id() { echo "$1" | tr 'a-z.-' 'A-Z__'; }
keys="$RUNNER_TEMP/keys"
mkdir -p "$keys" ~/.ssh
# GitHub's SSH host keys, retrieved from its API over TLS
curl -fsS https://api.github.com/meta | jq -r '.ssh_keys[] | "github.com " + .' | tr -d '\r' > ~/.ssh/known_hosts

add() {
  local repo="$1" name key
  case "$repo" in '' | *[!A-Za-z0-9._-]*) echo "deps: a repository name under Emmet-v15: $repo"; exit 1 ;; esac
  name="KEY_$(id "$repo")"
  key=$(jq -r --arg k "$name" '.[$k] // empty' <<< "$SECRETS" | tr -d '\r')
  [ -n "$key" ] || { echo "no $name secret: scripts/add-repo.sh $repo"; exit 1; }
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

add "$REPO"
git clone -q --no-checkout "https://github.com/Emmet-v15/$REPO" src
git -C src checkout -q "$REF"
if [ -f src/ops/build.json ]; then
  for dep in $(jq -r '.deps[]? // empty' src/ops/build.json | tr -d '\r'); do
    [ "$dep" = "$REPO" ] || add "$dep"
  done
fi
echo "artifact=ARTIFACT_$(id "$REPO")" >> "$GITHUB_OUTPUT"
echo "$REPO at $(git -C src rev-parse --short HEAD)"
