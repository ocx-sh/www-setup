#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
# Kind: TOOL (bats suite for the GitHub token handling of scripts/gen-dist.sh)
#
# A stub curl first on PATH answers the Releases API call with an empty list and
# records argv and stdin, so the suite proves where GITHUB_TOKEN travels.

load ../install/helpers/load
bats_require_minimum_version 1.5.0

GEN="${BATS_TEST_DIRNAME}/../../scripts/gen-dist.sh"
TOKEN="ghs_tokentokentoken0123456789"

setup() {
    STUB_DIR="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "$STUB_DIR"
    cat >"${STUB_DIR}/curl" <<'STUB'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a" >>"${STUB_LOG}.argv"; done
cat >>"${STUB_LOG}.stdin"
printf '[]'
STUB
    chmod +x "${STUB_DIR}/curl"
    export STUB_LOG="${BATS_TEST_TMPDIR}/log"
    export PATH="${STUB_DIR}:${PATH}"
    touch "${STUB_LOG}.stdin"
}

@test "GITHUB_TOKEN reaches curl on stdin, never on argv" {
    GITHUB_TOKEN="$TOKEN" run --separate-stderr sh "$GEN" </dev/null
    assert_success
    run grep -F "$TOKEN" "${STUB_LOG}.argv"
    [ "$status" -eq 1 ]
    run grep -F "Authorization: Bearer ${TOKEN}" "${STUB_LOG}.stdin"
    assert_success
}

@test "without GITHUB_TOKEN no Authorization header is sent" {
    unset GITHUB_TOKEN
    run --separate-stderr sh "$GEN" </dev/null
    assert_success
    run grep -c -i 'authorization' "${STUB_LOG}.argv" "${STUB_LOG}.stdin"
    assert_output --partial "argv:0"
    assert_output --partial "stdin:0"
}
