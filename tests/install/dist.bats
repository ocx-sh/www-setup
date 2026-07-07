#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
#
# Coverage for scripts/gen-dist.sh (the dist.json manifest generator).
#
# The generator sources releases from the ocx-sh/ocx GitHub Releases API and
# inlines a per-target sha256 from each release's sha256.sum asset. These tests
# drive its offline hatches `--releases-file <path>` (a raw GitHub-Releases-API
# JSON array) and `--checksums-dir <dir>` (<dir>/<tag>/sha256.sum), so no
# network is exercised.
#
# Asserted contract:
#   - stdout is valid JSON (python3 json.load).
#   - flat leaf objects (no nested braces) so the installers' grep/string-match
#     parse is safe; targets DERIVED from sha256.sum (8 for a full release).
#   - inline sha256 + url per (version,target) row; newest-first ordering.
#   - latest / latest_next top-level pointers per channel.
#   - draft releases and releases without a sha256.sum are skipped.
#   - empty array `[]` input -> a valid empty manifest (releases == []).
#   - unknown argument -> exit 2.

bats_require_minimum_version 1.5.0

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/gen-dist.sh"

setup() {
    RELEASES="${BATS_TEST_TMPDIR}/releases.json"
    EMPTY="${BATS_TEST_TMPDIR}/empty.json"
    CKS="${BATS_TEST_TMPDIR}/cks"

    cat >"$RELEASES" <<'JSON'
[
  {"tag_name":"v0.6.0-rc.1","prerelease":true,"draft":false,
   "assets":[{"name":"sha256.sum","browser_download_url":"https://example/sha"}]},
  {"tag_name":"v0.10.0","prerelease":false,"draft":false,
   "assets":[{"name":"sha256.sum","browser_download_url":"https://example/sha"}]},
  {"tag_name":"v0.9.0","prerelease":false,"draft":false,
   "assets":[{"name":"sha256.sum","browser_download_url":"https://example/sha"}]},
  {"tag_name":"v0.11.0","prerelease":false,"draft":true,
   "assets":[{"name":"sha256.sum","browser_download_url":"https://example/sha"}]},
  {"tag_name":"v0.5.0","prerelease":false,"draft":false,
   "assets":[]}
]
JSON

    printf '[]\n' >"$EMPTY"

    # 8-target full release for 0.10.0; a single target for the others.
    mkdir -p "$CKS/v0.10.0" "$CKS/v0.9.0" "$CKS/v0.6.0-rc.1"
    # Mixed extensions on one release: the .tar.gz rows exercise the current
    # release format, the .tar.xz rows prove gen-dist still parses pre-switch
    # (<= 0.4.x) assets. gen-dist's ASSET_RE accepts tar.gz|tar.xz|zip.
    cat >"$CKS/v0.10.0/sha256.sum" <<'SUM'
1111111111111111111111111111111111111111111111111111111111111111  ocx-x86_64-unknown-linux-gnu.tar.gz
2222222222222222222222222222222222222222222222222222222222222222  ocx-aarch64-unknown-linux-gnu.tar.xz
3333333333333333333333333333333333333333333333333333333333333333  ocx-x86_64-unknown-linux-musl.tar.xz
4444444444444444444444444444444444444444444444444444444444444444  ocx-aarch64-unknown-linux-musl.tar.xz
5555555555555555555555555555555555555555555555555555555555555555  ocx-x86_64-apple-darwin.tar.xz
6666666666666666666666666666666666666666666666666666666666666666  ocx-aarch64-apple-darwin.tar.xz
7777777777777777777777777777777777777777777777777777777777777777  ocx-x86_64-pc-windows-msvc.zip
8888888888888888888888888888888888888888888888888888888888888888  ocx-aarch64-pc-windows-msvc.zip
deadbeefdeadbeef  ocx-installer.sh
SUM
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  ocx-x86_64-unknown-linux-gnu.tar.xz\n' >"$CKS/v0.9.0/sha256.sum"
    printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  ocx-x86_64-unknown-linux-gnu.tar.xz\n' >"$CKS/v0.6.0-rc.1/sha256.sum"
}

