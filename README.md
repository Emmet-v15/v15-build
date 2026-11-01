# v15-build

This is the sole path for checking, building, and releasing the owner's
private apps. GitHub's free runners (Windows, Linux, macOS, iOS, Android)
handle checks and builds for apps that pay for their own Actions minutes.
Any task requiring keys held by the owner—such as update signing, the
Android keystore, releasing, and installing—is performed on the owner's
machine using a single shared script, `scripts/publish.sh`.

Runs do not trigger on push or pull requests; the owner starts each run
(`workflow_dispatch`, from `scripts/dispatch.sh`). A run fetches the app and
its private repositories using each repository's read-only deploy key, then
deletes the keys before running the app's code. Each other secret an app
names is read only by the step that needs it; no step sees every secret
(GitHub would then hold every run for approval). Because logs are public,
steps output only error lines. Release files are encrypted with the app's
key, kept for one day, and their sha256 and size are printed in the log
(`v15-sum` lines) so a build can be compared without downloading it. Runner
images and actions are pinned (images by name, actions by commit).

## An app

`ops/build.json` in the app's repository. A Windows-only Rust app
requires only the top-level keys (the original form, all optional):

```json
{
  "deps": ["v15-kit", "v15-notify"],
  "dir": ".",
  "tools": ["nasm"],
  "package": "myapp-app",
  "exe": "myapp.exe",
  "features": ["tauri/custom-protocol"],
  "before_release": ["npm --prefix ui ci && npm --prefix ui run build"],
  "checks": ["fmt", "clippy", "test"],
  "commands": ["node --test web/test/"],
  "release": { "app": "myapp", "pubkey": "…", "windows": { "files": ["myapp.exe"], "link": "myapp.exe" } }
}
```

