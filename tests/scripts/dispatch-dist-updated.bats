#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
# Kind: TOOL (bats suite for scripts/dispatch-dist-updated.sh)
#
# A stub curl first on PATH records argv, stdin and the -d body, so the suite
# proves the payload contract, where the token travels, and the warn-only policy.

load ../install/helpers/load
bats_require_minimum_version 1.5.0

SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/dispatch-dist-updated.sh"
TOKEN="ghp_tokentokentoken0123456789"

setup() {
    STUB_DIR="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "$STUB_DIR"
    cat >"${STUB_DIR}/curl" <<'STUB'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a" >>"${STUB_LOG}.argv"; done
cat >>"${STUB_LOG}.stdin"
exit "${STUB_RC:-0}"
STUB
    chmod +x "${STUB_DIR}/curl"
    export STUB_LOG="${BATS_TEST_TMPDIR}/log"
    export PATH="${STUB_DIR}:${PATH}"
    touch "${STUB_LOG}.stdin" "${STUB_LOG}.argv"
    DIST="${BATS_TEST_TMPDIR}/dist.json"
    printf '{"schema":1,"latest":{"version":"0.7.0","channel":"stable"},"releases":[]}\n' >"$DIST"
    export DIST_RECEIVERS="ocx-sh/devcontainer-features ocx-sh/find_ocx"
    export OCX_ANNOUNCE_TOKEN="$TOKEN"
}

@test "payload carries version, sha256 and snapshot url to every receiver" {
    run --separate-stderr sh "$SCRIPT" "$DIST"
    assert_success
    sha=$(sha256sum "$DIST" | awk '{print $1}')
    run grep -F "{\"event_type\":\"dist-updated\",\"client_payload\":{\"version\":\"0.7.0\",\"sha256\":\"${sha}\",\"url\":\"https://setup.ocx.sh/dist/${sha}.json\"}}" "${STUB_LOG}.argv"
    assert_success
    run grep -c 'repos/.*/dispatches' "${STUB_LOG}.argv"
    assert_output 2
    run grep -F 'repos/ocx-sh/find_ocx/dispatches' "${STUB_LOG}.argv"
    assert_success
}

@test "token reaches curl on stdin, never on argv" {
    run --separate-stderr sh "$SCRIPT" "$DIST"
    assert_success
    run grep -F "$TOKEN" "${STUB_LOG}.argv"
    [ "$status" -eq 1 ]
    run grep -F "Authorization: Bearer ${TOKEN}" "${STUB_LOG}.stdin"
    assert_success
}

@test "missing token warns, sends nothing, exits 0" {
    unset OCX_ANNOUNCE_TOKEN
    run --separate-stderr sh "$SCRIPT" "$DIST"
    assert_success
    assert_output --partial "::warning::OCX_ANNOUNCE_TOKEN is not available"
    [ ! -s "${STUB_LOG}.argv" ]
}

@test "a failing dispatch warns and still exits 0" {
    STUB_RC=22 run --separate-stderr sh "$SCRIPT" "$DIST"
    assert_success
    assert_output --partial "::warning::dist-updated dispatch to ocx-sh/devcontainer-features failed"
}

@test "manifest without a stable version warns and sends nothing" {
    printf '{"schema":1,"latest":null,"releases":[]}\n' >"$DIST"
    run --separate-stderr sh "$SCRIPT" "$DIST"
    assert_success
    assert_output --partial "::warning::dist.json has no latest stable version"
    [ ! -s "${STUB_LOG}.argv" ]
}

@test "missing argument is a usage error" {
    run --separate-stderr sh "$SCRIPT"
    [ "$status" -eq 2 ]
}
