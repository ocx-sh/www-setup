# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

# shellcheck shell=sh
# Kind: LIB (sourced by the publish scripts; POSIX sh, no options set here)

# bunny.sh -- the upload transport for setup.ocx.sh (Bunny Edge Storage).
#
# Plain curl against the Edge Storage HTTP API. No CLI, no node, no npm:
#
#   PUT    https://<host>/<zone>/<path>     AccessKey: <storage zone password>
#   GET    https://<host>/<zone>/<path>     (existence probe)
#
# Uploads carry a `Checksum` header (SHA256, HEX, UPPERCASE) so Bunny verifies
# the body server-side and rejects a truncated transfer with 400 -- the integrity
# check the old rsync transport got for free.
#
# NOTE: Edge Storage is DIRECTORY-backed, not a flat keyspace. A path cannot be
# both a file and a directory, so `sh` and `sh/next` can never coexist as stored
# objects. The friendly per-shell URLs are therefore served by Edge Rules
# rewriting onto the stored layout -- see deploy/bunny/README.md. Do not try to
# publish an object at a friendly URL; it will collide.
#
# Auth: BUNNY_STORAGE_KEY, or BUNNY_STORAGE_KEY_FILE pointing at a file holding
# it (keeps the key out of shell history). Either way the key reaches curl on
# stdin as a header file (-H @-), never on argv where `ps` would show it.
#
# Required env: BUNNY_STORAGE_ZONE, and one of BUNNY_STORAGE_KEY{,_FILE}.
# Optional env: BUNNY_STORAGE_HOST (default storage.bunnycdn.com = Frankfurt),
#               DRY_RUN.

# Region hostnames (the zone's region is fixed at creation):
#   storage.bunnycdn.com      Frankfurt, DE   (default)
#   uk.storage.bunnycdn.com   London, UK
#   ny.storage.bunnycdn.com   New York, US
#   la.storage.bunnycdn.com   Los Angeles, US
#   se.storage.bunnycdn.com   Stockholm, SE
#   sg.storage.bunnycdn.com   Singapore, SG
#   syd.storage.bunnycdn.com  Sydney, AU
#   br.storage.bunnycdn.com   Sao Paulo, BR
#   jh.storage.bunnycdn.com   Johannesburg, SA
BUNNY_STORAGE_HOST="${BUNNY_STORAGE_HOST:-storage.bunnycdn.com}"

# bn_require_auth -- fail fast and loudly before any upload is attempted.
bn_require_auth() {
    [ "${DRY_RUN:-0}" = "1" ] && return 0
    : "${BUNNY_STORAGE_ZONE:?BUNNY_STORAGE_ZONE is required}"

    if [ -n "${BUNNY_STORAGE_KEY_FILE:-}" ]; then
        [ -r "$BUNNY_STORAGE_KEY_FILE" ] || {
            echo "bunny: BUNNY_STORAGE_KEY_FILE ($BUNNY_STORAGE_KEY_FILE) is not readable" >&2
            exit 2
        }
        # Strip a trailing newline; a stray one becomes part of the header value
        # and every request 401s with no useful diagnostic.
        BUNNY_STORAGE_KEY=$(tr -d '\r\n' <"$BUNNY_STORAGE_KEY_FILE")
    fi

    : "${BUNNY_STORAGE_KEY:?BUNNY_STORAGE_KEY (or BUNNY_STORAGE_KEY_FILE) is required}"
}

# bn_sha256_upper FILE -- SHA256 as UPPERCASE hex, the format Bunny's Checksum
# header requires. macOS ships shasum, not sha256sum.
bn_sha256_upper() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print toupper($1)}'
    else
        shasum -a 256 "$1" | awk '{print toupper($1)}'
    fi
}

# bn_auth_header -- the AccessKey header as a curl header file for `-H @-`.
# On argv the key would sit in /proc/PID/cmdline, readable by every local user.
bn_auth_header() {
    printf 'AccessKey: %s\n' "$BUNNY_STORAGE_KEY"
}

# bn_exists KEY -- 0 if present (200), 1 if absent (404), exit 3 on anything else.
# A 5xx, 401 or timeout read as "absent" would let bn_put_new overwrite an
# immutable object, so only an explicit 404 counts as absent.
bn_exists() {
    _code=$(bn_auth_header | curl -sS -o /dev/null -w '%{http_code}' \
        --connect-timeout 10 --max-time 60 -H @- \
        "https://${BUNNY_STORAGE_HOST}/${BUNNY_STORAGE_ZONE}/$1") || {
        echo "bunny: existence probe of $1 failed (curl rc=$?)" >&2
        exit 3
    }
    case "$_code" in
        200) return 0 ;;
        404) return 1 ;;
        *)
            echo "bunny: existence probe of $1 returned HTTP $_code, refusing to guess" >&2
            exit 3
            ;;
    esac
}

# bn_put KEY FILE -- upload, overwriting. Used for the mutable pointers and the
# rolling dist.json. Parent directories are created implicitly by the API.
bn_put() {
    [ "${DRY_RUN:-0}" = "1" ] && return 0
    _sum=$(bn_sha256_upper "$2")
    # --fail so a 4xx is a non-zero exit and `set -e` aborts the publish rather
    # than reporting success on a rejected upload.
    bn_auth_header | curl -fsS -X PUT \
        --connect-timeout 10 --max-time 300 \
        -H @- \
        -H "Checksum: ${_sum}" \
        --data-binary "@$2" \
        "https://${BUNNY_STORAGE_HOST}/${BUNNY_STORAGE_ZONE}/$1" >/dev/null
}

# bn_put_new KEY FILE -- upload only when KEY is absent. The append-only
# guarantee for archive/ and dist/<sha256>.json: a re-run of a release tag must
# never silently rewrite a published artifact.
#
# ponytail: GET-then-PUT. The Storage API has no conditional-write header, and
# the publish pipeline is single-writer (one release job; a `dist-manifest`
# concurrency group on the cron), so the TOCTOU window is not reachable.
bn_put_new() {
    [ "${DRY_RUN:-0}" = "1" ] && return 0
    if bn_exists "$1"; then
        echo "bunny: $1 already published -- leaving it untouched" >&2
        return 0
    fi
    bn_put "$1" "$2"
}
