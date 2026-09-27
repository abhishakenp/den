# Developing den

## Remote build mode

Compiling den and running its test suite loads a laptop for minutes (the suite opens real windows
and WebKit processes). In remote build mode that work runs on GitHub Actions instead:

1. Edit locally, commit to your branch or worktree.
2. Run `scripts/ci-check.sh` (add `--snapshots` to also render the UI snapshot scenarios).
   It force-pushes `HEAD` to the scratch branch `ci/<branch-or-worktree-name>`, waits for the run
   on that exact commit, prints each job's result and any failed tests, and downloads every artifact
   (test logs, crash reports, perf report, snapshot PNGs) to `.ci-artifacts/<run-id>/`.
   It exits non-zero unless the run is green.
3. Rebase onto `main` and push only when `ci-check.sh` is green.

A local `swift build` or `scripts/test.sh` is optional. Only committed changes are tested: the
script warns if the working tree is dirty. Pushing again to the same `ci/` branch cancels the
superseded run. `ci/**` branches are scratch space: `scripts/ci-check.sh` force-pushes them (never
`main`), and the `Prune ci/ branches` workflow deletes them 7 days after their last commit.

### What CI runs

`.github/workflows/ci.yml`, on `main`, pull requests to `main`, `ci/**` and manual dispatch, on
the `macos-26` arm64 runner (a 3-core M1 VM with a logged-in GUI session):

- Xcode 26 (`/Applications/Xcode_26.5.app`, else the newest Xcode 26) builds the host; the
  swift.org 6.3.2 toolchain (cached, `$CORDIS_TOOLCHAIN`) builds the Embedded Swift plugins.
- `swift build`, `scripts/bundle.sh` (ad hoc signature: `DEN_SIGN_IDENTITY=-`),
  `scripts/test.sh` through `scripts/ci/run-tests.sh` (the full suite, UI tests included; if a
  runner ever lacks a GUI session the window suites are skipped by name, with a warning).
- `scripts/perf.sh --report-only`: budgets were calibrated on an M3, so a runner's numbers are
  reported in the job summary and the `perf` artifact but never fail the build.
- With `--snapshots` (dispatch input `snapshots`): `scripts/snapshots.sh` on a second runner, the
  PNGs uploaded as the `snapshots` artifact.

### Runner limits

GitHub's documented limits for standard hosted runners
([Actions limits](https://docs.github.com/en/actions/reference/limits)): at most **5 concurrent
macOS jobs** on the Free, Pro and Team plans (50 on Enterprise), 20 concurrent jobs in total on
Free. den is public, so standard runners cost nothing. A `ci-check.sh` run uses one macOS job, or
two with `--snapshots`; more agents than that queue rather than fail.

### Dev builds from CI

Every green push to `main` uploads `den-<commit>.zip` (the `den-app` artifact, kept 14 days).
It is ad hoc signed and not Sparkle-signed: the EdDSA key for update feeds stays on the
maintainer's Mac. So it is fine for trying a commit, but it is not a drop-in for the local updater:
an ad hoc signature has a different designated requirement from the local `den Local Signing`
identity, so macOS would treat it as a different app (Keychain and TCC grants would ask again).
The updater keeps building locally for that reason.
