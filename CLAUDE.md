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
| `src/install.ps1` | PowerShell installer (cross-platform: Windows PS 5.1 Desktop floor + 7; Linux/macOS PS 7+). `.zip`/`ocx.exe` on Windows, `.tar.gz` (older releases `.tar.xz`)/`ocx` on Unix. Mirrors the sh contract |
| `src/install.nu` | Nushell installer (env-driven; cross-platform) |
| `src/install.fish` | fish installer (unix-only) |
| `src/install.elv` | Elvish installer (cross-platform) |
| `scripts/publish-installers.sh` | Upload all five `src/install.*` → Bunny `archive/<VERSION>/` (immutable, write-if-absent; both `install.<ext>` and the shell-segment alias) + the `latest/` or `next/` pointer (channel-routed), then `publish-dist.sh` |
| `scripts/gen-dist.sh` | Generate `dist.json` (distribution manifest) from the **`ocx-sh/ocx` GitHub Releases API**; targets DERIVED from each release's `sha256.sum` (inline per-target checksum + URL); uses `GITHUB_TOKEN` in CI |
| `scripts/publish-dist.sh` | Regenerate + upload the manifest: immutable `dist/<sha256>.json` snapshot, `dist.json.sha256` sidecar, then the rolling `dist.json` last (overwrite, clobber-safe) |
| `external/` | Vendored Bats as git submodules (`bats-core`, `bats-support`, `bats-assert`) |
| `scripts/lib/bunny.sh` | Sourced LIB (no shebang, mode 100644): `bn_put` (overwrite) / `bn_put_new` (write-if-absent) over the Bunny Edge Storage HTTP API with plain `curl`. The key travels on stdin as a header file (`curl -H @-`), never argv; a `Checksum` header makes uploads verified server-side. `bn_put_new` probes first: 404 = absent, 200 = present, anything else exits 3 and writes nothing |
| `scripts/shell-gate.sh`, `shell-format.sh`, `core-weaken.sh`, `core-weaken-ack.sh`, `hex_in_comment.awk` | Shell gate of record (ShellCheck + shfmt over the git-fed file list, hygiene, nu/fish/elvish parse), the formatter, the scan for added lines that weaken a check, its PR-job wrapper (a finding passes only when a commit body carries `Weaken-Ok: <path>: <kind>: <reason>`), and the commit-hash-in-comment scan |
| `scripts/fish-scan.sh`, `fish-indent.sh`, `elv-gate.sh`, `nu-gate.nu` | Per-dialect gates: fish habit scan + `fish_indent` (the ocx fish package ships none, so the script links the multicall binary), elvish compile/deprecation/removed-name check, nu strict parse |
| `scripts/bats-ci.sh`, `bats-census.sh`, `bats-lint.sh`, `bats-runner-list.sh` | Bats pipeline: `bats-ci.sh` runs pinned bats 1.14.0 under `--tap`, a canary failing suite that must go red, then `bats-census.sh` (disk count = TAP plan, zero skip budget). It does not lint: `bats-lint.sh` (vacuous test forms) and `bats-runner-list.sh` (unlisted suites) run separately as `task test:bats:lint` |
| `scripts/ci-*.sh`, `ci-*.py` | Workflow and Taskfile lint behind `task ci:verify` (step shell, tainted `${{ }}`, or/and chains, pipefail, ShellCheck over embedded bodies) |
| `scripts/Invoke-PSGate.ps1`, `Invoke-PesterGate.ps1`, `Install-PinnedModule.ps1`, `gates-parse-gate.ps1`, `ps-sec-iex-leak.ps1`, `ps-sec-iex-survival.ps1`, `Test-DiscoveryCode.ps1`, `pester-lint.sh` | PowerShell gates: PSScriptAnalyzer 1.25.0 wrapper, the Pester 6.2.0 census, pinned module install, 5.1 parse, `irm \| iex` leak and survival probes, Pester discovery-time code lint |
| `.shellcheckrc`, `.editorconfig`, `.gitattributes`, `PSScriptAnalyzerSettings.{installer,test}.psd1` | Gate profiles: ShellCheck (default severity plus four profile keys), shfmt style, LF-only line endings, one analyzer settings file per kind (`src/` vs tests), and `zizmor.yml` (the one recorded zizmor ignore) |
| `tests/scripts/*.bats` | Bats for the publish/dist scripts and the docker harness: `bunny.sh` probe semantics and key-off-argv (PATH-stub `curl` recording argv and stdin), `gen-dist.sh` token handling, TERM handling of `gen-dist.sh`/`publish-dist.sh`, `smoke.sh`/`install-shells.sh` failing closed, and `shell-gate.bats` (the shell gate against a temporary repository: clean pass, authored-script failure, and a tracked vendored fixture it must not lint). Run by `task test:bats` and the `bats-linux` CI job |
| `deploy/bunny/` | The live deployment: `edge-rules.py` (`plan`/`apply`/`verify`) owns the pull zone's routing — the exact-`/` 302 to `ocx.sh/install/`, the per-shell `/sh /pwsh /nu /fish /elvish` (+ `/next`, `/<VERSION>`) rewrites onto `archive/ latest/ next/`, `/dist`, the `/docs/` + `/actions/` upstream proxies, the immutable-vs-300s cache split, and the `text/plain` content type. Also owns the zone **resilience settings** (`ZONE_SETTINGS` → `zone`/`zone-apply`: origin shield, origin retries, stale-while-*, request coalescing) on a separate axis from routing. See its [README](deploy/bunny/README.md) |
| `deploy/nginx/` | SUPERSEDED reference (the old self-hosted server block), kept as the rollback target until the Bunny DNS cutover is verified |
| `deploy/github/` | Reference snippet (`ocx-release-dispatch.yml.example`) the `ocx-sh/ocx` repo adds to its release workflow to dispatch `ocx-released` at this repo |
| `tests/install/*.bats` | Bats env-knob, exit-code, print-path, dist suites (sh) |
| `tests/install/{nu,fish,elvish}/*.bats` | Per-shell installer suites (`server_require_shell`: skip locally when the shell is absent, fail when `OCX_TEST_REQUIRE_SHELLS` is set) |
| `tests/install/ps1/*.Tests.ps1` | Pester equivalents (ps1); `Fixture.psm1` serves the fixture over TLS, `Run-Installer.ps1` + `Trust-Fixture.ps1` launch the installer trusting the localhost cert |
| `tests/docker/` | Distro × arch × installer integration matrix harness |
| `site/` | The `/install/` section of ocx.sh (Astro Starlight, deployed to the `ocx.sh` storage zone, not this one). Pages `index/versions/configuration/mirrors/reference/examples` (MDX), `scripts/` (`check-anchors`, `check-fences`, `docs-gate`, and `contract.test.mjs`, the drift guard that compares every `OCX_INSTALL_*` knob and `# Exit:` code in `src/install.*` with `configuration.mdx` / `reference.mdx`), `record-casts.mjs` + `run-cast-script.sh` (record `casts/*.sh` in containers against the live setup.ocx.sh into the committed `public/casts/`), `session-casts.test.mjs` (every page ShellSession is a subset of its cast's final screen), `casts/README.md` (cast keys). Canonical home of the knob, exit-code, pinning and mirror docs; the README links to it |
| `taskfiles/site.taskfile.yml`, `ocx.toml` `[group.site.tools]` / `[group.casts.tools]` | `site:install`, `site:dev`, `site:build`, `site:test` (part of `task verify`), `site:check`, `site:lighthouse` (all four categories 100 plus size budgets over every built page), `site:casts` (records the casts; needs docker and network, not part of `verify`). Node, pnpm and uv come from the `site` ocx group (`ocx exec -g site --`) |
| `.github/workflows/` | verify, test-installers, test-docker-matrix, verify-distros, release, update-dist (`dist.json` rebuild on dispatch + hourly cron + manual), `site` (build, check and Lighthouse the `/install/` site on PRs; deploy to ocx.sh on a `v*` tag or dispatch, behind `vars.BUNNY_DEPLOY`, environment `ocx.sh` needs a `v*` tag deployment rule), `_changes.yml` (reusable path-filter: verify + test-installers skip a shell's lint/tests when neither its `src/install.*` nor a shared path changed; the shared set includes `tests/scripts/**`, `.gitmodules` and `zizmor.yml`). `verify.yml` also runs a `zizmor` job (workflow security audit, `zizmor.yml` config) and, on PRs, `cog check` |

## Commands

All tasks run through [Task](https://taskfile.dev). Locally, the dev toolchain (linters, test tools) is provisioned by the OCX toolchain via [direnv](https://direnv.net) (`.envrc` runs `eval "$(ocx direnv export)"`) plus Task. CI dogfoods the same toolchain: the lint/bats workflows bootstrap it via `ocx-sh/setup-ocx` (or `tests/ci/install-ocx.sh` inside distro containers); only the Pester jobs (runner pwsh + PSGallery) and the marketplace lint actions (actionlint/markdownlint/lychee/hawkeye) remain ad-hoc.

```bash
task verify                                # lint (5 shells, workflows, meta) + bats + pester
task ci:verify                             # workflow + Taskfile checks (scripts/ci-verify.sh)
task ci:zizmor                             # zizmor audit of the workflows (pinned version, offline, medium floor; config zizmor.yml)
task shell:verify                          # scripts/shell-gate.sh (ShellCheck + shfmt + hygiene + nu/fish/elvish parse), bats lint, comment hash scan
task shell:format                          # rewrite shell files with shfmt (style from .editorconfig)
task shell:weaken [BASE=origin/main]       # print added lines that weaken a check (PR-only job in verify.yml)
task pwsh:verify                           # PSScriptAnalyzer 1.25.0 via Invoke-PSGate.ps1 (pwsh via ocx [group.linux]; system pwsh on macOS/Windows)
task nu:verify                             # nu-gate.nu --strict
task fish:verify                           # fish --no-execute + fish-scan.sh + fish_indent --check
task elvish:verify                         # elv-gate.sh
task site:test                             # /install/ site unit tests + installer-contract drift guard
task site:check                            # build the site + anchors, fences, docs-quality gate, ocx-site check
task site:lighthouse                       # Lighthouse over the built /install/ pages (Chromium via Playwright)
task site:dev                              # Astro dev server for /install/
task test:bootstrap                        # git submodule init (vendored bats)
task test:bats                             # bats 1.14.0 through scripts/bats-ci.sh (census, zero skip budget)
task test:bats:lint                        # bats-lint.sh + bats-runner-list.sh
task test:pester                           # Pester 6.2.0 through Invoke-PesterGate.ps1 (census; installs the pinned module)
task test:pester:lint                      # pester-lint.sh + Test-DiscoveryCode.ps1
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
| 2 | Argument or environment validation; no SHA-256 tool; `OCX_INSTALL_CA_BUNDLE` with a wget that cannot take it |
| 3 | Network / download / manifest failure; manifest row without a valid `sha256`; non-`https` URL |
| 4 | Checksum mismatch; unpinned manifest over a wget without TLS validation (`sh`, `fish`) |
| 5 | Archive extraction failure |
| 6 | `ocx self setup` failure |
| 7 | Unsupported platform / architecture (also an undecidable glibc/musl Linux host, in all five installers) |
| 129 / 130 / 143 | `sh` and `fish` only: `SIGHUP` / `SIGINT` / `SIGTERM` (fish from its 3.6.0 floor). nu, elvish and pwsh cannot trap |

Pick the most specific code when calling `err()`. Reusing codes across unrelated failures breaks downstream CI diagnostics.

## Testing tiers

1. **Bats** (`tests/install/*.bats` + `tests/install/{nu,fish,elvish}/`) — VENDORED bats (`external/bats-core/bin/bats`; run `git submodule update --init --recursive` first). A fixture HTTPS server (python3 + ssl) serves `dist.json` + the archive; exercises env knobs, exit-code paths, stdout/stderr discipline, the `ocx self setup` hand-off argv, and `gen-dist.sh` (`dist.bats`). Every leg goes through `scripts/bats-ci.sh`: pinned bats 1.14.0 under `--tap`, a canary failing suite that must go red, then the census (static `@test` count on disk = TAP plan = result lines). The skip budget is zero: CI sets `OCX_TEST_REQUIRE_SHELLS=1`, so `server_require_shell` fails an absent interpreter instead of skipping. Linux CI sets `CENSUS_SKIP_OK` empty, so no skip passes there; the platform-fact allowlist (`GNU wget not installed`, `timeout(1) not available`, plus `busybox has no macOS build` on macOS) applies only to the macOS leg and `task test:bats`. The macOS leg drops `dist.bats` via `CENSUS_EXCLUDE`. Declared interpreter floors: `sh` runs on dash, busybox ash, ksh and bash 3.2; fish 3.6.0 (tested 3.6.0 to 4.8); nu 0.105.1 to 0.116.1; Elvish 0.20.1 (tested 0.20.1 and 0.21.0). CI runs the `ocx.lock` versions (re-resolved against the floating tags in `ocx.toml` with ocx 0.6.5, so the locked tools are newer than before), so the floors are checked by running the suites in containers (Elvish 0.20.1 on `alpine:3.20`, fish 3.6.0 on `debian:12`). CI runs Bats on **ubuntu** (all suites incl `dist.bats`, plus `tests/scripts`; `CENSUS_SKIP_OK` is empty, so no skip passes) **and macos-26** (`bats-macos`: sh + nu + fish + elvish install suites; `dist.bats` excluded as a CI-side Linux tool). The nu/fish/elvish interpreters come from ocx.toml via `ocx run -g all …` — `-g all` because **fish lives in `[group.unix]`, not `[tools]`** (the `ocx.sh/fish-shell/fish` package has no windows leaf) and **pwsh lives in `[group.linux]`** (the locked `ocx.sh/powershell/powershell` now has darwin and windows leaves, but only glibc on Linux, no musl; macOS and Windows still use a system pwsh). `ocx run` resolves only the tools it names, but a whole-scope `ocx pull` resolves everything in scope — so the pull scopes are per-OS: Windows pulls `default` only, macOS pulls `default,unix`, Linux pulls everything. Suites are **bash-3.2-safe** (macOS stock `/bin/bash`): no negative array subscripts, and the fixture helper's `server_sha256` falls back to `shasum`. **Windows** nu/elvish use a fixture-free smoke (`smoke-windows-nu-elvish` in `test-installers.yml`) — full Bats needs bash, so it drives each installer through the `__OCX_TESTING_INSTALL_BINARY` hatch under an ocx-provisioned interpreter and asserts the PrintPath contract.
2. **Pester** (`tests/install/ps1/*.Tests.ps1`) — symmetric coverage for the PowerShell installer, pinned to Pester 6.2.0 and run through `Invoke-PesterGate.ps1` (a census: red on zero tests, a changed plan or skips above `-MaxSkipped`, which is 0 on Linux/macOS and 22 on Windows, where the stub-exec tests and the Unix-only `Get-UnixTarget` test self-skip). The fixture serves TLS (python `ssl`, the vendored localhost cert) and suites launch the installer through `Run-Installer.ps1`/`Trust-Fixture.ps1`; `Source.Tests.ps1` and the `iex:` scenarios in `ExitCodes.Tests.ps1` pin the source contract and the `irm | iex` isolation. Runs on windows-latest **+ ubuntu-latest + macos-26** (install.ps1 is cross-platform; the download→extract→`self setup` path executes on the POSIX hosts, self-skips on Windows where the shell-script stub is not a PE).
3. **Docker matrix** (`tests/docker/run.sh`) — real distros × arch × **installer** (INSTALLER axis: sh/nu/fish/elvish/**pwsh**), network-free via an injected stub (the per-commit + nightly smoke); a SHELL-axis **activation matrix** (bash/dash/zsh/ksh/fish/nu/elvish) runs **nightly + dispatch** against a real network install (writes the profile/shim blocks a stub can't):
   - **Alpine** (musl) — `linux/amd64`, `linux/arm64`
   - **Fedora** (glibc, dnf) — `linux/amd64`, `linux/arm64`
   - **Ubuntu** (glibc, apt) — `linux/amd64`, `linux/arm64`

   A missing requested shell or a failed shell download fails the cell (`install-shells.sh` exits 69 / 3); `NU_VERSION` is pinned at the nu floor, 0.105.1.
4. **Script suites** (`tests/scripts/*.bats`) — publish/dist scripts and the docker harness, no fixture server. Linux only (`docker-harness.bats` reads `/etc/os-release`; needs `python3`, `sh`, `seq`). `task test:bats` runs them as its second `bats-ci.sh` call (`TESTS_DIR=tests/scripts`), and the `bats-linux` CI job runs them too.

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

- [`.claude/rules/installers.md`](.claude/rules/installers.md) — env-knob naming, stdout discipline, exit-code matrix, per-dialect floors, and the recorded overrides of the shell-quality defaults
- [`.claude/rules/publish.md`](.claude/rules/publish.md) — storage key layout, write-if-absent vs overwrite, versioned-vs-latest
- [`.claude/rules/testing-bash.md`](.claude/rules/testing-bash.md) — Bats + fixture HTTP server patterns
- [`.claude/rules/testing-pwsh.md`](.claude/rules/testing-pwsh.md) — Pester patterns
- [`.claude/rules/workflow-release.md`](.claude/rules/workflow-release.md) — git-cliff → tag → publish flow
- [`.claude/rules/update-docs.md`](.claude/rules/update-docs.md) — keep README/CLAUDE in sync
