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

1. **FLAT archive layout.** The release `.zip` puts `ocx.exe` at the archive
   root (no `ocx-<target>/` wrapper dir), matching the real cargo-dist release —
   and the only layout that resolves on a non-Windows pwsh host (`Join-Path`
   treats `\` as a literal on Linux, so the nested `ocx-<target>\ocx.exe`
   candidate never matches there; only the flat `ocx.exe` candidate hits).
2. **`dist.json` manifest with `application/json`.** The harness serves a
   `dist.json` (a single object with FLAT leaf objects; one stable `0.0.0`
   release with an inline `sha256` + a DUMMY `url`) so `ConvertFrom-Json` in
   `Get-DistManifest` parses it cleanly. Suites point `OCX_INSTALL_DIST_URL` at
   it and set `OCX_INSTALL_MIRROR_URL` to the fixture's release base so the
   artifact download is redirected to the fixture (the manifest `url` is a
   dummy). There is **no** separate `sha256.sum` — the checksum is inline.
3. **Separate stdout/stderr log files.** `Start-Process` on Linux pwsh refuses
   to redirect both streams to the same file; the harness always passes two.

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
the binary only; it honors `-PrintPath` / `OCX_INSTALL_PRINT_PATH`. Because the
default path `& <bin> ...`s the copied stub, scenarios that need binary execution
are gated `-Skip:(-not $IsWindows)` (the sh-shebang stub has no `+x` and is not a
real PE off Windows); the bad-path → exit 2 and the file-placement / parse-only
scenarios need no execution and stay un-gated.

## Cross-platform execution (windows-latest vs ubuntu-pwsh)

The installer is Windows-only by intent, but most paths execute meaningfully on
ubuntu-pwsh because `Detect-Architecture` keys off `RuntimeInformation` (returns
the `*-pc-windows-msvc` target on any X64 host) and the suites set `OCX_HOME`
explicitly. Tests that must **execute the stub / extracted `ocx.exe`** (the
recorded `self setup` argv assertion, the exit-6 `self setup`-failure test, the
fast-path version probe) are gated `-Skip:(-not $IsWindows)`; on Linux those
scenarios self-skip. Scenarios that only check exit codes / file placement /
parsing stay un-gated and must pass on ubuntu-pwsh.

`OCX_INSTALL_DOWNLOADER` has no Pester mirror by design — it is sh-only
(install.ps1 always uses `Invoke-WebRequest`).

## PowerShell 5.1 (Desktop) vs. 7 in CI

The installer is written 5.1-safe (no ternary, `??`, `&&`/`||` chains, `$IsWindows`
auto-var, `-SkipCertificateCheck`, `-SslProtocol`). `test-installers.yml`:

- On `windows-latest`, runs the Pester suite **and** a smoke install on **both**
  hosts — Windows PowerShell 5.1 (`powershell.exe`) and PowerShell 7 (`pwsh`).
  Install Pester v5 for the 5.1 host:
  `Install-Module Pester -MinimumVersion 5 -Force -Scope CurrentUser -SkipPublisherCheck`.
- The 5.1 smoke install drives the test hatch:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File src/install.ps1 -NoSetup -PrintPath -NoSmoketest`.
- Keeps the ubuntu pwsh-7 leg + Bats on ubuntu/macos.

The `-Skip:(-not $IsWindows)` gating governs which scenarios execute the
copied/extracted binary: those run on the Windows hosts (both shells) and skip on
the ubuntu-pwsh leg.

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

CI runs Bats on ubuntu + macos (vendored bats) and Pester on windows-latest (both
`powershell.exe` 5.1 and `pwsh` 7) + ubuntu-latest with pwsh installed.
