#!/usr/bin/env bash
# An app's tests, run the same way everywhere: the "test" commands in its
# ops/build.json, in the repository's root, in order. On this PC it is the
# one test command for every app; the builder runs this same file in each
# run's Windows job (check.sh, run.sh), so passing here means passing there.
# Every cargo command must pass --locked (or --frozen): a test never moves
# Cargo.lock.
#   bash test.sh [app]   the app's folder (any folder inside it), or its name
#                        beside this repository; default: the current folder
# Each command's output goes to a file and only its error lines are shown
# (the builder's log is public). Every command runs; it exits 1 if any
# failed. On this PC cargo gets the RAM rule (ram.sh) before each command.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
app="${1:-.}"
[ -d "$app" ] || app="$here/../../$app"
top=$(git -C "$app" rev-parse --show-toplevel 2> /dev/null) || { echo "test: no repository at ${1:-.}"; exit 1; }
cd "$top"
cfg=ops/build.json
[ -f "$cfg" ] || { echo "test: $top has no $cfg"; exit 1; }
cmds=$(node -e '
  const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const t = c.test;
  if (!Array.isArray(t) || !t.length || t.some((x) => typeof x !== "string" || !x.trim() || /[\r\n]/.test(x))) {
    console.error("test: ops/build.json needs \"test\", a list of commands (v15-build README.md, \"Tests\")");
    process.exit(1);
  }
  for (const x of t)
    for (const part of x.split(/&&|\|\||;|\|/))
      if (/\bcargo\s+(\+\S+\s+)?(build|check|test|clippy|run|bench|doc|nextest)\b/.test(part) && !/\s--(locked|frozen)\b/.test(part)) {
        console.error("test: cargo without --locked: " + x);
        process.exit(1);
      }
  console.log(t.join("\n"));
' "$cfg" | tr -d '\r') || exit 1
[ -n "$cmds" ] || exit 1

ci=${GITHUB_ACTIONS:-}
logs="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/v15-test/$(basename "$top")"
rm -rf "$logs"
mkdir -p "$logs"
[ -n "$ci" ] || source "$here/ram.sh"
n=0 failed=0
while IFS= read -r cmd; do
  n=$((n + 1))
  log="$logs/$n.log"
  [ -n "$ci" ] || v15_jobs
  t=$(date +%s)
  if bash -c "$cmd" > "$log" 2>&1 < /dev/null; then
    echo "ok ($(($(date +%s) - t)) s): $cmd"
  else
    failed=$((failed + 1))
    if [ -n "$ci" ]; then echo "::error::$cmd"; else echo "FAILED ($(($(date +%s) - t)) s): $cmd"; fi
    # error lines only; if none exist, the log's last lines
    grep -iE "^ *error|error:|error\[|FAILED|panicked at|^E |not ok|Traceback|What went wrong|^\* " "$log" | head -40 | grep . || tail -15 "$log"
    [ -n "$ci" ] || echo "   the whole output: $(cygpath -w "$log" 2> /dev/null || echo "$log")"
  fi
done <<< "$cmds"

if [ "$failed" = 0 ]; then
  echo "test: $(basename "$top"), all $n passed"
else
  echo "test: $(basename "$top"), $failed of $n failed"
  exit 1
fi
