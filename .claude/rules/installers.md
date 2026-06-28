# Installer rules (src/install.{sh,ps1,nu,fish,elv})

These rules govern the five canonical shell installers under `src/`. They are the load-bearing artifacts published to `setup.ocx.sh` and consumed by the GitHub Action and GitLab Function repos (which live in separate marketplaces). Be conservative.

## Thin-bootstrap contract

Every installer is a **thin bootstrap**. It does exactly four things and nothing more:

1. **Detect** the platform (`<arch>-<os>-<libc/vendor>` target triple).
2. **Resolve** the release from the distribution manifest (`dist.json`): the latest stable version (or `OCX_INSTALL_VERSION`), then the `(version, target)` row → inline `sha256` + download URL.
3. **Download + verify** the archive against the manifest's inline `sha256` (no separate `sha256.sum` fetch), then `safe_extract`.
4. **Hand off** to the downloaded binary's `ocx self setup`.

`ocx self setup` owns *everything* that touches the user's machine: the package-store self-install, the per-shell env shims under `$OCX_HOME`, the managed shell-profile activation blocks, and completions. **The installers no longer write any of that** — there is no `create_env_file`, `modify_shell_profile`, completion sentinel, or `--remote package install` bootstrap. If you find yourself adding shim/profile/completion logic to an installer, stop: it belongs in `ocx self setup`.

## `ocx self setup` hand-off (the argv contract)

Global flags precede `self setup`; subcommand args follow it (clap parses them at different levels). `--no-modify-path` is keyed off `OCX_NO_MODIFY_PATH` truthy **or** the `--no-modify-path` flag.

| Path | argv |
|---|---|
| default | `<bin> self setup <version> [--no-modify-path]` (version is a positional) |
| test hatch (`__OCX_TESTING_INSTALL_BINARY`) | `<bin> --offline self setup [--no-modify-path]` (no version positional — candidate is `local`) |
| `OCX_INSTALL_NO_SETUP` | (no invocation — binary placed on the canonical bin dir only) |

A non-zero `self setup` exit → `err`/`Err` exit **6**. The recorded argv is asserted by the Bats/Pester suites (a regression to the old `--remote package install` would fail them).

## Env-knob naming (two-tier taxonomy)

**Tier 1 — shared OCX env** (read by the binary too; no `INSTALL` infix): `OCX_HOME`, `OCX_NO_MODIFY_PATH`. Plus standard externals `NO_COLOR`, `TMPDIR`.

**Tier 2 — installer-only knobs**, all `OCX_INSTALL_*` with a strict grammar:

- **values (bare nouns):** `OCX_INSTALL_VERSION` (empty = latest stable; the portable pinning channel for every shell), `OCX_INSTALL_REPO` (`ocx-sh/ocx`).
- **endpoints (`_URL` suffix):** `OCX_INSTALL_DIST_URL` (manifest, default `https://setup.ocx.sh/dist.json`), `OCX_INSTALL_MIRROR_URL` (artifact host override — rewrites the per-target URL to `<MIRROR_URL>/<tag>/<filename>`).
- **opt-outs (`NO_` prefix):** `OCX_INSTALL_NO_SETUP` (skip `ocx self setup`), `OCX_INSTALL_NO_SMOKETEST`.
- **opt-ins (bare verb/adj):** `OCX_INSTALL_FORCE`, `OCX_INSTALL_QUIET`, `OCX_INSTALL_PRINT_PATH`.
- **sh-only:** `OCX_INSTALL_DOWNLOADER` (`curl`|`wget`).

> **`GITHUB_TOKEN` is not in the install path.** Latest-version resolution reads the self-hosted `dist.json`, not the GitHub Releases API. (`export_github_path()` / `GITHUB_PATH`, the unrelated CI PATH export, stays.)

