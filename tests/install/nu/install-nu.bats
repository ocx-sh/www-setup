#!/usr/bin/env bats
# Per-shell suite for src/install.nu against the shared HTTPS fixture.
# Skips when nu is not installed (CI runs it in docker; nushell 0.101.0 pinned).
# Nushell is env-driven (no positional args over `curl | nu`): version pinning
# uses OCX_INSTALL_VERSION.

bats_require_minimum_version 1.5.0

load ../helpers/server

INSTALL_NU="${BATS_TEST_DIRNAME}/../../../src/install.nu"
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
    command -v nu >/dev/null 2>&1 || skip "nu not installed"
    export OCX_HOME="${BATS_TEST_TMPDIR}/.ocx"
    export OCX_NO_MODIFY_PATH=1
    export CURL_CA_BUNDLE
    CURL_CA_BUNDLE="$(server_ca_bundle)"
    export OCX_STUB_ARGV="${BATS_TEST_TMPDIR}/stub-argv.log"
    export OCX_STUB_ENV="${BATS_TEST_TMPDIR}/stub-env.log"
    export OCX_INSTALL_DIST_URL="${FIXTURE_URL}/dist.json"
    export OCX_INSTALL_MIRROR_URL="${FIXTURE_URL}/releases/download"
    unset GITHUB_PATH OCX_INSTALL_NO_SETUP OCX_INSTALL_VERSION
    unset __OCX_TESTING_INSTALL_BINARY
    unset OCX_INSTALL_CA_BUNDLE OCX_MANAGED_CONFIG SSL_CERT_FILE SSL_CERT_DIR
}

