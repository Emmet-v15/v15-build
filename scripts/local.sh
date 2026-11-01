#!/usr/bin/env bash
# Set `LOCAL=1` in `publish.sh` to build one platform's release files on
# this PC instead of the builder, using the same method: a clean worktree
# at the commit, the app's npm packages, and then, for a Windows app in its
# original form, its "before_release" commands and the same `cargo build`
# (package, features, `V15_BUILD_ID`), or for a platform section, its
# "build" commands (`scripts/run.sh`). This is limited to Windows and
# Android (as this is a Windows PC).
#   bash local.sh <app repo> <sha> <build id> <platform> <out dir>
# The RAM rule: cargo receives floor((free GB - 6) / 1.5) jobs, with a
# minimum of 1, and is limited to 1 job while another build (rustc, cargo,
# java, gradle) runs.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
top="${1:?usage: local.sh <app repo> <sha> <build> <platform> <out>}"
sha="${2:?}" build="${3:?}" platform="${4:?}" out="${5:?}"
case "$platform" in windows | android) ;; *) echo "local: $platform can't be built on this PC"; exit 1 ;; esac
cd "$top"
j() {
  node -e '
    const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const r = new Function("c", "return (" + process.argv[2] + ")")(c);
    if (r === undefined || r === null) process.exit(0);
    console.log(Array.isArray(r) ? r.join("\n") : String(r));
  ' "$1" "$2" | tr -d '\r'
}

free=$(powershell -NoProfile -Command "[math]::Floor((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB * 10) / 10" | tr -d '\r')
jobs=$(awk -v f="$free" 'BEGIN { j = int((f - 6) / 1.5); print (j < 1 ? 1 : j) }')
busy=$(tasklist 2>/dev/null | grep -ciE "^(rustc|cargo|java|gradle)" || true)
[ "$busy" = 0 ] || jobs=1
echo "local: $platform, $free GB free, $busy other build processes: $jobs cargo jobs"
export CARGO_BUILD_JOBS=$jobs

work="$top/state/release/$build/local-$platform"
rm -rf "$work"
mkdir -p "$work"
git worktree add -q --detach "$work/src" "$sha"
cleanup() { git -C "$top" worktree remove --force "$work/src" 2>/dev/null || true; }
trap cleanup EXIT
cd "$work/src"
cfg=ops/build.json
dir=$(j "$cfg" 'c.dir || "."')
if [ -f package-lock.json ]; then
  npm ci --no-audit --no-fund > "$work/npm.log" 2>&1 || { grep -iE "err" "$work/npm.log" | head -20; exit 1; }
fi
mkdir -p "$out"

if [ -z "$(j "$cfg" "c['$platform'] && 'y'")" ]; then
  # the original form (scripts/release.sh)
  pkg=$(j "$cfg" 'c.package') exe=$(j "$cfg" 'c.exe') features=$(j "$cfg" '(c.features || []).join(",")')
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    bash -c "$cmd" > "$work/before.log" 2>&1 || { echo "local: $cmd failed"; grep -iE "fail|error" "$work/before.log" | head -20; exit 1; }
  done <<< "$(j "$cfg" 'c.before_release || []')"
  # the main checkout's target folder: its release build is warm
  export CARGO_TARGET_DIR="$top/$dir/target"
  (cd "$dir" && V15_BUILD_ID=$build cargo build --release --locked -p "$pkg" ${features:+--features "$features"}) > "$work/build.log" 2>&1 \
    || { grep -E "^error" "$work/build.log" | head -20; exit 1; }
  cp "$CARGO_TARGET_DIR/release/$exe" "$out/"
else
  # a platform section: its "build" commands, in the order the builder
  # executes them
  V15_CMDS=$(j "$cfg" "c['$platform'].build || []") \
  V15_FILES=$(j "$cfg" "(c.release && c.release['$platform'] && c.release['$platform'].files) || c['$platform'].outputs || []") \
    PLATFORM=$platform V15_TOP="$work" V15_SRC="$work/src" V15_OUT="$out" V15_BUILD_ID=$build \
    bash "$here/run.sh" build
fi
echo "local: $platform built"
