#!/usr/bin/env bash
# Before the keys are removed and before any app code executes, the
# platform's tools (ops/build.json, the platform's section):
#   Rust     the toolchain rust-toolchain.toml names (else stable), with the
#            section's "targets"
#   APT      "apt" packages (Linux)
#   BREW     "brew" formulae (macOS)
#   ANDROID  "android" in "tools": the runner's SDK and NDK, and the NDK's
#            compilers for cargo's Android targets
#   XCODE    "xcode:N" in "tools": that Xcode selected
# (node, java, and nasm are their own steps.)
set -euo pipefail
retry() {
  local n
  for n in 1 2 3; do
    "$@" && return 0
    [ "$n" = 3 ] || { echo "retrying: $1 ($n)"; sleep $((n * 20)); }
  done
  return 1
}
log="$RUNNER_TEMP/tools.log"

if [ -n "${XCODE:-}" ]; then
  app="/Applications/Xcode_$XCODE.app"
  [ -d "$app" ] || { echo "no Xcode $XCODE on this runner: $(ls -d /Applications/Xcode_* | xargs -n1 basename | tr '\n' ' ')"; exit 1; }
  sudo xcode-select -s "$app"
fi

if [ -n "${APT:-}" ]; then
  # shellcheck disable=SC2086
  { retry sudo apt-get update -qq && retry sudo apt-get install -y -qq -o Acquire::Retries=3 $APT; } > "$log" 2>&1 \
    || { grep -E "^E:|error" "$log" | head -20; exit 1; }
fi
if [ -n "${BREW:-}" ]; then
  # shellcheck disable=SC2086
  retry brew install -q $BREW > "$log" 2>&1 || { grep -iE "error" "$log" | head -20; exit 1; }
fi

if [ "${ANDROID:-}" = true ]; then
  sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
  ndk="${ANDROID_NDK_LATEST_HOME:-${ANDROID_NDK_HOME:-}}"
  [ -d "$sdk" ] && [ -d "$ndk" ] || { echo "no Android SDK or NDK on this runner"; exit 1; }
  bin=$(echo "$ndk"/toolchains/llvm/prebuilt/*/bin)
  {
    echo "ANDROID_HOME=$sdk"
    echo "NDK_HOME=$ndk"
    # cargo check and build for Android targets outside Gradle (Tauri's own
    # build sets these itself)
    for t in aarch64-linux-android armv7-linux-androideabi x86_64-linux-android i686-linux-android; do
      cc="$bin/${t/armv7-linux-androideabi/armv7a-linux-androideabi}24-clang"
      u=$(echo "$t" | tr 'a-z-' 'A-Z_')
      echo "CC_${t//-/_}=$cc"
      echo "AR_${t//-/_}=$bin/llvm-ar"
      echo "CARGO_TARGET_${u}_LINKER=$cc"
    done
  } >> "$GITHUB_ENV"
  # When a Tauri app's project is created with the Rust CLI, its Gradle build
  # runs `cargo tauri android android-studio-script`. In this case, the app's
  # own npm CLI (node_modules/.bin/tauri) handles the task, using the same
  # version the app pins.
  if ! cargo tauri --version > /dev/null 2>&1; then
    mkdir -p "$RUNNER_TEMP/bin"
    cat > "$RUNNER_TEMP/bin/cargo-tauri" <<EOF2
#!/usr/bin/env bash
[ "\${1:-}" = tauri ] && shift
exec "$GITHUB_WORKSPACE/src/node_modules/.bin/tauri" "\$@"
EOF2
    chmod +x "$RUNNER_TEMP/bin/cargo-tauri"
    echo "$RUNNER_TEMP/bin" >> "$GITHUB_PATH"
  fi
  echo "Android SDK, NDK $(basename "$ndk")"
fi

cd "src/${DIR:-.}"
if [ -f rust-toolchain.toml ] || [ -f rust-toolchain ] || [ -f ../rust-toolchain.toml ] || [ -f "$GITHUB_WORKSPACE/src/rust-toolchain.toml" ]; then
  retry rustup toolchain install > "$log" 2>&1 || retry rustup show > "$log" 2>&1 || { tail -5 "$log"; exit 1; }
else
  { retry rustup update --no-self-update stable && rustup default stable; } > "$log" 2>&1 || { tail -5 "$log"; exit 1; }
fi
if [ -n "${TARGETS:-}" ]; then
  # shellcheck disable=SC2086
  retry rustup target add $TARGETS > "$log" 2>&1 || { tail -5 "$log"; exit 1; }
fi
echo "$(rustc --version)${TARGETS:+, $TARGETS}"
