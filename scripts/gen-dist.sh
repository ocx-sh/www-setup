#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

# gen-dist.sh — emit the self-hosted distribution manifest (dist.json) from the
# OCX *product* repo's GitHub Releases API.
#
# dist.json is a Node-`dist`-style manifest: it lists every published OCX
# release × build target with an inline sha256 checksum and a download URL. The
# installers read it to (a) resolve the latest stable version and (b) resolve
# the (version,target) row -> sha256 + url for the download. There is NO
# separate sha256.sum fetch in the install path anymore; the checksum is inline.
#
# Source of truth: ocx-sh/ocx GitHub Releases API (NOT this repo's git tags).
# This repo's `v*` tags version the installer scripts only — decoupled.
#
# Key boundary: this generator runs in CI (where GITHUB_TOKEN is available) and
# MAY call the GitHub Releases API. That does NOT reintroduce a GitHub dependency
# into the install path: the installers stay tokenless and read the self-hosted
# dist.json this script produces.
#
# Output (stdout): a single JSON object. The two latest pointers and every
# `releases[]` element are FLAT objects (no nested braces) so the installers'
# jq-free parses are safe — POSIX `grep -o '{[^{}]*}'` and fish `string match -r`
# both extract each leaf object cleanly; nu/elvish use native JSON.
#
#   {
#     "schema": 1,
#     "latest": {"version":"0.5.0","channel":"stable"},
#     "latest_next": {"version":"0.6.0-rc.1","channel":"next"},
#     "releases": [
#       {"version":"0.5.0","channel":"stable","tag":"v0.5.0","target":"x86_64-unknown-linux-gnu","filename":"ocx-x86_64-unknown-linux-gnu.tar.gz","sha256":"abc…","url":"https://github.com/ocx-sh/ocx/releases/download/v0.5.0/ocx-x86_64-unknown-linux-gnu.tar.gz"},
#       …
#     ]
#   }
#
# - releases[] is newest-first by semver-aware order; within a release, targets
#   are sorted by target string for determinism.
# - Build targets are DERIVED from each release's sha256.sum (filenames
#   `ocx-<target>.<ext>`), never hardcoded. A full release carries 8 targets
#   (linux gnu+musl, darwin, windows × x86_64/aarch64).
# - `latest` is the newest stable release's {version,channel}; `latest_next` the
#   newest prerelease's. Either is `null` when that channel has no release.
# - Draft releases are skipped. Releases with no sha256.sum source are skipped
#   (warned) — they are not binary releases.
#
# Clobber-safety (load-bearing): any sha256.sum FETCH failure (a present asset
# URL that curl cannot retrieve, or a missing --checksums-dir file) -> exit 3,
# NEVER a partial manifest. An empty release list -> a valid empty manifest
# (`"releases": []`), distinguishable from a failure (which never prints JSON).
#
# Repo resolution (precedence): --repo <owner/repo> > OCX_RELEASES_REPO env >
# default ocx-sh/ocx.
#
# Auth: sends `Authorization: Bearer $GITHUB_TOKEN` only when GITHUB_TOKEN is
# non-empty (CI). Works unauthenticated otherwise (best-effort, may rate-limit).
#
# Testing hatches (offline / deterministic):
#   --releases-file <path>   read a raw GitHub-API releases JSON array from a
#                            file instead of the network.
#   --checksums-dir <dir>    read each release's checksums from
#                            <dir>/<tag>/sha256.sum instead of fetching the asset.
#
# Exit codes: 0 success; 2 unknown argument; 3 network / API / parse / fetch.

set -eu

DEFAULT_REPO="ocx-sh/ocx"
REPO=""
RELEASES_FILE=""
CHECKSUMS_DIR=""
PER_PAGE=100
USER_AGENT="setup.ocx.sh-gen-dist"

usage() {
    cat <<'EOF'
Usage: gen-dist.sh [--repo <owner/repo>] [--releases-file <path>]
                   [--checksums-dir <dir>]

Emit the distribution manifest (dist.json) to stdout, sourced from the OCX
product repo's GitHub Releases API, with an inline sha256 per release × target.

Options:
  --repo <owner/repo>      Source repo (default: $OCX_RELEASES_REPO or ocx-sh/ocx).
  --releases-file <path>   Read a raw GitHub-API releases JSON array from a file
                           instead of the network (testing hatch).
  --checksums-dir <dir>    Read each release's checksums from
                           <dir>/<tag>/sha256.sum instead of fetching the asset
                           (testing hatch).
  -h, --help               Show this help and exit.

Environment:
  OCX_RELEASES_REPO        Source repo when --repo is not given.
  GITHUB_TOKEN             When non-empty, used as a Bearer token for the API.

Exit codes: 0 success; 2 unknown argument; 3 network/API/parse/fetch failure.
EOF
}

