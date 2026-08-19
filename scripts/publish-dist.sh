#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

# publish-dist.sh — regenerate the distribution manifest and upload it to
# setup.ocx.sh as dist.json (overwrite, never --delete), alongside an immutable
# content-addressed snapshot and a sha256 sidecar:
#
#   /dist.json                 rolling pointer (overwritten every run)
#   /dist.json.sha256          sha256sum-format sidecar for the rolling manifest
#   /dist/<sha256>.json        immutable snapshot, append-only
#
# The snapshot is what makes a reproducible install possible without standing up
# a mirror: OCX_INSTALL_DIST_URL=https://setup.ocx.sh/dist/<sha256>.json pins the
# WHOLE closure (every release row carries an inline sha256), and the installers
# verify the body against the digest in its own name. Same layout `ocx-mirror
# dist sync` emits, so a mirror of setup.ocx.sh is shape-for-shape identical.
#
# This is the single upload path for the manifest. It is called by both the
# installer-publish pipeline (scripts/publish-installers.sh) and the
# dispatch/cron workflow (.github/workflows/update-dist.yml).
#
# The manifest is sourced from the OCX *product* repo's GitHub Releases API via
# scripts/gen-dist.sh (default ocx-sh/ocx, override with OCX_RELEASES_REPO).
# GITHUB_TOKEN and OCX_RELEASES_REPO are inherited from the environment and
# consumed by the generator.
#
# Clobber-safety (load-bearing): the generator exits non-zero (3) on any fetch /
# parse / checksum failure and NEVER prints a partial manifest. `set -e` aborts
# the upload on a non-zero generator exit, so a transient GitHub outage during
# the hourly cron cannot overwrite the live dist.json. We stage the generated
# bytes to a mktemp file first and only rsync that file.
#
# Required env: SSH_KEY (path to private key), SETUP_OCX_HOST.
# Optional env: SSH_PORT (default 22), DRY_RUN=1, OCX_RELEASES_REPO, GITHUB_TOKEN.

set -eu

: "${SSH_KEY:?SSH_KEY (path to private key) is required}"
: "${SETUP_OCX_HOST:=setup.ocx.sh}"

SSH_PORT="${SSH_PORT:-22}"
DRY_RUN="${DRY_RUN:-0}"

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
GEN_DIST="$REPO_ROOT/scripts/gen-dist.sh"

[ -f "$GEN_DIST" ] || {
    echo "publish-dist: $GEN_DIST missing" >&2
    exit 1
}

RSYNC_OPTS="-avz"
[ "$DRY_RUN" = "1" ] && RSYNC_OPTS="$RSYNC_OPTS --dry-run"
SSH_CMD="ssh -i $SSH_KEY -p $SSH_PORT -o StrictHostKeyChecking=accept-new"

echo "publish-dist: HOST=$SETUP_OCX_HOST REPO=${OCX_RELEASES_REPO:-ocx-sh/ocx} DRY_RUN=$DRY_RUN"

# Generate the manifest. On any generator failure (curl rc!=0, HTTP error,
# unparseable body, sha256.sum fetch failure) gen-dist.sh exits 3 and `set -e`
# aborts here BEFORE any upload — the live dist.json is left untouched.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT INT TERM
DIST_TMP="$STAGE/dist.json"

sh "$GEN_DIST" >"$DIST_TMP"

echo "publish-dist: generated dist manifest ($(wc -c <"$DIST_TMP") bytes)"

# Digest over the bytes as generated — the same bytes served, and the same bytes
# the installers hash when the URL is a pin. macOS ships shasum, not sha256sum.
if command -v sha256sum >/dev/null 2>&1; then
    DIST_SHA=$(sha256sum "$DIST_TMP" | awk '{print $1}')
else
    DIST_SHA=$(shasum -a 256 "$DIST_TMP" | awk '{print $1}')
fi
[ -n "$DIST_SHA" ] || {
    echo "publish-dist: failed to hash the generated manifest" >&2
    exit 1
}
echo "publish-dist: manifest sha256 $DIST_SHA"

mkdir -p "$STAGE/dist"
cp "$DIST_TMP" "$STAGE/dist/${DIST_SHA}.json"
printf '%s  dist.json\n' "$DIST_SHA" >"$STAGE/dist.json.sha256"

# mktemp creates staging files mode 600; rsync -a preserves them, leaving the
# remote copies unreadable by the nginx worker (HTTP 403). Force world-read so
# they are actually servable.
chmod 644 "$DIST_TMP" "$STAGE/dist.json.sha256" "$STAGE/dist/${DIST_SHA}.json"

# Publish order is load-bearing and mirrors what `ocx-mirror dist sync` does:
# immutable snapshot, then the sidecar, then the rolling dist.json LAST. A
# consumer reading mid-run therefore resolves either the old manifest or the new
# one, and never learns a digest whose snapshot is not already fetchable.
#
# --ignore-existing on the snapshot: it is content-addressed and append-only, so
# a re-run of an unchanged manifest is a no-op rather than a rewrite. The remote
# dist/ dir is created by rsync's --mkpath — the deploy key is locked to a forced
# rsync command (rrsync ...,restrict), which rejects an `ssh mkdir`.
# shellcheck disable=SC2086
rsync $RSYNC_OPTS --mkpath --ignore-existing -e "$SSH_CMD" \
    "$STAGE/dist/${DIST_SHA}.json" "${SETUP_OCX_HOST}:dist/${DIST_SHA}.json"

# shellcheck disable=SC2086
rsync $RSYNC_OPTS -e "$SSH_CMD" \
    "$STAGE/dist.json.sha256" "${SETUP_OCX_HOST}:dist.json.sha256"

# Upload (overwrite, never --delete) so sibling versioned dirs are preserved.
# shellcheck disable=SC2086
rsync $RSYNC_OPTS -e "$SSH_CMD" \
    "$DIST_TMP" "${SETUP_OCX_HOST}:dist.json"

echo "publish-dist: done"
