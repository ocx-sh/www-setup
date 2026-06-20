# CLAUDE.md

Guidance for Claude Code when working in this repository.

> **Obsidian vault:** if `obsidian-ocx` MCP is connected, read vault `Home.md` first for cross-session knowledge.

## Project

`setup.ocx.sh` is the canonical website hosting the **shell installers** that bring [OCX](https://ocx.sh) to CI runners, developer machines, and Linux servers. There are **five thin installers**, one per supported shell entrypoint (`<shell>` ∈ `sh pwsh nu fish elvish`; `<ext>` ∈ `sh ps1 nu fish elv`):

```
setup.ocx.sh/<shell>            # bare → latest-stable installer (nginx rewrite → latest/install.<ext>)
setup.ocx.sh/<shell>/next       # latest-prerelease ("next"); alias /<shell>/canary
setup.ocx.sh/<shell>/<VERSION>  # pinned (immutable) → archive/<VERSION>/install.<ext>
setup.ocx.sh/dist               # → dist.json distribution manifest (OCX_INSTALL_DIST_URL)
```

Each installer is a **thin bootstrap**: detect platform → resolve the release from `dist.json` → download + verify the archive against the manifest's inline `sha256` → hand off to the downloaded binary's `ocx self setup` (which owns the package-store install, the per-shell env shims, and the managed shell-profile activation blocks — the installers no longer write any of that themselves). This repo owns those five installer files (and their release pipeline + the manifest). Latest-version resolution reads the self-hosted `dist.json` (no GitHub API, no `GITHUB_TOKEN` in the install path). `dist.json` itself is generated **from the `ocx-sh/ocx` GitHub Releases API** (CI-side, with `GITHUB_TOKEN`), inlining a per-target checksum + download URL, so it lists OCX *product* versions — decoupled from this repo's own `v*` tags, which version the installer scripts. The GitHub Action lives in `ocx-sh/setup-ocx` (GitHub Marketplace); the GitLab Function lives in its own repo (GitLab CI Catalog). Documentation paths (`/docs/...`) and action paths (`/actions/...`) on `setup.ocx.sh` are forwarded by nginx to those upstreams.

## Surfaces

| Path | Responsibility |
|---|---|
| `src/install.sh` | Canonical POSIX installer (bash/zsh/ash/ksh/dash). Env knobs `OCX_INSTALL_*`, exit codes 0–7, stderr-only logging, thin `ocx self setup` hand-off |
| `src/install.ps1` | PowerShell installer (Windows; PS 5.1 Desktop floor). Mirrors the sh contract |
| `src/install.nu` | Nushell installer (env-driven; cross-platform) |
| `src/install.fish` | fish installer (unix-only) |
| `src/install.elv` | Elvish installer (cross-platform) |
| `scripts/publish-installers.sh` | rsync of all five `src/install.*` → `setup.ocx.sh:archive/<VERSION>/` (immutable) + the `latest/` or `next/` pointer dir (channel-routed), then `publish-dist.sh` |
| `scripts/gen-dist.sh` | Generate `dist.json` (distribution manifest) from the **`ocx-sh/ocx` GitHub Releases API**; targets DERIVED from each release's `sha256.sum` (inline per-target checksum + URL); uses `GITHUB_TOKEN` in CI |
| `scripts/publish-dist.sh` | Regenerate + rsync `dist.json` to `setup.ocx.sh:/dist.json` (overwrite, clobber-safe) |
| `external/` | Vendored Bats as git submodules (`bats-core`, `bats-support`, `bats-assert`) |
| `deploy/nginx/` | Reference nginx server block: the per-shell `/sh /pwsh /nu /fish /elvish` (+ `/next`, `/<VERSION>`) regex-rewrite layer onto `archive/ latest/ next/`, plus `/dist` |
| `deploy/github/` | Reference snippet (`ocx-release-dispatch.yml.example`) the `ocx-sh/ocx` repo adds to its release workflow to dispatch `ocx-released` at this repo |
| `tests/install/*.bats` | Bats env-knob, exit-code, print-path, dist suites (sh) |
| `tests/install/{nu,fish,elvish}/*.bats` | Per-shell installer suites (gate on shell presence) |
| `tests/install/ps1/*.Tests.ps1` | Pester equivalents (ps1) |
| `tests/docker/` | Distro × arch × installer integration matrix harness |
| `.github/workflows/` | verify, test-installers, test-docker-matrix, release, update-dist (`dist.json` rebuild on dispatch + hourly cron + manual) |

## Commands

All tasks run through [Task](https://taskfile.dev). Locally, the dev toolchain (linters, test tools) is provisioned by the OCX toolchain via [direnv](https://direnv.net) (`.envrc` runs `eval "$(ocx direnv export)"`) plus Task. CI dogfooding through `ocx-sh/setup-ocx` is being rolled out — today the workflows still install their tools ad-hoc, so the local OCX toolchain and CI can drift.

```bash
task verify                                # lint (5 shells) + bats + pester
task shell:verify                          # shellcheck + shfmt
task pwsh:verify                           # PSScriptAnalyzer (needs pwsh on PATH)
task nu:verify                             # nu --ide-check
task fish:verify                           # fish -n + fish_indent --check
task elvish:verify                         # elvish -compileonly
task test:bootstrap                        # git submodule init (vendored bats)
task test:bats                             # vendored bats: env-knob, exit-code, print-path, dist, per-shell
task test:pester                           # Pester (needs pwsh + Pester module)
task docker:integration DISTRO=alpine PLATFORM=linux/amd64
task docker:integration:all                # full 3×2 matrix
task publish:dry-run                       # validates rsync paths

task release:prepare                       # git-cliff bump + changelog + tag locally
```

## Stdout / stderr contract

All five `src/install.*`:

- All informational / warning / error messages go to **stderr**.
- **stdout** is silent on success unless `OCX_INSTALL_PRINT_PATH=1` (or `-PrintPath`), in which case the **final stdout line** is the absolute OCX bin dir.

This contract is load-bearing for downstream wrappers that do `BIN_DIR=$(./install.sh | tail -n1)`.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Generic / legacy |
| 2 | Argument or environment validation |
| 3 | Network / download / manifest failure |
| 4 | Checksum mismatch |
| 5 | Archive extraction failure |
| 6 | `ocx self setup` failure |
| 7 | Unsupported platform / architecture |

Pick the most specific code when calling `err()`. Reusing codes across unrelated failures breaks downstream CI diagnostics.

## Testing tiers

1. **Bats** (`tests/install/*.bats` + `tests/install/{nu,fish,elvish}/`) — VENDORED bats (`external/bats-core/bin/bats`; run `git submodule update --init --recursive` first). A fixture HTTPS server (python3 + ssl) serves `dist.json` + the archive; exercises env knobs, exit-code paths, stdout/stderr discipline, the `ocx self setup` hand-off argv, and `gen-dist.sh` (`dist.bats`). Per-shell suites skip where the shell is absent.
2. **Pester** (`tests/install/ps1/*.Tests.ps1`) — symmetric coverage for the PowerShell installer.
3. **Docker matrix** (`tests/docker/run.sh`) — real distros × arch × **installer** (new INSTALLER axis: sh/nu/fish/elvish), network-free via an injected stub:
   - **Alpine** (musl) — `linux/amd64`, `linux/arm64`
   - **Fedora** (glibc, dnf) — `linux/amd64`, `linux/arm64`
   - **Ubuntu** (glibc, apt) — `linux/amd64`, `linux/arm64`

Cross-installer parity is enforced manually across all FIVE installers on the thin contract: a change to one (`src/install.sh`) must be mirrored in the others (and their tests) in the same PR. See `.claude/rules/installers.md`.

## Releases

This project is **pre-release**: there are zero git tags and nothing has shipped yet. The first release will cut the initial tag.

- Conventional Commits drive versioning via [git-cliff](https://git-cliff.org).
- `task release:prepare` produces the version commit + tag locally; pushing the tag triggers `.github/workflows/release.yml`.
- The release workflow does: gh release (git-cliff notes; `prerelease: true` for `-`-suffixed tags) → `publish-installers` job (channel-routed rsync of all five installers via `SETUP_OCX_DEPLOY_KEY` + refresh/upload `dist.json` via `publish-dist.sh`). The manifest is also rebuilt out-of-band by `update-dist.yml` on `repository_dispatch(ocx-released)` from `ocx-sh/ocx` + an hourly cron fallback + manual dispatch.
- A `-`-suffixed tag (`vX.Y.Z-rc.1`) is a prerelease: it routes to the `next` channel and the GitHub prerelease flag; stable pointers are untouched.

The conventional-commit → version-bump mapping (applies once the project starts versioning):

| Prefix | Purpose | Version bump |
|---|---|---|
| `feat:` | New feature | minor |
| `fix:` | Bug fix | patch |
| `feat!:` / `fix!:` / `BREAKING CHANGE` | Breaking change | major |
| `perf:` | Performance improvement | patch |
| `refactor:` | Code restructuring | — |
| `docs:` / `test:` / `ci:` / `build:` / `chore:` | No bump | — |

Scopes are optional: `feat(install): add OCX_INSTALL_MIRROR_URL`.

**Do not** add `Co-Authored-By` trailers or attribution lines to commits or PRs.

## Required release secrets

| Secret | Used by |
|---|---|
| `SETUP_OCX_DEPLOY_KEY` | `publish-installers` rsync to `setup.ocx.sh` |
| `SETUP_OCX_DISPATCH_TOKEN` | Lives in **`ocx-sh/ocx`** (not this repo): a token scoped to setup.ocx.sh (fine-grained PAT `contents:read` + `actions:write`, or classic `repo`) that `ocx-sh/ocx` uses to fire the `repository_dispatch(ocx-released)` that rebuilds `dist.json`. See `deploy/github/ocx-release-dispatch.yml.example`. |

## Deep context

- [`.claude/rules/installers.md`](.claude/rules/installers.md) — env-knob naming, stdout discipline, exit-code matrix
- [`.claude/rules/publish.md`](.claude/rules/publish.md) — rsync flags, versioned-vs-latest path layout
- [`.claude/rules/testing-bash.md`](.claude/rules/testing-bash.md) — Bats + fixture HTTP server patterns
- [`.claude/rules/testing-pwsh.md`](.claude/rules/testing-pwsh.md) — Pester patterns
- [`.claude/rules/workflow-release.md`](.claude/rules/workflow-release.md) — git-cliff → tag → publish flow
- [`.claude/rules/update-docs.md`](.claude/rules/update-docs.md) — keep README/CLAUDE in sync
