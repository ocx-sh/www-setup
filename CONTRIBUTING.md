# Contributing

Thanks for helping land changes to the canonical OCX installer scripts.

## Prerequisites

- [Task](https://taskfile.dev) — task runner.
- [OCX](https://ocx.sh) — provisions the linters and test tools used here via its toolchain. Local dev wires it through [direnv](https://direnv.net): `.envrc` runs `eval "$(ocx direnv export)"` so the tools land on PATH on `cd`. Package resolution populates the local index on demand; no manual index step is needed.
- **Vendored Bats** — the Bats framework lives as git submodules under `external/`. After cloning, run:
  ```sh
  git submodule update --init --recursive    # or: task test:bootstrap
  ```
  The test tasks depend on this; a fresh clone resolves Bats without a manual step. The pinned version is Bats 1.14.0; `scripts/bats-ci.sh` refuses any other.
- `pwsh` — PowerShell 7+. Needed for Pester tests and PSScriptAnalyzer. `src/install.ps1` is **cross-platform** (Windows + Linux + macOS) but still targets a **Windows PowerShell 5.1 Desktop floor** on Windows (no ternary, `??`, `&&`/`||` chains, `$IsWindows` auto-var, `-SkipCertificateCheck`, `-SslProtocol`); on Unix it needs `tar` for extraction (xz-utils only for releases older than the .tar.gz switch). Pester is pinned to 6.2.0 and PSScriptAnalyzer to 1.25.0 (installed by `scripts/Install-PinnedModule.ps1`). CI runs the Pester suite on windows-latest + ubuntu-latest + macos-26 (pwsh 7); the 5.1 floor is held by a parse gate and a fixture-free `powershell.exe` smoke install on Windows.
- **Exotic shells** — `nu` (Nushell), `fish`, `elvish` are provisioned via the OCX toolchain (`ocx.toml`: `ocx.sh/nushell/nushell`, `ocx.sh/fish-shell/fish`, `ocx.sh/elvish/elvish`). Declared floors: nu 0.105.1 (tested up to 0.116.1), fish 3.6.0, elvish 0.20.1. Their lint gates are `scripts/nu-gate.nu`, `scripts/fish-scan.sh` plus `fish -n` and `fish_indent --check`, and `scripts/elv-gate.sh`. The nu, fish and elvish suites run locally and in CI; where an interpreter is missing the suite skips locally and fails when `OCX_TEST_REQUIRE_SHELLS` is set, as in CI. On Linux, `pwsh` itself is also OCX-provisioned (`ocx.sh/powershell/powershell` in `[group.linux]` — Linux has glibc leaves only, no musl; macOS/Windows still use a system pwsh).
- `python3` — used by the Bats fixture HTTPS server.
- `docker` with `buildx` and (for non-native arches) QEMU binfmt handlers — required for `tests/docker/`. Run `task docker:qemu:register` to install handlers on Linux hosts.

## Layout

```
src/install.sh               POSIX installer (bash/zsh/ash/ksh/dash; Linux + macOS)
src/install.ps1              PowerShell installer (cross-platform; PS 5.1 floor on Windows, PS 7+ on Unix)
src/install.nu               Nushell installer (env-driven; cross-platform)
src/install.fish             fish installer (unix-only)
src/install.elv              Elvish installer (cross-platform)
scripts/publish-installers.sh   Upload all 5 installers to Bunny Edge Storage (archive/<VERSION>/ + latest|next/), then publish-dist.sh
scripts/gen-dist.sh             Generate dist.json (manifest) from the ocx-sh/ocx Releases API (inline sha256)
scripts/publish-dist.sh         Regenerate + upload dist.json (overwrite, clobber-safe)
scripts/lib/bunny.sh            Upload transport (bn_put / bn_put_new over curl; key on stdin)
scripts/*-gate.* scripts/ci-*   Per-dialect quality gates and workflow/Taskfile checks (task shell:verify, pwsh:verify, ci:verify, ...)
scripts/bats-ci.sh              Bats pipeline: version pin, canary, census (bats-census.sh); the lint is separate (task test:bats:lint)
scripts/Invoke-PesterGate.ps1   Pester census gate (pinned 6.2.0)
external/                    Vendored Bats submodules (bats-core, bats-support, bats-assert)
deploy/bunny/                Live routing + zone settings (edge-rules.py: plan/apply/verify, zone-apply)
deploy/nginx/                SUPERSEDED reference nginx block, kept as the rollback target
tests/install/*.bats         Bats env-knob / exit-code / print-path / dist suites (sh)
tests/install/{nu,fish,elvish}/  Per-shell installer suites (skip locally where the shell is absent)
tests/install/ps1/*.Tests.ps1   Pester equivalents (+ Fixture.psm1, Run-Installer.ps1, Trust-Fixture.ps1)
tests/install/helpers/       Shared fixture HTTPS server helpers + load.bash (bats-assert)
tests/scripts/               Bats for the publish/dist scripts, the shell gate and the docker harness (task test:bats, Linux)
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
task test:bats                                                # vendored bats through bats-ci.sh: pin, canary, census (zero skips); on Linux also tests/scripts
task test:bats:lint test:pester:lint                          # vacuous-test and Pester-pin lint
task test:pester                                              # Pester only, census gate (needs pwsh)
task shell:verify pwsh:verify nu:verify fish:verify elvish:verify   # per-dialect quality gates
task ci:verify meta:verify                                    # workflow/Taskfile checks, license headers, links
task ci:zizmor                                                # workflow security audit (zizmor)
task docker:integration DISTRO=alpine PLATFORM=linux/amd64    # one distro × arch
task docker:integration:all                                   # full matrix
```

The Bats suite spins a `python3 ssl` HTTPS server against a fixture release tree — archive + a `dist.json` manifest (with an inline `sha256`) — built per-test in `${BATS_FILE_TMPDIR}`. No network access is required. Tests point `OCX_INSTALL_DIST_URL` at the fixture manifest and redirect the artifact download to the fixture via `OCX_INSTALL_MIRROR_URL` (the manifest `url` is a dummy). They inject a binary without a network artifact via the internal test-only hatch `__OCX_TESTING_INSTALL_BINARY` (a path to a stub or real `ocx`; never a public knob) and assert the recorded `ocx self setup` hand-off argv.

The docker matrix runs each installer (`sh`/`nu`/`fish`/`elvish`) via its own interpreter against an injected stub (network-free, deterministic) across alpine/fedora/ubuntu × amd64/arm64. The per-shell *activation* matrix (which exercises the `ocx self setup`-written profile/autoload blocks) needs a real `ocx` binary and runs nightly and on manual dispatch. Set the `VERSION` argument / `OCX_INSTALL_VERSION` to pin a release:

```sh
tests/docker/run.sh fedora linux/arm64 latest "" nu
```

> **CI toolchain note:** CI dogfoods the same OCX toolchain as local dev: the lint/bats workflows bootstrap it via `ocx-sh/setup-ocx` (or `tests/ci/install-ocx.sh` inside distro containers). Only the Pester jobs (runner pwsh + PSGallery, version-pinned) and the marketplace lint actions (actionlint/markdownlint/lychee/hawkeye) remain ad-hoc — keep those pinned versions roughly in sync with `ocx.toml` to avoid local/CI drift.

## Commit conventions

This repo uses Conventional Commits parsed by [git-cliff](https://git-cliff.org/) (see `cliff.toml`). The project is pre-release but has shipped (`v0.1.x`); the version-bump column is the mapping `task release:prepare` applies. Recognised prefixes:

| Prefix | Purpose | Version bump |
|---|---|---|
| `feat:` | New feature | minor |
| `fix:` | Bug fix | patch |
| `feat!:` / `fix!:` / `BREAKING CHANGE:` | Breaking change | major |
| `perf:` | Performance improvement | patch |
| `refactor:` | Code restructuring | — |
| `docs:` / `test:` / `ci:` / `build:` / `chore:` | No bump | — |

Scopes are optional: `feat(install): add OCX_INSTALL_MIRROR_URL`.

The PR workflow runs `cog check` (`cog.toml`, merge commits ignored); commits that aren't conventional will fail the gate.

**Do not** add `Co-Authored-By:` trailers, attribution lines, or any similar metadata to commits or PRs.

## Cross-installer parity

`src/install.{sh,ps1,nu,fish,elv}` are independent implementations of the same thin contract. When you change one, mirror the change across the others in the same PR — and update the matching Bats + Pester scenarios. See [`.claude/rules/installers.md`](.claude/rules/installers.md) for the full 5-way rule.

## Releases

The project is **pre-release** but has shipped (`v0.1.0-rc.1`, `v0.1.0`, `v0.1.1`, plus the `v0` major alias). Releases are tag-driven:

```sh
task release:prepare                           # interactive: pick auto|patch|minor|major, then CHANGELOG + verify
task release:prepare BUMP=minor                # non-interactive (required on CI / no TTY)
task release:prepare BUMP=auto VERSION=0.2.0   # pin an exact version
git add -A && git commit -m "release: vX.Y.Z"
git tag vX.Y.Z
git push origin main && git push origin vX.Y.Z
```

The tag push triggers `release.yml`, which creates the GitHub release and uploads all five installers to Bunny Edge Storage (then refreshes `dist.json`). See [`.claude/rules/workflow-release.md`](.claude/rules/workflow-release.md) for the full flow.