**Rename map (history)** — old → new: `OCX_INSTALL_INDEX_URL`→`OCX_INSTALL_DIST_URL`; `OCX_INSTALL_BASE_URL`→`OCX_INSTALL_MIRROR_URL`; `OCX_INSTALL_SKIP_SELF_INIT`→`OCX_INSTALL_NO_SETUP`; `OCX_INSTALL_NO_BIN_SMOKETEST`→`OCX_INSTALL_NO_SMOKETEST`. **Dropped:** `OCX_INSTALL_FORMAT_URL`, `OCX_INSTALL_CHECKSUM_FORMAT_URL` (URLs now come inline from `dist.json`). **Added:** `OCX_INSTALL_VERSION`.

When introducing a new knob: pick the most boring possible name fitting the grammar above; default to empty/`0`; document it in `README.md` (env matrix) and the test suites; mirror it in **all five** installers (env name identical; pwsh adds a `[switch]`/`[string]` param that the env overrides).

`OCX_INSTALL_DIST_URL` is fetched over the HTTPS-enforced downloader (no token). `get_latest_version` (sh) / `Get-LatestVersion` (ps1) / the nu/fish/elvish equivalents pick the first `"channel":"stable"` leaf object (the manifest is newest-first), strip a leading `v`, and validate semver. Any fetch failure, empty body, or no-stable-entry → exit **3** with a message containing the substring `latest version`.

Truthy values (case-sensitive): `1`, `true`, `yes`, `TRUE`, `YES`, `True`, `Yes`. Anything else is falsy.

### Internal test-only hatch: `__OCX_TESTING_INSTALL_BINARY`

`__OCX_TESTING_INSTALL_BINARY` (double-underscore prefix, **TEST-ONLY, UNDOCUMENTED**) is an internal download-skip hatch. It must never appear in `usage()`/help, the README env matrix, or the user-facing tables. When set to a path, the installer (`install_local_test_binary` in sh, `Install-LocalTestBinary` in ps1, and the nu/fish/elvish equivalents):

- validates the path is a file (exit **2** on miss; message contains `__OCX_TESTING_INSTALL_BINARY`), copies it to the canonical bin dir (`$OCX_HOME/$OCX_BIN_SUBPATH/ocx`), and `chmod +x` (unix);
- **skips** download + checksum + extract + the network manifest probe (the version is `local`, so the semver validation is bypassed);
- then either runs `<bin> --offline self setup [--no-modify-path]` (default) or, under `OCX_INSTALL_NO_SETUP`, places the binary only;
- keeps the stdout/stderr discipline (all logs → stderr; honors `OCX_INSTALL_PRINT_PATH` / `-PrintPath`).

The Bats/Pester/docker suites own this hatch — they use it to exercise the install + `self setup` hand-off against a stub or real binary with no network artifact. See `.claude/rules/testing-bash.md` / `.claude/rules/testing-pwsh.md`.

## Stdout / stderr discipline (load-bearing)

All five installers must follow this contract:

- All informational, warning, and error output goes to **stderr**.
- **stdout** is silent on success unless `OCX_INSTALL_PRINT_PATH` is truthy (or `-PrintPath`), in which case the **final stdout line** is the absolute path to the OCX bin dir.
- The success banner / "installed to ..." text is informational and goes to **stderr**, not stdout.

This contract is what lets downstream callers do `BIN_DIR=$(./install.sh | tail -n1)`. Breaking it breaks every wrapper that depends on a clean stdout.

## Exit codes (stable contract)

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Generic / legacy fallback |
| 2 | Argument or environment validation failure |
| 3 | Network / download / manifest failure |
| 4 | Checksum mismatch |
| 5 | Archive extraction failure |
| 6 | `ocx self setup` failure |
| 7 | Unsupported platform / architecture |

When `err()` is called from a new code path, choose the most specific code. Adding new codes is fine; reusing them across unrelated failure modes is not — it breaks the diagnostic value for CI scripts.

### Accepted divergence: unknown-argument exit code

The exit-code contract above (codes 2–7 for in-script `err()` paths) holds identically on all installers. There is one **accepted, justified divergence** in the unknown-argument path:

