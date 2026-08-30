# CLAUDE.md

Guidance for Claude Code when working in this repository.

> **Obsidian vault:** if `obsidian-ocx` MCP is connected, read vault `Home.md` first for cross-session knowledge.

## Project

`setup.ocx.sh` is the canonical website hosting the **shell installers** that bring [OCX](https://ocx.sh) to CI runners, developer machines, and Linux servers. There are **five thin installers**, one per supported shell entrypoint (`<shell>` ∈ `sh pwsh nu fish elvish`; `<ext>` ∈ `sh ps1 nu fish elv`):

```
setup.ocx.sh/<shell>            # bare → latest-stable installer (edge-rule rewrite → latest/<shell>)
setup.ocx.sh/<shell>/next       # bleeding-edge ("next"): newest of prerelease + stable; alias /<shell>/canary
setup.ocx.sh/<shell>/<VERSION>  # pinned (immutable) → archive/<VERSION>/install.<ext>
setup.ocx.sh/dist               # → dist.json distribution manifest (OCX_INSTALL_DIST_URL)
setup.ocx.sh/dist/<sha256>.json # immutable manifest snapshot — pins the whole closure, digest-verified
```

Each installer is a **thin bootstrap**: detect platform → resolve the release from `dist.json` → download + verify the archive against the manifest's inline `sha256` → hand off to the downloaded binary's `ocx self setup` (which owns the package-store install, the per-shell env shims, and the managed shell-profile activation blocks — the installers no longer write any of that themselves). This repo owns those five installer files (and their release pipeline + the manifest). Latest-version resolution reads the self-hosted `dist.json` (no GitHub API, no `GITHUB_TOKEN` in the install path). `dist.json` itself is generated **from the `ocx-sh/ocx` GitHub Releases API** (CI-side, with `GITHUB_TOKEN`), inlining a per-target checksum + download URL, so it lists OCX *product* versions — decoupled from this repo's own `v*` tags, which version the installer scripts. The GitHub Action lives in `ocx-sh/setup-ocx` (GitHub Marketplace); the GitLab Function lives in its own repo (GitLab CI Catalog). Documentation paths (`/docs/...`) and action paths (`/actions/...`) on `setup.ocx.sh` are forwarded by nginx to those upstreams.

## Surfaces

| Path | Responsibility |
|---|---|
| `src/install.sh` | Canonical POSIX installer (bash/zsh/ash/ksh/dash). Env knobs `OCX_INSTALL_*`, exit codes 0–7, stderr-only logging, thin `ocx self setup` hand-off |
| `src/install.ps1` | PowerShell installer (cross-platform: Windows PS 5.1 Desktop floor + 7; Linux/macOS PS 7+). `.zip`/`ocx.exe` on Windows, `.tar.xz`/`ocx` on Unix. Mirrors the sh contract |
| `src/install.nu` | Nushell installer (env-driven; cross-platform) |
| `src/install.fish` | fish installer (unix-only) |
| `src/install.elv` | Elvish installer (cross-platform) |
| `scripts/publish-installers.sh` | Upload all five `src/install.*` → Bunny `archive/<VERSION>/` (immutable, write-if-absent; both `install.<ext>` and the shell-segment alias) + the `latest/` or `next/` pointer (channel-routed), then `publish-dist.sh` |
| `scripts/gen-dist.sh` | Generate `dist.json` (distribution manifest) from the **`ocx-sh/ocx` GitHub Releases API**; targets DERIVED from each release's `sha256.sum` (inline per-target checksum + URL); uses `GITHUB_TOKEN` in CI |
| `scripts/publish-dist.sh` | Regenerate + upload the manifest: immutable `dist/<sha256>.json` snapshot, `dist.json.sha256` sidecar, then the rolling `dist.json` last (overwrite, clobber-safe) |
| `external/` | Vendored Bats as git submodules (`bats-core`, `bats-support`, `bats-assert`) |
| `scripts/lib/bunny.sh` | The upload transport: `bn_put` (overwrite) / `bn_put_new` (write-if-absent) over the Bunny Edge Storage HTTP API with plain `curl`. Sends a `Checksum` header so uploads are verified server-side |
| `deploy/bunny/` | The live deployment: `edge-rules.py` (`plan`/`apply`/`verify`) owns the pull zone's routing — the per-shell `/sh /pwsh /nu /fish /elvish` (+ `/next`, `/<VERSION>`) rewrites onto `archive/ latest/ next/`, `/dist`, the `/docs/` + `/actions/` upstream proxies, the immutable-vs-300s cache split, and the `text/plain` content type. Also owns the zone **resilience settings** (`ZONE_SETTINGS` → `zone`/`zone-apply`: origin shield, origin retries, stale-while-*, request coalescing) on a separate axis from routing. See its [README](deploy/bunny/README.md) |
| `deploy/nginx/` | SUPERSEDED reference (the old self-hosted server block), kept as the rollback target until the Bunny DNS cutover is verified |
| `deploy/github/` | Reference snippet (`ocx-release-dispatch.yml.example`) the `ocx-sh/ocx` repo adds to its release workflow to dispatch `ocx-released` at this repo |
| `tests/install/*.bats` | Bats env-knob, exit-code, print-path, dist suites (sh) |
| `tests/install/{nu,fish,elvish}/*.bats` | Per-shell installer suites (gate on shell presence) |
| `tests/install/ps1/*.Tests.ps1` | Pester equivalents (ps1) |
| `tests/docker/` | Distro × arch × installer integration matrix harness |
| `.github/workflows/` | verify, test-installers, test-docker-matrix, verify-distros, release, update-dist (`dist.json` rebuild on dispatch + hourly cron + manual), `_changes.yml` (reusable path-filter: verify + test-installers skip a shell's lint/tests when neither its `src/install.*` nor a shared path changed) |

## Commands

All tasks run through [Task](https://taskfile.dev). Locally, the dev toolchain (linters, test tools) is provisioned by the OCX toolchain via [direnv](https://direnv.net) (`.envrc` runs `eval "$(ocx direnv export)"`) plus Task. CI dogfoods the same toolchain: the lint/bats workflows bootstrap it via `ocx-sh/setup-ocx` (or `tests/ci/install-ocx.sh` inside distro containers); only the Pester jobs (runner pwsh + PSGallery) and the marketplace lint actions (actionlint/markdownlint/lychee/hawkeye) remain ad-hoc.

```bash
task verify                                # lint (5 shells) + bats + pester
task shell:verify                          # shellcheck + shfmt
task pwsh:verify                           # PSScriptAnalyzer (pwsh via ocx [group.linux]; system pwsh on macOS/Windows)
task nu:verify                             # nu --ide-check
task fish:verify                           # fish -n + fish_indent --check
task elvish:verify                         # elvish -compileonly
task test:bootstrap                        # git submodule init (vendored bats)
task test:bats                             # vendored bats: env-knob, exit-code, print-path, dist, per-shell
task test:pester                           # Pester (pwsh via ocx [group.linux]; installs Pester module on demand)
task docker:integration DISTRO=alpine PLATFORM=linux/amd64
task docker:integration:all                # full 3×2 matrix
task publish:dry-run                       # validates storage keys (offline, no credentials)
task rules:plan                            # render the Bunny edge-rule set (offline)
task rules:apply                           # apply them to the pull zone (needs BUNNY_API_KEY)
task rules:verify                          # probe every routed URL against the live zone
task zone:plan                             # diff the pull-zone resilience settings (needs BUNNY_API_KEY)
task zone:apply                            # apply them + purge (needs BUNNY_API_KEY)

task release:prepare                       # interactive bump (auto|patch|minor|major) + changelog + verify
task release:prepare BUMP=minor            # non-interactive; VERSION=X.Y.Z pins exactly
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

1. **Bats** (`tests/install/*.bats` + `tests/install/{nu,fish,elvish}/`) — VENDORED bats (`external/bats-core/bin/bats`; run `git submodule update --init --recursive` first). A fixture HTTPS server (python3 + ssl) serves `dist.json` + the archive; exercises env knobs, exit-code paths, stdout/stderr discipline, the `ocx self setup` hand-off argv, and `gen-dist.sh` (`dist.bats`). Per-shell suites skip where the shell is absent. CI runs Bats on **ubuntu** (all suites incl `dist.bats`) **and macos-latest** (`bats-macos`: sh + nu + fish + elvish install suites; `dist.bats` excluded as a CI-side Linux tool). The nu/fish/elvish interpreters come from ocx.toml via `ocx run -g all …` — `-g all` because **fish lives in `[group.unix]`, not `[tools]`** (the `ocx.sh/fish-shell/fish` package has no windows leaf) and **pwsh lives in `[group.linux]`** (`ocx.sh/powershell/powershell` ships linux-glibc leaves only). `ocx run` resolves only the tools it names, but a whole-scope `ocx pull` resolves everything in scope — so the pull scopes are per-OS: Windows pulls `default` only, macOS pulls `default,unix`, Linux pulls everything. Suites are **bash-3.2-safe** (macOS stock `/bin/bash`): no negative array subscripts, and the fixture helper's `server_sha256` falls back to `shasum`. **Windows** nu/elvish use a fixture-free smoke (`smoke-windows-nu-elvish` in `test-installers.yml`) — full Bats needs bash, so it drives each installer through the `__OCX_TESTING_INSTALL_BINARY` hatch under an ocx-provisioned interpreter and asserts the PrintPath contract.
2. **Pester** (`tests/install/ps1/*.Tests.ps1`) — symmetric coverage for the PowerShell installer. Runs on windows-latest **+ ubuntu-latest + macos-latest** (install.ps1 is cross-platform; the download→extract→`self setup` path executes on the POSIX hosts, self-skips on Windows where the shell-script stub is not a PE).
3. **Docker matrix** (`tests/docker/run.sh`) — real distros × arch × **installer** (INSTALLER axis: sh/nu/fish/elvish/**pwsh**), network-free via an injected stub (the per-commit + nightly smoke); a SHELL-axis **activation matrix** (bash/dash/zsh/ksh/fish/nu/elvish) runs **nightly + dispatch** against a real network install (writes the profile/shim blocks a stub can't):
   - **Alpine** (musl) — `linux/amd64`, `linux/arm64`
   - **Fedora** (glibc, dnf) — `linux/amd64`, `linux/arm64`
   - **Ubuntu** (glibc, apt) — `linux/amd64`, `linux/arm64`

Cross-installer parity is enforced manually across all FIVE installers on the thin contract: a change to one (`src/install.sh`) must be mirrored in the others (and their tests) in the same PR. See `.claude/rules/installers.md`.

## Releases

This project is **pre-release** but has shipped: tags `v0.1.0-rc.1`, `v0.1.0`, `v0.1.1` exist (plus the `v0` major alias), so `archive/` was already populated — it was backfilled into Bunny from each tag's tree (byte-verified against the live host) rather than re-published from `main`, whose `src/` has since drifted.

- Conventional Commits drive versioning via [git-cliff](https://git-cliff.org).
- `task release:prepare` produces the version commit + tag locally; pushing the tag triggers `.github/workflows/release.yml`.
- The release workflow does: gh release (git-cliff notes; `prerelease: true` for `-`-suffixed tags) → `publish-installers` job (channel-routed upload of all five installers to Bunny Edge Storage via `BUNNY_STORAGE_KEY` + refresh/upload `dist.json` via `publish-dist.sh`). The manifest is also rebuilt out-of-band by `update-dist.yml` on `repository_dispatch(ocx-released)` from `ocx-sh/ocx` + an hourly cron fallback + manual dispatch.
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
| `BUNNY_STORAGE_KEY` | Bunny Storage Zone password for `sh-ocx-setup`, used by `publish-installers` + `update-dist`. Write access to the installer docroot — treat as high value |
| `BUNNY_STORAGE_ZONE` | Storage zone name (`sh-ocx-setup`) |
| `SETUP_OCX_DISPATCH_TOKEN` | Lives in **`ocx-sh/ocx`** (not this repo): a token scoped to setup.ocx.sh (fine-grained PAT `contents:read` + `actions:write`, or classic `repo`) that `ocx-sh/ocx` uses to fire the `repository_dispatch(ocx-released)` that rebuilds `dist.json`. See `deploy/github/ocx-release-dispatch.yml.example`. |

## Deep context

- [`.claude/rules/installers.md`](.claude/rules/installers.md) — env-knob naming, stdout discipline, exit-code matrix
- [`.claude/rules/publish.md`](.claude/rules/publish.md) — storage key layout, write-if-absent vs overwrite, versioned-vs-latest
- [`.claude/rules/testing-bash.md`](.claude/rules/testing-bash.md) — Bats + fixture HTTP server patterns
- [`.claude/rules/testing-pwsh.md`](.claude/rules/testing-pwsh.md) — Pester patterns
- [`.claude/rules/workflow-release.md`](.claude/rules/workflow-release.md) — git-cliff → tag → publish flow
- [`.claude/rules/update-docs.md`](.claude/rules/update-docs.md) — keep README/CLAUDE in sync
