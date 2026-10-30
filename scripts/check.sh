#!/usr/bin/env bash
# Runs the app's checks offline, after fetch.sh retrieves everything: the
# "checks" field in ops/build.json (defaulting to fmt, clippy, test), within
# its "dir", followed by its "commands" at the repository's root. Each check
# saves its full output to a file and displays only error lines (logs are
# public).
set -uo pipefail
cd src
export CARGO_NET_OFFLINE=true
cfg=ops/build.json
checks="fmt clippy test"
commands=""
# jq on the Windows runner ends lines with CR LF
if [ -f "$cfg" ]; then
  checks=$(jq -r 'if .checks then .checks[] else "fmt", "clippy", "test" end' "$cfg" | tr -d '\r')
  commands=$(jq -r '.commands[]? // empty' "$cfg" | tr -d '\r')
fi
failed=0
top=$(dirname "$PWD")

cd "${DIR:-.}"
for c in $checks; do
  case "$c" in
    fmt) cargo fmt --all --check > "$top/fmt.log" 2>&1 || { echo "::error::fmt"; grep -E "^Diff in" "$top/fmt.log" | head -20; failed=1; } ;;
    clippy) cargo clippy --workspace --all-targets --locked -- -D warnings > "$top/clippy.log" 2>&1 || {
      echo "::error::clippy"
      grep -E "^(error|warning)|^ *--> " "$top/clippy.log" | head -40
      failed=1
    } ;;
    test)
      if cargo test --workspace --locked > "$top/test.log" 2>&1; then
        grep -E "^test result" "$top/test.log"
      else
        echo "::error::test"
        grep -E "^test .* FAILED|panicked at|^error|^test result" "$top/test.log" | head -40
        failed=1
      fi
      ;;
    *) echo "unknown check $c"; failed=1 ;;
  esac
done
cd "$top/src"

printf '%s\n' "$commands" | while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  if bash -c "$cmd" > ../cmd.log 2>&1; then
    echo "ok: $cmd"
  else
    echo "::error::$cmd"
    grep -iE "fail|error|not ok" ../cmd.log | head -30
    exit 1
  fi
done || failed=1

exit $failed