- **sh / fish** — an unknown option is caught by the in-script arg parser and routed through `err "unknown option: …" 2` (sh) / argparse failure → exit **2** (fish), consistent with the rest of the contract. (nu / elvish are env-driven and ignore unknown flags.)
- **pwsh** — an unknown flag (e.g. `-BogusFlag`) is rejected by the `[CmdletBinding()]` param binder *before* `Main` ever runs. The binder owns unknown-argument rejection and exits **1**; it has no hook to emit code 2. Through the `irm … | iex` (or `[scriptblock]::Create`) idiom the parser/binder error surfaces but the pipeline yields **no deterministic exit code** — callers must not rely on a specific number there.

This divergence is accepted because PowerShell parameter binding owns unknown-argument rejection and structurally cannot emit code 2. Every exit code that *is* produced by an in-script error path (2–7) remains symmetric.

## Cross-installer parity (5-way)

`src/install.{sh,ps1,nu,fish,elv}` are independent implementations of the same thin contract. Whenever you change one, change the others in the same PR:

- New env knob → all five
- New exit code → all five
- New flag → wherever the dialect parses flags (`sh`/`fish`/`pwsh`); for `nu`/`elvish` (env-driven) wire the equivalent env knob
- Behavioral default change → all five

Tests in `tests/install/env-knobs.bats` + `tests/install/{nu,fish,elvish}/` (per-shell) and `tests/install/ps1/Knobs.Tests.ps1` (Pester) enforce parity through symmetric coverage.

### Per-dialect notes

- **sh** (`src/install.sh`) — POSIX (bash/zsh/ash/ksh/dash). `--version` flag + `OCX_INSTALL_VERSION`. curl/wget; `OCX_INSTALL_DOWNLOADER`.
- **pwsh** (`src/install.ps1`) — **cross-platform**: Windows (PS 5.1 Desktop floor + 7) AND Linux/macOS (PS 7+; 5.1 is Windows-only). Switch params `-Version -NoModifyPath -Quiet -Force -PrintPath -NoSetup -NoSmoketest`. Env wins over switches. `Detect-Architecture` emits `*-pc-windows-msvc` / `*-unknown-linux-{gnu,musl}` / `*-apple-darwin` (OS gate via `RuntimeInformation.IsOSPlatform`; the `$PSVersionTable.PSEdition -eq 'Desktop'` shortcut keeps 5.1 from ever touching the Core-only Unix branch). Binary `ocx.exe`/`ocx`; `.zip` (zip-slip-safe `System.IO.Compression`) on Windows, `.tar.xz` (shells to `tar xf`, needs `xz-utils`) on Unix — dispatch keys off the manifest filename extension. 5.1-safety: no ternary/`??`/`&&`/`||`/`$IsWindows`/`$IsMacOS`/`$IsLinux` (the last collide with read-only auto-vars — local vars use other names).
- **nu** (`src/install.nu`) — Nushell, cross-platform. **Env-driven** (Nushell gets no positional args over `curl | nu`): pin with `OCX_INSTALL_VERSION`. Native JSON (`from json`), `open --raw | hash sha256`.
- **fish** (`src/install.fish`) — fish, unix-only. `argparse` flags + env. JSON via `string match -r` on the flat manifest (no jq). NB: `version` is a reserved fish var — locals use `ocxver`.
- **elvish** (`src/install.elv`) — Elvish, cross-platform. Native `from-json`; `?()`/`try` wrap every external (Elvish throws on nonzero external exit).

## Canonical bin dir

`OCX_BIN_SUBPATH = symlinks/ocx.sh/ocx/cli/current/content/bin`. `${OCX_HOME}/${OCX_BIN_SUBPATH}` is what `OCX_INSTALL_PRINT_PATH` emits, what the idempotent fast-path probes (`<bin>/ocx version` == requested version, unless `OCX_INSTALL_FORCE`), what `OCX_INSTALL_NO_SETUP` populates, and what `ocx self setup` symlinks into the package store on the default path.
