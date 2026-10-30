#!/usr/bin/env bash
# While the keys are present, it fetches all build dependencies, then
# deletes the keys before any app code (build scripts, tests, npm install
# scripts) executes.
set -euo pipefail
cd src

if [ -f Cargo.lock ]; then
  cargo fetch --locked > ../fetch.log 2>&1 || { grep -E "error|failed|denied" ../fetch.log | head -20; exit 1; }
fi

rm -rf "$RUNNER_TEMP/keys" ~/.ssh/config
git config --global --get-regexp '^url\.' | sed -E 's/\.insteadof .*//I' | sort -u | while read -r s; do
  git config --global --remove-section "$s"
done

if [ -f package-lock.json ]; then
  npm ci --no-audit --no-fund > ../npm.log 2>&1 || { grep -iE "err" ../npm.log | head -20; exit 1; }
fi
