#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

# publish-dist.sh — regenerate the distribution manifest and upload it to
# setup.ocx.sh as dist.json (overwrite, never --delete).
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
DIST_TMP=$(mktemp)
trap 'rm -f "$DIST_TMP"' EXIT INT TERM

sh "$GEN_DIST" >"$DIST_TMP"

echo "publish-dist: generated dist manifest ($(wc -c <"$DIST_TMP") bytes)"

# Upload (overwrite, never --delete) so sibling versioned dirs are preserved.
# shellcheck disable=SC2086
rsync $RSYNC_OPTS -e "$SSH_CMD" \
    "$DIST_TMP" "${SETUP_OCX_HOST}:dist.json"

echo "publish-dist: done"
