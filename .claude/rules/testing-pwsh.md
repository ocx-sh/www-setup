# PowerShell testing rules (Pester)

## Layout

```
tests/install/ps1/
├── Fixture.psm1          # Shared fixture builder + http.server harness (imported by all suites)
├── Knobs.Tests.ps1       # OCX_INSTALL_* env var behavior (mirrors env-knobs.bats)
├── ExitCodes.Tests.ps1   # Numbered exit-code paths 5/6 + self-setup argv (mirrors exit-codes.bats)
└── PrintPath.Tests.ps1   # Stdout/stderr discipline + -PrintPath (mirrors print-path.bats)
```

`Fixture.psm1` is the PowerShell analogue of `tests/install/helpers/server.bash`:
it builds the fake release tree (archive + a `dist.json` manifest) and spins the
fixture HTTP server so the suites stay DRY.

## Conventions

- Use Pester v5 (`New-PesterConfiguration` API; no v3-style globals).
- Run with: `Invoke-Pester -Configuration (New-PesterConfiguration -Hashtable @{ Run = @{ Path = 'tests/install/ps1' } })`, or via `task test:pester` / the CI Pester step.
- One `It` per scenario. Top-level `BeforeAll` builds one fixture + server per file; `BeforeEach` resets a fresh `OCX_HOME` and the env knobs.
- Build the fixture and server through `Fixture.psm1` (`New-OcxFixture`, `Start-FixtureServer`), not ad-hoc inside each `It`.
- Test against the **environment-variable form** of every knob first, then the flag form (`-NoSetup`, `-NoSmoketest`, `-Version`, `-PrintPath`, …). The env form is the contract; flags are sugar. Env wins over switches.

## Fixture harness (`Fixture.psm1`)

Things the harness gets right that a naive `python -m http.server` does not:

1. **Platform-appropriate FLAT archive.** install.ps1 is cross-platform, so the
   fixture builds the archive the host installer expects: on Windows a `.zip` with
   `ocx.exe` at the root (`Compress-Archive`); on Unix a `.tar.xz` with an
   executable `ocx` at the root (`tar -cJf`, chmod +x). Both are FLAT (no
   `ocx-<target>/` wrapper dir), matching the real cargo-dist release. The target,
   binary name, and extension come from `Resolve-FixtureTarget` /
   `Get-FixtureBinName` / `Get-FixtureArchiveExt`, which mirror install.ps1's own
   `Detect-Architecture` so the fixture filename matches exactly what the installer
   requests. (Manual fixtures that build their own archive use `New-OcxArchive`.)
2. **`dist.json` manifest with `application/json`.** The harness serves a
   `dist.json` (a single object with FLAT leaf objects; one stable `0.0.0`
   release with an inline `sha256` + a DUMMY `url`) so `ConvertFrom-Json` in
   `Get-DistManifest` parses it cleanly. Suites point `OCX_INSTALL_DIST_URL` at
   it and set `OCX_INSTALL_MIRROR_URL` to the fixture's release base so the
   artifact download is redirected to the fixture (the manifest `url` is a
   dummy). There is **no** separate `sha256.sum` — the checksum is inline.
3. **Separate stdout/stderr log files.** `Start-Process` on Linux pwsh refuses
   to redirect both streams to the same file; the harness always passes two.
4. **A `/redirect/<path>` 302 route.** The server answers `/redirect/...` with a
   302 to the same artifact under `/releases/download/...`, mirroring GitHub's
   release-asset redirect to `objects.githubusercontent.com`. Pointing
   `OCX_INSTALL_MIRROR_URL` at `$Server.RedirectMirrorUrl` (instead of
   `$Server.MirrorUrl`) drives the download through a real hop so the installer's
   `Resolve-DownloadUrl` redirect resolver is exercised (`Knobs.Tests.ps1` →
   "follows a 302 redirect"). `Resolve-DownloadUrl` uses `[HttpWebRequest]`
   (AllowAutoRedirect off, https re-checked per hop) precisely because
   `Invoke-WebRequest -MaximumRedirection 0` signals a redirect with a different,
   `.Response`-less exception on Windows PowerShell 5.1 than on 7 — under
   `Set-StrictMode` that bare property read was itself a terminating error, so a
   5.1 `curl|pwsh` install crashed in the redirect path. The redirect resolver
   path is covered per-commit on pwsh 7 (the fixture test, all hosts) and on real
   GitHub under **both** `powershell` (5.1) and `pwsh` (7) by the nightly
   `install-ps1-windows` matrix in `test-installers.yml`. The hermetic fixture
   test has no Bats mirror — `install.sh` delegates redirect-following to `curl`,
   which has no equivalent strict-mode failure mode.

The canonical bin dir asserted everywhere is
`symlinks/ocx.sh/ocx/cli/current/content/bin` via `Get-ExpectedBinDir`. The
no-setup knob is **`OCX_INSTALL_NO_SETUP`** / `-NoSetup`; the smoketest knob is
**`OCX_INSTALL_NO_SMOKETEST`** / `-NoSmoketest`.

## Stub `self setup` hand-off + `__OCX_TESTING_INSTALL_BINARY`

