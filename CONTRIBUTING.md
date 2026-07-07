# Contributing

Thanks for helping land changes to the canonical OCX installer scripts.

## Prerequisites

- [Task](https://taskfile.dev) — task runner.
- [OCX](https://ocx.sh) — provisions the linters and test tools used here via its toolchain. Local dev wires it through [direnv](https://direnv.net): `.envrc` runs `eval "$(ocx direnv export)"` so the tools land on PATH on `cd`. After installing OCX, run `task ocx:index-update` once to populate `.ocx/index/`. (CI does not yet use this path — see the note below.)
- **Vendored Bats** — the Bats framework lives as git submodules under `external/`. After cloning, run:
  ```sh
  git submodule update --init --recursive    # or: task test:bootstrap
  ```
  The test tasks depend on this; a fresh clone resolves Bats without a manual step.
- `pwsh` — PowerShell 7+. Needed for Pester tests and PSScriptAnalyzer. `src/install.ps1` is **cross-platform** (Windows + Linux + macOS) but still targets a **Windows PowerShell 5.1 Desktop floor** on Windows (no ternary, `??`, `&&`/`||` chains, `$IsWindows` auto-var, `-SkipCertificateCheck`, `-SslProtocol`); on Unix it needs `tar` for extraction (xz-utils only for releases older than the .tar.gz switch). CI runs Pester on windows-latest + ubuntu-latest + macos-latest and smoke-installs under both `powershell.exe` (5.1) and `pwsh` (7) on Windows.
- **Exotic shells** — `nu` (Nushell), `fish`, `elvish` are provisioned via the OCX toolchain (`ocx.toml`: `ocx.sh/nushell`, `ocx.sh/fish`, `ocx.sh/elvish`). Their lint gates are `nu --ide-check`, `fish -n` + `fish_indent --check`, and `elvish -compileonly`. The fish suite runs locally; nu/elvish are exercised in the docker matrix.
- `python3` — used by the Bats fixture HTTPS server.
- `docker` with `buildx` and (for non-native arches) QEMU binfmt handlers — required for `tests/docker/`. Run `task docker:qemu:register` to install handlers on Linux hosts.

## Layout

```
src/install.sh               POSIX installer (bash/zsh/ash/ksh/dash; Linux + macOS)
src/install.ps1              PowerShell installer (cross-platform; PS 5.1 floor on Windows, PS 7+ on Unix)
src/install.nu               Nushell installer (env-driven; cross-platform)
src/install.fish             fish installer (unix-only)
src/install.elv              Elvish installer (cross-platform)
scripts/publish-installers.sh   rsync all 5 installers → setup.ocx.sh (archive/<VERSION>/ + latest|next/), then publish-dist.sh
scripts/gen-dist.sh             Generate dist.json (manifest) from the ocx-sh/ocx Releases API (inline sha256)
scripts/publish-dist.sh         Regenerate + rsync dist.json (overwrite, clobber-safe)
external/                    Vendored Bats submodules (bats-core, bats-support, bats-assert)
deploy/nginx/                Reference nginx server block (/sh … regex-rewrite onto archive/ latest/ next/, + /dist)
tests/install/*.bats         Bats env-knob / exit-code / print-path / dist suites (sh)
tests/install/{nu,fish,elvish}/  Per-shell installer suites (skip where the shell is absent)
tests/install/ps1/*.Tests.ps1   Pester equivalents
tests/install/helpers/       Shared fixture HTTPS server helpers + load.bash (bats-assert)
tests/ci/                    CI smoke-install helper(s)
tests/docker/                Distro × arch × installer integration matrix (alpine, fedora, ubuntu)
taskfile.yml + taskfiles/    Task automation (lint × 5 shells, test, release, publish)
.claude/                     AI rules + permissions (Claude Code)
.github/workflows/           CI: verify, test-installers, test-docker-matrix, release, update-dist
```

## Running tests

```sh
git submodule update --init --recursive                       # once — vendored bats
task verify                                                   # lint (5 shells) + Bats + Pester
task test:bats                                                # vendored bats: env-knobs, exit-codes, print-path, dist, per-shell
task test:pester                                              # Pester only (needs pwsh)
task nu:verify  fish:verify  elvish:verify                    # exotic-shell lint gates
task docker:integration DISTRO=alpine PLATFORM=linux/amd64    # one distro × arch
task docker:integration:all                                   # full matrix
```

The Bats suite spins a `python3 ssl` HTTPS server against a fixture release tree — archive + a `dist.json` manifest (with an inline `sha256`) — built per-test in `${BATS_FILE_TMPDIR}`. No network access is required. Tests point `OCX_INSTALL_DIST_URL` at the fixture manifest and redirect the artifact download to the fixture via `OCX_INSTALL_MIRROR_URL` (the manifest `url` is a dummy). They inject a binary without a network artifact via the internal test-only hatch `__OCX_TESTING_INSTALL_BINARY` (a path to a stub or real `ocx`; never a public knob) and assert the recorded `ocx self setup` hand-off argv.

The docker matrix runs each installer (`sh`/`nu`/`fish`/`elvish`) via its own interpreter against an injected stub (network-free, deterministic) across alpine/fedora/ubuntu × amd64/arm64. The per-shell *activation* matrix (which exercises the `ocx self setup`-written profile/autoload blocks) needs a real `ocx` binary and runs on manual dispatch. Set the `VERSION` argument / `OCX_INSTALL_VERSION` to pin a release:

```sh
tests/docker/run.sh fedora linux/arm64 latest "" nu
```

> **CI toolchain note:** locally, `task` and the linters/test tools come from the OCX toolchain (via direnv). The GitHub Actions workflows do **not** yet dogfood `ocx-sh/setup-ocx` — they currently install each tool ad-hoc. Migrating CI onto `setup-ocx` + `task` is planned, not done; until then keep the pinned versions in the workflows roughly in sync with `ocx.toml` to avoid local/CI drift.

## Commit conventions

This repo uses Conventional Commits parsed by [git-cliff](https://git-cliff.org/) (see `cliff.toml`). The project is still pre-release (no tags yet); the version-bump column describes the mapping that takes effect once versioning starts. Recognised prefixes:

| Prefix | Purpose | Version bump |
|---|---|---|
| `feat:` | New feature | minor |
| `fix:` | Bug fix | patch |
| `feat!:` / `fix!:` / `BREAKING CHANGE:` | Breaking change | major |
| `perf:` | Performance improvement | patch |
| `refactor:` | Code restructuring | — |
| `docs:` / `test:` / `ci:` / `build:` / `chore:` | No bump | — |

Scopes are optional: `feat(install): add OCX_INSTALL_MIRROR_URL`.

The PR workflow runs `cocogitto check-latest-tag-only`; commits that aren't conventional will fail the gate.

**Do not** add `Co-Authored-By:` trailers, attribution lines, or any similar metadata to commits or PRs.

## Cross-installer parity

`src/install.{sh,ps1,nu,fish,elv}` are independent implementations of the same thin contract. When you change one, mirror the change across the others in the same PR — and update the matching Bats + Pester scenarios. See [`.claude/rules/installers.md`](.claude/rules/installers.md) for the full 5-way rule.

## Releases

The project is **pre-release** — no tags exist yet, so the first release cuts the initial tag. Releases are tag-driven:

```sh
task release:prepare       # git-cliff bump + CHANGELOG + verify
git add -A && git commit -m "release: vX.Y.Z"
git tag vX.Y.Z
git push origin main && git push origin vX.Y.Z
```

The tag push triggers `release.yml`, which creates the GitHub release and rsyncs all five installers to `setup.ocx.sh` (then refreshes `dist.json`). See [`.claude/rules/workflow-release.md`](.claude/rules/workflow-release.md) for the full flow.
