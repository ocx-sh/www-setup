# Publish rules

The installer-publish pipeline owns one job: keep `setup.ocx.sh` serving the latest set of installer scripts at predictable URLs. This file documents the contract.

## URL layout

Five entrypoints, one per shell (`<shell>` ∈ `sh pwsh nu fish elvish`; `<ext>` ∈ `sh ps1 nu fish elv`):

```
setup.ocx.sh/<shell>                          # bare shortcut → <shell>/install.<ext> (nginx try_files)
setup.ocx.sh/<shell>/install.<ext>            # latest STABLE pointer (mutable)
setup.ocx.sh/<shell>/next/install.<ext>       # latest PRERELEASE ("next") pointer (mutable)
setup.ocx.sh/<shell>/<VERSION>/install.<ext>  # pinned (immutable, append-only)
setup.ocx.sh/dist                             # bare shortcut → dist.json (nginx try_files)
setup.ocx.sh/dist.json                        # distribution manifest (overwritten every release)
setup.ocx.sh/releases                         # legacy alias → dist.json
```

`<VERSION>` is the semver string without a leading `v` (e.g. `2.0.1`, not `v2.0.1`).

The bare `/<shell>` and `/dist` paths are served directly by nginx `try_files` (no redirect, no file duplication). The nginx routing contract is mirrored in `deploy/nginx/setup.ocx.sh.conf.example` — keep the two in sync. The host's live nginx config is authoritative; the example is reference.

### `dist.json` (the distribution manifest)

**Source of truth: the `ocx-sh/ocx` GitHub Releases API** — *not* this repo's git tags. `scripts/gen-dist.sh` fetches `https://api.github.com/repos/ocx-sh/ocx/releases?per_page=100` (with `GITHUB_TOKEN` in CI to avoid rate limits) and, per non-draft release, fetches that release's `sha256.sum` asset to DERIVE the build targets and inline a per-target checksum + download URL. It emits a single JSON object whose two top-level pointers (`latest`, `latest_next`) and every `releases[]` element are FLAT objects (no nested braces), so the installers' jq-free parses are safe — POSIX `grep -o '{[^{}]*}'` and fish `string match -r` both extract each leaf cleanly; nu/elvish use native JSON:

```json
{
  "schema": 1,
  "latest": {"version":"0.5.0","channel":"stable"},
  "latest_next": {"version":"0.6.0-rc.1","channel":"next"},
  "releases": [
    {"version":"0.5.0","channel":"stable","tag":"v0.5.0","target":"x86_64-unknown-linux-gnu","filename":"ocx-x86_64-unknown-linux-gnu.tar.xz","sha256":"abc…","url":"https://github.com/ocx-sh/ocx/releases/download/v0.5.0/ocx-x86_64-unknown-linux-gnu.tar.xz"}
  ]
}
```

`releases[]` is newest-first; a full release carries 8 targets (linux gnu+musl, darwin, windows × x86_64/aarch64) derived from `sha256.sum` (never hardcoded). The installers resolve the latest stable via the first `"channel":"stable"` leaf, then resolve the `(version,target)` row → inline `sha256` + `url`. There is **no separate `sha256.sum` fetch** in the install path; the checksum is inline.

The manifest is rebuilt and uploaded (overwrite) by `.github/workflows/update-dist.yml`, which runs on three triggers: a `repository_dispatch` of type `ocx-released` fired by `ocx-sh/ocx` when a new OCX release ships (the fast path), an **hourly cron** (the fallback if a dispatch is absent or fails), and `workflow_dispatch` (manual). It is **also** refreshed opportunistically on this repo's own installer releases — `scripts/publish-dist.sh` regenerates and uploads it as part of the `publish-installers` job.

#### Decoupled versioning

`dist.json` lists **OCX product versions** (from `ocx-sh/ocx`). This repo's own `v*` tags version the **installer scripts** (`src/install.*`) and the publish pipeline — they do **not** appear in `dist.json` and do not gate which OCX version the installer resolves. Shipping a new installer does not require a new OCX release, and a new OCX release does not require re-tagging the installer.

