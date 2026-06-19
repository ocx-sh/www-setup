# Release workflow

## Local steps

1. `git checkout main && git pull`
2. `task release:prepare` — computes next version from conventional commits, regenerates `CHANGELOG.md`, runs `task verify`.
3. Review the diff. Adjust `CHANGELOG.md` if `git-cliff` mis-grouped something.
4. Commit and tag:
   ```bash
   git add -A
   git commit -m "release: vX.Y.Z"
   git tag vX.Y.Z
   ```
5. Push both:
   ```bash
   git push origin main
   git push origin vX.Y.Z
   ```

The tag push triggers `.github/workflows/release.yml`.

## What the release workflow does

| Job | Action |
|---|---|
| `release` | Generates GitHub release notes from git-cliff `--latest`, creates the release. Marks it `prerelease: true` when the tag contains `-`, and SKIPS the "update major version tag" step for prerelease tags. |
| `publish-installers` | Table-driven rsync of all five `src/install.*` to the channel-appropriate paths via `publish-installers.sh` (`SETUP_OCX_DEPLOY_KEY`), then refreshes + uploads `dist.json` via `publish-dist.sh` (which regenerates it from the `ocx-sh/ocx` Releases API via `gen-dist.sh`) |

Both jobs run on every `v*` tag (prereleases included). There is no mirror-to-GitLab step — the GLF lives in a separate repo now.

## Stable vs. prerelease ("next") tags

Channel routing keys off the tag string (`-` present → prerelease). For each installer `<shell>`/`<ext>`:

| Tag shape | Example | GH release | Pointer overwritten | Pinned copy |
|---|---|---|---|---|
| stable | `v0.5.0` | normal | `<shell>/install.<ext>` (bare `/<shell>`) | `<shell>/0.5.0/` |
| prerelease | `v0.5.0-rc.1` | `prerelease: true` | `<shell>/next/install.<ext>` (stable pointers untouched) | `<shell>/0.5.0-rc.1/` |

Every installer release (either channel) also refreshes `dist.json` — but note the manifest is sourced from the **`ocx-sh/ocx` Releases API**, not this repo's tags, so its contents track OCX product versions independently of the installer-script tag you just pushed (see the Cross-repo manifest section below). Validate locally with `task publish:dry-run` (stable) or `task publish:dev-dry-run` (prerelease).

## Version policy

The project is **pre-release**: there are zero git tags and nothing has shipped yet. The first release will cut the initial tag. Once versioning starts, the conventional-commit → bump mapping is:

- `feat:` → minor
- `fix:`, `perf:` → patch
- `feat!:` / `fix!:` / `BREAKING CHANGE:` → major
- Everything else → no bump

(Pre-1.0 SemVer convention — breaking changes may be folded into minor bumps — is at the maintainer's discretion until the line is settled at the first release.)

A prerelease is cut by tagging with a SemVer prerelease suffix (`vX.Y.Z-rc.1`, `vX.Y.Z-beta.2`, …). The `-` routes it to the `next` channel and the GitHub `prerelease` flag automatically — no separate step.

## Cross-repo manifest

`dist.json` tracks **OCX product versions** published by `ocx-sh/ocx`, sourced from that repo's GitHub Releases API (channel = the API `prerelease` flag), with an inline per-target `sha256` + download URL. It is rebuilt by `.github/workflows/update-dist.yml` on three triggers:

| Trigger | Role |
|---|---|
| `repository_dispatch` (`ocx-released`) | Fast path — fired by `ocx-sh/ocx` the moment a new OCX release publishes. |
| hourly `cron` | Fallback — catches up within the hour if a dispatch is absent or fails. |
| `workflow_dispatch` | Manual rebuild. |

The dispatch snippet that `ocx-sh/ocx` adds to its own release workflow is checked in here as reference: [`deploy/github/ocx-release-dispatch.yml.example`](../../deploy/github/ocx-release-dispatch.yml.example). It POSTs to the setup.ocx.sh `repository_dispatch` API with `event_type: ocx-released` and `client_payload.version` = the released tag, authed Bearer with `SETUP_OCX_DISPATCH_TOKEN`.

- **`SETUP_OCX_DISPATCH_TOKEN`** lives as a secret in **`ocx-sh/ocx`** (not this repo). It is a token scoped to setup.ocx.sh — a fine-grained PAT with `contents: read` + `actions: write`, or a classic PAT with `repo` scope — used only to trigger this repo's workflows.
- Generation runs in CI with `GITHUB_TOKEN` (to avoid API rate limits); the **install path stays tokenless** — the installer reads the self-hosted `dist.json`, never the GitHub API.

## What never goes in a release commit

- `Co-Authored-By:` trailers
- Attribution lines
- Anything `git-cliff` can't parse as conventional — it'll either be dropped or grouped under "Other"
