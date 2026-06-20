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

Each installer is a **thin bootstrap**: it detects the platform, resolves the release from the manifest, downloads + verifies the archive against the manifest's inline `sha256`, then hands off to the downloaded binary's `ocx self setup` — which owns the package-store install, the per-shell env shims, and the managed shell-profile activation blocks.

The bare paths are nginx rewrites onto the latest-stable installer. The pre-release ("next") channel and pinned, immutable copies are reachable at the same friendly per-shell prefix:

```
https://setup.ocx.sh/<shell>/next          # next (latest prerelease)  [alias: /<shell>/canary]
https://setup.ocx.sh/<shell>/<VERSION>     # pinned, immutable (e.g. /sh/0.5.0)
```

`<VERSION>` is the semver string without a leading `v` (e.g. `0.5.0`). The canonical, immutable artifact for a release lives at `https://setup.ocx.sh/archive/<VERSION>/install.<ext>` (`<ext>` ∈ `sh ps1 nu fish elv`) — the per-shell URLs above are nginx rewrites onto it.

The GitHub Action and GitLab Function listings live in **separate repositories** so they can publish to the native GitHub Marketplace and GitLab CI Catalog. Documentation paths (`/docs/*`) and action paths (`/actions/*`) on `setup.ocx.sh` are forwarded by nginx to those upstream surfaces.

## Quick start

```sh
# POSIX (Linux / macOS):
curl -fsSL https://setup.ocx.sh/sh | sh

# fish:
curl -fsSL https://setup.ocx.sh/fish | fish

# Nushell:
curl -fsSL https://setup.ocx.sh/nu | nu

# Elvish:
curl -fsSL https://setup.ocx.sh/elvish | elvish
```

```powershell
# PowerShell (Windows):
irm https://setup.ocx.sh/pwsh | iex
```

### Pinning a version

Use the `OCX_INSTALL_VERSION` env knob — it is portable across every shell's `curl | <shell>` argument-passing quirks:

```sh
OCX_INSTALL_VERSION=0.5.0 curl -fsSL https://setup.ocx.sh/sh | sh
```

`--version` is also accepted where the dialect parses flags cleanly (`sh`, `fish`, and `pwsh`'s `-Version`). For PowerShell, compile to a scriptblock so `-Version` binds to the param:

```powershell
& ([scriptblock]::Create((irm https://setup.ocx.sh/pwsh))) -Version 0.5.0
```

### Pinned install URL (recommended for CI)

```sh
curl -fsSL https://setup.ocx.sh/sh/0.5.0 | sh
```

The installers resolve "latest" by reading the self-hosted distribution manifest at `https://setup.ocx.sh/dist.json` — there is **no GitHub API dependency** in the install path. The manifest lists the published OCX product versions (from `ocx-sh/ocx`) with an inline checksum and download URL per platform; override it with `OCX_INSTALL_DIST_URL`.

## Configuration

The `OCX_INSTALL_*` prefix scopes a knob to install-time; the shared runtime envs (`OCX_HOME`, `OCX_NO_MODIFY_PATH`, `NO_COLOR`, `TMPDIR`) keep their existing names.

| Variable | Purpose | Default |
|---|---|---|
| `OCX_INSTALL_VERSION` | Pin a version (empty = latest stable). The portable pinning channel for every shell. | _(latest)_ |
| `OCX_INSTALL_REPO` | GitHub owner/repo | `ocx-sh/ocx` |
| `OCX_INSTALL_DIST_URL` | Distribution manifest (`dist.json`) used to resolve the latest version + per-target checksum/URL | `https://setup.ocx.sh/dist.json` |
| `OCX_INSTALL_MIRROR_URL` | Artifact host override — rewrites the per-target download URL to `<MIRROR_URL>/<tag>/<filename>` | _(use manifest URL)_ |
| `OCX_INSTALL_NO_SETUP` | Place the binary on PATH only; skip `ocx self setup` (env shims + profile blocks). The CI / air-gapped path. `OCX_NO_MODIFY_PATH` is a no-op in this mode. | `0` |
| `OCX_INSTALL_NO_SMOKETEST` | Skip the post-extract `ocx version` smoke test | `0` |
| `OCX_INSTALL_FORCE` | Reinstall even if the target version is already present | `0` |
| `OCX_INSTALL_QUIET` | Suppress informational stderr output | `0` |
| `OCX_INSTALL_PRINT_PATH` | Emit the bin dir as the final stdout line | `0` |
| `OCX_INSTALL_DOWNLOADER` | Force a downloader (`curl` or `wget`); default auto-detects (sh only) | _(auto)_ |

The full list lives in `src/install.sh` (and its peers); see [`.claude/rules/installers.md`](.claude/rules/installers.md) for the naming + 5-way parity rules.

## Stdout / stderr contract

- All informational, warning, and error output goes to **stderr**.
- **Stdout is silent on success** unless `OCX_INSTALL_PRINT_PATH` is truthy (or `-PrintPath`), in which case the final stdout line is the absolute OCX bin dir.

This contract lets downstream callers do:

```sh
BIN_DIR=$(OCX_INSTALL_PRINT_PATH=1 OCX_INSTALL_QUIET=1 curl -fsSL https://setup.ocx.sh/sh | sh | tail -n1)
export PATH="$BIN_DIR:$PATH"
```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Generic / legacy fallback |
| 2 | Argument or environment validation |
| 3 | Network / download / manifest failure |
| 4 | Checksum mismatch |
| 5 | Archive extraction failure |
| 6 | `ocx self setup` failure |
| 7 | Unsupported platform / architecture |

## Development

```sh
git submodule update --init --recursive        # vendored bats (external/)
task verify                                    # lint (5 shells) + Bats + Pester
task test:bats                                 # only Bats (vendored)
task test:pester                               # only Pester (needs pwsh + Pester)
task docker:integration DISTRO=alpine PLATFORM=linux/amd64
task publish:dry-run                           # validate rsync paths
```

[`CONTRIBUTING.md`](CONTRIBUTING.md) covers prerequisites and the PR flow. [`CLAUDE.md`](CLAUDE.md) is the AI-collaboration entry point.

## License

[Apache-2.0](LICENSE)
