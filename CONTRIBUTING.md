# Contributing to Patch Gremlin

Thanks for helping out. Patch Gremlin runs as root and edits the update path
on other people's servers, so the bar for changes is deliberately high.

## Getting set up

```bash
git clone https://github.com/ChiefGyk3D/Patch-Gremlin
cd Patch-Gremlin
sudo apt-get install -y bats shellcheck   # or: sudo dnf install -y bats ShellCheck
./tests/run.sh
```

The suite runs entirely in a sandbox — it never writes outside a temporary
directory and never contacts the network. Command stubs live in
`tests/helpers/`, and log fixtures in `tests/fixtures/`.

## Before opening a pull request

```bash
./tests/run.sh                                                # must be green
shellcheck -x -S style $(find . -name '*.sh' -not -path './.git/*')
find . -name '*.sh' -not -path './.git/*' -exec bash -n {} \;
```

Use `./tests/run.sh` rather than calling `bats` directly: distro bats versions
differ (Ubuntu 22.04 ships 1.2.1, which has no `--print-output-on-failure`)
and the runner detects what the local build supports.

## Testing conventions

Every behavioural change needs a test. Two mechanisms make that possible:

- **`PATCH_GREMLIN_ROOT`** — a DESTDIR-style prefix. The installer and
  uninstaller stage a complete install into that directory, skipping package
  installation and logging `systemctl` calls to `$PATCH_GREMLIN_ROOT/systemctl.log`.
- **`PATCH_GREMLIN_SOURCE_ONLY=1`** — makes `update-notifier.sh` define its
  functions and return without running `main`, so individual functions can be
  unit-tested.
- **`PATCH_GREMLIN_AUTOMATIC_UNIT=dnf-automatic|dnf5-automatic`** — forces the
  RHEL systemd unit base, bypassing package detection. Lets the suite cover
  both the EL9 and Fedora 41+ unit layouts on one host.
- **`PATCH_GREMLIN_OS_TYPE=debian|rhel`** — forces the package-family branch in
  both the installer and the notifier. Without it, tests asserting apt paths
  quietly depended on whichever family the host belonged to and failed on
  Fedora and Rocky.

Paths are environment-overridable (`PATCH_GREMLIN_LOG_FILE`,
`PATCH_GREMLIN_SECRETS_FILE`, `PATCH_GREMLIN_STATE_DIR`, …) specifically so
tests never touch the host.

When you fix a bug, add a test that fails against the old code and say so in a
comment. Several tests carry a note explaining the exact defect they pin down;
please keep that up.

## Shell style

This project targets bash 4.x on Debian and RHEL family systems.

- `set -euo pipefail` in anything that runs unattended.
- Never `((count++))` for a counter that starts at zero — it returns exit
  status 1 on the first increment and `set -e` will kill the script. Use
  `count=$((count + 1))`.
- Never read `$?` after an assignment (`X=$(cmd); if [[ $? -ne 0 ]]`) — under
  `set -e` the script has already exited. Use `if ! X=$(cmd); then`.
- Never read `$?` inside `if ! cmd; then` — it is the status of the negation.
- Quote every expansion unless you deliberately want word splitting, and say
  so in a comment when you do.
- Interpolating anything into JSON goes through `json_escape`.
- `grep -P`, `grep -oP` and GNU-only flags are avoided for portability.

## Commit messages

Conventional-commit prefixes (`fix:`, `feat:`, `docs:`, `ci:`, `test:`) with a
body explaining *why*. For bug fixes, describe the failure mode — a future
reader should be able to tell whether a refactor reintroduces it.

## Releasing

Tag `vX.Y.Z`. The release workflow runs the suite, verifies required files and
their executable bits, builds the tarball and drafts release notes. Update
`CHANGELOG.md` and the `PATCH_GREMLIN_VERSION` constant in each script first.
