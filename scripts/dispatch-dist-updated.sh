#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

# Kind: CI (POSIX sh: runs on dash and busybox ash)
# Exit: 0 always once the arguments are valid (a failed dispatch only warns), 2 usage

# dispatch-dist-updated.sh <dist.json> -- tell the receiver repos that a new
# dist.json is live. Sends a `dist-updated` repository_dispatch to each repo in
# DIST_RECEIVERS (space-separated owner/repo) with
#
#   {"version": "<latest stable ocx version>", "sha256": "<sha256 of dist.json>",
#    "url": "https://setup.ocx.sh/dist/<sha256>.json"}
#
# The dispatch is an accelerator (receivers also poll hourly), so it must never
# fail the publish: every problem is a ::warning:: and the exit stays 0. The
# token travels on curl's stdin as a header file, never on argv.
#
# Required env: DIST_RECEIVERS. Optional env: OCX_ANNOUNCE_TOKEN (absent -> warn
# and skip), DIST_BASE_URL (default https://setup.ocx.sh), GITHUB_API_URL.

set -eu

[ "$#" -eq 1 ] && [ -f "$1" ] || {
    echo "usage: dispatch-dist-updated.sh <dist.json>" >&2
    exit 2
}
DIST="$1"

if [ -z "${OCX_ANNOUNCE_TOKEN:-}" ]; then
    echo "::warning::OCX_ANNOUNCE_TOKEN is not available; skipping dist-updated dispatch"
    exit 0
fi

if command -v sha256sum >/dev/null 2>&1; then
    sha=$(sha256sum "$DIST" | awk '{print $1}')
else
    sha=$(shasum -a 256 "$DIST" | awk '{print $1}')
fi
version=$(jq -r '.latest.version // empty' "$DIST") || version=
if [ -z "$sha" ] || [ -z "$version" ]; then
    echo "::warning::dist.json has no latest stable version or no digest; skipping dist-updated dispatch"
    exit 0
fi

body=$(jq -nc --arg v "$version" --arg s "$sha" --arg u "${DIST_BASE_URL:-https://setup.ocx.sh}/dist/${sha}.json" \
    '{event_type: "dist-updated", client_payload: {version: $v, sha256: $s, url: $u}}')

for repo in ${DIST_RECEIVERS:-}; do
    if printf 'Authorization: Bearer %s\n' "$OCX_ANNOUNCE_TOKEN" | curl --silent --show-error --fail-with-body \
        --retry 3 --connect-timeout 10 --max-time 60 \
        -X POST -H @- \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        -d "$body" \
        "${GITHUB_API_URL:-https://api.github.com}/repos/${repo}/dispatches"; then
        echo "dispatch-dist-updated: notified $repo ($version, $sha)"
    else
        echo "::warning::dist-updated dispatch to $repo failed; the receiver's hourly poll covers it"
    fi
done
exit 0
