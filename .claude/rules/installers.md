# Installer rules (src/install.{sh,ps1,nu,fish,elv})

These rules govern the five canonical shell installers under `src/`. They are the load-bearing artifacts published to `setup.ocx.sh` and consumed by the GitHub Action and GitLab Function repos (which live in separate marketplaces). Be conservative.

## Thin-bootstrap contract

Every installer is a **thin bootstrap**. It does exactly four things and nothing more:

1. **Detect** the platform (`<arch>-<os>-<libc/vendor>` target triple).
2. **Resolve** the release from the distribution manifest (`dist.json`): the latest stable version (or `OCX_INSTALL_VERSION`), then the `(version, target)` row → inline `sha256` + download URL.
3. **Download + verify** the archive against the manifest's inline `sha256` (no separate `sha256.sum` fetch), then `safe_extract`.
   Every network fetch is **retried 3 times with 1s/2s backoff** — see *Download retry* below. Integrity **fails closed** — see *Integrity fails closed* below.
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

### Transport: https at script level, probed downloader flags

- **https is asserted by the script, not left to the backend.** The manifest URL,
  the mirror-rewritten archive URL and the manifest-row URL are each refused with
  exit **3** (message contains `non-https`) before any request, in all five
  dialects and on every backend, loopback included — there is no `http://127.0.0.1`
  exemption. The assert sits in **statement position** (not in a command
  substitution or `if` condition, where a dialect's `exit` demotes to a return) and
  before the request is made. It does not run before the downloader is chosen: sh
  asserts inside `download_once`, after `detect_downloader`. curl's `--proto '=https'` stays as defence in
  depth; the fixture servers speak TLS for the same reason.
- **Optional downloader flags are probed, never assumed** (sh and fish; nu, elvish
  and pwsh use no wget). `curl --tlsv1.2` is sent only when `curl --help all` lists
  it; wget gets only `-q -O` plus whichever of `--https-only`,
  `--secure-protocol=TLSv1_2` and `--ca-certificate` its `--help` lists. A flag
  BusyBox rejects would otherwise fail every download.
- **BusyBox wget** is recognised by its `--help` banner and draws one `warn`, in sh
  and in fish. A CA bundle with a wget that lacks `--ca-certificate` is exit **2**:
  never fall back silently to the system store. In sh and fish, a wget that prints
  `certificate validation not implemented` marks the transport unvalidated, and an
  unpinned (rolling) manifest fetched over it is exit **4**; a `dist/<sha256>.json` pin is still accepted because
  the digest authenticates it. Accepted gap: without `--https-only` such a wget
  does not itself refuse an https-to-http redirect.
- **pwsh** forces TLS 1.2 for `Invoke-WebRequest` through `Enable-Tls12`: it assigns
  by number (adding Tls13 only when the enum has it, never naming `Tls13`), never
  `-bor`s onto the current value, and restores the caller's `SecurityProtocol` in
  `finally`.

### Integrity fails closed

Every installer verifies the archive against the manifest's inline `sha256` and
**never** downgrades to warn-and-continue. There is no `required` argument on the
verify function in any dialect.

- **No hash tool → exit 2**, before the download is trusted. sh accepts
  `sha256sum`, `shasum` or `openssl`; fish and elvish the same three
  (elvish uses `certutil` on Windows); nu (`hash sha256`) and pwsh
  (`Get-FileHash`) hash in-process, so have no missing-tool case.
- **A manifest row whose `sha256` is blank, absent or not 64 hex digits → exit 3**,
  message contains `no valid sha256`, checked right after the row lookup and before
  any download (so the idempotent fast path is unaffected). nu and elvish compare
  case-insensitively.
- **A mismatch → exit 4**, single-shot (see *Download retry*).

### Temp files and signals

Temp files are removed on success, on the idempotent fast path and on **every** error
exit. The mechanism is per dialect:

| Dialect | Mechanism | Signals |
|---|---|---|
| sh | traps bound before `mktemp`; the `EXIT` trap preserves the status, clears itself and removes the dir | `HUP`/`INT`/`TERM` exit 129/130/143 without continuing |
| fish | every temp path goes through `__ocx_mktemp` into one list; an `--on-event fish_exit` handler removes them | `--on-signal` handlers only record the pending signal; `__ocx_check_signal` (at the start of `__ocx_err`, after each download attempt and retry sleep, after the manifest fetch and extract, and at the end of `main`) cleans up and exits 129/130/143 from normal flow. Asserted on fish 3.6.0, 4.0.2 and 4.9 |
| nu | `__ocx-err` raises `error make {msg: 'ocx-exit:CODE:text'}`; `__ocx-entry` is the **only** place that exits, and removes the one `mktemp -d` work dir first | none: nu has no trap, a killed run leaves its dir |
| elvish | `ocx-err` removes every tracked temp path before `exit`, and the main call sits in `try { } finally { }` (elvish `exit` skips `finally`, so both are needed) | none: elvish has no trap |
| pwsh | `Err` throws; `finally` removes the work dir, the temp files and the env names the script set (`Remove-Item Env:NAME`, because `SetEnvironmentVariable($n, $null)` leaves the name in the `Env:` provider) | none: PowerShell has no trap for them |

The suites run each installer under a private `TMPDIR` and assert it is empty after
every exit path. A BSD `mktemp` that ignores `TMPDIR` would make those assertions
vacuously green, not red.

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
- no hash tool available → exit **2** (see *Integrity fails closed*): the digest is the only thing authenticating a pin, so there is no unverified path.
- Non-pinned (rolling) URLs have nothing to verify against and are fetched as before — except in sh and fish over a wget that does not validate TLS, which refuses them with exit **4** (see *Transport*).

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
| 129, 130, 143 | sh and fish only: `HUP`, `INT`, `TERM` (128 + signal; fish from the 3.6.0 floor). nu, elvish and pwsh cannot trap and claim none of these |

Codes 2, 3 and 4 also cover the integrity and transport failures of the sections above: no hash tool or a CA bundle a wget cannot take (2); a manifest row without a valid `sha256` or a non-https URL (3); a mismatch, or a rolling manifest over an unvalidated wget in sh or fish (4). Exit 7 is also the answer when any of the five installers cannot tell glibc from musl on a Linux host: sh's `detect_libc` (called by `detect_target`) tries the `ldd` banner, then the musl loader files, then glibc evidence, and exits 7 on none rather than guessing a target; the other four apply the same order and the same exit. There is deliberately no `OCX_INSTALL_TARGET` knob; it would need five-way parity.

When `err()` is called from a new code path, choose the most specific code. Adding new codes is fine; reusing them across unrelated failure modes is not — it breaks the diagnostic value for CI scripts.

### Accepted divergence: unknown-argument exit code

The exit-code contract above (codes 2–7 for in-script `err()` paths) holds identically on all installers. There is one **accepted, justified divergence** in the unknown-argument path:

- **sh / fish** — an unknown option is caught by the in-script arg parser and routed through `err "unknown option: …" 2` (sh) / argparse failure → exit **2** (fish), consistent with the rest of the contract. (nu / elvish are env-driven and ignore unknown flags.)
- **pwsh** — an unknown flag (e.g. `-BogusFlag`) is rejected by the `[CmdletBinding()]` param binder *before* `Main` ever runs. The binder owns unknown-argument rejection and exits **1**; it has no hook to emit code 2. Through the `irm … | iex` (or `[scriptblock]::Create`) idiom the parser/binder error surfaces but the pipeline yields **no deterministic exit code** — callers must not rely on a specific number there.

This divergence is accepted because PowerShell parameter binding owns unknown-argument rejection and structurally cannot emit code 2. Every exit code that *is* produced by an in-script error path (2–7) remains symmetric.

**pwsh delivery of the code.** `Err` never calls `exit` (under `irm … | iex` or a scriptblock that closes the caller's own PowerShell). It prints the message, then throws an exception carrying the code in `Data['OcxExit']`; the single `try/catch` at the bottom of `install.ps1` calls `exit <code>` when `$PSCommandPath` is set (file run: `-File`, called by path) and otherwise sets `$global:LASTEXITCODE` and throws `ocx install failed (exit code N)`: an interactive session survives a throw, and a non-interactive `pwsh -c "irm … | iex"` still exits non-zero, so automation never reads a failed install as success. A `catch` that could swallow that exception must rethrow when `Data.Contains('OcxExit')`. Pester: the `iex:` and `scriptblock:` scenarios in `ExitCodes.Tests.ps1`.

## Script header (lines 2 to 8)

Every `src/install.*` carries, in its first eight lines, a `# Kind: INST` line, a `# Exit:` line listing its codes, and its interpreter floor. Only `Source.Tests.ps1` asserts a header (`# Kind: INST` of `install.ps1`); no Bats suite asserts the others, so those headers are held by review. The floor line is dialect-specific:

| Installer | Floor line |
|---|---|
| `install.sh` | `Floor: POSIX.1-2017` (plus probed `local`); `# Exit:` adds 129 130 143 |
| `install.ps1` | `Floor: Windows PowerShell 5.1`, PowerShell 7 on Linux and macOS; `# Exit:` states there are no signal statuses |
| `install.nu` | `# nu-range: 0.105.1..0.116.1`; says nu has no trap |
| `install.fish` | `Floor: fish 3.6.0. Tested: 3.6.0, 4.8.`; `# Exit:` adds 129/130/143 |
| `install.elv` | `# elvish-floor: 0.20.1`; says elvish has no trap |

The floor is the oldest interpreter the suite is run against, not a documentation claim: a syntax or builtin newer than the floor is a regression. `core-weaken.sh` reports the added `# Kind:` lines; they are intended, and each is acknowledged with a `Weaken-Ok: <path>: Kind header changed: <reason>` line in a commit body, which `core-weaken-ack.sh` (the PR job) accepts.

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

- **sh** (`src/install.sh`) — POSIX (bash/zsh/ash/ksh/dash/BusyBox ash), floor POSIX.1-2017. `--version` flag + `OCX_INSTALL_VERSION`. curl/wget; `OCX_INSTALL_DOWNLOADER`. Argv for the version and managed-config flags is built with `set --`, never an unquoted expansion; `main ${1+"$@"}`. Source is pure ASCII.
- **pwsh** (`src/install.ps1`) — **cross-platform**: Windows (PS 5.1 Desktop floor + 7) AND Linux/macOS (PS 7+; 5.1 is Windows-only). Switch params `-Version -NoModifyPath -Quiet -Force -PrintPath -NoSetup -NoSmoketest`. Env wins over switches. `Detect-Architecture` emits `*-pc-windows-msvc` / `*-unknown-linux-{gnu,musl}` / `*-apple-darwin` (OS gate via `RuntimeInformation.IsOSPlatform`; the `$PSVersionTable.PSEdition -eq 'Desktop'` shortcut keeps 5.1 from ever touching the Core-only Unix branch). Binary `ocx.exe`/`ocx`; `.zip` (zip-slip-safe `System.IO.Compression`) on Windows, `.tar.gz` or older `.tar.xz` (shells to `tar xf`; `.tar.xz` needs `xz-utils`) on Unix — dispatch keys off the manifest filename extension. **`irm | iex` isolation:** the whole body runs in `& { param(...) } @PSBoundParameters`, so no function, variable, `ErrorActionPreference` or strict mode leaks into the caller's session (the script-level `$script:OcxIsWindows` is a local); it saves and restores `SecurityProtocol` and the caller's `LASTEXITCODE` (restored on success only; on failure it carries the delivered code) and removes the env names it set. The gates `ps-sec-iex-leak.ps1` and `ps-sec-iex-survival.ps1` probe both, and the `iex:` scenarios in `ExitCodes.Tests.ps1` pin them. 5.1-safety: no ternary/`??`/`&&`/`||`/`$IsWindows`/`$IsMacOS`/`$IsLinux` (the last collide with read-only auto-vars — local vars use other names).
- **nu** (`src/install.nu`) — Nushell 0.105.1 to 0.116.1, cross-platform. **Env-driven** (Nushell gets no positional args): pin with `OCX_INSTALL_VERSION`. Native JSON (`from json`), `open --raw | hash sha256`. A bare `curl | nu` installs nothing (nu starts a REPL and exits 1 on a non-tty stdin), so the documented entry hands nu the text: `nu -c "$(curl -fsSL URL || echo 'exit 3')"` from a POSIX shell, `nu -c (http get URL)` from inside nu. Both keep the installer's exit code, run nothing on a cut-off script and (first form) exit 3 on a failed download. Forms measured on 0.105.1, 0.114.1, 0.116.0 and 0.116.1, and, with `open --raw` standing in for `http get`, on Windows nu 0.116.1 (the script text is about 24 KB of argv). `nu /dev/stdin` and `source /dev/stdin` fail on 0.105.1, and a `--stdin` temp-file wrapper works but is too long for a front-door line. Helpers raise with `error make {msg: 'ocx-exit:CODE:text'}` (only `$e.msg` is stable across the range); `__ocx-entry` is the only caller of `exit`. Avoid `get -i` and `str downcase` (deprecation warnings from 0.112 / 0.114): use `$name in $env`, `$row.field? | default ''` and a `(?i)` regex. A tail-position external inside `try` can hang on nu >= 0.112 for a large capture; keep externals behind `complete`.
- **fish** (`src/install.fish`) — fish 3.6.0 or newer (tested 3.6.0, 4.0, 4.2, 4.8), unix-only. `argparse` flags + env. JSON via `string match -r` on the flat manifest (no jq). NB: `version` is a reserved fish var — locals use `ocxver`. `curl | fish` is a supported pipe entry; pin with `curl … | OCX_INSTALL_VERSION=x fish`. fish has no `-s` option, so flags (`--version`, `--no-modify-path`) work only when fish runs a saved file; through a pipe use the env knobs (`OCX_INSTALL_VERSION`, `OCX_NO_MODIFY_PATH`). Env knobs go on the receiving shell, never on `curl`. Never use an exit helper as a conditional's command (fish demotes the `exit`); call asserts in statement position.
- **elvish** (`src/install.elv`) — Elvish 0.20.1 or newer (tested 0.20.1 and 0.21.0), cross-platform. Native `from-json`; `?()`/`try` wrap every external (Elvish throws on nonzero external exit). A bare `curl | elvish` installs nothing (elvish reads stdin as a REPL, fails on multi-line fns and exits 0), so the documented entry is `elvish -c "$(curl -fsSL URL || echo 'exit 3')"` from a POSIX shell and `elvish -c (e:curl -fsSL URL | slurp)` from inside elvish (the latter exits 2 on any failure, since elvish wraps the child's status). `resolve` cannot probe a module member (`resolve os:mkdir-all` succeeds on 0.20.1 and the call then throws), so `ocx-mkdir-p` is `try { os:mkdir-all } catch { e:mkdir -p }`. The elvish suite extracts `fn NAME` from the source with awk, so keep `ocx-has-musl-loader` and `ocx-certutil-digest` as top-level fns closing with a column-0 brace. Windows needs `mktemp`, `rm`, `cp`, `chmod` and `tar` on `PATH` (present with Git for Windows).

## Quality-rule overrides

The shell-quality and powershell-quality rules pin defaults an adopter may override once, in shared config. These are this repository's recorded overrides; nothing else deviates.

| Pinned default | Override here | Why |
|---|---|---|
| Elvish floor 0.18.0 to 0.21.0 | Floor **0.20.1**, tested to 0.21.0 | The `os` module and `elv-gate.sh` (needs `-json`) both need 0.20.x, and 0.20.1 is what `alpine:3.20` ships |
| TOOL and CI scripts are `#!/usr/bin/env bash`, floor bash 3.2.57 | `scripts/*.sh` and `tests/docker/*.sh` that run in containers stay **POSIX sh**; the Kind line reads `CI (POSIX sh: …)` or `TOOL (POSIX sh: …)`. `tests/docker/run.sh` is bash 3.2.57. The gate wrappers (`bats-ci.sh`, `ci-verify.sh`, `shell-format.sh`) are bash 3.2 | They run inside busybox and dash containers (Alpine, minimal Debian) where bash may be absent |

The zero skip budget is not overridden: the only allowed skips are the platform facts in `CENSUS_SKIP_OK` (`GNU wget not installed`, `timeout(1) not available`, and `busybox has no macOS build` on the macOS leg).

Per-site waivers are not overrides. `install.sh` keeps `SC3043` (`local`, verified at runtime by `has_local`) and two `SC2310` directives, each with a same-line reason. The PowerShell test harness leaves four gate notes unfixed on purpose: Information-level `PSProvideCommentHelp` and `ENC03` (`2>file` in tests, ASCII output), the python-launcher `Start-Process` in `Fixture.psm1`, and the intentional top-level `exit` in `Run-Installer.ps1`.

## Canonical bin dir

`OCX_BIN_SUBPATH = symlinks/ocx.sh/ocx/cli/current/content/bin`. `${OCX_HOME}/${OCX_BIN_SUBPATH}` is what `OCX_INSTALL_PRINT_PATH` emits, what the idempotent fast-path probes (`<bin>/ocx version` == requested version, unless `OCX_INSTALL_FORCE`), what `OCX_INSTALL_NO_SETUP` populates, and what `ocx self setup` symlinks into the package store on the default path.
