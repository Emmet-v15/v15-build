#!/usr/bin/env bash
# Which v15-kit an app builds with: every Cargo.lock in its repository is
# read (the lock is what builds, kit crates pulled in through another
# dependency included).
#
#   bash kit.sh [app folder]     default: the current folder
#
# It fails (exit 1) when a lock holds a kit older than FLOOR, the oldest kit
# every app must ship with, or a kit that isn't a git dependency (a path to a
# local copy builds only on this PC). It warns, and passes, when the kit is
# older than its newest tag: KIT_LATEST, otherwise v15-kit's tags as gh sees
# them (on the builder, which can't see them, there is no warning).
#
# FLOOR moves only for a kit release every app must ship: a security fix, the
# update protocol, a broken self-update. Raising it stops every app behind it
# from checking or releasing until it moves (bump-kit.sh).
set -uo pipefail
FLOOR=0.6.3
KIT_REPO=Emmet-v15/v15-kit

app="${1:-.}"
top=$(git -C "$app" rev-parse --show-toplevel 2> /dev/null) || { echo "kit: no repository at $app"; exit 1; }
cd "$top"
ci=${GITHUB_ACTIONS:-}
err() { if [ -n "$ci" ]; then echo "::error::kit: $*"; else echo "kit: $*"; fi; }
note() { if [ -n "$ci" ]; then echo "::warning::kit: $*"; else echo "kit: warning: $*"; fi; }
older() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }

latest=${KIT_LATEST:-}
if [ -z "$latest" ] && [ -z "$ci" ] && command -v gh > /dev/null; then
  latest=$(gh api "repos/$KIT_REPO/tags" -q '.[].name' 2> /dev/null | tr -d '\r' | sed -n 's/^v\([0-9][0-9.]*\)$/\1/p' | sort -V | tail -1)
fi
latest=${latest#v}

failed=0
seen=0
# the kit's own repository builds its crates by path (the notify host)
self=0
[ -f crates/v15-shell/Cargo.toml ] && [ -f crates/v15-update/Cargo.toml ] && self=1
bump="bash ~/projects/v15-build/scripts/bump-kit.sh $(basename "$top")"
while IFS= read -r lock; do
  [ -n "$lock" ] || continue
  # "kit <version> <source>" for the kit's crates (a path dependency has no
  # source), "notify <version>" for v15-notify from its old repository
  newest="" old_notify=""
  while read -r kind version source; do
    if [ "$kind" = notify ]; then
      old_notify=$version
      continue
    fi
    [ "$source" = "-" ] && [ "$self" = 1 ] && continue
    seen=1
    if [ "$source" = "-" ]; then
      err "$lock: the kit is a path dependency on a local copy; use its git tag"
      failed=1
      continue
    fi
    { [ -z "$newest" ] || older "$newest" "$version"; } && newest=$version
    if older "$version" "$FLOOR"; then
      err "$lock: the kit is $version, older than the floor, $FLOOR: $bump"
      failed=1
    elif [ -n "$latest" ] && older "$version" "$latest"; then
      note "$lock: the kit is $version, its latest is $latest: $bump"
      seen=2
    fi
  done < <(tr -d '\r' < "$lock" | awk '
    function out() {
      if (s ~ /Emmet-v15\/v15-notify/) { if (n == "v15-notify") print "notify", v, s }
      else if ((s == "" || s ~ /Emmet-v15\/v15-kit/) && (n == "v15-shell" || n == "v15-update" || n == "v15-release" || n == "v15-notify"))
        print "kit", v, (s == "" ? "-" : s)
    }
    /^\[\[package\]\]/ { if (n != "") out(); n = ""; v = ""; s = "" }
    /^name = / { n = $3; gsub(/"/, "", n) }
    /^version = / { v = $3; gsub(/"/, "", v) }
    /^source = / { s = $3; gsub(/"/, "", s) }
    END { if (n != "") out() }' | sort -u)
  # v15-notify is part of the kit from 0.9.0: its old repository's copy beside
  # the kit's would be a second client (and duplicate JNI symbols on Android)
  if [ -n "$old_notify" ]; then
    if [ -n "$newest" ] && ! older "$newest" 0.9.0; then
      err "$lock: v15-notify $old_notify from its old repository beside the kit's own: $bump"
      failed=1
    else
      note "$lock: v15-notify comes from the kit from 0.9.0 on (its old repository is retired): $bump"
      seen=2
    fi
  fi
done < <(git ls-files -- '*Cargo.lock' 'Cargo.lock' | tr -d '\r')

if [ "$failed" = 0 ] && [ "$seen" = 1 ] && [ -z "$ci" ]; then
  echo "kit: ok (floor $FLOOR${latest:+, latest $latest})"
fi
exit $failed
