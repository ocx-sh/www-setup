# Publish rules

The installer-publish pipeline owns one job: keep `setup.ocx.sh` serving the latest set of installer scripts at predictable URLs. This file documents the contract.

## URL layout

Five entrypoints, one per shell (`<shell>` ∈ `sh pwsh nu fish elvish`; `<ext>` ∈ `sh ps1 nu fish elv`):

**Stored key layout** (version-major — what the publish pipeline uploads to Bunny Edge Storage). Edge Storage is DIRECTORY-backed, not a flat keyspace: a path is a file or a directory, never both, so `sh` and `sh/next` can never coexist as objects. The friendly URLs are therefore routed, never stored.

```
archive/<VERSION>/install.<ext>   # pinned (immutable, append-only); canonical artifact URL
archive/<VERSION>/<shell>        # same bytes, shell-segment name (feeds the pinned rewrite)
latest/<shell>                   # STABLE channel pointer (mutable, overwritten)
next/<shell>                     # "next" channel pointer: newest of prerelease + stable (mutable)
setup.ocx.sh/dist.json                        # distribution manifest (overwritten every release)
setup.ocx.sh/dist.json.sha256                 # sha256sum-format sidecar for the rolling manifest
setup.ocx.sh/dist/<sha256>.json               # immutable manifest snapshot (append-only)
```

Cache-Control is applied by pull-zone edge rules, per route, not stored per
object: `archive/` and `dist/<sha256>.json` get `max-age=31536000`; everything
else falls through to the zone default of `max-age=300`, which is what keeps a
published release and the dispatch-triggered `dist.json` refresh actually
visible instead of stale at the edge.

**Friendly per-shell URLs** (edge-rule rewrites onto the keys above; no objects of their own):

```
setup.ocx.sh/<shell>            # → latest/<shell>
setup.ocx.sh/<shell>/next       # → next/<shell>                 (alias: /<shell>/canary)
setup.ocx.sh/<shell>/<VERSION>  # → archive/<VERSION>/<shell>    (optional trailing /install.<ext>)
setup.ocx.sh/dist               # → dist.json
setup.ocx.sh/releases           # legacy alias → dist.json
```

`/dist` is matched EXACTLY (not as a prefix), so `/dist/<sha256>.json` is not shadowed by it — the snapshot is served straight from storage.

`<VERSION>` is the semver string without a leading `v` (e.g. `2.0.1`, not `v2.0.1`).

The per-shell `/<shell>` URLs carry no objects of their own — pull-zone edge rules rewrite them onto `latest/`, `next/`, and `archive/<VERSION>/`; `/dist` is an exact-match alias for `dist.json`. The `canary` segment is an alias for `next` (the pipeline only ever writes the `next/` prefix). **`deploy/bunny/edge-rules.py` IS the routing contract** — it is applied, not reference, and `edge-rules.py verify` probes every row of the table above against the live zone.

Two Bunny-specific traps, both found the hard way:

- **`*` is greedy across `/`.** A pattern of `https://*/sh` matches `/latest/sh` and `/archive/0.1.1/sh` too. Every wildcard must sit behind a fully anchored literal prefix and never in the host position — otherwise a pinned URL silently serves `latest`, which is an immutability violation that still returns 200.
- **Max 5 patterns per trigger.** `edge-rules.py` chunks across multiple trigger objects (`TriggerMatchingType` 0 = MatchAny), which the API accepts.

Matching is Lua patterns, not PCRE — no alternation, no lookaround. Rewrite targets use path-segment variable expansion (`%{Path.0}` is 0-indexed), and `ActionParameter1` must be a full URL; a relative path is rejected.

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

#### Content-addressed snapshots