err() {
    # err <message> [code]
    printf 'gen-dist: %s\n' "$1" >&2
    exit "${2:-1}"
}

warn() {
    printf 'gen-dist: %s\n' "$1" >&2
}

# --- argument parsing -------------------------------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo)
            [ "$#" -ge 2 ] || err "--repo requires an argument" 2
            REPO="$2"
            shift 2
            ;;
        --repo=*)
            REPO="${1#--repo=}"
            shift
            ;;
        --releases-file)
            [ "$#" -ge 2 ] || err "--releases-file requires an argument" 2
            RELEASES_FILE="$2"
            shift 2
            ;;
        --releases-file=*)
            RELEASES_FILE="${1#--releases-file=}"
            shift
            ;;
        --checksums-dir)
            [ "$#" -ge 2 ] || err "--checksums-dir requires an argument" 2
            CHECKSUMS_DIR="$2"
            shift 2
            ;;
        --checksums-dir=*)
            CHECKSUMS_DIR="${1#--checksums-dir=}"
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            err "unknown argument: $1" 2
            ;;
    esac
done

if [ -z "$REPO" ]; then
    REPO="${OCX_RELEASES_REPO:-$DEFAULT_REPO}"
fi

command -v python3 >/dev/null 2>&1 || err "python3 is required" 3

# --- acquire the raw GitHub-API releases JSON -------------------------------
API_JSON=""
if [ -n "$RELEASES_FILE" ]; then
    [ -f "$RELEASES_FILE" ] || err "--releases-file does not point to a file: $RELEASES_FILE" 3
    API_JSON=$(cat "$RELEASES_FILE") || err "failed to read $RELEASES_FILE" 3
else
    command -v curl >/dev/null 2>&1 || err "curl is required" 3
    API_URL="https://api.github.com/repos/${REPO}/releases?per_page=${PER_PAGE}"
    set -- \
        --silent --show-error --location \
        --proto "=https" \
        --max-time 30 \
        --retry 2 \
        --fail \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        --user-agent "${USER_AGENT}"
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        set -- "$@" -H "Authorization: Bearer ${GITHUB_TOKEN}"
    fi
    if API_JSON=$(curl "$@" "$API_URL" 2>&1); then
        :
    else
        rc=$?
        printf 'gen-dist: GitHub Releases API request failed (curl rc=%s) for %s\n' \
            "$rc" "$API_URL" >&2
        printf '%s\n' "$API_JSON" | head -5 >&2
        exit 3
    fi
fi

# --- plan: per non-draft release, emit "tag<TAB>channel<TAB>sha_url" ---------
# python parses the (nested) GitHub payload; we keep network in the shell. The
# sha_url is the browser_download_url of the asset named exactly "sha256.sum"
# (empty when absent).
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

printf '%s' "$API_JSON" | python3 -c '
import json, sys

raw = sys.stdin.read()
try:
    data = json.loads(raw)
except (ValueError, TypeError) as exc:
    sys.stderr.write("gen-dist: could not parse GitHub API response as JSON: %s\n" % exc)
    sys.exit(3)
if not isinstance(data, list):
    sys.stderr.write("gen-dist: expected a JSON array of releases, got %s\n" % type(data).__name__)
    sys.exit(3)

for rel in data:
    if not isinstance(rel, dict) or rel.get("draft") is True:
        continue
    tag = rel.get("tag_name")
    if not tag or not isinstance(tag, str):
        continue
    channel = "next" if rel.get("prerelease") is True else "stable"
    sha_url = ""
    for asset in (rel.get("assets") or []):
        if isinstance(asset, dict) and asset.get("name") == "sha256.sum":
            sha_url = asset.get("browser_download_url") or ""
            break
    # Tab-separated; tags/channels never contain tabs.
    sys.stdout.write("%s\t%s\t%s\n" % (tag, channel, sha_url))
' >"$WORKDIR/plan" || err "failed to parse the GitHub Releases API response" 3

# --- gather each release's sha256.sum into the work dir ---------------------
: >"$WORKDIR/meta"
TAB=$(printf '\t')

# Fetch one URL to stdout over enforced HTTPS (network mode only).
fetch_sha() {
    curl --silent --show-error --location --proto "=https" \
        --max-time 30 --retry 2 --fail --user-agent "${USER_AGENT}" "$1"
}