The stub answers `version` (`0.0.0`), `about`, and the `ocx self setup [...]` /
`--offline self setup [...]` hand-off (exits 0; records argv). It no longer emits
shims or completion sentinels — `ocx self setup` owns that. The argv is recorded
so the hand-off assertion (`self setup 0.0.0 --no-modify-path` on the default
path; `--offline self setup --no-modify-path` on the test-hatch path) works.

`__OCX_TESTING_INSTALL_BINARY` is the internal, undocumented, test-only
download-skip hatch (mirrors sh). When set, `Install-LocalTestBinary` validates
the path (`Err` exit **2** on miss — message contains `__OCX_TESTING_INSTALL_BINARY`),
copies it to the canonical bin dir, skips download/checksum/extract/manifest, then
either runs `<bin> --offline self setup` (default) or, under `-NoSetup`, places
the binary only; it honors `-PrintPath` / `OCX_INSTALL_PRINT_PATH`. On Unix
`Install-LocalTestBinary` chmod +x's the copied binary (the default path then
`& <bin> ...`s it). Scenarios that need binary execution self-skip on Windows
(`-Skip:($env:OS -eq 'Windows_NT')` — the sh-shebang stub is not a PE there); the
bad-path → exit 2 and the file-placement / parse-only scenarios need no execution
and stay un-gated.

## Cross-platform execution (POSIX hosts vs windows-latest)

install.ps1 is **cross-platform**. On the POSIX hosts (ubuntu + macos) the suites
exercise the **full** path — download → `.tar.xz` extract → `ocx` chmod →
`self setup` hand-off — against the executable shell-script stub. On Windows the
stub is named `ocx.exe` but is not a PE, so the scenarios that **execute** the
stub (the recorded `self setup` argv assertion, the exit-6 `self setup`-failure
test, the FORCE/idempotency version probe) self-skip there via
`-Skip:($env:OS -eq 'Windows_NT')`. The skip keys off `$env:OS`, not `$IsWindows`
(undefined under 5.1, and a local `$isLinux`/`$isMac` would collide with PS Core's
read-only auto-vars). Windows execution coverage lives in the 5.1 smoke + the
workflow_dispatch real-release jobs. Scenarios that only check exit codes / file
placement / parsing stay un-gated and pass on every host (the placement-assert bin
name is `Get-FixtureBinName`).

`OCX_INSTALL_DOWNLOADER` has no Pester mirror by design — it is sh-only
(install.ps1 always uses `Invoke-WebRequest`, on every OS).

## PowerShell 5.1 (Desktop) vs. 7 in CI

The installer is written 5.1-safe (no ternary, `??`, `&&`/`||` chains, `$IsWindows`
auto-var, `-SkipCertificateCheck`, `-SslProtocol`); the `$PSVersionTable.PSEdition
-eq 'Desktop'` shortcut keeps a 5.1 host from ever evaluating the Core-only Unix
branch. `test-installers.yml`:

- The `pester` job runs on **windows-latest + ubuntu-latest + macos-latest** (pwsh
  7). The POSIX legs execute the full path; Windows runs the parse/placement
  scenarios and self-skips the stub-execution ones.
- On `windows-latest`, also runs a 5.1 smoke install (`powershell.exe`). Install
  Pester v5 for a 5.1 host:
  `Install-Module Pester -MinimumVersion 5 -Force -Scope CurrentUser -SkipPublisherCheck`.
- The 5.1 smoke install drives the test hatch:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File src/install.ps1 -NoSetup -PrintPath -NoSmoketest`.
- pwsh is also an INSTALLER-axis cell in `test-docker-matrix.yml` (alpine/fedora/
  ubuntu × amd64/arm64) and has real-release dispatch jobs for linux + macos.

The `-Skip:($env:OS -eq 'Windows_NT')` gating governs which scenarios execute the
copied/extracted binary: those run on the POSIX hosts and self-skip on Windows.

## Parity with Bats

Every Bats scenario has a matching Pester scenario (same scenario, mirrored name):

| Bats | Pester suite |
|---|---|
| `env-knobs.bats` | `Knobs.Tests.ps1` |
| `exit-codes.bats` | `ExitCodes.Tests.ps1` |
| `print-path.bats` | `PrintPath.Tests.ps1` |

The cross-installer parity rule (`installers.md`) requires it: when you add a Bats
scenario, add the same-named scenario in the matching Pester suite. This includes
the latest-via-`dist.json` happy path, the dead-manifest → exit 3 (message
contains `latest version`) scenario, the checksum-mismatch → exit 4 path, the
`self setup`-failure → exit 6 path with the recorded argv, and the
`__OCX_TESTING_INSTALL_BINARY` happy (`--offline self setup` argv) + bad (exit 2)
paths. The accepted pwsh divergence — an unknown flag (`-BogusFlag`) is rejected
by the `[CmdletBinding()]` binder at exit 1 (indeterminate through `irm | iex`),
not the in-script exit 2 — is preserved. Exit code 7 (unsupported platform)
cannot be triggered on an X64 host in either suite — it is exercised by
`tests/docker/`.

CI runs Bats on ubuntu (vendored bats) and Pester on windows-latest (both
`powershell.exe` 5.1 and `pwsh` 7) + ubuntu-latest + macos-latest (pwsh 7).
