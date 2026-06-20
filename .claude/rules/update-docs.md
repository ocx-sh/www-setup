# Update docs

Keep `README.md` and `CONTRIBUTING.md` in sync when the project shape changes.

## README.md

The README is the front door for `curl | <shell>` users. Update when:

- **Curl one-liners** — any of the five installer URLs (bare `/sh`, `/pwsh`, `/nu`, `/fish`, `/elvish`, pinned `<VERSION>`, dev `/next`), or env-var overrides, change
- **Env-var matrix** — an `OCX_INSTALL_*` knob added, removed, or renamed in any `src/install.*` (the matrix omits internal/test-only hatches like `__OCX_TESTING_INSTALL_BINARY`)
- **Exit-code table** — code added, removed, or its meaning changes
- **Distribution manifest / channels** — `OCX_INSTALL_DIST_URL`, the `/dist` manifest, or the stable/`next` channel layout changes
- **URL layout** — the version-major on-disk dirs (`archive/<VERSION>/`, `latest/`, `next/`) or the nginx per-shell rewrite layer change (keep `deploy/nginx/setup.ocx.sh.conf.example` + `.claude/rules/publish.md` in sync)
- **Stdout/stderr contract** — discipline changes (which would be a major version bump)

## CONTRIBUTING.md

The CONTRIBUTING guide is for developers landing a PR. Update when:

- **Prerequisites** — a new tool dependency is introduced (Task, OCX, pwsh, nu/fish/elvish, docker buildx, the `git submodule update --init --recursive` for vendored bats, etc.); note the **Windows PowerShell 5.1 floor** the installer targets
- **Layout table** — a top-level dir is added/removed (e.g. `src/`, `external/`)
- **Running tests** — `task` names change in `taskfile.yml` (e.g. `nu:verify`/`fish:verify`/`elvish:verify`); the vendored-bats invocation; integration tests inject a binary via `__OCX_TESTING_INSTALL_BINARY`
- **Commit conventions** — git-cliff parser rules change in `cliff.toml`

## CLAUDE.md

The CLAUDE.md surfaces table must reflect reality. Update when a top-level dir is added/removed (e.g. `src/`, `external/`, `deploy/nginx/`, `deploy/github/`) or a top-level pipeline script/workflow is added (e.g. `scripts/gen-dist.sh`, `scripts/publish-dist.sh`, `.github/workflows/update-dist.yml`). Also update the **Required release secrets** table when a secret is added (e.g. `SETUP_OCX_DISPATCH_TOKEN`, which lives in `ocx-sh/ocx`).

## Cross-repo manifest

When the `dist.json` sourcing or refresh mechanism changes, keep these in sync (they all describe the same pipeline):

- `deploy/github/ocx-release-dispatch.yml.example` — the reference snippet `ocx-sh/ocx` adds to its release workflow (`repository_dispatch(ocx-released)`, `SETUP_OCX_DISPATCH_TOKEN`, the setup.ocx.sh repo slug in the API URL).
- `scripts/gen-dist.sh` — sources `dist.json` from the `ocx-sh/ocx` GitHub Releases API (channel = API `prerelease` flag), inlining a per-target `sha256` + URL derived from each release's `sha256.sum`; uses `GITHUB_TOKEN` in CI.
- `scripts/publish-dist.sh` — regenerate + rsync `dist.json` (also invoked on installer releases).
- `.github/workflows/update-dist.yml` — rebuilds the manifest on dispatch + hourly cron + manual.
- `.claude/rules/publish.md` and `.claude/rules/workflow-release.md` — the contract + the cross-repo dispatch/cron-fallback flow.

Invariant to preserve in all of them: generation may use the GitHub API (CI-side, with `GITHUB_TOKEN`); the **install path stays tokenless** (reads the self-hosted `dist.json`, with the checksum inline — no separate `sha256.sum` fetch). Installer-script `v*` tags are decoupled from the OCX product versions listed in `dist.json`.