| key | |
|---|---|
| `deps` | private repositories it fetches, as cargo git dependencies on `https://github.com/<owner>/<repo>` (≤ 4) |
| `dir` | the path to the Cargo workspace folder, relative to the root; default `.` |
| `tools` | tools the build needs beyond Rust and Node: `nasm` |
| `package`, `exe` | what a release builds (with `V15_BUILD_ID` set to the build id) |
| `features` | cargo features for the release build (`tauri/custom-protocol` embeds a Tauri app's UI, as `tauri build` does) |
| `before_release` | commands executed in the repository's root prior to the release build, e.g. building the UI it embeds |
| `checks` | any of `fmt`, `clippy` (warnings are errors), `test`; default is all three |
| `commands` | additional checks, run in the repository's root after the Rust ones |
| `release` | how it gets released: [A release](#a-release) |

### Platforms

Apps that ship on more platforms than Windows assign a section to each
platform (`windows`, `linux`, `macos`, `ios`, `android`). Each section runs
as a separate job on its own runner, using the app's own commands. If any
section exists, the top-level `tools`, `package`, `exe`, `features`,
`before_release`, `checks` and `commands` do not apply; `deps` and `dir`
still do. star's (`Emmet-v15/star3`) is the full example:

```json
"ios": {
  "tools": ["node"],
  "brew": ["xcodegen"],
  "targets": ["aarch64-apple-ios", "wasm32-unknown-unknown"],
  "timeout": 90,
  "checkouts": [{"secret": "PLUGIN", "path": "plugin", "ref": "main"}],
  "secrets": ["PLUGIN_ID"],
  "mask": ["PLUGIN_ID"],
  "cache": ["plugin"],
  "check": ["cargo check --manifest-path src-tauri/Cargo.toml --locked --target aarch64-apple-ios"],
  "build": ["bash scripts/build-release.sh ios"]
}
```

| key | |
|---|---|
| `runner` | the image, one of `windows-2025`, `windows-2022`, `ubuntu-24.04`, `ubuntu-22.04`, `macos-15`, `macos-14`; default `windows-2025` (windows), `ubuntu-24.04` (linux, android), `macos-15` (macos, ios). Linux packages built on the oldest image run on the most systems |
| `timeout` | Minutes before the job stops; default is 60 |
| `tools` | `node` (22; `node:20`), `java` (Temurin 17; `java:21`), `android` (the runner's SDK and NDK as `ANDROID_HOME` and `NDK_HOME`, and the NDK's compilers for cargo's Android targets), `xcode:16.4` (that Xcode selected), `nasm` |
| `targets` | Rust targets added to the toolchain (`rust-toolchain.toml`, otherwise stable) |
| `apt`, `brew` | packages installed first (Linux, macOS) |
| `checkouts` | up to 2 more private repositories, checked out beside the app (`src/`) at `path`, at `ref` (default `main`) with their history: `{"repo": "name"}` with its `KEY_<NAME>`, or `{"secret": "NAME"}`, whose repository and key are the app's secrets `NAME_REPO_<APP>` and `NAME_KEY_<APP>` (a name that stays out of the public log) |
| `secrets` | up to 4 of the app's own secrets, `NAME_<APP>`, in the environment of its `check` and `build` commands as `NAME` |
| `mask` | up to 2 of the app's secrets whose value (as written, Capitalised and UPPER CASE) is hidden in the log from the start |
| `keychain` | macOS: `{"cert": "MAC_CERT", "password": "MAC_CERT_PASSWORD", "identity": "…"}`, the app's secrets `MAC_CERT_<APP>` (a base64 .p12) and its password, are imported into the runner's keychain and trusted for code signing; the build signs with `APPLE_SIGNING_IDENTITY` |
| `cache` | other Cargo workspaces (beside `src/`) whose `target` is cached |
| `check` | commands execute in the repository's root on every run |
| `build` | On a release run, the commands execute at the repository's root with `V15_BUILD_ID` and `V15_OUT`; they place the platform's release files (`release` → the platform → `files`) into `$V15_OUT`. |

On every run, including releases, the checks execute first. The build
cache is saved only by runs of main's commits and releases, preventing
branches from overwriting main's cache (10 GB total across all apps).

### Setting one up

In Git Bash while `gh` is signed in:

```bash
bash scripts/add-repo.sh myapp                 # the app, and each of its deps once
bash scripts/add-repo.sh other-repo myapp NAME # a {"secret": "NAME"} checkout
bash scripts/artifact-key.sh myapp ../myapp/state/build-artifacts.key
bash scripts/app-secret.sh myapp MAC_CERT ../myapp/state/mac-signing.p12 --base64
bash scripts/app-secret.sh myapp MAC_CERT_PASSWORD ../myapp/state/mac-signing.pw
```

Checks, run from the app's `scripts/ci.sh`:

```bash
source ../v15-build/scripts/dispatch.sh
v15_build myapp "$(git rev-parse HEAD)" || exit 1
```

`v15_build <repo> <sha> [build] [platforms]` waits for the run to complete
(up to `V15_DEADLINE` minutes, default 120, then cancels it) and reruns its
failed jobs once only if the failure was due to infrastructure issues (a
lost runner, a timeout, or a network fault during setup), not if a check or
the build failed. `V15_BUILDER_REF=<branch>` executes this repository's
workflow from a branch.

## A release

The `release` section and the app's release-pull config (defaulting to
`ops/<app>.json`, installed on the server as `/etc/release-pull/<app>.json`
using v15-kit's `ops/release-pull/install.sh`) cover everything:

```json
"release": {
  "app": "myapp",
  "site": "https://v15.studio/myapp",
  "pubkey": "a6c8…",
  "windows": { "files": ["myapp.exe"], "link": "myapp.exe" }
}
```

| key | |
|---|---|
| `app` | the name in the update manifest, the release tags (`<app>-<build>`) and release-pull |
| `site` | where the app's files and `manifest.json` are served; default is `https://v15.studio/<app>` |
| `pubkey` | the public half of the update key, as it appears in the compiled app |
| `package` | the Cargo package whose version the manifest shows; default is the top-level `package` |
| `windows`, `linux`, `macos`, `ios`, `android` | For each platform, the `files` (built by the builder; on Windows, the first one is the exe installed by the kit's updater, served at `url`, defaulting to `<site>/<file>`, with its `.br`) and the `link`, whose download link is at the site root (installed by the release-pull config) |
| `android.sign` | `{"keystore": "…", "password": "…", "alias": "…"}`: The unsigned APK is signed here using zipalign and apksigner; the keystore remains on this machine. |
| `manifest`, `base` | the signed manifest's asset name (default `manifest.json`) and the live manifest it extends (default `<site>/manifest.json`) |
| `extra` | commands that add the app's own files to the release (`$V15_OUT`, with `V15_BUILD_ID`, `V15_VERSION`, `REMOTE`), e.g. an older manifest |
| `pull` | Release-pull configurations, one per release, starting with the app's own; default is `["ops/<app>.json"]`. A release contains only its configuration's assets and their `SHA256SUMS`; the first must be complete, while a later one (such as star's desktop packages) proceeds once it is ready. |

The app stores a single-line `scripts/publish.sh`:

```bash
exec bash "$(dirname "$0")/../../v15-build/scripts/publish.sh" "$(dirname "$0")/.."
```

`bash scripts/publish.sh` then:

1. **Preflight**: before anything is built, every problem is listed with its
   fix: main matches GitHub (pushing any local main ahead), no uncommitted
   changes; `state/update-signing.pem` and `state/build-artifacts.key`
   exist, the key's public half (`v15-release pubkey`) equals `pubkey`, and
   `pubkey` is compiled into the app (stored in an `.rs` file); `gh` is
   signed in and the builder holds the app's secrets; the server holds each
   release-pull config (identical to the repo's); for Android, the keystore
   and the SDK's apksigner are present.
2. **Build**: Execute one run on the builder for each platform, including
   checks, generating a build id (unix time). Files signed here (the exe,
   the APK) are downloaded, decrypted, and verified against the run's
   `v15-sum` lines.
3. **Sign**: Sign the APK with the keystore; add the exe to the live
   manifest (`v15-release add`, with its `.br`), then `v15-release verify`
   verifies that installing the live build would update to this one.
4. **Release**: Create a GitHub release for each release-pull config, then
   run the server's `release-pull`, which installs files in the config's
   order (manifests last) and fetches each served file back to verify its
   hash there, so nothing is downloaded locally for checking. The five
   newest releases are retained.

`DRY=1` halts after signing; files not requiring signing remain on the
builder, with their hashes sourced from the log. `BUILD=<id>` resumes a
build by skipping any completed steps (built, signed, on GitHub,
installed), ensuring that a mid-failure is retried rather than rebuilt.
`LOCAL=1` builds on this PC instead (for Windows and Android, using the
same cargo command and features or the same build commands, subject to the
RAM rule) to handle a GitHub outage or billing block; the release is signed
and published identically. Work is stored in `state/release/<build>/`
(keeping the newest 3).

## Keys

Each app's `state/` (gitignored) contains its update key
`update-signing.pem` and `build-artifacts.key`; star's also includes its
macOS certificate (`mac-signing.p12`, `.pw`), and its Android keystore is
`star.keystore` (`.pw`) in its root. These files are the only copies:
losing the update key or the keystore strands every installed app. Copies
elsewhere are the owner's call.

The repository requires approval for all outside collaborators on fork pull
requests, so no outside workflow runs occur here.