`scripts/publish-dist.sh` publishes three documents per run: the immutable snapshot `dist/<sha256>.json`, the sidecar `dist.json.sha256` (sha256sum format, naming `dist.json`), and the rolling `dist.json` **last**. That order is load-bearing and matches `ocx-mirror dist sync`: a consumer reading mid-run resolves either the old manifest or the new one, and never learns a digest whose snapshot is not already fetchable. The snapshot upload uses `--ignore-existing` (content-addressed ⇒ append-only; an unchanged manifest is a no-op) and `--mkpath` to create the remote `dist/` dir, since the `rrsync`-restricted deploy key rejects an `ssh mkdir`.

`OCX_INSTALL_DIST_URL=https://setup.ocx.sh/dist/<sha256>.json` pins the **whole closure** — every release row already carries an inline `sha256`, so one hash fixes every version, URL and checksum the installer will use. The installers detect the 64-hex basename and **verify the served body against it** (mismatch → exit **4**, missing sha256 tool → exit **2**, never a silent skip). That makes the serving host pure transport, which is what lets a mirror stay untrusted — see [`mirror-auth.md`](mirror-auth.md).

The manifest is rebuilt and uploaded (overwrite) by `.github/workflows/update-dist.yml`, which runs on three triggers: a `repository_dispatch` of type `ocx-released` fired by `ocx-sh/ocx` when a new OCX release ships (the fast path), an **hourly cron** (the fallback if a dispatch is absent or fails), and `workflow_dispatch` (manual). It is **also** refreshed opportunistically on this repo's own installer releases — `scripts/publish-dist.sh` regenerates and uploads it as part of the `publish-installers` job.

#### Decoupled versioning

`dist.json` lists **OCX product versions** (from `ocx-sh/ocx`). This repo's own `v*` tags version the **installer scripts** (`src/install.*`) and the publish pipeline — they do **not** appear in `dist.json` and do not gate which OCX version the installer resolves. Shipping a new installer does not require a new OCX release, and a new OCX release does not require re-tagging the installer.

#### The install path stays tokenless

Generation uses the GitHub API (CI-side, with `GITHUB_TOKEN`); **resolution does not**. The installer reads the self-hosted `dist.json` over the HTTPS-enforced downloader to resolve the latest version + checksum + URL — there is no GitHub API dependency in the install path, and `GITHUB_TOKEN` is never consulted by `OCX_INSTALL_DIST_URL`. The API boundary lives entirely in the generator (CI), never in the installed-on-the-machine path.

**Forwarded paths** (proxied to `ocx.sh` transparently by an OriginUrl edge rule):

```
setup.ocx.sh/docs/...      → ocx.sh/docs/...
setup.ocx.sh/actions/...   → GitHub Marketplace / GitLab CI Catalog
```

Never publish an object under a key an edge rule reroutes — it just confuses caches.

## Channel routing (see `scripts/publish-installers.sh`)

`publish-installers.sh` iterates the five `src/install.*` files; all five from one release land in the same `archive/<VERSION>/` dir. The channel is derived from `VERSION`: a `-` (prerelease) routes to `next` only; a stable version routes to **both** `latest` and `next`.

- **Always** publish the pinned immutable copies: `archive/<VERSION>/install.<ext>` **and** `archive/<VERSION>/<shell>` (all five, both names).
- **stable** → overwrite the `latest/<shell>` **and** `next/<shell>` pointers. `next` is the "bleeding edge" channel = newest of {latest stable, newest prerelease}; promoting a stable must not leave `next/` serving an older prerelease. (Edge case: patching an old stable line while a newer prerelease is pending would pull `next/` back — fix that by hand.)
- **next (prerelease)** → overwrite the `next/<shell>` pointers only; do **not** touch `latest/`.
- Edge Storage creates parent directories implicitly on PUT, so there is nothing to `mkdir` first. (This is what the old rsync `--mkpath` existed for.)
- Every installer release also refreshes `dist.json` via `scripts/publish-dist.sh` (which calls `scripts/gen-dist.sh` against the `ocx-sh/ocx` Releases API). The manifest is otherwise kept current by `.github/workflows/update-dist.yml` (dispatch + hourly cron + manual), independently of installer releases.
- Routing is applied out-of-band by `deploy/bunny/edge-rules.py apply`, never by CI — it needs `BUNNY_API_KEY`, an account-wide credential deliberately kept out of the release pipeline. Content publishing and routing changes are fully independent.