#### The install path stays tokenless

Generation uses the GitHub API (CI-side, with `GITHUB_TOKEN`); **resolution does not**. The installer reads the self-hosted `dist.json` over the HTTPS-enforced downloader to resolve the latest version + checksum + URL — there is no GitHub API dependency in the install path, and `GITHUB_TOKEN` is never consulted by `OCX_INSTALL_DIST_URL`. The API boundary lives entirely in the generator (CI), never in the installed-on-the-machine path.

**Forwarded paths** (handled by nginx, *not* this repo):

```
setup.ocx.sh/docs/...      → ocx.sh/docs/...
setup.ocx.sh/actions/...   → GitHub Marketplace / GitLab CI Catalog
```

Never publish a file under a path that nginx will reroute — it just confuses caches.

## Channel routing (see `scripts/publish-installers.sh`)

`publish-installers.sh` is **table-driven** over the five `src/install.*` files (each mapped to its URL prefix + filename). The channel is derived from `VERSION`: a `-` (prerelease) → `next`; otherwise `stable`.

- **Always** publish the pinned immutable copy: `<prefix>/<VERSION>/install.<ext>`.
- **stable** → also overwrite the latest pointers `<prefix>/install.<ext>`.
- **next** → overwrite `<prefix>/next/install.<ext>`; do **not** touch the stable pointers.
- Every installer release also refreshes `dist.json` via `scripts/publish-dist.sh` (which calls `scripts/gen-dist.sh` against the `ocx-sh/ocx` Releases API). The manifest is otherwise kept current by `.github/workflows/update-dist.yml` (dispatch + hourly cron + manual), independently of installer releases.

## rsync flags (see `scripts/publish-installers.sh`)

- Pinned versioned uploads use `--ignore-existing` so a re-run of a release tag never silently overwrites a previously published artifact. If you ever need to overwrite, do it by hand, then audit the cache invalidation downstream.
- Latest + `next` pointers and `dist.json` overwrite freely. They **never** use `--delete` — adjacent versioned dirs must be preserved.
- `dist.json` is staged to a mktemp file first (`publish-dist.sh`); the generator is clobber-safe (exits non-zero on any fetch/parse/checksum failure and never emits a partial manifest), and `set -e` aborts the upload before the live `dist.json` is touched.
- All transfers happen over SSH with a deploy key (`SETUP_OCX_DEPLOY_KEY` secret) bound to the `setup.ocx.sh` environment. The key is single-purpose; it has no shell, no sudo, no read access outside the docroot.

## Versioned vs latest

Latest is a **convenience** for `curl ... | <shell>`; production CI pins (via `OCX_INSTALL_VERSION` or a pinned `<VERSION>` URL). Therefore:

- A bug in an installer published to `<VERSION>/` requires a new version (you can't unpublish — immutable). The latest pointer should be moved off the bad version immediately.
- The stable pointer (`<shell>/install.<ext>`, served bare at `/<shell>`) always tracks the highest **stable** semver tag with a release, never a prerelease. Prereleases land on the `next` channel only.
- `dist.json` lists both channels (newest-first). The installers' latest-resolution selects the first `stable` entry; `next` consumers pin the `/<shell>/next` pointer (or a pinned `<VERSION>`).

## Pre-release smoke

Before tagging:

```sh
task publish:dry-run        # stable: rsync --dry-run, no upload
task publish:dev-dry-run    # prerelease/next: validates the next/ rsync paths + manifest gen
```

After tagging, the release workflow handles upload. Verify post-release:

```sh
curl -fsSL https://setup.ocx.sh/sh/<VERSION>/install.sh | sh -s -- --version
curl -fsSL https://setup.ocx.sh/sh                      | sh   # bare stable
curl -fsSL https://setup.ocx.sh/dist                            # distribution manifest
```
