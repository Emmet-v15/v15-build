# v15-build

A public builder for private Rust/Tauri app repositories: it runs checks
(fmt, clippy, tests) and builds release exes on GitHub's free Windows
runners, for repositories whose own Actions minutes are paid.

No runs occur on push or pull requests; the owner initiates each run
(`workflow_dispatch`, from `scripts/dispatch.sh`). The run fetches the app and
its private dependencies using each repository's read-only deploy key, then
deletes the keys before executing the app's code. Since logs are public, steps
output only error lines. The release exe is encrypted with the app's key,
retained for one day, and signed on the owner's machine.

## An app

`ops/build.json` in the app's repository, all optional:

```json
{
  "deps": ["some-private-lib"],
  "package": "myapp-app",
  "exe": "myapp.exe",
  "checks": ["fmt", "clippy", "test"],
  "commands": ["node --test web/test/"]
}
```

| key | |
|---|---|
| `deps` | private repositories it fetches, as cargo git dependencies on `https://github.com/<owner>/<repo>` |
| `package`, `exe` | what a release builds (with `V15_BUILD_ID` set to the build id) |
| `checks` | any of `fmt`, `clippy` (warnings are errors), `test`; default is all three |
| `commands` | additional checks, run in the repository's root after the Rust ones |

To configure one, use Git Bash with `gh` signed in:

```bash
bash scripts/add-repo.sh myapp                 # the app, and each of its deps once
bash scripts/artifact-key.sh myapp ../myapp/state/build-artifacts.key   # only for releases
```

From the app's own scripts:

```bash
source ../v15-build/scripts/dispatch.sh
v15_build myapp "$(git rev-parse HEAD)" || exit 1          # check
v15_build myapp "$(git rev-parse HEAD)" 1793400000 && \
  v15_build_fetch "$V15_RUN" state/out state/build-artifacts.key   # release
```

The repository requires approval for all outside collaborators on fork pull
requests, so no outside workflow runs occur here.
