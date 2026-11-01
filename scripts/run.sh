#!/usr/bin/env bash
# After fetch.sh removes the keys, the platform's own commands
# (ops/build.json, the PLATFORM section) run in the repository's root.
#   run.sh check   its "check" commands
#   run.sh build   its "build" commands, with V15_BUILD_ID (the build id)
#                  and V15_OUT (the folder its files go to); then each of
#                  the release's files for the platform ("release" → the
#                  platform → "files", else the section's "outputs") must be
#                  there
# The app secrets the section names ("secrets") are in the environment
# under their names, from N1..N4 and S1..S4. Each command's output is
# written to a file; only error lines are displayed (the log is public).
#
# LOCAL=1 (scripts/local.sh): on the owner's machine, in a worktree at the
# commit; the same commands.
set -uo pipefail
mode="${1:?usage: run.sh check|build}"
top="${V15_TOP:-$PWD}"
cd "${V15_SRC:-src}"
cfg=ops/build.json
q() { jq -r --arg p "$PLATFORM" "$1" "$cfg" | tr -d '\r'; }

for i in 1 2 3 4; do
  n="N$i" s="S$i"
  [ -n "${!n:-}" ] || continue
  export "${!n}=${!s:-}"
  unset "$s"
done

case "$mode" in
  check) cmds=${V15_CMDS-$(q '.[$p].check[]? // empty')} ;;
  build)
    case "${V15_BUILD_ID:-}" in '' | *[!0-9]*) echo "build id must be digits"; exit 1 ;; esac
    export V15_BUILD_ID
    export V15_OUT="${V15_OUT:-$top/out}"
    mkdir -p "$V15_OUT"
    cmds=${V15_CMDS-$(q '.[$p].build[]? // empty')}
    [ -n "$cmds" ] || { echo "ops/build.json: \"$PLATFORM\" has no \"build\" commands"; exit 1; }
    ;;
  *) echo "usage: run.sh check|build"; exit 1 ;;
esac

log="$top/$mode.log"
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  t=$(date +%s)
  if bash -c "$cmd" > "$log" 2>&1 < /dev/null; then
    echo "ok ($(($(date +%s) - t)) s): $cmd"
  else
    echo "::error::$cmd"
    # error lines only; if none exist, the log's last lines
    grep -iE "^ *error|error:|error\[|FAILED|^E:|not ok|What went wrong|^\* " "$log" | head -40 | grep . || tail -15 "$log"
    exit 1
  fi
done <<< "$cmds"

if [ "$mode" = build ]; then
  files=${V15_FILES-$(q '(.release[$p].files // .[$p].outputs // [])[]')}
  [ -n "$files" ] || { echo "ops/build.json: no files for $PLATFORM (\"release\" → \"$PLATFORM\" → \"files\")"; exit 1; }
  for f in $files; do
    case "$f" in *[!A-Za-z0-9._-]*) echo "files: names, not paths: $f"; exit 1 ;; esac
    [ -f "$V15_OUT/$f" ] || { echo "::error::$PLATFORM: the build made no $f"; exit 1; }
  done
  # only the release's files leave the runner
  for f in "$V15_OUT"/*; do
    case " $(echo $files) " in *" $(basename "$f") "*) ;; *) rm -rf "$f" ;; esac
  done
fi
exit 0