run_gen() {
    # --separate-stderr so $output is the manifest only (the generator logs
    # "skipping" warnings to stderr, which would otherwise corrupt $output).
    run --separate-stderr "$SCRIPT" --releases-file "$RELEASES" --checksums-dir "$CKS"
}

@test "emits valid JSON" {
    run_gen
    [ "$status" -eq 0 ]
    run python3 -c 'import json,sys; json.load(sys.stdin)' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "schema, latest + latest_next pointers" {
    run_gen
    [ "$status" -eq 0 ]
    run python3 - "$output" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d["schema"] == 1, d["schema"]
assert d["latest"] == {"version": "0.10.0", "channel": "stable"}, d["latest"]
assert d["latest_next"] == {"version": "0.6.0-rc.1", "channel": "next"}, d["latest_next"]
PY
    [ "$status" -eq 0 ]
}

@test "8 targets derived from sha256.sum for the full release" {
    run_gen
    [ "$status" -eq 0 ]
    run python3 - "$output" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
targets = sorted(r["target"] for r in d["releases"] if r["version"] == "0.10.0")
assert len(targets) == 8, targets
assert "x86_64-unknown-linux-musl" in targets, targets
assert "aarch64-pc-windows-msvc" in targets, targets
# The non-ocx-<target> asset (ocx-installer.sh) is NOT a row.
assert all("installer" not in t for t in targets), targets
PY
    [ "$status" -eq 0 ]
}

@test "inline sha256 + url per row" {
    run_gen
    [ "$status" -eq 0 ]
    run python3 - "$output" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
row = next(r for r in d["releases"]
           if r["version"] == "0.10.0" and r["target"] == "x86_64-unknown-linux-gnu")
assert row["sha256"] == "1" * 64, row["sha256"]
assert row["filename"] == "ocx-x86_64-unknown-linux-gnu.tar.gz", row
assert row["tag"] == "v0.10.0", row
assert row["url"] == ("https://github.com/ocx-sh/ocx/releases/download/"
                      "v0.10.0/ocx-x86_64-unknown-linux-gnu.tar.gz"), row["url"]
PY
    [ "$status" -eq 0 ]
}

@test "newest-first ordering: 0.10.0 before 0.9.0" {
    run_gen
    [ "$status" -eq 0 ]
    run python3 - "$output" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
versions = [r["version"] for r in d["releases"]]
# First row is the newest stable.
assert versions[0] == "0.6.0-rc.1" or versions[0] == "0.10.0", versions[:3]
assert versions.index("0.10.0") < versions.index("0.9.0"), versions
PY
    [ "$status" -eq 0 ]
}

@test "flat leaf objects: no nested braces (installer grep-safe)" {
    run_gen
    [ "$status" -eq 0 ]
    run python3 - "$output" <<'PY'
import sys
for line in sys.argv[1].splitlines():
    s = line.strip().rstrip(",")
    if not s.startswith("{") or not s.endswith("}"):
        continue
    inner = s[1:-1]
    assert "{" not in inner and "}" not in inner, line
PY
    [ "$status" -eq 0 ]
}

@test "draft release and no-asset release are skipped" {
    run_gen
    [ "$status" -eq 0 ]
    [[ "$output" != *"0.11.0"* ]]
    run python3 - "$output" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
versions = {r["version"] for r in d["releases"]}
assert "0.11.0" not in versions, versions   # draft
assert "0.5.0" not in versions, versions     # no sha256.sum asset
PY
    [ "$status" -eq 0 ]
}

@test "empty array input yields a valid empty manifest" {
    run "$SCRIPT" --releases-file "$EMPTY" --checksums-dir "$CKS"
    [ "$status" -eq 0 ]
    run python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["releases"]==[] and d["latest"] is None, d' <<<"$output"
    [ "$status" -eq 0 ]
}

@test "unknown argument exits 2" {
    run "$SCRIPT" --bogus-flag
    [ "$status" -eq 2 ]
}
