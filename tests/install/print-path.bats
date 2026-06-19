#!/usr/bin/env bats
# Stdout/stderr discipline. Documents the load-bearing contract that lets
# downstream wrappers do `BIN_DIR=$(./install.sh | tail -n1)`.

bats_require_minimum_version 1.5.0

load helpers/server

INSTALL_SH="${BATS_TEST_DIRNAME}/../../src/install.sh"

# Canonical CLI bin subpath (real on-disk store layout). Mirrors
# OCX_BIN_SUBPATH in src/install.sh.
BIN_SUBPATH="symlinks/ocx.sh/ocx/cli/current/content/bin"

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

# These tests use `run --separate-stderr` so $stdout and $stderr are split.
# Under a plain `run`, bats merges both into $output and leaves $stderr empty,
# which would let stderr leaks pass silently.

@test "stdout is empty on default success" {
    run --separate-stderr sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [ -z "$stdout" ]
    # ...and the installer was not silent: its banner went to stderr.
    [ -n "$stderr" ]
}

@test "OCX_INSTALL_PRINT_PATH=1 prints the bin dir as the final stdout line" {
    OCX_INSTALL_PRINT_PATH=1 run --separate-stderr sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "${OCX_HOME}/${BIN_SUBPATH}" ]
}

@test "stderr carries the informational banner even with PRINT_PATH set" {
    OCX_INSTALL_PRINT_PATH=1 run --separate-stderr sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    echo "$stderr" | grep -q 'Installing\|Detected\|Downloading\|Verified\|self setup\|installed'
    ! echo "$stdout" | grep -q 'Installing\|Detected\|Downloading\|Verified'
}

@test "OCX_INSTALL_QUIET=1 silences stderr informational lines" {
    OCX_INSTALL_QUIET=1 run --separate-stderr sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    ! echo "$stderr" | grep -q 'Installing\|Downloading\|Detected platform' || false
}

@test "error messages always go to stderr (exit 2 path)" {
    run --separate-stderr sh "$INSTALL_SH" --bogus
    [ "$status" -eq 2 ]
    [ -z "$stdout" ]
    echo "$stderr" | grep -qi 'unknown\|invalid\|usage'
}

@test "__OCX_TESTING_INSTALL_BINARY mode honors PRINT_PATH on final stdout line" {
    local _localbin="${BATS_TEST_TMPDIR}/local-ocx"
    server_stub_body >"$_localbin"
    chmod +x "$_localbin"
    __OCX_TESTING_INSTALL_BINARY="$_localbin" OCX_INSTALL_PRINT_PATH=1 \
        run --separate-stderr sh "$INSTALL_SH"
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "${OCX_HOME}/${BIN_SUBPATH}" ]
}

@test "__OCX_TESTING_INSTALL_BINARY mode keeps stdout silent without PRINT_PATH" {
    local _localbin="${BATS_TEST_TMPDIR}/local-ocx"
    server_stub_body >"$_localbin"
    chmod +x "$_localbin"
    __OCX_TESTING_INSTALL_BINARY="$_localbin" \
        run --separate-stderr sh "$INSTALL_SH"
    [ "$status" -eq 0 ]
    [ -z "$stdout" ]
    [ -n "$stderr" ]
}
