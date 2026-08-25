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

The bare paths are Bunny CDN edge-rule rewrites onto the latest-stable installer. The pre-release ("next") channel and pinned, immutable copies are reachable at the same friendly per-shell prefix:

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
# PowerShell (Windows PowerShell 5.1+ on Windows; PowerShell 7+ on Linux / macOS):
irm https://setup.ocx.sh/pwsh | iex
```

On Linux/macOS the PowerShell installer needs `tar` on `PATH` for archive extraction (xz-utils only for releases older than the .tar.gz switch; both already present on most systems); for a shell-native install there, the POSIX `https://setup.ocx.sh/sh` one-liner is also available.

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

### Pinned manifest (reproducible install)

Every manifest ever published is kept, unchanged, at a content-addressed URL:

```sh
OCX_INSTALL_DIST_URL=https://setup.ocx.sh/dist/<sha256>.json curl -fsSL https://setup.ocx.sh/sh | sh
```

Because every release row carries an inline `sha256`, pinning the manifest pins the **whole closure** — one hash, fully reproducible. The installers recognise a `dist/<sha256>.json` URL and **verify the served body against the digest in its own name** (mismatch → exit 4), so the host serving it is pure transport and needs no trust. The current digest is published at `https://setup.ocx.sh/dist.json.sha256`, and `ocx-mirror dist sync` emits the same layout for a corporate mirror.

## Configuration

The `OCX_INSTALL_*` prefix scopes a knob to install-time; the shared runtime envs (`OCX_HOME`, `OCX_NO_MODIFY_PATH`, `NO_COLOR`, `TMPDIR`) keep their existing names.

| Variable | Purpose | Default |
|---|---|---|
| `OCX_INSTALL_VERSION` | Pin a version (empty = latest stable). The portable pinning channel for every shell. | _(latest)_ |
| `OCX_INSTALL_REPO` | GitHub owner/repo | `ocx-sh/ocx` |
| `OCX_INSTALL_DIST_URL` | Distribution manifest (`dist.json`) used to resolve the latest version + per-target checksum/URL. A `dist/<sha256>.json` snapshot pins the whole closure and is verified against that digest. | `https://setup.ocx.sh/dist.json` |
| `OCX_INSTALL_MIRROR_URL` | Artifact host override — rewrites the per-target download URL to `<MIRROR_URL>/<tag>/<filename>` | _(use manifest URL)_ |
| `OCX_INSTALL_NO_SETUP` | Place the binary on PATH only; skip `ocx self setup` (env shims + profile blocks). The CI / air-gapped path. `OCX_NO_MODIFY_PATH` is a no-op in this mode. | `0` |
| `OCX_INSTALL_NO_SMOKETEST` | Skip the post-extract `ocx version` smoke test | `0` |
| `OCX_INSTALL_FORCE` | Reinstall even if the target version is already present | `0` |
| `OCX_INSTALL_QUIET` | Suppress informational stderr output | `0` |
| `OCX_INSTALL_PRINT_PATH` | Emit the bin dir as the final stdout line | `0` |
| `OCX_INSTALL_DOWNLOADER` | Force a downloader (`curl` or `wget`); default auto-detects (sh only) | _(auto)_ |
| `OCX_INSTALL_CA_BUNDLE` | CA bundle trusted for every download — a PEM **file path**, or the PEM text itself. For TLS-intercepting corporate proxies. Also handed to `ocx self setup` as `SSL_CERT_FILE`. Not used by `install.ps1`'s own downloads (see below). | _(system trust store)_ |

The full list lives in `src/install.sh` (and its peers); see [`.claude/rules/installers.md`](.claude/rules/installers.md) for the naming + 5-way parity rules.

## Corporate mirrors: one patched installer

A site that mirrors OCX internally usually wants **one** copy of the installer that already knows the local manifest, artifact host, CA, and managed config — instead of asking every developer to export four environment variables.

Each installer carries an embedded configuration block near the top, holding four placeholders:

| Placeholder | Sets |
|---|---|
| `@OCX_INSTALL_DIST_URL@` | the distribution manifest URL (a `dist/<sha256>.json` pin works here too) |
| `@OCX_INSTALL_MIRROR_URL@` | the artifact host override |
| `@OCX_INSTALL_CA_BUNDLE@` | the CA bundle — a path, **or** an inline PEM block |
| `@OCX_MANAGED_CONFIG@` | the managed-config OCI reference (`host/repo:tag`), forwarded as `ocx self setup --managed-config <REF>` |

The placeholders are spelled identically in all five installers, so **one command patches every dialect**:

```sh
# Fetch whichever dialects your site needs (-O would name the file `sh`).
for pair in sh:sh pwsh:ps1 nu:nu fish:fish elvish:elv; do
  curl -fsSL "https://setup.ocx.sh/${pair%%:*}" -o "install.${pair##*:}"
done

sed -i \
  -e "s|@OCX_INSTALL_DIST_URL@|https://artifactory.corp/ocx/dist.json|" \
  -e "s|@OCX_INSTALL_MIRROR_URL@|https://artifactory.corp/ocx/releases|" \
  -e "s|@OCX_MANAGED_CONFIG@|registry.corp.example/ocx/managed-config:v1|" \
  install.*
```

The placeholder is single-quoted in every dialect, which means the value is never interpolated **and may span newlines** — so the CA bundle can be the certificate itself, leaving nothing to distribute alongside the script. A value spanning lines needs a tool that is not line-oriented:

```sh
python3 - install.sh <<'PY'
import sys
p = sys.argv[1]
pem = open('corp-root-ca.pem').read()
s = open(p).read().replace('@OCX_INSTALL_CA_BUNDLE@', pem)
open(p, 'w').write(s)
PY
```

Rules:

- **Precedence is environment > embedded > built-in default**, so CI and one-off overrides keep working on a patched copy.
- A placeholder **left unreplaced is ignored** — an unpatched installer behaves exactly as it always has.
- Values must not contain a single quote.
- The mirror must allow **anonymous read**; there is no credential knob in any dialect. See [`.claude/rules/mirror-auth.md`](.claude/rules/mirror-auth.md).

### The CA bundle covers both hops

An install is two HTTPS conversations, not one: the installer fetches the manifest and the archive, then `ocx self setup` pulls the package store from the registry. `OCX_INSTALL_CA_BUNDLE` covers both — the installer passes it to `curl --cacert` / `wget --ca-certificate`, and exports it as **`SSL_CERT_FILE`** for the `ocx self setup` child, which is how OCX picks up a host CA ([env reference](https://ocx.sh/docs/reference/environment#external-ca-certificates)). An `SSL_CERT_FILE` already in the environment is left alone.

Three things worth knowing:

- **PEM only.** `SSL_CERT_FILE` ignores DER; convert with `openssl x509 -inform der -in corp.crt -out corp.pem`. An inline value is recognised by containing `-----BEGIN`, so a bundle that opens with comment lines (as Fedora/RHEL's does) works unchanged.
- **curl/wget _replace_ the system trust store** with the bundle you give them, while OCX _merges_ it with its compiled-in Mozilla roots. So if the installer must reach both an internal host and a public one in the same run, the bundle needs the public roots too (`cat corp-root.pem /etc/ssl/certs/ca-certificates.crt`). Same semantics as `CURL_CA_BUNDLE`.
- **`install.ps1` does not use it for its own downloads**: `Invoke-WebRequest` has no PowerShell 5.1-safe CA-bundle option, so it warns and falls back to the system trust store (on Windows, install the CA into the machine certificate store). It still validates the value, materializes an inline PEM, and exports `SSL_CERT_FILE` for `ocx self setup` — the gap is one flag, not the knob. Patching all five copies uniformly is therefore safe.

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
task publish:dry-run                           # validate storage keys (offline)
```

[`CONTRIBUTING.md`](CONTRIBUTING.md) covers prerequisites and the PR flow. [`CLAUDE.md`](CLAUDE.md) is the AI-collaboration entry point.

## License

[Apache-2.0](LICENSE)
