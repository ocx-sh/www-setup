#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
# Kind: TOOL (bats suite for the signal handling of the dist scripts)
#
# A stub curl serves one release and stalls on the sha256.sum fetch. TERM sent
# during that stall must end the run with 143 and remove the temp directory;
# a returning cleanup trap would remove it and carry on instead.

load ../install/helpers/load
bats_require_minimum_version 1.5.0

GEN="${BATS_TEST_DIRNAME}/../../scripts/gen-dist.sh"
PUB="${BATS_TEST_DIRNAME}/../../scripts/publish-dist.sh"

setup() {
    STUB_DIR="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "$STUB_DIR" "${BATS_TEST_TMPDIR}/tmp"
    cat >"${STUB_DIR}/curl" <<'STUB'
#!/bin/sh
cat >/dev/null
case " $* " in
  *sha256.sum*) : >"${STUB_STARTED}"; sleep 2; printf '%s  ocx-x86_64-unknown-linux-gnu.tar.xz\n' "$(printf 'a%.0s' $(seq 64))" ;;
  *) printf '[{"tag_name":"v1.0.0","prerelease":false,"assets":[{"name":"sha256.sum","browser_download_url":"https://example.invalid/sha256.sum"}]}]' ;;
esac
STUB
    chmod +x "${STUB_DIR}/curl"
    export PATH="${STUB_DIR}:${PATH}"
    export STUB_STARTED="${BATS_TEST_TMPDIR}/started"
    export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    export DRY_RUN=1 GEN_ATTEMPTS=1
}

# term_during_fetch SCRIPT -- start SCRIPT, TERM it once the sha fetch stalls.
term_during_fetch() {
    sh "$1" >/dev/null 2>&1 </dev/null &
    pid=$!
    n=0
    while [ ! -e "$STUB_STARTED" ] && [ "$n" -lt 100 ]; do
        sleep 0.1
        n=$((n + 1))
    done
    [ -e "$STUB_STARTED" ]
    kill -TERM "$pid"
    rc=0
    wait "$pid" || rc=$?
}

@test "gen-dist exits 143 on TERM and removes its work directory" {
    term_during_fetch "$GEN"
    [ "$rc" -eq 143 ]
    [ -z "$(ls -A "$TMPDIR")" ]
}

@test "publish-dist exits 143 on TERM and removes its stage directory" {
    term_during_fetch "$PUB"
    [ "$rc" -eq 143 ]
    [ -z "$(ls -A "$TMPDIR")" ]
}
