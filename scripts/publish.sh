#!/usr/bin/env bash
# Each app release follows the same procedure (README.md, "A release"): run
# preflight, build on the builder (or locally with LOCAL=1), sign locally,
# release on GitHub, and install via empire's release-pull. This process is
# controlled by the "release" section in the app's ops/build.json.
#
#   bash ../v15-build/scripts/publish.sh <app repo>
#   DRY=1      build and sign only (state/release/<build>/), nothing released;
#              files that need no signing here stay on the builder (their
#              hashes are read from its log)
#   LOCAL=1    build here instead of on the builder (a GitHub outage or a
#              billing block): the same commands, under the RAM rule; the
#              platforms this PC can't build wait for a later run
#   BUILD=<id> resume that build: whatever already happened (built, signed,
#              released on GitHub, installed) is skipped
#   NOTES=...  the release notes the app shows
#   REMOTE=... the server with release-pull (default empire)
#
# Requires gh signed in, node, openssl, v15-release (v15-kit), and ssh to
# REMOTE. Also requires the app's state/ directory (which is gitignored; a
# worktree uses its main checkout's state/), containing update-signing.pem
# (the update key) and build-artifacts.key (the builder's encryption key,
# scripts/artifact-key.sh).
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=dispatch.sh
source "$here/dispatch.sh"
cd "${1:?usage: publish.sh <app repo>}"
cd "$(git rev-parse --show-toplevel)"
top=$PWD
DRY="${DRY:-0}"
LOCAL="${LOCAL:-0}"
REMOTE="${REMOTE:-empire}"
NOTES="${NOTES:-}"
CFG=ops/build.json
PLATFORMS_ALL="windows linux macos ios android"

say() { echo "publish: $*"; }
die() { echo "publish: $*" >&2; exit 1; }
# a JavaScript expression over ops/build.json (c): a string, or one line per
# array item
j() {
  node -e '
    const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const r = new Function("c", "return (" + process.argv[2] + ")")(c);
    if (r === undefined || r === null) process.exit(0);
    console.log(Array.isArray(r) ? r.join("\n") : typeof r === "object" ? JSON.stringify(r) : String(r));
  ' "$1" "$2" | tr -d '\r'
}
cfg() { j "$CFG" "$1"; }
# the main checkout (state/, keystores: gitignored, so not in a worktree)
main_root=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
local_file() { if [ -e "$top/$1" ]; then echo "$top/$1"; else echo "$main_root/$1"; fi; }

[ -f "$CFG" ] || die "no $CFG"
command -v node > /dev/null || die "no node"
[ -n "$(cfg 'c.release && c.release.app')" ] || die "$CFG has no \"release\" section (README.md, \"A release\")"
APP=$(cfg 'c.release.app')
PUBKEY=$(cfg 'c.release.pubkey')
SITE=$(cfg 'c.release.site || "https://v15.studio/" + c.release.app')
MANIFEST=$(cfg 'c.release.manifest || "manifest.json"')
BASE=$(cfg 'c.release.base || ""')
[ -n "$BASE" ] || BASE="$SITE/manifest.json"
PACKAGE=$(cfg 'c.release.package || c.package || ""')
DIR=$(cfg 'c.dir || "."')
REPO=$(git remote get-url origin | sed -E 's#\.git$##; s#.*[/:]##')
PLATFORMS=""
for p in $PLATFORMS_ALL; do [ -n "$(cfg "c.release.$p && 'y'")" ] && PLATFORMS="$PLATFORMS $p"; done
PULLS=$(cfg "c.release.pull || ['ops/' + c.release.app + '.json']")
files_of() { cfg "(c.release.$1.files || [])"; }
EXE=$(files_of windows | head -1)
EXE_URL=$(cfg 'c.release.windows && c.release.windows.url || ""')
[ -n "$EXE" ] && [ -z "$EXE_URL" ] && EXE_URL="$SITE/$EXE"
APK=$(cfg 'c.release.android && c.release.android.sign ? c.release.android.files[0] : ""')
# Files for a platform signed here are downloaded; the others remain on the
# builder until released.
signed_here() { case "$1" in windows) [ -n "$EXE" ] ;; android) [ -n "$APK" ] ;; *) return 1 ;; esac; }

