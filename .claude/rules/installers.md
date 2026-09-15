# Installer rules (src/install.{sh,ps1,nu,fish,elv})

These rules govern the five canonical shell installers under `src/`. They are the load-bearing artifacts published to `setup.ocx.sh` and consumed by the GitHub Action and GitLab Function repos (which live in separate marketplaces). Be conservative.

## Thin-bootstrap contract

Every installer is a **thin bootstrap**. It does exactly four things and nothing more:

1. **Detect** the platform (`<arch>-<os>-<libc/vendor>` target triple).
2. **Resolve** the release from the distribution manifest (`dist.json`): the latest stable version (or `OCX_INSTALL_VERSION`), then the `(version, target)` row → inline `sha256` + download URL.
3. **Download + verify** the archive against the manifest's inline `sha256` (no separate `sha256.sum` fetch), then `safe_extract`.
   Every network fetch is **retried 3 times with 1s/2s backoff** — see *Download retry* below.
4. **Hand off** to the downloaded binary's `ocx self setup`.

`ocx self setup` owns *everything* that touches the user's machine: the package-store self-install, the per-shell env shims under `$OCX_HOME`, the managed shell-profile activation blocks, and completions. **The installers no longer write any of that** — there is no `create_env_file`, `modify_shell_profile`, completion sentinel, or `--remote package install` bootstrap. If you find yourself adding shim/profile/completion logic to an installer, stop: it belongs in `ocx self setup`.

## `ocx self setup` hand-off (the argv contract)

Global flags precede `self setup`; subcommand args follow it (clap parses them at different levels). `--no-modify-path` is keyed off `OCX_NO_MODIFY_PATH` truthy **or** the `--no-modify-path` flag.

| Path | argv |
|---|---|
| default | `<bin> self setup <version> [--no-modify-path] [--managed-config <REF>]` (version is a positional) |
| test hatch (`__OCX_TESTING_INSTALL_BINARY`) | `<bin> --offline self setup [--no-modify-path]` (no version positional — candidate is `local`; no `--managed-config`, the OCI fetch cannot succeed offline) |
| `OCX_INSTALL_NO_SETUP` | (no invocation — binary placed on the canonical bin dir only) |

`--managed-config <REF>` is appended **only** when the embedded `@OCX_MANAGED_CONFIG@`
placeholder has been replaced **and** `OCX_MANAGED_CONFIG` is unset in the
environment. `ocx self setup` resolves the ref itself when the flag is absent
(its own order is flag > `OCX_MANAGED_CONFIG` > existing seed), so omitting the
flag is what keeps env ahead of embedded.

A non-zero `self setup` exit → `err`/`Err` exit **6**. The recorded argv is asserted by the Bats/Pester suites (a regression to the old `--remote package install` would fail them).

## Env-knob naming (two-tier taxonomy)

**Tier 1 — shared OCX env** (read by the binary too; no `INSTALL` infix): `OCX_HOME`, `OCX_NO_MODIFY_PATH`, `OCX_MANAGED_CONFIG`. Plus standard externals `NO_COLOR`, `TMPDIR`.

**Tier 2 — installer-only knobs**, all `OCX_INSTALL_*` with a strict grammar:

- **values (bare nouns):** `OCX_INSTALL_VERSION` (empty = latest stable; the portable pinning channel for every shell), `OCX_INSTALL_REPO` (`ocx-sh/ocx`), `OCX_INSTALL_CA_BUNDLE` (CA bundle for every download — a PEM file path, or the PEM text itself; see below).
- **endpoints (`_URL` suffix):** `OCX_INSTALL_DIST_URL` (manifest, default `https://setup.ocx.sh/dist.json`; a `dist/<sha256>.json` snapshot URL pins the manifest — see below), `OCX_INSTALL_MIRROR_URL` (artifact host override — rewrites the per-target URL to `<MIRROR_URL>/<tag>/<filename>`).
- **opt-outs (`NO_` prefix):** `OCX_INSTALL_NO_SETUP` (skip `ocx self setup`), `OCX_INSTALL_NO_SMOKETEST`.
- **opt-ins (bare verb/adj):** `OCX_INSTALL_FORCE`, `OCX_INSTALL_QUIET`, `OCX_INSTALL_PRINT_PATH`.
- **sh-only:** `OCX_INSTALL_DOWNLOADER` (`curl`|`wget`).

> **`GITHUB_TOKEN` is not in the install path.** Latest-version resolution reads the self-hosted `dist.json`, not the GitHub Releases API. (`export_github_path()` / `GITHUB_PATH`, the unrelated CI PATH export, stays.)

**Rename map (history)** — old → new: `OCX_INSTALL_INDEX_URL`→`OCX_INSTALL_DIST_URL`; `OCX_INSTALL_BASE_URL`→`OCX_INSTALL_MIRROR_URL`; `OCX_INSTALL_SKIP_SELF_INIT`→`OCX_INSTALL_NO_SETUP`; `OCX_INSTALL_NO_BIN_SMOKETEST`→`OCX_INSTALL_NO_SMOKETEST`. **Dropped:** `OCX_INSTALL_FORMAT_URL`, `OCX_INSTALL_CHECKSUM_FORMAT_URL` (URLs now come inline from `dist.json`). **Added:** `OCX_INSTALL_VERSION`, `OCX_INSTALL_CA_BUNDLE`.