@test "nu: default install hands off to 'ocx self setup <version>'" {
    OCX_INSTALL_VERSION=0.0.0 run nu "$INSTALL_NU"
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "nu: latest resolves from dist.json (no version pin)" {
    OCX_INSTALL_NO_SETUP=1 run nu "$INSTALL_NU"
    [ "$status" -eq 0 ]
    [ -x "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
}

@test "nu: OCX_INSTALL_NO_SETUP places the binary and skips setup" {
    OCX_INSTALL_VERSION=0.0.0 OCX_INSTALL_NO_SETUP=1 run nu "$INSTALL_NU"
    [ "$status" -eq 0 ]
    [ -x "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
    [ ! -f "$OCX_STUB_ARGV" ] || ! grep -q -- "self setup" "$OCX_STUB_ARGV"
}

@test "nu: OCX_INSTALL_PRINT_PATH emits bin dir as final stdout line" {
    OCX_INSTALL_VERSION=0.0.0 OCX_INSTALL_PRINT_PATH=1 OCX_INSTALL_QUIET=1 \
        run --separate-stderr nu "$INSTALL_NU"
    [ "$status" -eq 0 ]
    [ "${lines[${#lines[@]}-1]}" = "${OCX_HOME}/${BIN_SUBPATH}" ]
}

@test "nu: stdout silent on success without PRINT_PATH" {
    OCX_INSTALL_VERSION=0.0.0 run --separate-stderr nu "$INSTALL_NU"
    [ "$status" -eq 0 ]
    [ -z "$stdout" ]
}

@test "nu: no row for the version → exit 3" {
    OCX_INSTALL_VERSION=9.9.9 run nu "$INSTALL_NU"
    [ "$status" -eq 3 ]
}

@test "nu: checksum mismatch → exit 4" {
    local _t="${BATS_TEST_TMPDIR}/cksum"
    server_build_fixture "$_t" >/dev/null
    server_write_dist "$_t" "$FIXTURE_TARGET" \
        "0000000000000000000000000000000000000000000000000000000000000000" \
        "ocx-${FIXTURE_TARGET}.tar.gz"
    local _info _pid _port
    _info=$(server_start "$_t" "${BATS_TEST_TMPDIR}/ck.log")
    _pid="${_info% *}"
    _port="${_info#* }"
    OCX_INSTALL_VERSION=0.0.0 \
        OCX_INSTALL_DIST_URL="https://127.0.0.1:${_port}/dist.json" \
        OCX_INSTALL_MIRROR_URL="https://127.0.0.1:${_port}/releases/download" \
        run nu "$INSTALL_NU"
    server_stop "$_pid"
    [ "$status" -eq 4 ]
}

@test "nu: invalid version → exit 2" {
    OCX_INSTALL_VERSION="foo;rm" run nu "$INSTALL_NU"
    [ "$status" -eq 2 ]
}

@test "nu: __OCX_TESTING_INSTALL_BINARY records '--offline self setup'" {
    local _localbin="${BATS_TEST_TMPDIR}/local-ocx"
    server_stub_body >"$_localbin"
    chmod +x "$_localbin"
    __OCX_TESTING_INSTALL_BINARY="$_localbin" run nu "$INSTALL_NU"
    [ "$status" -eq 0 ]
    [ -x "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
    grep -qxF -- "--offline self setup --no-modify-path" "$OCX_STUB_ARGV"
}

@test "nu: __OCX_TESTING_INSTALL_BINARY non-file → exit 2" {
    __OCX_TESTING_INSTALL_BINARY="${BATS_TEST_TMPDIR}/nope" run nu "$INSTALL_NU"
    [ "$status" -eq 2 ]
}

@test "nu: pinned manifest dist/<sha256>.json installs and is digest-verified" {
    local _t="${BATS_TEST_TMPDIR}/pin-ok"
    server_build_fixture "$_t" >/dev/null
    local _sha
    _sha=$(server_publish_dist_snapshot "$_t")
    local _info _pid _port
    _info=$(server_start "$_t" "${BATS_TEST_TMPDIR}/pin-ok.log")
    _pid="${_info% *}"
    _port="${_info#* }"
    OCX_INSTALL_DIST_URL="https://127.0.0.1:${_port}/dist/${_sha}.json" \
        OCX_INSTALL_MIRROR_URL="https://127.0.0.1:${_port}/releases/download" \
        OCX_INSTALL_NO_SETUP=1 \
        run nu "$INSTALL_NU"
    server_stop "$_pid"
    [ "$status" -eq 0 ]
    [ -x "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
}

@test "nu: pinned manifest with an altered body → exit 4" {
    local _t="${BATS_TEST_TMPDIR}/pin-bad"
    server_build_fixture "$_t" >/dev/null
    local _sha
    _sha=$(server_publish_dist_snapshot "$_t")
    printf '\n' >>"$_t/dist/${_sha}.json"
    local _info _pid _port
    _info=$(server_start "$_t" "${BATS_TEST_TMPDIR}/pin-bad.log")
    _pid="${_info% *}"
    _port="${_info#* }"
    OCX_INSTALL_DIST_URL="https://127.0.0.1:${_port}/dist/${_sha}.json" \
        OCX_INSTALL_MIRROR_URL="https://127.0.0.1:${_port}/releases/download" \
        run nu "$INSTALL_NU"
    server_stop "$_pid"
    [ "$status" -eq 4 ]
}

# --- Embedded configuration block (corporate mirrors) -----------------------

@test "nu: a sed-ed dist URL is used when the env is unset" {
    command -v nu >/dev/null 2>&1 || skip "nu not installed"
    local _copy="${BATS_TEST_TMPDIR}/install-embedded.nu"
    server_embed_config "$INSTALL_NU" "$_copy" \
        "OCX_INSTALL_DIST_URL=${FIXTURE_URL}/dist.json" \
        "OCX_INSTALL_MIRROR_URL=${FIXTURE_URL}/releases/download"
    unset OCX_INSTALL_DIST_URL OCX_INSTALL_MIRROR_URL
    OCX_INSTALL_VERSION=0.0.0 run nu "$_copy"
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "nu: the environment wins over the embedded value" {
    command -v nu >/dev/null 2>&1 || skip "nu not installed"
    local _copy="${BATS_TEST_TMPDIR}/install-embedded.nu"
    # The embedded manifest URL is dead; setup() still exports the fixture one.
    server_embed_config "$INSTALL_NU" "$_copy" \
        "OCX_INSTALL_DIST_URL=https://127.0.0.1:1/dead/dist.json"
    OCX_INSTALL_VERSION=0.0.0 run nu "$_copy"
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "nu: an embedded managed-config ref is forwarded to 'ocx self setup'" {
    command -v nu >/dev/null 2>&1 || skip "nu not installed"
    local _copy="${BATS_TEST_TMPDIR}/install-managed.nu"
    server_embed_config "$INSTALL_NU" "$_copy" \
        "OCX_MANAGED_CONFIG=registry.corp.example/ocx/managed-config:v1"
    OCX_INSTALL_VERSION=0.0.0 run nu "$_copy"
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path --managed-config registry.corp.example/ocx/managed-config:v1" "$OCX_STUB_ARGV"
}

@test "nu: OCX_INSTALL_CA_BUNDLE as an inline PEM block is materialized" {
    command -v nu >/dev/null 2>&1 || skip "nu not installed"
    local _copy="${BATS_TEST_TMPDIR}/install-ca.nu"
    server_embed_config "$INSTALL_NU" "$_copy" \
        "OCX_INSTALL_CA_BUNDLE=$(server_ca_bundle_inline)"
    # Drop the CURL_CA_BUNDLE that setup() exports: the install can only succeed
    # if the embedded PEM really reaches curl.
    unset CURL_CA_BUNDLE
    OCX_INSTALL_VERSION=0.0.0 run nu "$_copy"
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "nu: OCX_INSTALL_CA_BUNDLE neither a file nor inline PEM → exit 2" {
    command -v nu >/dev/null 2>&1 || skip "nu not installed"
    OCX_INSTALL_CA_BUNDLE="${BATS_TEST_TMPDIR}/no-such-ca.pem" \
        OCX_INSTALL_VERSION=0.0.0 run nu "$INSTALL_NU"
    [ "$status" -eq 2 ]
}

@test "nu: no CA bundle - the fixture cert is rejected (negative control)" {
    command -v nu >/dev/null 2>&1 || skip "nu not installed"
    # Without CURL_CA_BUNDLE nothing trusts the fixture's self-signed cert. This
    # is what makes the OCX_INSTALL_CA_BUNDLE success above meaningful.
    unset CURL_CA_BUNDLE
    OCX_INSTALL_VERSION=0.0.0 run nu "$INSTALL_NU"
    [ "$status" -ne 0 ]
}

@test "nu: OCX_INSTALL_CA_BUNDLE is handed to 'ocx self setup' via SSL_CERT_FILE" {
    command -v nu >/dev/null 2>&1 || skip "nu not installed"
    unset CURL_CA_BUNDLE
    OCX_INSTALL_CA_BUNDLE="$(server_ca_bundle)" OCX_INSTALL_VERSION=0.0.0 run nu "$INSTALL_NU"
    [ "$status" -eq 0 ]
    # Second hop: `ocx self setup` pulls the package store itself and reads the
    # host trust store via SSL_CERT_FILE. One bundle must cover both.
    grep -qxF -- "SSL_CERT_FILE=$(server_ca_bundle)" "$OCX_STUB_ENV"
}

@test "nu: a large manifest over the ^curl CA path does not deadlock" {
    command -v nu >/dev/null 2>&1 || skip "nu not installed"
    # Regression guard. An external command left in TAIL POSITION inside `try`
    # hangs forever in nushell: `try` holds a stream nobody drains, and the
    # deadlock only bites once the body outgrows the 64 KiB pipe buffer. The
    # ordinary fixture manifest is a few hundred bytes, so it hid this
    # completely while the real 73 KiB setup.ocx.sh manifest hung every install
    # that took the ^curl path. Setting the CA bundle is what selects that path
    # (`http get` has no CA-bundle option). `timeout` turns a regression into a
    # failed assertion instead of a hung CI job.
    # macOS ships no coreutils `timeout`; without it a regression would hang the
    # run instead of failing it, so skip rather than assert blind.
    command -v timeout >/dev/null 2>&1 || skip "timeout(1) not available"
    server_pad_dist "$FIXTURE_DIR"
    unset CURL_CA_BUNDLE
    OCX_INSTALL_DIST_URL="${FIXTURE_URL}/dist-big.json" \
        OCX_INSTALL_CA_BUNDLE="$(server_ca_bundle)" \
        OCX_INSTALL_VERSION=0.0.0 \
        run timeout 60 nu "$INSTALL_NU"
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}
