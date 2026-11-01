#!/usr/bin/env bash
# Sets one of the app's own secrets (ops/build.json "secrets", "mask",
# "keychain"), NAME_<APP>, from a local file or stdin; it is never printed.
# --base64 stores the file base64-encoded (a .p12).
#   bash scripts/app-secret.sh <app repo> <NAME> <file> [--base64]
#   printf %s value | bash scripts/app-secret.sh <app repo> <NAME> -
set -euo pipefail
app="${1:?usage: app-secret.sh <app repo> <NAME> <file|-> [--base64]}"
name="${2:?usage: app-secret.sh <app repo> <NAME> <file|-> [--base64]}"
file="${3:?usage: app-secret.sh <app repo> <NAME> <file|-> [--base64]}"
builder="${V15_BUILDER:-Emmet-v15/v15-build}"
case "$app" in *[!A-Za-z0-9._-]*) echo "a repository name under Emmet-v15"; exit 1 ;; esac
case "$name" in '' | *[!A-Z0-9_]*) echo "NAME: A-Z, 0-9, _"; exit 1 ;; esac
secret="${name}_$(echo "$app" | tr 'a-z.-' 'A-Z__')"
if [ "${4:-}" = --base64 ]; then
  base64 -w0 "$file" | gh secret set "$secret" --repo "$builder"
elif [ "$file" = - ]; then
  tr -d '\r\n' | gh secret set "$secret" --repo "$builder"
else
  # (a trailing line break is not part of a password)
  tr -d '\r\n' < "$file" | gh secret set "$secret" --repo "$builder"
fi
echo "$app: secret $secret set"
