#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

# publish-installers.sh — rsync the five thin installers to setup.ocx.sh.
#
# VERSION-MAJOR layout. All five installers from one release land in a single
# immutable per-version dir; the mutable channel pointers live in their own dirs:
#
#   archive/<VERSION>/install.{sh,ps1,nu,fish,elv}   pinned (immutable, append-only)
#   latest/install.*                                  stable pointer  (overwritten)
#   next/install.*                                    prerelease pointer (overwritten)
#
# nginx exposes the friendly per-shell URLs (/sh, /sh/next, /sh/<VERSION>, …) by
# rewriting onto these dirs — see deploy/nginx/setup.ocx.sh.conf.example.
#
# Channel routing (from VERSION):
#   - VERSION contains a `-` (prerelease) -> pointer dir `next`.
#   - otherwise                            -> pointer dir `latest`.
#   The other pointer dir is left untouched (a prerelease never moves `latest`).
#
# The pinned copy uses --ignore-existing so a re-run of a release tag never
# silently overwrites a previously published artifact. Pointers and the manifest
# never use --delete (so sibling versioned dirs are preserved).
#
# After the installer transfers, the distribution manifest is refreshed via
# scripts/publish-dist.sh (sourced from the OCX product repo's GitHub Releases
# API) and uploaded to the docroot root as dist.json (overwrite). This is what
# OCX_INSTALL_DIST_URL reads.
#
# Required env: VERSION (no leading v), SSH_KEY (path), SETUP_OCX_HOST.
# Optional env: SSH_PORT (default 22), DRY_RUN=1, OCX_RELEASES_REPO, GITHUB_TOKEN.

set -eu

: "${VERSION:?VERSION is required (e.g. 1.2.3, no leading v)}"
: "${SSH_KEY:?SSH_KEY (path to private key) is required}"
: "${SETUP_OCX_HOST:=setup.ocx.sh}"

SSH_PORT="${SSH_PORT:-22}"
DRY_RUN="${DRY_RUN:-0}"

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC_DIR="$REPO_ROOT/src"
PUBLISH_DIST="$REPO_ROOT/scripts/publish-dist.sh"

[ -f "$PUBLISH_DIST" ] || {
    echo "publish-installers: $PUBLISH_DIST missing" >&2
    exit 1
}

# All five installers ship together; each lands under archive/<VERSION>/ and the
# channel pointer dir under its own filename (destfile == srcfile).
INSTALLER_FILES="install.sh install.ps1 install.nu install.fish install.elv"

# Pre-flight: every source file must exist before any upload. A plain for-loop
# (not a pipe) so a miss aborts the whole script under `set -e`.
for f in $INSTALLER_FILES; do
    [ -f "$SRC_DIR/$f" ] || {
        echo "publish-installers: $SRC_DIR/$f missing" >&2
        exit 1
    }
done

# Channel routing: a `-` in VERSION marks a prerelease (`next`); else `stable`.
case "$VERSION" in
    *-*) CHANNEL="next" ;;
    *) CHANNEL="stable" ;;
esac

RSYNC_OPTS="-avz"
SSH_CMD="ssh -i $SSH_KEY -p $SSH_PORT -o StrictHostKeyChecking=accept-new"

# run_rsync <args…> — transfer, unless DRY_RUN (then skip the network entirely;
# the logical target is echoed by the caller, so the dry-run still validates the
# publish paths offline, with no reachable host or deploy key required).
run_rsync() {
    [ "$DRY_RUN" = "1" ] && return 0
    # shellcheck disable=SC2086
    rsync $RSYNC_OPTS "$@"
}

echo "publish-installers: VERSION=$VERSION CHANNEL=$CHANNEL HOST=$SETUP_OCX_HOST DRY_RUN=$DRY_RUN"

# Channel pointer dir: stable -> latest/ ; next -> next/. The other is untouched.
if [ "$CHANNEL" = "next" ]; then
    POINTER_DIR="next"
else
    POINTER_DIR="latest"
fi

# Create the remote dirs up front so rsync's per-file transfers land cleanly.
# Done with `ssh mkdir -p` rather than rsync --mkpath to avoid depending on a
# recent rsync on the receiving host. Skipped under DRY_RUN.
REMOTE_MKDIR="mkdir -p archive/${VERSION} ${POINTER_DIR}"
if [ "$DRY_RUN" = "1" ]; then
    echo "publish-installers: [dry-run] would ssh ${SETUP_OCX_HOST} '${REMOTE_MKDIR}'"
else
    # shellcheck disable=SC2086
    $SSH_CMD "$SETUP_OCX_HOST" "$REMOTE_MKDIR"
fi

# Upload each installer: pinned immutable copy under archive/<VERSION>/ + the
# channel pointer. The path-echo before each transfer makes `task publish:dry-run`
# a real target validator even when the host is unreachable (run_rsync no-ops
# under DRY_RUN).
for f in $INSTALLER_FILES; do
    src="$SRC_DIR/$f"

    # Pinned (immutable, append-only) — always, regardless of channel.
    echo "publish-installers: -> archive/${VERSION}/${f} (pinned)"
    run_rsync --ignore-existing -e "$SSH_CMD" \
        "$src" "${SETUP_OCX_HOST}:archive/${VERSION}/${f}"

    # Channel pointer (mutable, no --delete).
    echo "publish-installers: -> ${POINTER_DIR}/${f} (pointer)"
    run_rsync -e "$SSH_CMD" \
        "$src" "${SETUP_OCX_HOST}:${POINTER_DIR}/${f}"
done

# Refresh the distribution manifest (sourced from the OCX product repo's GitHub
# Releases API) and upload it (overwrite). This is what OCX_INSTALL_DIST_URL
# (default https://setup.ocx.sh/dist.json) reads. SSH_KEY/SETUP_OCX_HOST/SSH_PORT/
# DRY_RUN are inherited; OCX_RELEASES_REPO + GITHUB_TOKEN (when set) feed the
# generator. A generator failure aborts the manifest upload (clobber-safety)
# without affecting the installer transfers above. Skipped under DRY_RUN (it
# makes a live GitHub API call + upload) — validate the manifest with `task dist`.
if [ "$DRY_RUN" = "1" ]; then
    echo "publish-installers: [dry-run] skipping dist.json refresh — run 'task dist' to validate the manifest"
else
    sh "$PUBLISH_DIST"
fi

echo "publish-installers: done"
