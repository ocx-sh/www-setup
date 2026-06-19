#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

# publish-installers.sh — rsync the five thin installers to setup.ocx.sh.
#
# One src/ dir holds all five installers; this script maps each source file to
# its published URL prefix and filename:
#
#   src/install.sh    -> sh/…/install.sh
#   src/install.ps1   -> pwsh/…/install.ps1
#   src/install.nu    -> nu/…/install.nu
#   src/install.fish  -> fish/…/install.fish
#   src/install.elv   -> elvish/…/install.elv
#
# Channel routing (from VERSION):
#   - VERSION contains a `-` (prerelease) -> `next` channel.
#   - otherwise                            -> `stable` channel.
#
# Per installer:
#   - Pinned (immutable, append-only): <prefix>/<VERSION>/<file> with
#     --ignore-existing so a re-run of a release tag never silently overwrites a
#     previously published artifact.
#   - Channel pointer (mutable, no --delete):
#       stable -> <prefix>/<file>
#       next   -> <prefix>/next/<file>   (stable pointers left untouched)
#
# After the installer transfers, the distribution manifest is refreshed via
# scripts/publish-dist.sh (sourced from the OCX product repo's GitHub Releases
# API) and uploaded to the docroot root as dist.json (overwrite). This is what
# OCX_INSTALL_DIST_URL reads.
#
# Pointers and the manifest never use --delete (so sibling versioned dirs are
# preserved).
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

# source→URL table: "<srcfile> <urlprefix> <destfile>" — one row per installer.
INSTALLER_TABLE="install.sh sh install.sh
install.ps1 pwsh install.ps1
install.nu nu install.nu
install.fish fish install.fish
install.elv elvish install.elv"

# Pre-flight: every source file must exist before any upload.
echo "$INSTALLER_TABLE" | while read -r srcfile _prefix _destfile; do
    [ -n "$srcfile" ] || continue
    [ -f "$SRC_DIR/$srcfile" ] || {
        echo "publish-installers: $SRC_DIR/$srcfile missing" >&2
        exit 1
    }
done

# Channel routing: a `-` in VERSION marks a prerelease (`next`); else `stable`.
case "$VERSION" in
    *-*) CHANNEL="next" ;;
    *) CHANNEL="stable" ;;
esac

RSYNC_OPTS="-avz"
[ "$DRY_RUN" = "1" ] && RSYNC_OPTS="$RSYNC_OPTS --dry-run"
SSH_CMD="ssh -i $SSH_KEY -p $SSH_PORT -o StrictHostKeyChecking=accept-new"

echo "publish-installers: VERSION=$VERSION CHANNEL=$CHANNEL HOST=$SETUP_OCX_HOST DRY_RUN=$DRY_RUN"

# Upload each installer: pinned immutable copy + the channel pointer. The here-doc
# feeds the loop on the CURRENT shell (not a pipe) so an rsync failure aborts the
# whole script under `set -e`.
while read -r srcfile prefix destfile; do
    [ -n "$srcfile" ] || continue
    src="$SRC_DIR/$srcfile"

    # Pinned (immutable, append-only) — always, regardless of channel.
    # shellcheck disable=SC2086
    rsync $RSYNC_OPTS --ignore-existing -e "$SSH_CMD" \
        "$src" "${SETUP_OCX_HOST}:${prefix}/${VERSION}/${destfile}"

    # Channel pointer (mutable, no --delete).
    if [ "$CHANNEL" = "next" ]; then
        # shellcheck disable=SC2086
        rsync $RSYNC_OPTS -e "$SSH_CMD" \
            "$src" "${SETUP_OCX_HOST}:${prefix}/next/${destfile}"
    else
        # shellcheck disable=SC2086
        rsync $RSYNC_OPTS -e "$SSH_CMD" \
            "$src" "${SETUP_OCX_HOST}:${prefix}/${destfile}"
    fi
done <<EOF
$INSTALLER_TABLE
EOF

# Refresh the distribution manifest (sourced from the OCX product repo's GitHub
# Releases API) and upload it (overwrite). This is what OCX_INSTALL_DIST_URL
# (default https://setup.ocx.sh/dist.json) reads. SSH_KEY/SETUP_OCX_HOST/SSH_PORT/
# DRY_RUN are inherited; OCX_RELEASES_REPO + GITHUB_TOKEN (when set) feed the
# generator. A generator failure aborts the manifest upload (clobber-safety)
# without affecting the installer transfers above.
sh "$PUBLISH_DIST"

echo "publish-installers: done"
