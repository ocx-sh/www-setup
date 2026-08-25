#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

# publish-installers.sh — upload the five thin installers to setup.ocx.sh
# (Bunny Edge Storage).
#
# STORED LAYOUT. Edge Storage is directory-backed, so a path can be a file or a
# directory but never both: `sh` and `sh/next` cannot coexist. The friendly
# per-shell URLs are therefore NOT stored — they are served by Edge Rules
# rewriting onto the layout below. See deploy/bunny/README.md.
#
#   archive/<VERSION>/install.{sh,ps1,nu,fish,elv}   pinned, immutable, append-only
#   archive/<VERSION>/{sh,pwsh,nu,fish,elvish}       same bytes, shell-segment name
#   latest/{sh,pwsh,nu,fish,elvish}                  stable pointer   (overwritten)
#   next/{sh,pwsh,nu,fish,elvish}                    next pointer     (overwritten)
#
# The shell-segment copies exist so ONE edge rule can serve all five shells:
#   ^/(sh|pwsh|nu|fish|elvish)$            -> /latest/$1
#   ^/(sh|pwsh|nu|fish|elvish)/(next|canary)$ -> /next/$1
#   ^/(sh|pwsh|nu|fish|elvish)/([0-9][^/]*)$  -> /archive/$2/$1
# Naming them by extension instead would cost five rules apiece against a
# 20-rule-per-pull-zone budget. `archive/<VERSION>/install.<ext>` is kept because
# it is the published canonical artifact URL (shipped contract, curl -O friendly).
#
# Channel routing (from VERSION):
#   - VERSION contains a `-` (prerelease) -> pointer prefix `next`.
#   - otherwise                            -> pointer prefix `latest`.
#   The other pointer is left untouched (a prerelease never moves `latest`).
#
# Pinned copies use bn_put_new (write-if-absent), so a re-run of a release tag
# never silently overwrites a published artifact. Pointers overwrite. Nothing is
# ever deleted.
#
# Required env: VERSION (no leading v), BUNNY_STORAGE_ZONE, BUNNY_STORAGE_KEY
#               (or BUNNY_STORAGE_KEY_FILE).
# Optional env: BUNNY_STORAGE_HOST, OCX_SRC_DIR (publish from somewhere other
#               than ./src — used to backfill a past tag), OCX_SKIP_DIST=1
#               (skip the manifest refresh; backfilling history must not move
#               the live dist.json), DRY_RUN=1, OCX_RELEASES_REPO, GITHUB_TOKEN.

set -eu

: "${VERSION:?VERSION is required (e.g. 1.2.3, no leading v)}"

DRY_RUN="${DRY_RUN:-0}"

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC_DIR="${OCX_SRC_DIR:-$REPO_ROOT/src}"
PUBLISH_DIST="$REPO_ROOT/scripts/publish-dist.sh"

# bunny.sh is linted on its own via `git ls-files '*.sh'`; shellcheck cannot
# resolve the runtime-computed $REPO_ROOT.
# shellcheck source=scripts/lib/bunny.sh disable=SC1091
. "$REPO_ROOT/scripts/lib/bunny.sh"

[ -f "$PUBLISH_DIST" ] || {
    echo "publish-installers: $PUBLISH_DIST missing" >&2
    exit 1
}

# <shell-segment>:<filename>. The segment is the public URL word (/sh, /pwsh…);
# the filename is the canonical artifact name. Both are published.
INSTALLERS="sh:install.sh pwsh:install.ps1 nu:install.nu fish:install.fish elvish:install.elv"

# Pre-flight: every source file must exist before any upload. A plain for-loop
# (not a pipe) so a miss aborts the whole script under `set -e`.
for entry in $INSTALLERS; do
    f=${entry#*:}
    [ -f "$SRC_DIR/$f" ] || {
        echo "publish-installers: $SRC_DIR/$f missing" >&2
        exit 1
    }
done

bn_require_auth

# Channel routing: a `-` in VERSION marks a prerelease (`next`); else `stable`.
case "$VERSION" in
    *-*) CHANNEL="next" ;;
    *) CHANNEL="stable" ;;
esac

echo "publish-installers: VERSION=$VERSION CHANNEL=$CHANNEL ZONE=${BUNNY_STORAGE_ZONE:-<unset>} SRC=$SRC_DIR DRY_RUN=$DRY_RUN"

# Channel pointer prefixes:
#   prerelease -> next/ only          (latest/ is never moved by a prerelease)
#   stable     -> latest/ AND next/   (next is "bleeding edge" = newest of the
#                                       two channels; a stable promotion must not
#                                       leave next/ serving an OLDER prerelease)
# Edge case (out of order): patching an old stable line while a newer prerelease
# is pending would pull next/ back — handle that by hand on the rare occasion.
if [ "$CHANNEL" = "next" ]; then
    POINTER_DIRS="next"
else
    POINTER_DIRS="latest next"
fi

# The key-echo before each transfer makes `task publish:dry-run` a real target
# validator even with no credentials present (bn_put/bn_put_new no-op under
# DRY_RUN).
for entry in $INSTALLERS; do
    seg=${entry%%:*}
    f=${entry#*:}
    src="$SRC_DIR/$f"

    # Pinned (immutable, append-only) — always, regardless of channel.
    echo "publish-installers: -> archive/${VERSION}/${f} (pinned)"
    bn_put_new "archive/${VERSION}/${f}" "$src"

    echo "publish-installers: -> archive/${VERSION}/${seg} (pinned alias)"
    bn_put_new "archive/${VERSION}/${seg}" "$src"

    # Channel pointer(s) (mutable, overwrite). Stable writes latest/ + next/.
    for ptr in $POINTER_DIRS; do
        echo "publish-installers: -> ${ptr}/${seg} (pointer)"
        bn_put "${ptr}/${seg}" "$src"
    done
done

# Refresh the distribution manifest (sourced from the OCX product repo's GitHub
# Releases API) and upload it (overwrite). This is what OCX_INSTALL_DIST_URL
# (default https://setup.ocx.sh/dist.json) reads. The Bunny + DRY_RUN env is
# inherited; OCX_RELEASES_REPO + GITHUB_TOKEN (when set) feed the generator. A
# generator failure aborts the manifest upload (clobber-safety) without affecting
# the installer transfers above. Skipped under DRY_RUN (it makes a live GitHub
# API call + upload) — validate the manifest with `task dist`.
if [ "$DRY_RUN" = "1" ]; then
    echo "publish-installers: [dry-run] skipping dist.json refresh — run 'task dist' to validate the manifest"
elif [ "${OCX_SKIP_DIST:-0}" = "1" ]; then
    echo "publish-installers: OCX_SKIP_DIST=1 — leaving dist.json untouched"
else
    sh "$PUBLISH_DIST"
fi

echo "publish-installers: done"
