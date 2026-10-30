#!/usr/bin/env bash
# Enables the builder to access a private repository (an app, or a private
# dependency of an app) by creating a new read-only deploy key on
# Emmet-v15/<repo>, storing its private half in this repo's secret
# KEY_<REPO>. Re-running replaces the key. The private half is never
# persisted to disk.
#   bash scripts/add-repo.sh <repo>
set -euo pipefail
repo="${1:?usage: add-repo.sh <repo>}"
builder="${V15_BUILDER:-Emmet-v15/v15-build}"
case "$repo" in *[!A-Za-z0-9._-]*) echo "a repository name under Emmet-v15"; exit 1 ;; esac
name="KEY_$(echo "$repo" | tr 'a-z.-' 'A-Z__')"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# an earlier key of this builder is removed first
for id in $(gh repo deploy-key list --repo "Emmet-v15/$repo" --json id,title -q '.[] | select(.title == "v15-build") | .id' | tr -d '\r'); do
  gh repo deploy-key delete "$id" --repo "Emmet-v15/$repo"
done
ssh-keygen -q -t ed25519 -N '' -C "v15-build:$repo" -f "$tmp/key"
gh repo deploy-key add "$tmp/key.pub" --repo "Emmet-v15/$repo" --title v15-build
gh secret set "$name" --repo "$builder" < "$tmp/key"
echo "$repo: read-only key added, secret $name set"
