#!/usr/bin/env bash
# The release exe is the "package" in ops/build.json, built in its "dir"
# using V15_BUILD_ID (and its "features"), with its "exe" copied to out/
# (encrypted by the next step). Its "before_release" commands run first in
# the repository's root (e.g., building a web UI the exe embeds).
set -euo pipefail
case "$V15_BUILD_ID" in '' | *[!0-9]*) echo "build id must be digits"; exit 1 ;; esac
top=$PWD
cd src
export CARGO_NET_OFFLINE=true
cfg=ops/build.json
pkg=$(jq -r '.package // empty' "$cfg" 2>/dev/null | tr -d '\r' || true)
exe=$(jq -r '.exe // empty' "$cfg" 2>/dev/null | tr -d '\r' || true)
[ -n "$pkg" ] && [ -n "$exe" ] || { echo "ops/build.json needs \"package\" and \"exe\" for a release"; exit 1; }
case "$exe" in *[!A-Za-z0-9._-]*) echo "exe: a file name"; exit 1 ;; esac
features=$(jq -r '.features // [] | join(",")' "$cfg" | tr -d '\r')
case "$features" in *[!A-Za-z0-9_/,-]*) echo "features: cargo feature names"; exit 1 ;; esac

jq -r '.before_release[]? // empty' "$cfg" | tr -d '\r' | while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  bash -c "$cmd" > "$top/before.log" 2>&1 || { echo "::error::$cmd"; grep -iE "fail|error" "$top/before.log" | head -20; exit 1; }
done

cd "${DIR:-.}"
cargo build --release --locked -p "$pkg" ${features:+--features "$features"} > "$top/build.log" 2>&1 \
  || { grep -E "^error" "$top/build.log" | head -20; exit 1; }
mkdir -p "$top/out"
cp "target/release/$exe" "$top/out/"