When introducing a new knob: pick the most boring possible name fitting the grammar above; default to empty/`0`; document it in `README.md` (env matrix) and the test suites; mirror it in **all five** installers (env name identical; pwsh adds a `[switch]`/`[string]` param that the env overrides).

### The embedded configuration block (corporate mirrors)

Every installer carries a sed-able configuration block near the top, so a site
can host ONE patched copy carrying its own defaults. Four placeholders:
`@OCX_INSTALL_DIST_URL@`, `@OCX_INSTALL_MIRROR_URL@`, `@OCX_INSTALL_CA_BUNDLE@`,
`@OCX_MANAGED_CONFIG@` — each named for the environment variable it backs.

**The uniform-sed contract is the point, and it is load-bearing.** Assignment
syntax diverges across the five dialects (`X=`, `$X =`, `set -g X`, `def`,
`var`), so the sed target can never be the LINE. What all five share is the `#`
comment character and a single-quoted string literal, so the target is the
**token inside the quotes**. Consequences to preserve:

- Each token appears **exactly once per file**, on its assignment line. Never
  write a complete token anywhere else — a live token in a header comment gets
  rewritten too, which is why the in-file recipe says `<TOKEN>`, not a real one.
- Values are **single-quoted** in all five dialects: no interpolation, and
  newlines are allowed — an entire PEM block substitutes cleanly for
  `@OCX_INSTALL_CA_BUNDLE@`. Values must not contain a single quote.
- An unreplaced placeholder is **ignored**: the guard matches `@OCX_*@` (sh
  `case`, fish/pwsh `-like`/`string match`, nu/elvish prefix+suffix). The guard
  pattern deliberately carries **no complete token**, so no sed can corrupt it.
  A pristine installer must therefore behave bit-identically to one with no
  block at all.
- **Precedence is environment > embedded > built-in default.** The dialect's
  existing default idiom is preserved; only its fallback is rerouted through the
  resolver (`ocx_cfg` / `__ocx_cfg` / `__ocx-cfg` / `ocx-cfg` /
  `Resolve-EmbeddedConfig`).

`tests/install/helpers/server.bash` (`server_embed_config`) and
`tests/install/ps1/Fixture.psm1` (`New-EmbeddedInstaller`) patch a copy the same
way a mirror would; both deliberately do a plain literal replace with no
per-shell special-casing, which is what makes them a regression test for the
uniform-sed contract itself.

### Download retry

Every network hop retries **3 times, 1s then 2s**, in all five dialects. Both
fetches (manifest and archive) are idempotent GETs, so this is safe.

| Dialect | Retry wrapper | Single-shot inner |
|---|---|---|
| sh | `download_to_file` | `download_once` |
| fish | `__ocx_download_file` | `__ocx_download_once` |
| nu | `__ocx-fetch-text`, `__ocx-download-file` | `…-once` variants |
| elvish | `ocx-fetch-text`, `ocx-download-file` | inline `while` |
| pwsh | `Download-File`, `Download-String` | `Download-FileOnce`, `Download-StringOnce` |

Rules to preserve:

- **Retries on ANY failure**, not on a parsed status code — status parsing would
  mean five dialect-specific error grammars. The accepted ceiling: a genuine 404
  costs two extra requests before it still exits 3.
- **The attempt count is not a knob.** No `OCX_INSTALL_RETRIES` — three is right
  for a transient edge failure and nothing has asked to tune it.
- **Retry the fetch only.** Checksum mismatch (exit 4) sits outside these
  functions and stays single-shot; a corrupt body is not a transient error.
- **Exit codes are unchanged** — exhausted retries still `err … 3`.
- The retry notice goes through `say`/`__ocx-say`/`Say` (stderr, silenced by
  `OCX_INSTALL_QUIET`), never `warn`.
- `Download-String` **rethrows** the original exception once exhausted, so the
  caller's existing `try/catch → Err 3` fires unchanged.
- nu: the wrapper must use `while`, not `loop` — a `loop` evaluates to
  `nothing` and fails the declared return type under `nu --ide-check`. The
  `-once` fetch returns `''` on failure rather than `null`, because a `mut`
  seeded with `null` is typed `nothing` and poisons the `-> string` signature.

This exists because a single CDN edge PoP served HTTP 500 for `dist.json` on
100% of its requests for four days while every other PoP was healthy. Retry is
defence in depth, not the cure — a client pinned to a bad PoP retries into the
same wall. See [`deploy/bunny/README.md`](../../deploy/bunny/README.md).

### `OCX_INSTALL_CA_BUNDLE`

A PEM **file path**, or the PEM text itself, materialized to a temp file (which
is what curl/wget need, and what `SSL_CERT_FILE` names). A value that is neither
a readable file nor an inline PEM block → exit **2**.

