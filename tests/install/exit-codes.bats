#!/usr/bin/env bats
# Focused coverage for exit codes 5 (archive extract), 6 ('ocx self setup'),
# and 3 (manifest fetch). Exit codes 2, 3 (no row), 4 are covered by
# env-knobs.bats. Exit code 7 (unsupported platform) is exercised by
# tests/docker/.

load helpers/server

INSTALL_SH="${BATS_TEST_DIRNAME}/../../src/install.sh"

setup_file() {
    export FIXTURE_DIR="${BATS_FILE_TMPDIR}/srv"
    FIXTURE_TARGET=$(server_build_fixture "$FIXTURE_DIR")
    export FIXTURE_TARGET
    local _info
    _info=$(server_start "$FIXTURE_DIR" "${BATS_FILE_TMPDIR}/server.log")
    export FIXTURE_PID="${_info% *}"
    export FIXTURE_PORT="${_info#* }"
    export FIXTURE_URL="https://127.0.0.1:${FIXTURE_PORT}"
}

teardown_file() {
    server_stop "${FIXTURE_PID:-}"
}

setup() {
    export OCX_HOME="${BATS_TEST_TMPDIR}/.ocx"
    export OCX_NO_MODIFY_PATH=1
    export CURL_CA_BUNDLE
    CURL_CA_BUNDLE="$(server_ca_bundle)"
    export OCX_STUB_ARGV="${BATS_TEST_TMPDIR}/stub-argv.log"
    export OCX_INSTALL_DIST_URL="${FIXTURE_URL}/dist.json"
    export OCX_INSTALL_MIRROR_URL="${FIXTURE_URL}/releases/download"
    unset GITHUB_PATH OCX_INSTALL_NO_SETUP OCX_INSTALL_VERSION
    unset __OCX_TESTING_INSTALL_BINARY
}

@test "exit 5: corrupt archive (bad xz) fails to extract" {
    local _t="${BATS_TEST_TMPDIR}/extract"
    server_build_fixture "$_t" >/dev/null
    local _file="ocx-${FIXTURE_TARGET}.tar.xz"
    # Replace the archive with garbage; recompute the sha so checksum PASSES and
    # the EXTRACTION path is the one that fails.
    printf 'not a real xz archive\n' >"$_t/releases/download/v0.0.0/${_file}"
    local _sum
    _sum=$(server_sha256 "$_t/releases/download/v0.0.0/${_file}")
    server_write_dist "$_t" "$FIXTURE_TARGET" "$_sum" "$_file"
    local _info _pid _port
    _info=$(server_start "$_t" "${BATS_TEST_TMPDIR}/e.log")
    _pid="${_info% *}"
    _port="${_info#* }"
    OCX_INSTALL_DIST_URL="https://127.0.0.1:${_port}/dist.json" \
        OCX_INSTALL_MIRROR_URL="https://127.0.0.1:${_port}/releases/download" \
        run sh "$INSTALL_SH" --version 0.0.0
    server_stop "$_pid"
    [ "$status" -eq 5 ]
}

@test "exit 5: archive missing ocx binary" {
    local _t="${BATS_TEST_TMPDIR}/missing"
    mkdir -p "$_t/releases/download/v0.0.0"
    local _empty="${BATS_TEST_TMPDIR}/empty-bundle"
    mkdir -p "$_empty/ocx-${FIXTURE_TARGET}"
    printf 'README\n' >"$_empty/ocx-${FIXTURE_TARGET}/README.txt"
    local _file="ocx-${FIXTURE_TARGET}.tar.xz"
    (cd "$_empty" && tar cJf "$_t/releases/download/v0.0.0/${_file}" "ocx-${FIXTURE_TARGET}")
    local _sum
    _sum=$(server_sha256 "$_t/releases/download/v0.0.0/${_file}")
    server_write_dist "$_t" "$FIXTURE_TARGET" "$_sum" "$_file"
    local _info _pid _port
    _info=$(server_start "$_t" "${BATS_TEST_TMPDIR}/m.log")
    _pid="${_info% *}"
    _port="${_info#* }"
    OCX_INSTALL_DIST_URL="https://127.0.0.1:${_port}/dist.json" \
        OCX_INSTALL_MIRROR_URL="https://127.0.0.1:${_port}/releases/download" \
        run sh "$INSTALL_SH" --version 0.0.0
    server_stop "$_pid"
    [ "$status" -eq 5 ]
}

@test "exit 6: 'ocx self setup' failure (asserts the corrected hand-off argv)" {
    local _bs="${BATS_TEST_TMPDIR}/bsfail"
    mkdir -p "$_bs/releases/download/v0.0.0"
    local _build="${BATS_TEST_TMPDIR}/build-bsfail/ocx-${FIXTURE_TARGET}"
    mkdir -p "$_build"
    cat >"$_build/ocx" <<'STUB'
#!/bin/sh
# Fixture ocx stub that records argv then FAILS `self setup`.
if [ -n "${OCX_STUB_ARGV:-}" ]; then
    printf '%s\n' "$*" >>"$OCX_STUB_ARGV"
fi
case "$1" in
    version) echo "0.0.0" ;;
    self) [ "$2" = "setup" ] && { echo "stub self setup failure" >&2; exit 9; }; echo "stub ocx" ;;
    *) echo "stub ocx" ;;
esac
STUB
    chmod +x "$_build/ocx"
    local _file="ocx-${FIXTURE_TARGET}.tar.xz"
    (cd "${BATS_TEST_TMPDIR}/build-bsfail" && tar cJf "$_bs/releases/download/v0.0.0/${_file}" "ocx-${FIXTURE_TARGET}")
    local _sum
    _sum=$(server_sha256 "$_bs/releases/download/v0.0.0/${_file}")
    server_write_dist "$_bs" "$FIXTURE_TARGET" "$_sum" "$_file"
    local _info _pid _port
    _info=$(server_start "$_bs" "${BATS_TEST_TMPDIR}/bs.log")
    _pid="${_info% *}"
    _port="${_info#* }"
    OCX_INSTALL_DIST_URL="https://127.0.0.1:${_port}/dist.json" \
        OCX_INSTALL_MIRROR_URL="https://127.0.0.1:${_port}/releases/download" \
        run sh "$INSTALL_SH" --version 0.0.0
    server_stop "$_pid"
    [ "$status" -eq 6 ]
    # The hand-off must have been the corrected `ocx self setup <version>`.
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
    ! grep -q -- "--remote package install" "$OCX_STUB_ARGV"
}

@test "exit 3: latest-version resolution fails when the manifest URL is dead" {
    OCX_INSTALL_DIST_URL="https://127.0.0.1:1/dist.json" \
        run sh "$INSTALL_SH"
    [ "$status" -eq 3 ]
    echo "$output" | grep -qi 'latest version'
}

@test "exit 2: __OCX_TESTING_INSTALL_BINARY pointing at a missing file" {
    __OCX_TESTING_INSTALL_BINARY="${BATS_TEST_TMPDIR}/no-such-binary" \
        run sh "$INSTALL_SH"
    [ "$status" -eq 2 ]
}
