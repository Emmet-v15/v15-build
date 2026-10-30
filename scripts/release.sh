#!/usr/bin/env bash
# The release exe: the "package" in ops/build.json, built with
# V15_BUILD_ID, with its "exe" copied to out/ (encrypted by the next
# step).
set -euo pipefail
case "$V15_BUILD_ID" in '' | *[!0-9]*) echo "build id must be digits"; exit 1 ;; esac
cd src
export CARGO_NET_OFFLINE=true
pkg=$(jq -r '.package // empty' ops/build.json 2>/dev/null | tr -d '\r' || true)
exe=$(jq -r '.exe // empty' ops/build.json 2>/dev/null | tr -d '\r' || true)
[ -n "$pkg" ] && [ -n "$exe" ] || { echo "ops/build.json needs \"package\" and \"exe\" for a release"; exit 1; }
case "$exe" in *[!A-Za-z0-9._-]*) echo "exe: a file name"; exit 1 ;; esac
cargo build --release --locked -p "$pkg" > ../build.log 2>&1 || { grep -E "^error" ../build.log | head -20; exit 1; }
mkdir -p ../out
cp "target/release/$exe" ../out/
