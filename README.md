<!-- doc_type: readme -->
<div align="center">
  <img src="assets/logo.svg" alt="OCX" width="120" />

# setup.ocx.sh

Canonical hosting for the [OCX](https://ocx.sh) installer scripts.

</div>

`setup.ocx.sh` serves a thin installer for **every supported shell** under bare, friendly paths — each one a one-liner in that shell's own language:

```
https://setup.ocx.sh/sh             # POSIX: bash / zsh / ash / ksh / dash (Linux + macOS)
https://setup.ocx.sh/pwsh           # PowerShell 5.1+ (Windows + cross-platform pwsh)
https://setup.ocx.sh/nu             # Nushell (Linux + macOS + Windows)
https://setup.ocx.sh/fish           # fish (Linux + macOS)
https://setup.ocx.sh/elvish         # Elvish (Linux + macOS + Windows)
https://setup.ocx.sh/dist           # dist.json — the distribution manifest the installers read
```

Each installer is a **thin bootstrap**: it detects the platform, resolves the release from the manifest, downloads + verifies the archive against the manifest's inline `sha256`, then hands off to the downloaded binary's `ocx self setup`.
That command owns the package-store install, the per-shell env shims, and the managed shell-profile activation blocks.

The bare paths are Bunny CDN edge-rule rewrites onto the latest-stable installer. The pre-release ("next") channel and pinned, immutable copies are reachable at the same friendly per-shell prefix:

```
https://setup.ocx.sh/<shell>/next          # next (latest prerelease)  [alias: /<shell>/canary]
https://setup.ocx.sh/<shell>/<VERSION>     # pinned, immutable installer script (e.g. /sh/0.2.1)
```

`<VERSION>` is the version of the **installer script**, a semver string without a leading `v` (e.g. `0.2.1`) — not the OCX version it installs (see [Pin a version](https://ocx.sh/install/versions/)). The canonical, immutable artifact for a release lives at `https://setup.ocx.sh/archive/<VERSION>/install.<ext>` (`<ext>` ∈ `sh ps1 nu fish elv`) — the per-shell URLs above are edge-rule rewrites onto it.

The GitHub Action and GitLab Function listings live in **separate repositories** so they can publish to the native GitHub Marketplace and GitLab CI Catalog. Documentation paths (`/docs/*`) and action paths (`/actions/*`) on `setup.ocx.sh` are forwarded to those upstream surfaces by edge rules.

## Quick start

```sh
# POSIX (Linux / macOS):
curl -fsSL https://setup.ocx.sh/sh | sh

# fish:
curl -fsSL https://setup.ocx.sh/fish | fish

# Nushell (from a POSIX shell, or from inside nu):
nu -c "$(curl -fsSL https://setup.ocx.sh/nu || echo 'exit 3')"
nu -c (http get https://setup.ocx.sh/nu)

# Elvish (from a POSIX shell, or from inside elvish):
elvish -c "$(curl -fsSL https://setup.ocx.sh/elvish || echo 'exit 3')"
elvish -c (e:curl -fsSL https://setup.ocx.sh/elvish | slurp)
```

```powershell
# PowerShell (Windows PowerShell 5.1+ on Windows; PowerShell 7+ on Linux / macOS):
irm https://setup.ocx.sh/pwsh | iex
```

Under `irm | iex`, a failed PowerShell install prints the error and throws instead of closing your session, with the exit code in `$LASTEXITCODE`. The installer runs in its own script block and restores `SecurityProtocol`, so it leaves no functions, variables or strict-mode settings in your session.

Nushell and Elvish do not run a script from a pipe. A bare `curl … | nu` exits 1, because nu starts a REPL and refuses a non-terminal stdin. `curl … | elvish` reads stdin as a REPL, prints parse errors and exits 0 with nothing installed. The forms above pass the script as `-c` text instead. The installer's exit code is kept, and a cut-off download fails to parse and runs nothing. In the POSIX-shell form, `|| echo 'exit 3'` turns a failed download into exit 3. They need nu 0.105.1 or newer and Elvish 0.20.1 or newer.

On Linux/macOS the PowerShell installer needs `tar` on `PATH` for archive extraction (xz-utils only for releases older than the .tar.gz switch). Most systems already have both. For a shell-native install there, use the POSIX `https://setup.ocx.sh/sh` one-liner.

## Documentation

The full documentation lives at [ocx.sh/install/](https://ocx.sh/install/), built from [`site/`](site/) in this repository.

| Page | Covers |
|---|---|
| [Install OCX](https://ocx.sh/install/) | One-liners per shell, what the installer prints, onward links |
| [Pin a version](https://ocx.sh/install/versions/) | Installer channels, `OCX_INSTALL_VERSION`, pinned installer script, pinned manifest |
| [Configuration](https://ocx.sh/install/configuration/) | Every `OCX_INSTALL_*` and shared variable, flags, precedence |
| [Mirrors and proxies](https://ocx.sh/install/mirrors/) | `OCX_INSTALL_DIST_URL` / `OCX_INSTALL_MIRROR_URL`, the patched installer, the CA bundle |
| [Examples](https://ocx.sh/install/examples/) | Developer machine per shell, Dockerfile, air-gapped host, generic CI job |
| [Exit codes and contract](https://ocx.sh/install/reference/) | Exit codes, stdout/stderr contract, URL layout, fixed behaviour |

`site/scripts/contract.test.mjs` fails when a knob or exit code in `src/install.*` is missing from those pages, or the reverse.

## Development

```sh
git submodule update --init --recursive        # vendored bats (external/)
task verify                                    # lint (5 shells, workflows, docs) + Bats + Pester
task test:bats                                 # only Bats (vendored, through the census)
task test:pester                               # only Pester (pinned Pester, through the census)
task site:test                                 # the /install/ site tests and the installer-contract drift guard
task site:check                                # build the /install/ site and run its gates
task shell:format                              # rewrite shell files with shfmt
task docker:integration DISTRO=alpine PLATFORM=linux/amd64
task publish:dry-run                           # validate storage keys (offline)
```

[`CONTRIBUTING.md`](CONTRIBUTING.md) covers prerequisites and the PR flow. [`CLAUDE.md`](CLAUDE.md) is the AI-collaboration entry point.

## License

[Apache-2.0](LICENSE)
