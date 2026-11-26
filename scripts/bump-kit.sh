#!/usr/bin/env bash
# Moves apps to a v15-kit release: each Cargo.toml's kit dependency (a tag,
# rev or branch) becomes the release's tag, Tauri's exact pins become the
# kit's, the Cargo.lock files that hold the kit are updated for it alone, and
# the app's tests run (test.sh). Nothing is committed. From v0.9.0 the kit
# holds v15-notify: a dependency on its old repository moves to the kit's (the
# same tag, so one copy), and ops/build.json's "deps" drops "v15-notify".
#
#   bash bump-kit.sh [--to vX.Y.Z] [--no-test] <app>...
#                    an app is its folder, or its name beside this repository;
#                    default --to: the kit's newest tag
#
# An app with uncommitted changes to a Cargo.toml or Cargo.lock is skipped, so
# the bump is a change of its own. Exits 1 if any app was skipped or failed.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KIT_REPO=Emmet-v15/v15-kit
to="" test=1 apps=()
while [ $# -gt 0 ]; do
  case "$1" in
    --to) to="$2"; shift 2 ;;
    --no-test) test=0; shift ;;
    -*) echo "bump-kit: unknown option $1"; exit 2 ;;
    *) apps+=("$1"); shift ;;
  esac
done
[ ${#apps[@]} -gt 0 ] || { echo "usage: bump-kit.sh [--to vX.Y.Z] [--no-test] <app>..."; exit 2; }
command -v gh > /dev/null || { echo "bump-kit: needs gh, signed in"; exit 1; }

if [ -z "$to" ]; then
  to=$(gh api "repos/$KIT_REPO/tags" -q '.[].name' | tr -d '\r' | grep -E '^v[0-9]+(\.[0-9]+)*$' | sort -V | tail -1)
  [ -n "$to" ] || { echo "bump-kit: can't read $KIT_REPO's tags"; exit 1; }
fi
case "$to" in v*) ;; *) to="v$to" ;; esac
# the kit's Tauri pins at that tag (tauri-build moves with tauri-plugin)
kit_toml=$(gh api "repos/$KIT_REPO/contents/Cargo.toml?ref=$to" -H "Accept: application/vnd.github.raw" | tr -d '\r') ||
  { echo "bump-kit: no $to in $KIT_REPO"; exit 1; }
tauri=$(sed -n 's/^tauri = {[^}]*version = "=\([0-9.]*\)".*/\1/p' <<< "$kit_toml")
plugin=$(sed -n 's/^tauri-plugin = {[^}]*version = "=\([0-9.]*\)".*/\1/p' <<< "$kit_toml")
[ -n "$tauri" ] && [ -n "$plugin" ] || { echo "bump-kit: no exact tauri / tauri-plugin pins in $to's Cargo.toml"; exit 1; }
echo "bump-kit: to $to (tauri =$tauri, tauri-build =$plugin)"
# 0.9.0 and later: v15-notify is the kit's
notify=0
[ "$(printf '%s\n%s\n' "${to#v}" 0.9.0 | sort -V | head -1)" = 0.9.0 ] && notify=1

failed=()
for app in "${apps[@]}"; do
  dir=$app
  [ -d "$dir" ] || dir="$here/../../$app"
  top=$(git -C "$dir" rev-parse --show-toplevel 2> /dev/null) || { echo "$app: no repository"; failed+=("$app"); continue; }
  name=$(basename "$top")
  if [ -n "$(git -C "$top" status --porcelain -- '*Cargo.toml' '*Cargo.lock' 'Cargo.toml' 'Cargo.lock')" ]; then
    echo "$name: skipped, uncommitted changes to a Cargo.toml or Cargo.lock"
    failed+=("$name")
    continue
  fi
  tomls=$(cd "$top" && git ls-files -- '*Cargo.toml' 'Cargo.toml' | tr -d '\r' | while read -r f; do grep -lE 'Emmet-v15/v15-(kit|notify)"' "$f"; done)
  [ -n "$tomls" ] || { echo "$name: no Cargo.toml depends on the kit"; continue; }
  for f in $tomls; do
    # the kit by tag, whatever pinned it before; Tauri's exact pins as the kit's
    TO=$to TAURI=$tauri PLUGIN=$plugin NOTIFY=$notify perl -pi -e '
      if ($ENV{NOTIFY} && /Emmet-v15\/v15-notify"/) { s/Emmet-v15\/v15-notify"/Emmet-v15\/v15-kit"/; }
      if (/Emmet-v15\/v15-kit"/) { s/\b(?:tag|rev|branch)\s*=\s*"[^"]*"/tag = "$ENV{TO}"/; }
      s/^(tauri\s*=\s*(?:\{[^}]*?version\s*=\s*)?)"=[0-9.]+"/$1"=$ENV{TAURI}"/;
      s/^(tauri-build\s*=\s*(?:\{[^}]*?version\s*=\s*)?)"=[0-9.]+"/$1"=$ENV{PLUGIN}"/;
    ' "$top/$f"
  done
  ok=1
  # Tauri is updated only when its pins moved: unlocking it otherwise
  # reshuffles its dependencies' versions for nothing
  want="v15-shell v15-update v15-release"
  [ "$notify" = 1 ] && want="$want v15-notify"
  # shellcheck disable=SC2086
  git -C "$top" diff -- $tomls | grep -qE '^\+tauri(-build)? *=' && want="$want tauri tauri-build"
  # each lock that holds the kit, updated for the kit (and Tauri) alone
  for lock in $(cd "$top" && git ls-files -- '*Cargo.lock' 'Cargo.lock' | tr -d '\r'); do
    grep -qE 'Emmet-v15/v15-(kit|notify)' "$top/$lock" || continue
    ldir=$(dirname "$top/$lock")
    pkgs=""
    for p in $want; do grep -q "^name = \"$p\"\$" "$top/$lock" && pkgs="$pkgs -p $p"; done
    # shellcheck disable=SC2086
    if ! out=$(cd "$ldir" && cargo update -q $pkgs 2>&1 && cargo metadata --locked --format-version 1 2>&1 > /dev/null); then
      echo "$name: $lock doesn't resolve with $to:"
      grep -E "error|failed|required by" <<< "$out" | head -10
      ok=0
    fi
  done
  # the builder no longer fetches v15-notify on its own
  if [ "$notify" = 1 ] && [ -f "$top/ops/build.json" ]; then
    perl -0pi -e 's/,\s*"v15-notify"//; s/"v15-notify"\s*,\s*//; s/\[\s*"v15-notify"\s*\]/[]/' "$top/ops/build.json"
  fi
  if [ "$ok" = 1 ] && ! kout=$(bash "$here/kit.sh" "$top"); then echo "$kout"; ok=0; fi
  if [ "$ok" = 1 ] && [ "$test" = 1 ]; then
    if [ -f "$top/ops/build.json" ]; then bash "$here/test.sh" "$top" || ok=0
    else echo "$name: no ops/build.json, so no tests ran"; fi
  fi
  if [ "$ok" = 1 ]; then echo "$name: on $to ($(git -C "$top" diff --stat -- "*Cargo.toml" "*Cargo.lock" | tail -1 | sed 's/^ *//'))"
  else failed+=("$name"); fi
done

[ ${#failed[@]} = 0 ] || { echo "bump-kit: not done: ${failed[*]}"; exit 1; }
