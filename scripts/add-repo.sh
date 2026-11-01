#!/usr/bin/env bash
# Creates a new read-only deploy key on a private repository to enable
# builder access, storing the private half in a secret of this repo.
# Re-running replaces the key. The private half is never persisted to disk.
#   bash scripts/add-repo.sh <repo>
#       an app, or a private dependency of one: secret KEY_<REPO>
#   bash scripts/add-repo.sh <repo> <app> <NAME>
#       an extra checkout of <app> whose name stays out of the public log
#       (ops/build.json "checkouts": {"secret": "NAME"}): secrets
#       NAME_KEY_<APP> (the key) and NAME_REPO_<APP> (Emmet-v15/<repo>)
set -euo pipefail
repo="${1:?usage: add-repo.sh <repo> [<app> <NAME>]}"
app="${2:-}"
alias="${3:-}"
builder="${V15_BUILDER:-Emmet-v15/v15-build}"
case "$repo" in *[!A-Za-z0-9._-]*) echo "a repository name under Emmet-v15"; exit 1 ;; esac
up() { echo "$1" | tr 'a-z.-' 'A-Z__'; }
if [ -n "$app" ]; then
  case "$alias" in '' | *[!A-Z0-9_]*) echo "NAME: A-Z, 0-9, _"; exit 1 ;; esac
  name="${alias}_KEY_$(up "$app")"
  title="v15-build $app $alias"
else
  name="KEY_$(up "$repo")"
  title="v15-build"
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The builder's earlier key (for this use) is removed first.
for id in $(gh repo deploy-key list --repo "Emmet-v15/$repo" --json id,title -q ".[] | select(.title == \"$title\") | .id" | tr -d '\r'); do
  gh repo deploy-key delete "$id" --repo "Emmet-v15/$repo"
done
ssh-keygen -q -t ed25519 -N '' -C "v15-build:$repo" -f "$tmp/key"
gh repo deploy-key add "$tmp/key.pub" --repo "Emmet-v15/$repo" --title "$title"
gh secret set "$name" --repo "$builder" < "$tmp/key"
if [ -n "$app" ]; then
  printf 'Emmet-v15/%s' "$repo" | gh secret set "${alias}_REPO_$(up "$app")" --repo "$builder"
  echo "$repo: read-only key added for $app, secrets $name and ${alias}_REPO_$(up "$app") set"
else
  echo "$repo: read-only key added, secret $name set"
fi
