# Update docs

Keep `README.md` and `CONTRIBUTING.md` in sync when the project shape changes.

## site/ (canonical user docs)

The knob matrix, exit-code table, URL layout, pinning, mirror and CA-bundle docs live on the `/install/` site (`site/src/content/docs/`, published at `https://ocx.sh/install/`). The README carries the quick start and links to the pages. Update the site when:

- an `OCX_INSTALL_*` knob, a flag, or an embedded-config placeholder is added, removed or renamed (`configuration.mdx`, `mirrors.mdx`)
- an exit code is added or its meaning changes (`reference.mdx`)
- the URL layout, channels or manifest pinning change (`versions.mdx`, `reference.mdx`)
- a one-liner changes (`index.mdx`, `examples.mdx`, `versions.mdx`)

`site/scripts/contract.test.mjs` (run by `task site:test`, part of `task verify`) enforces the first two: every `OCX_INSTALL_*` name in `src/install.*` must appear on `configuration.mdx` and the reverse, and every code in an installer's `# Exit:` header must be a table row on `reference.mdx` and the reverse. It does not check meanings. Pages follow `.claude/rules/docs-quality.md`.

## README.md

The README is the front door for `curl | <shell>` users: the quick start and a table linking to the site. Update when:

- **Curl one-liners** — any of the five installer URLs (bare `/sh`, `/pwsh`, `/nu`, `/fish`, `/elvish`, pinned `<VERSION>`, dev `/next`) changes
- **URL layout** — the version-major key prefixes (`archive/<VERSION>/`, `latest/`, `next/`) or the per-shell rewrite layer change (keep `deploy/bunny/edge-rules.py` and `.claude/rules/publish.md` in sync)
- **Site pages** — a page under `site/src/content/docs/` is added, renamed or removed

## CONTRIBUTING.md

The CONTRIBUTING guide is for developers landing a PR. Update when:

- **Prerequisites** — a new tool dependency is introduced (Task, OCX, pwsh, nu/fish/elvish, docker buildx, the `git submodule update --init --recursive` for vendored bats, etc.); note the **Windows PowerShell 5.1 floor** the installer targets
- **Layout table** — a top-level dir is added/removed (e.g. `src/`, `external/`)
- **Running tests** — `task` names change in `taskfile.yml` (e.g. `nu:verify`/`fish:verify`/`elvish:verify`); the vendored-bats invocation; integration tests inject a binary via `__OCX_TESTING_INSTALL_BINARY`
- **Commit conventions** — git-cliff parser rules change in `cliff.toml`

## CLAUDE.md

The CLAUDE.md surfaces table must reflect reality. Update when a top-level dir is added/removed (e.g. `src/`, `external/`, `deploy/bunny/`, `deploy/github/`) or a top-level pipeline script/workflow is added (e.g. `scripts/gen-dist.sh`, `scripts/publish-dist.sh`, `scripts/lib/bunny.sh`, `.github/workflows/update-dist.yml`). Also update the **Required release secrets** table when a secret is added (e.g. `SETUP_OCX_DISPATCH_TOKEN`, which lives in `ocx-sh/ocx`).

## Cross-repo manifest

When the `dist.json` sourcing or refresh mechanism changes, keep these in sync (they all describe the same pipeline):

- `deploy/github/ocx-release-dispatch.yml.example` — the reference snippet `ocx-sh/ocx` adds to its release workflow (`repository_dispatch(ocx-released)`, `SETUP_OCX_DISPATCH_TOKEN`, the setup.ocx.sh repo slug in the API URL).
- `scripts/gen-dist.sh` — sources `dist.json` from the `ocx-sh/ocx` GitHub Releases API (channel = API `prerelease` flag), inlining a per-target `sha256` + URL derived from each release's `sha256.sum`; uses `GITHUB_TOKEN` in CI.
- `scripts/publish-dist.sh` — regenerate + upload `dist.json` to Bunny Edge Storage (also invoked on installer releases).
- `.github/workflows/update-dist.yml` — rebuilds the manifest on dispatch + hourly cron + manual.
- `.claude/rules/publish.md` and `.claude/rules/workflow-release.md` — the contract + the cross-repo dispatch/cron-fallback flow.

Invariant to preserve in all of them: generation may use the GitHub API (CI-side, with `GITHUB_TOKEN`); the **install path stays tokenless** (reads the self-hosted `dist.json`, with the checksum inline — no separate `sha256.sum` fetch). Installer-script `v*` tags are decoupled from the OCX product versions listed in `dist.json`.