# ── preflight: verifies all items before the build begins ─────────────────
problems=()
warn=()
problem() { problems+=("$1"); }
command -v gh > /dev/null && gh auth status > /dev/null 2>&1 || problem "gh is not signed in: gh auth login"
command -v v15-release > /dev/null || problem "no v15-release: cargo install --git https://github.com/Emmet-v15/v15-kit v15-release"
command -v openssl > /dev/null || problem "no openssl (Git Bash has one)"
[ -n "$PLATFORMS" ] || problem "\"release\" names no platform (windows, linux, macos, ios, android)"
case "$PUBKEY" in *[!0-9a-f]* | "") problem "release.pubkey: the 64 hex digits the app compiles in" ;; esac
[ ${#PUBKEY} = 64 ] || problem "release.pubkey: 64 hex digits"
[ -n "$PACKAGE" ] || problem "release.package (or \"package\"): the Cargo package whose version is the release's"

git fetch -q origin main || problem "git fetch origin main failed"
SHA=$(git rev-parse HEAD)
BRANCH=$(git rev-parse --abbrev-ref HEAD)
PUSH=0
if [ "$SHA" != "$(git rev-parse origin/main)" ]; then
  if [ "$BRANCH" = main ] && git merge-base --is-ancestor origin/main HEAD; then PUSH=1
  else problem "HEAD (${SHA::7}, $BRANCH) is not main as GitHub has it: release from main (git switch main; git pull)"; fi
fi
[ -z "$(git status --porcelain --untracked-files=no)" ] || problem "uncommitted changes would not be in it: commit or stash them"

STATE="$top/state"
[ -f "$STATE/update-signing.pem" ] || STATE="$main_root/state"
KEY="$STATE/update-signing.pem"
ART="$STATE/build-artifacts.key"
[ -f "$KEY" ] || problem "no state/update-signing.pem (the app's update key; never regenerate it)"
[ -f "$ART" ] || problem "no state/build-artifacts.key: bash ../v15-build/scripts/artifact-key.sh $REPO state/build-artifacts.key"
if [ -f "$KEY" ] && command -v v15-release > /dev/null; then
  have=$(v15-release pubkey --key "$KEY" 2>/dev/null | tr -d '\r')
  [ "$have" = "$PUBKEY" ] || problem "state/update-signing.pem is the key $have, not release.pubkey $PUBKEY"
fi
git grep -q "$PUBKEY" HEAD -- '*.rs' || problem "release.pubkey is not compiled into the app (no .rs file at HEAD holds it)"

if [ "$LOCAL" != 1 ] && gh auth status > /dev/null 2>&1; then
  secrets=$(gh secret list --repo "$V15_BUILDER" --json name -q '.[].name' 2>/dev/null | tr -d '\r')
  up=$(echo "$REPO" | tr 'a-z.-' 'A-Z__')
  # the app's, its deps' and its checkouts' keys, and the secrets named by its
  # sections
  for s in "KEY_$up" "ARTIFACT_$up" $(cfg "[].concat(
      (c.deps || []).filter(d => d.toLowerCase() !== '$REPO'.toLowerCase()).map(d => 'KEY_' + d.toUpperCase().replace(/[.-]/g, '_')),
      ...['windows', 'linux', 'macos', 'ios', 'android'].map(p => !c[p] ? [] : [].concat(
        (c[p].secrets || []).map(s => s + '_$up'), (c[p].mask || []).map(s => s + '_$up'),
        c[p].keychain ? [c[p].keychain.cert + '_$up', c[p].keychain.password + '_$up'] : [],
        ...(c[p].checkouts || []).map(x => x.secret ? [x.secret + '_KEY_$up', x.secret + '_REPO_$up'] : ['KEY_' + x.repo.toUpperCase().replace(/[.-]/g, '_')]))))"); do
    grep -qx "$s" <<< "$secrets" || problem "the builder has no secret $s (README.md, \"An app\")"
  done
fi

if [ -n "$APK" ]; then
  ks=$(local_file "$(cfg 'c.release.android.sign.keystore')")
  kspw=$(local_file "$(cfg 'c.release.android.sign.password')")
  ksalias=$(cfg 'c.release.android.sign.alias')
  [ -s "$ks" ] && [ -s "$kspw" ] || problem "no Android keystore $(cfg 'c.release.android.sign.keystore') and its password file (never regenerate them)"
  bt=$(ls -d "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$LOCALAPPDATA/Android/Sdk}}"/build-tools/* 2>/dev/null | sort -V | tail -1)
  zipalign=$bt/zipalign; [ -e "$zipalign.exe" ] && zipalign="$zipalign.exe"
  apksigner=$bt/apksigner; [ -e "$apksigner.bat" ] && apksigner="$apksigner.bat"
  [ -n "$bt" ] && [ -e "$apksigner" ] && [ -e "$zipalign" ] || problem "no Android build-tools (apksigner, zipalign): the Android SDK"
fi

pull_name() { basename "$1" .json; }
for pull in $PULLS; do
  [ -f "$pull" ] || { problem "no $pull (the release-pull config)"; continue; }
  name=$(pull_name "$pull")
  live=$(ssh -o ConnectTimeout=15 "$REMOTE" "cat /etc/release-pull/$name.json" 2>/dev/null) || live=""
  if [ -z "$live" ]; then
    msg="$REMOTE has no release-pull for $name: bash ../v15-kit/ops/release-pull/install.sh $REMOTE $pull"
    if [ "$DRY" = 1 ]; then warn+=("$msg"); else problem "$msg"; fi
  elif [ "$(printf '%s' "$live" | node -e 'console.log(JSON.stringify(JSON.parse(require("fs").readFileSync(0,"utf8"))))')" != "$(node -e 'console.log(JSON.stringify(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))))' "$pull")" ]; then
    warn+=("$REMOTE's /etc/release-pull/$name.json differs from $pull (empire's is what installs; reinstall it with v15-kit's ops/release-pull/install.sh)")
  fi
done

if [ "$LOCAL" = 1 ]; then
  for p in $PLATFORMS; do
    case "$p" in windows) ;; android) [ -n "${NDK_HOME:-}" ] || warn+=("LOCAL=1: no NDK_HOME, android waits for the builder") ;;
      *) warn+=("LOCAL=1: $p can't be built on this PC; it waits for a run on the builder (BUILD=<id> without LOCAL)") ;; esac
  done
fi

for w in "${warn[@]}"; do echo "publish: warning: $w"; done
if [ ${#problems[@]} -gt 0 ]; then
  for p in "${problems[@]}"; do echo "publish: $p" >&2; done
  die "preflight failed: nothing built"
fi

VERSION=$(cargo metadata --no-deps --format-version 1 --manifest-path "$DIR/Cargo.toml" 2>/dev/null \
  | node -e 'const m=JSON.parse(require("fs").readFileSync(0,"utf8"));const p=m.packages.find(p=>p.name===process.argv[1]);if(!p)process.exit(1);console.log(p.version)' "$PACKAGE" | tr -d '\r') \
  || die "no Cargo package $PACKAGE in $DIR"
BUILD="${BUILD:-$(date +%s)}"
case "$BUILD" in *[!0-9]*) die "BUILD: a build id (unix time)" ;; esac
WORK="$STATE/release/$BUILD"
FILES="$WORK/files"
mkdir -p "$FILES"
if [ -f "$WORK/sha" ] && [ "$(cat "$WORK/sha")" != "$SHA" ]; then
  die "build $BUILD was made from $(cut -c1-7 "$WORK/sha"), not ${SHA::7}: a new build (no BUILD) or check out that commit"
fi
echo "$SHA" > "$WORK/sha"
[ "$PUSH" = 0 ] || git push -q origin main || die "git push failed"
echo "== $APP $VERSION, build $BUILD, from ${SHA::7}$([ "$DRY" = 1 ] && echo ", dry run")$([ "$LOCAL" = 1 ] && echo ", built here") =="

# ── build ──────────────────────────────────────────────────────────────────
have_files() { local f; for f in $(files_of "$1"); do [ -f "$FILES/$f" ] || return 1; done; }
run_of() { cat "$WORK/run-$1" 2>/dev/null || true; }
need=""
for p in $PLATFORMS; do have_files "$p" || need="$need $p"; done
if [ "$LOCAL" = 1 ]; then
  for p in $need; do
    case "$p" in windows) ;; android) [ -n "${NDK_HOME:-}" ] || continue ;; *) continue ;; esac
    say "$p: building here"
    bash "$here/local.sh" "$top" "$SHA" "$BUILD" "$p" "$FILES" || die "$p: the local build failed"
    echo local > "$WORK/run-$p"
  done
else
  todo=""
  for p in $need; do
    r=$(run_of "$p")
    if [ -n "$r" ] && [ "$r" != local ] && v15_build_has "$r" "$p"; then say "$p: built already (run $r)"; else todo="$todo $p"; fi
  done
  if [ -n "$todo" ]; then
    say "building$todo on the builder (checks first, in the same run)"
    ok=1
    v15_build "$REPO" "$SHA" "$BUILD" "$(echo $todo | tr ' ' ',')" || ok=0
    [ -n "${V15_RUN:-}" ] || die "the builder's run didn't start: LOCAL=1 builds here"
    for p in $todo; do v15_build_has "$V15_RUN" "$p" && echo "$V15_RUN" > "$WORK/run-$p"; done
    [ "$ok" = 1 ] || say "the run failed for some platforms: what built goes on; resume with BUILD=$BUILD"
  fi
  for p in $need; do
    r=$(run_of "$p")
    [ -n "$r" ] || continue
    if signed_here "$p" || [ "$DRY" != 1 ]; then
      v15_build_fetch "$r" "$FILES" "$ART" "$p" || die "$p: the files didn't come back from run $r"
    else
      # (a dry run leaves them there: their hashes, from the run's log)
      v15_build_sums "$r" "$p" > "$WORK/sums-$p" || true
      say "$p: built on run $r, not downloaded: $(awk '{printf "%s %s bytes, ", $3, $2}' "$WORK/sums-$p")"
    fi
  done
fi

# ── sign ───────────────────────────────────────────────────────────────────
if [ -n "$APK" ] && [ -f "$FILES/$APK" ] && [ ! -f "$FILES/$APK.unsigned" ]; then
  say "android: signing $APK with $(basename "$ks") (alias $ksalias)"
  mv "$FILES/$APK" "$FILES/$APK.unsigned"
  "$zipalign" -f -p 4 "$FILES/$APK.unsigned" "$FILES/$APK.aligned" > /dev/null
  "$apksigner" sign --ks "$ks" --ks-key-alias "$ksalias" --ks-pass "file:$kspw" --key-pass "file:$kspw" \
    --out "$FILES/$APK" "$FILES/$APK.aligned" || { mv "$FILES/$APK.unsigned" "$FILES/$APK"; die "android: signing failed"; }
  rm -f "$FILES/$APK.aligned" "$FILES/$APK.idsig"
fi
if [ -n "$APK" ] && [ -f "$FILES/$APK" ]; then
  cert=$("$apksigner" verify --print-certs "$FILES/$APK" 2>/dev/null | grep -m1 "SHA-256 digest" | sed 's/.*: //' | tr -d '')
  [ -n "$cert" ] || die "android: $APK doesn't verify"
  say "android: $APK signed, certificate SHA-256 $cert"
fi

if [ -n "$EXE" ] && [ -f "$FILES/$EXE" ] && [ ! -f "$FILES/$MANIFEST" ]; then
  say "windows: signing $EXE into $MANIFEST (on $BASE)"
  (
    cd "$FILES"
    v15-release add --app "$APP" --platform windows-x86_64 --build "$BUILD" --version "$VERSION" \
      --file "$EXE" --url "$EXE_URL" --br --notes "$NOTES" \
      --base "$BASE" --out "$MANIFEST.tmp" --key "$KEY" --expect-pubkey "$PUBKEY"
  ) || die "windows: signing failed"
  mv "$FILES/$MANIFEST.tmp" "$FILES/$MANIFEST"
fi
if [ -n "$EXE" ] && [ -f "$FILES/$MANIFEST" ]; then
  # what an install of the live build would update to: this one
  prev=$(curl -fsS --max-time 30 "$BASE" 2>/dev/null | node -e 'try{const m=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(m.latest||0)}catch{console.log(0)}' | tr -d '\r')
  [ -n "$prev" ] && [ "$prev" != "$BUILD" ] && [ "$prev" -lt "$BUILD" ] || prev=$((BUILD - 1))
  v15-release verify --manifest "$FILES/$MANIFEST" --app "$APP" --platform windows-x86_64 \
    --pubkey "$PUBKEY" --current "$prev" --file "$FILES/$EXE" > "$WORK/verify.log" 2>&1 \
    || { cat "$WORK/verify.log"; die "windows: the signed manifest doesn't verify"; }
  grep -q "$BUILD" "$WORK/verify.log" || { cat "$WORK/verify.log"; die "windows: an install of build $prev would not update to $BUILD"; }
  say "windows: $MANIFEST verified (an install of build $prev updates to $BUILD)"
fi

# the app's own extra files (older manifests, archives), once
if [ ! -f "$WORK/extra.done" ] && [ -n "$(cfg 'c.release.extra && "y"')" ]; then
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    V15_OUT="$FILES" V15_BUILD_ID="$BUILD" V15_VERSION="$VERSION" V15_SHA="$SHA" V15_APP="$APP" REMOTE="$REMOTE" \
      bash -c "$cmd" || die "extra: $cmd failed"
  done <<< "$(cfg 'c.release.extra')"
  touch "$WORK/extra.done"
fi

# ── each release: its files (the release-pull config's assets) and SHA256SUMS
ready=""
waiting=""
for pull in $PULLS; do
  name=$(pull_name "$pull")
  assets=$(j "$pull" 'c.files.map(f => f.asset)')
  missing=""
  remote=""
  for a in $assets; do
    if [ -f "$FILES/$a" ]; then continue; fi
    if [ "$DRY" = 1 ] && cat "$WORK"/sums-* 2>/dev/null | awk '{print $3}' | grep -qx "$a"; then remote="$remote $a"; continue; fi
    missing="$missing $a"
  done
  if [ -n "$missing" ]; then
    waiting="$waiting $name"
    say "$name: not ready, missing$missing"
    continue
  fi
  rel="$WORK/$name"
  rm -rf "$rel" && mkdir -p "$rel"
  local_assets=""
  for a in $assets; do [ -f "$FILES/$a" ] && { cp "$FILES/$a" "$rel/$a"; local_assets="$local_assets $a"; }; done
  if [ -z "$remote" ]; then
    # shellcheck disable=SC2086
    (cd "$rel" && v15-release sums --out SHA256SUMS $assets > /dev/null)
    say "$name: ready"
    sed 's/^/    /' "$rel/SHA256SUMS"
  else
    say "$name: ready (signed here:$local_assets; on the builder:$remote)"
  fi
  ready="$ready $pull"
done

if [ "$DRY" = 1 ]; then
  say "dry run: build $BUILD built and signed in $WORK, nothing released"
  [ -z "$waiting" ] || die "not ready:$waiting"
  exit 0
fi

# ── release and install ────────────────────────────────────────────────────
for pull in $ready; do
  name=$(pull_name "$pull")
  repo=$(j "$pull" 'c.repo')
  prefix=$(j "$pull" 'c.tag.replace(/^\^/, "").replace(/-\[0-9\]\+\$$/, "")')
  tag="$prefix-$BUILD"
  rel="$WORK/$name"
  if gh release view "$tag" --repo "$repo" > /dev/null 2>&1; then
    up=$(gh release view "$tag" --repo "$repo" --json assets -q '.assets[].name' | tr -d '\r')
    for f in "$rel"/*; do
      grep -qx "$(basename "$f")" <<< "$up" && continue
      gh release upload "$tag" "$f" --repo "$repo" || die "$tag: uploading $(basename "$f") failed: resume with BUILD=$BUILD"
    done
    say "$tag: on GitHub"
  else
    say "$tag: releasing on GitHub ($(du -ch "$rel"/* | tail -1 | cut -f1) to upload)"
    gh release create "$tag" "$rel"/* --repo "$repo" --target "$SHA" --title "$prefix $BUILD" \
      --notes "Built from main at $SHA. $NOTES" || die "$tag: the release failed: resume with BUILD=$BUILD"
  fi
  # the newest 5 are kept
  gh release list --repo "$repo" --limit 100 --json tagName -q '.[].tagName' | tr -d '\r' | grep -E "^$prefix-[0-9]+$" \
    | sort -t- -k"$(($(echo "$prefix" | tr -cd - | wc -c) + 2))" -rn | tail -n +6 \
    | while read -r old; do gh release delete "$old" --repo "$repo" --cleanup-tag -y > /dev/null && say "pruned $old"; done

  if ssh "$REMOTE" "grep -qF '$name: $tag installed' /var/log/release-pull.log"; then
    say "$tag: installed already"
  else
    say "$tag → $REMOTE (release-pull $name)"
    # release-pull places each file, with manifests last, and fetches every
    # served file to verify its hash: nothing is downloaded locally.
    gh auth token | ssh "$REMOTE" "release-pull $name '$tag'" || die "$tag: release-pull failed: resume with BUILD=$BUILD"
  fi
done

# older builds' folders are removed (the newest 3 stay)
ls -d "$STATE/release"/*/ 2>/dev/null | sort -r | tail -n +4 | xargs -r rm -rf
[ -z "$waiting" ] || die "released, but not:$waiting (resume with BUILD=$BUILD)"
say "live: $APP build $BUILD"