# Read the plan from a FILE (not a pipe) so this loop runs in the current shell:
# a fetch failure's `err` (exit 3) then aborts the whole script (clobber-safety),
# instead of dying in a masked pipe subshell and emitting a partial manifest.
# `meta` accumulates "tag<TAB>channel" for every release that contributed a
# checksum file at "$WORKDIR/<tag>.sha".
while IFS="$TAB" read -r tag channel sha_url; do
    [ -n "$tag" ] || continue
    if [ -n "$CHECKSUMS_DIR" ]; then
        sha_path="$CHECKSUMS_DIR/$tag/sha256.sum"
        if [ ! -f "$sha_path" ]; then
            warn "no checksums for $tag at $sha_path — skipping"
            continue
        fi
        cp "$sha_path" "$WORKDIR/$tag.sha" || err "failed to read $sha_path" 3
    else
        if [ -z "$sha_url" ]; then
            warn "release $tag has no sha256.sum asset — skipping"
            continue
        fi
        # Fetch failure of a PRESENT asset -> exit 3, no partial manifest.
        fetch_sha "$sha_url" >"$WORKDIR/$tag.sha" ||
            err "failed to fetch sha256.sum for $tag from $sha_url" 3
    fi
    if [ ! -s "$WORKDIR/$tag.sha" ]; then
        warn "empty sha256.sum for $tag — skipping"
        rm -f "$WORKDIR/$tag.sha"
        continue
    fi
    printf '%s\t%s\n' "$tag" "$channel" >>"$WORKDIR/meta"
done <"$WORKDIR/plan"

# --- build the manifest from meta + the gathered checksum files -------------
REPO_ENV="$REPO" python3 - "$WORKDIR" <<'PY' || err "failed to build dist.json" 3
import json, os, re, sys

workdir = sys.argv[1]
repo = os.environ["REPO_ENV"]
download_base = "https://github.com/%s/releases/download" % repo


def parse_version(v):
    core, _, pre = v.partition("-")
    core_parts = []
    for part in core.split("."):
        if part.isdigit():
            core_parts.append((1, int(part), ""))
        else:
            core_parts.append((0, 0, part))
    has_pre = 1 if pre == "" else 0
    pre_parts = []
    if pre:
        for part in pre.split("."):
            if part.isdigit():
                pre_parts.append((1, int(part), ""))
            else:
                pre_parts.append((0, 0, part))
    return (core_parts, has_pre, pre_parts)


meta_path = os.path.join(workdir, "meta")
releases_meta = []
if os.path.exists(meta_path):
    with open(meta_path) as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            tag, _, channel = line.partition("\t")
            releases_meta.append((tag, channel))

# Sort releases newest-first by semver-aware order of the version (tag minus v).
def rel_key(item):
    tag = item[0]
    version = tag[1:] if tag.startswith("v") else tag
    return parse_version(version)


releases_meta.sort(key=rel_key, reverse=True)

ASSET_RE = re.compile(r"^ocx-(?P<target>.+?)\.(?P<ext>tar\.xz|tar\.gz|zip)$")

releases = []
latest = None
latest_next = None

for tag, channel in releases_meta:
    version = tag[1:] if tag.startswith("v") else tag
    sha_path = os.path.join(workdir, "%s.sha" % tag)
    if not os.path.exists(sha_path):
        continue
    rows = []
    with open(sha_path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            # "<hash>  <filename>" (one or more spaces; optional binary "*").
            m = re.match(r"^([0-9a-fA-F]{64})\s+\*?(.+)$", line)
            if not m:
                continue
            sha = m.group(1).lower()
            filename = m.group(2).strip()
            am = ASSET_RE.match(filename)
            if not am:
                continue  # not an ocx-<target> binary archive (e.g. installer scripts)
            target = am.group("target")
            url = "%s/%s/%s" % (download_base, tag, filename)
            rows.append({
                "version": version,
                "channel": channel,
                "tag": tag,
                "target": target,
                "filename": filename,
                "sha256": sha,
                "url": url,
            })
    if not rows:
        continue
    rows.sort(key=lambda r: r["target"])
    releases.extend(rows)
    if channel == "stable" and latest is None:
        latest = {"version": version, "channel": "stable"}
    if channel == "next" and latest_next is None:
        latest_next = {"version": version, "channel": "next"}


def flat_obj(d, keys):
    parts = []
    for k in keys:
        parts.append("%s:%s" % (json.dumps(k), json.dumps(d[k])))
    obj = "{" + ",".join(parts) + "}"
    # A flat object must contain exactly one '{' and one '}'.
    if re.findall(r"[{}]", obj) != ["{", "}"]:
        sys.stderr.write("gen-dist: refusing to emit non-flat object: %s\n" % obj)
        sys.exit(3)
    return obj


out = []
out.append("{")
out.append('  "schema": 1,')
out.append('  "latest": %s,' % (flat_obj(latest, ["version", "channel"]) if latest else "null"))
out.append('  "latest_next": %s,' % (flat_obj(latest_next, ["version", "channel"]) if latest_next else "null"))
if releases:
    out.append('  "releases": [')
    rel_keys = ["version", "channel", "tag", "target", "filename", "sha256", "url"]
    lines = ["    " + flat_obj(r, rel_keys) for r in releases]
    out.append(",\n".join(lines))
    out.append("  ]")
else:
    out.append('  "releases": []')
out.append("}")
sys.stdout.write("\n".join(out) + "\n")
PY
