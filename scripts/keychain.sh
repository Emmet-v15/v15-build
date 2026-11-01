#!/usr/bin/env bash
# ops/build.json "keychain" (macOS): the app's signing certificate (a
# base64 .p12 in CERT, password in PW) is placed in a keychain created for
# this run and trusted for code signing only on this runner, allowing
# codesign and Tauri's bundler to accept it (via APPLE_SIGNING_IDENTITY in
# the app's build commands). If IDENTITY is provided, it must match the
# certificate's signing name.
set -euo pipefail
[ -n "${CERT:-}" ] && [ -n "${PW:-}" ] || { echo "keychain: the app's certificate and password secrets are empty"; exit 1; }
echo "$CERT" | base64 --decode > "$RUNNER_TEMP/cert.p12"
kc="$RUNNER_TEMP/sign.keychain-db"
security create-keychain -p ci "$kc"
security set-keychain-settings "$kc"
security unlock-keychain -p ci "$kc"
# shellcheck disable=SC2046
security list-keychains -d user -s "$kc" $(security list-keychains -d user | tr -d '"')
security import "$RUNNER_TEMP/cert.p12" -k "$kc" -P "$PW" -T /usr/bin/codesign > /dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k ci "$kc" > /dev/null
openssl pkcs12 -in "$RUNNER_TEMP/cert.p12" -nokeys -passin env:PW -out "$RUNNER_TEMP/cert.pem" 2>/dev/null \
  || openssl pkcs12 -legacy -in "$RUNNER_TEMP/cert.p12" -nokeys -passin env:PW -out "$RUNNER_TEMP/cert.pem"
sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$RUNNER_TEMP/cert.pem"
rm -f "$RUNNER_TEMP/cert.p12" "$RUNNER_TEMP/cert.pem"
if [ -n "${IDENTITY:-}" ]; then
  security find-identity -v -p codesigning "$kc" | grep -qF "\"$IDENTITY\"" || { echo "keychain: the certificate is not \"$IDENTITY\""; exit 1; }
fi
echo "keychain: a signing identity"
