#!/usr/bin/env bash
# While the keys are present, it fetches all build dependencies, then
# deletes the keys before any app code (build scripts, tests, npm install
# scripts) executes.
set -euo pipefail
cd src

# DIR: the Cargo workspace's folder (ops/build.json "dir", from source.sh)
if [ -f "${DIR:-.}/Cargo.lock" ]; then
  # Tried three times: a network fault isn't the app's
  ok=0
  for n in 1 2 3; do
    (cd "${DIR:-.}" && cargo fetch --locked) > ../fetch.log 2>&1 && { ok=1; break; }
    grep -qE "lock file|--locked" ../fetch.log && break
    [ "$n" = 3 ] || sleep $((n * 20))
  done
  [ "$ok" = 1 ] || { grep -E "error|failed|denied" ../fetch.log | head -20; exit 1; }
fi

rm -rf "$RUNNER_TEMP/keys" ~/.ssh/config
# (awk and sed written as macOS's accept them too)
git config --global --get-regexp '^url\.' | awk '{print $1}' | sed -E 's/\.[iI]nstead[oO]f$//' | sort -u | while read -r s; do
  git config --global --remove-section "$s"
done

if [ -f package-lock.json ]; then
  npm ci --no-audit --no-fund > ../npm.log 2>&1 || { grep -iE "err" ../npm.log | head -20; exit 1; }
fi
# none of the keys remain
[ ! -e "$RUNNER_TEMP/keys" ] && ! git config --global --get-regexp '^url\.' > /dev/null || { echo "the keys were not removed"; exit 1; }
