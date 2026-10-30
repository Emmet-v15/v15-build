#!/usr/bin/env bash
# Sets the key used to encrypt an app's release exe (secret
# ARTIFACT_<REPO>) from the app's own key file, such as
# state/build-artifacts.key. If the file is missing, it creates one
# first.
#   bash scripts/artifact-key.sh <repo> <key file>
set -euo pipefail
repo="${1:?usage: artifact-key.sh <repo> <key file>}"
file="${2:?usage: artifact-key.sh <repo> <key file>}"
builder="${V15_BUILDER:-Emmet-v15/v15-build}"
case "$repo" in *[!A-Za-z0-9._-]*) echo "a repository name under Emmet-v15"; exit 1 ;; esac
if [ ! -f "$file" ]; then
  mkdir -p "$(dirname "$file")"
  # Git Bash's openssl appends CR LF to the output; GitHub trims the secret, but the file
  # does not.
  openssl rand -base64 48 | tr -d '\r\n' > "$file"
fi
tr -d '\r\n' < "$file" | gh secret set "ARTIFACT_$(echo "$repo" | tr 'a-z.-' 'A-Z__')" --repo "$builder"
echo "$repo: artifact key set"
