#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
# Kind: TOOL (bats suite for scripts/lib/bunny.sh; bash 3.2-safe)
#
# bunny.sh talks to Bunny Edge Storage with curl. A stub curl first on PATH
# records argv and stdin and answers the existence probe with $STUB_CODE like
# the real curl does: with -f / --fail a 4xx or 5xx exits 22 and prints nothing,
# without it the code is printed and the exit is 0. STUB_RC forces an exit status
# (28 = timeout). The suite needs no network and no credentials.

load ../install/helpers/load

LIB="${BATS_TEST_DIRNAME}/../../scripts/lib/bunny.sh"
KEY="s3cret-storage-key-0123456789"

setup() {
    STUB_DIR="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "$STUB_DIR"
    cat >"${STUB_DIR}/curl" <<'STUB'
#!/bin/sh
# argv, one word per line, appended per call; stdin kept for header-file reads.
for a in "$@"; do printf '%s\n' "$a" >>"${STUB_LOG}.argv"; done
printf -- '--call--\n' >>"${STUB_LOG}.argv"
cat >>"${STUB_LOG}.stdin"
case " $* " in
  *" PUT "*) printf 'PUT\n' >>"${STUB_LOG}.puts"; exit 0 ;;
esac
[ "${STUB_RC:-0}" -eq 0 ] || exit "$STUB_RC"
for a in "$@"; do
  case "$a" in
    --fail) [ "${STUB_CODE:-200}" -lt 400 ] || exit 22 ;;
    --*) ;;
    -*f*) [ "${STUB_CODE:-200}" -lt 400 ] || exit 22 ;;
  esac
done
printf '%s' "${STUB_CODE:-200}"
STUB
    chmod +x "${STUB_DIR}/curl"
    export STUB_LOG="${BATS_TEST_TMPDIR}/log"
    export PATH="${STUB_DIR}:${PATH}"
    export BUNNY_STORAGE_KEY="$KEY" BUNNY_STORAGE_ZONE=zone
    unset DRY_RUN STUB_RC
    printf 'payload' >"${BATS_TEST_TMPDIR}/obj"
}

put_new() { run sh -c '. "$1"; bn_put_new archive/1.0.0/install.sh "$2"' _ "$LIB" "${BATS_TEST_TMPDIR}/obj"; }

puts() { if [ -f "${STUB_LOG}.puts" ]; then wc -l <"${STUB_LOG}.puts" | tr -d ' '; else echo 0; fi; }

@test "bn_put_new uploads when the probe answers 404" {
    STUB_CODE=404 put_new
    assert_success
    [ "$(puts)" = 1 ]
}

@test "bn_put_new refuses to overwrite when the probe answers 403 (a -f curl exits 22)" {
    STUB_CODE=403 put_new
    [ "$(puts)" = 0 ]
    [ "$status" -eq 3 ]
}

@test "bn_put_new leaves an object the probe answers 200 for untouched" {
    STUB_CODE=200 put_new
    assert_success
    assert_output --partial "already published"
    [ "$(puts)" = 0 ]
}

@test "bn_put_new refuses to overwrite when the probe answers 500" {
    STUB_CODE=500 put_new
    [ "$(puts)" = 0 ]
    [ "$status" -eq 3 ]
    assert_output --partial "HTTP 500"
}

@test "bn_put_new refuses to overwrite when the probe answers 401" {
    STUB_CODE=401 put_new
    [ "$(puts)" = 0 ]
    [ "$status" -eq 3 ]
}

@test "bn_put_new refuses to overwrite when curl itself fails (timeout rc 28)" {
    STUB_RC=28 put_new
    [ "$(puts)" = 0 ]
    [ "$status" -eq 3 ]
    assert_output --partial "curl rc=28"
}

@test "the storage key never appears on curl argv, only on stdin" {
    STUB_CODE=404 put_new
    assert_success
    # Neither call (probe, PUT) carried the key in its arguments; checked before
    # the call count so a leak is reported as a leak.
    run grep -F "$KEY" "${STUB_LOG}.argv"
    [ "$status" -eq 1 ]
    [ "$(grep -c -e '--call--' "${STUB_LOG}.argv")" -eq 2 ]
    # The header still reached curl, as a header file on stdin.
    run grep -F "AccessKey: ${KEY}" "${STUB_LOG}.stdin"
    assert_success
}

@test "the upload keeps the Checksum header and a PUT" {
    STUB_CODE=404 put_new
    assert_success
    run grep -c '^Checksum: [0-9A-F]\{64\}$' "${STUB_LOG}.argv"
    assert_output 1
}