## Upload verbs (see `scripts/lib/bunny.sh`)

Two verbs, both plain `curl` against the Edge Storage HTTP API. Every upload carries a `Checksum` header (SHA256, uppercase hex) so Bunny verifies the body server-side and rejects a truncated transfer with 400:

- **`bn_put_new KEY FILE`** — write-if-absent. Pinned versioned uploads and `dist/<sha256>.json` snapshots use it, so a re-run of a release tag never silently overwrites a previously published artifact. If you ever need to overwrite, do it by hand, then audit the cache invalidation downstream. It is a GET-then-PUT rather than a conditional write: the Storage API has no conditional-write header. The pipeline is single-writer (one release job; a `dist-manifest` concurrency group on the cron), so the TOCTOU window is not reachable.
- **`bn_put KEY FILE`** — overwrite. The `latest/` + `next/` pointers and `dist.json` use it. **Nothing ever deletes** — there is no DELETE path anywhere in the pipeline, and the `archive/` versioned keys must be preserved. Publishing is an upload-only push, not a sync: removing a file from `src/` never removes it from the store.
- `dist.json` is staged to a mktemp file first (`publish-dist.sh`); the generator is clobber-safe (exits non-zero on any fetch/parse/checksum failure and never emits a partial manifest). Generation is retried as a whole — 3 attempts, 60s apart (`GEN_ATTEMPTS`/`GEN_RETRY_DELAY`) — because GitHub's release-asset CDN intermittently 500s a healthy `sha256.sum` for minutes; once exhausted the script exits 3 before the live `dist.json` is touched.
- Auth is `BUNNY_STORAGE_KEY` + `BUNNY_STORAGE_ZONE`, bound to the `setup.ocx.sh` environment. The storage key is scoped to that one storage zone. The account-wide `BUNNY_API_KEY` (used for edge rules and purges) is deliberately NOT in CI.

## Versioned vs latest

Latest is a **convenience** for `curl ... | <shell>`; production CI pins (via `OCX_INSTALL_VERSION` or a pinned `<VERSION>` URL). Therefore:

- A bug in an installer published to `archive/<VERSION>/` requires a new version (you can't unpublish — immutable). The `latest/` pointer should be moved off the bad version immediately.
- The stable pointer (`latest/<shell>`, served at the bare `/<shell>`) always tracks the highest **stable** semver tag with a release, never a prerelease. The `next` pointer tracks the **newest** installer of either channel: a prerelease moves it ahead, and a stable promotion also advances it (so `next` is never behind `latest`).
- `dist.json` lists both channels (newest-first). The installers' latest-resolution selects the first `stable` entry; `next` consumers use the `/<shell>/next` URL (or a pinned `<VERSION>`).

## Pre-release smoke

Before tagging:

```sh
task publish:dry-run        # stable: validate archive/ + latest/ keys offline (no upload, no credentials)
task publish:dev-dry-run    # prerelease/next: validate archive/ + next/ keys offline
task dist                   # validate the dist.json manifest (live ocx-sh/ocx Releases API)
task rules:plan             # render the edge-rule set offline
task rules:verify           # probe every routed URL against the live zone
```

After tagging, the release workflow handles upload. Verify post-release:

```sh
curl -fsSL https://setup.ocx.sh/sh/<VERSION>  | sh -s -- --version   # pinned
curl -fsSL https://setup.ocx.sh/sh            | sh                   # bare stable
curl -fsSL https://setup.ocx.sh/dist                                # distribution manifest
curl -fsI  https://setup.ocx.sh/sh/<VERSION> | grep -i cache-control # immutable
curl -fsI  https://setup.ocx.sh/sh          | grep -i cache-control  # max-age=300
```