Detection is by **content, not by a leading marker**: the value counts as inline
PEM when it *contains* `-----BEGIN` anywhere. A real distro bundle opens with
comment lines or a certificate label (Fedora/RHEL's extracted
`tls-ca-bundle.pem` does exactly that), so a `starts-with` test rejects genuine
bundles; a filesystem path can never contain `-----BEGIN`, so the looser test
costs nothing. The fixture suites feed a comment-prefixed bundle
(`server_ca_bundle_inline`) to keep this honest.

Threaded into curl as `--cacert` and wget as `--ca-certificate=`, passed as its
own argv element so a path containing spaces works. In `install.nu` a configured
bundle **skips the `http get` attempt entirely** and takes the `^curl` path —
`http get` has no CA-bundle option, and letting it run would succeed against the
wrong trust store.

**Both hops, one bundle.** An install is two HTTPS conversations: the installer
fetches manifest + archive, then `ocx self setup` pulls the package store from the
registry. Covering only the first hop would leave `self setup` failing behind
exactly the proxy the knob exists for, so when the knob is set the installer
hands the bundle to the child through **two** variables (each only when not
already in the environment — env wins, as everywhere):

- **`OCX_EXTRA_CA_CERTS=<value as supplied>`** — path or PEM text, unchanged;
  ocx does the same `-----BEGIN` content sniff. `ocx self setup` (ocx ≥ the
  release carrying [ocx-sh/ocx#465](https://github.com/ocx-sh/ocx/pull/465))
  reads it before any network hop and persists the certificate text as
  `extra_ca_certs_pem` in `$OCX_HOME/config.toml`, so every later `ocx`
  invocation trusts the CA — on Windows and macOS too. Roots are additive. An
  older ocx ignores the unknown variable; an env var, not a flag, is what keeps
  the installers compatible with every released ocx. ocx caps the value at
  32 KiB (a concatenated public-roots bundle exceeds it → `self setup` refuses →
  exit 6; the README tells users to pre-set the corporate root alone).
- **`SSL_CERT_FILE=<resolved path>`** — how an older ocx discovers a host CA
  (merged into its compiled-in Mozilla roots, PEM only). reqwest's platform
  verifier reads it on **Linux/BSD only**; on Windows and macOS it is a no-op.
  Kept for that older ocx, never the primary hand-off.

Note the asymmetry, and keep it documented: `curl --cacert` / `wget
--ca-certificate` **replace** the system trust store, whereas OCX **merges**. A
bundle that must reach a public host as well as an internal one needs the public
roots in it.

Trust only: the inline `sha256` from `dist.json` remains the integrity boundary.
See [`mirror-auth.md`](mirror-auth.md).

**ACCEPTED DIVERGENCE — `install.ps1` does not use it for its OWN downloads.**
`Invoke-WebRequest` has no PowerShell 5.1-safe CA-bundle parameter, and a
`ServerCertificateValidationCallback` override is out of scope. install.ps1
therefore emits one `Warn` and continues on the system trust store for the
manifest + archive fetch, so a uniformly sed-ed installer set still installs; on
Windows the CA belongs in the machine certificate store. **Everything else stays
symmetric**: it validates the value (exit **2**), materializes an inline PEM to a
temp file, and exports `OCX_EXTRA_CA_CERTS` + `SSL_CERT_FILE` for the `ocx self
setup` hand-off — the divergence is exactly one flag, not the knob.

Materializing in ps1 is not optional: `SSL_CERT_FILE` names a PATH, so exporting
raw PEM text would hand `ocx self setup` garbage.

### Content-addressed manifest pins

`OCX_INSTALL_DIST_URL` may name a **content-addressed snapshot** — `.../dist/<sha256>.json`, published by `scripts/publish-dist.sh` and by `ocx-mirror dist sync`. Every release row already carries an inline `sha256`, so pinning the manifest pins the whole closure.

All five installers detect the pin the same way and MUST keep doing so: strip any `?query`/`#fragment`, take the basename, and match `^[0-9a-f]{64}\.json$`. On a match the manifest is downloaded **to a file** and hashed there — never captured into a shell variable, because every dialect's command substitution strips the trailing newline the digest covers — then compared:

- mismatch → exit **4** (the ordinary checksum code);
- no `sha256sum`/`shasum` available → exit **2**. A pin MUST NOT degrade to the unverified warn-and-continue path that a rolling manifest allows: the digest is the only thing authenticating it.
- Non-pinned (rolling) URLs are unchanged — nothing to verify against.

The verification call must sit in **statement position**, not inside a command substitution or an `if` condition: POSIX `$(…)` runs in a subshell, and fish demotes `exit` inside a conditional's command to a plain return — either way the process would continue past a failed check and report the wrong code. `sh` and `fish` therefore pass a destination path into `fetch_dist` / `__ocx_fetch_dist` instead of echoing the body.

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
- New embedded-config placeholder → all five, same token spelling, once per file
- New exit code → all five
- Download/retry semantics → all five (see *Download retry*)
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
