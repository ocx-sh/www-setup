#!/usr/bin/env bats
# Per-shell suite for src/install.nu against the shared HTTPS fixture.
# Needs nu on PATH (server_require_shell skips locally, fails when CI sets
# OCX_TEST_REQUIRE_SHELLS). Declared range: nu 0.105.1..0.116.1.
# Nushell is env-driven (no positional args over a pipe): version pinning
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
    server_require_shell nu
    # A private TMPDIR makes "the installer left nothing behind" assertable.
    export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    mkdir -p "$TMPDIR"
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
    unset OCX_INSTALL_CA_BUNDLE OCX_MANAGED_CONFIG SSL_CERT_FILE SSL_CERT_DIR OCX_EXTRA_CA_CERTS
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
    [ "${lines[${#lines[@]} - 1]}" = "${OCX_HOME}/${BIN_SUBPATH}" ]
}

@test "nu: stdout silent on success without PRINT_PATH" {
    OCX_INSTALL_VERSION=0.0.0 run --separate-stderr nu "$INSTALL_NU"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "nu: ocx self setup output goes to stderr, stdout stays silent" {
    OCX_INSTALL_VERSION=0.0.0 run --separate-stderr nu "$INSTALL_NU"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    echo "$stderr" | grep -qF 'ocx-stub: self setup result'
}

@test "nu: with PRINT_PATH stdout is exactly the bin dir, self setup output on stderr" {
    OCX_INSTALL_VERSION=0.0.0 OCX_INSTALL_PRINT_PATH=1 run --separate-stderr nu "$INSTALL_NU"
    [ "$status" -eq 0 ]
    [ "$output" = "${OCX_HOME}/${BIN_SUBPATH}" ]
    [ "${#lines[@]}" -eq 1 ]
    echo "$stderr" | grep -qF 'ocx-stub: self setup result'
}

@test "nu: the success banner goes to stderr after the self setup hand-off" {
    OCX_INSTALL_VERSION=0.0.0 run --separate-stderr nu "$INSTALL_NU"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    echo "$stderr" | grep -qF 'ocx 0.0.0 installed successfully!'
    echo "$stderr" | grep -qF 'Restart your shell'
}

@test "nu: OCX_INSTALL_QUIET silences the success banner" {
    OCX_INSTALL_VERSION=0.0.0 OCX_INSTALL_QUIET=1 run --separate-stderr nu "$INSTALL_NU"
    [ "$status" -eq 0 ]
    if echo "$stderr" | grep -qF 'installed successfully'; then
        false
    fi
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

# Retry. The real incident: one CDN edge PoP answered 500 for dist.json while
# every other PoP served it fine, and a single unretried GET aborted the whole
# install with exit 3.
@test "nu: retry: a transient 500 on the manifest is retried and the install succeeds" {
    OCX_INSTALL_DIST_URL="${FIXTURE_URL}/flaky/2/dist.json" run nu "$INSTALL_NU"
    [ "$status" -eq 0 ]
    # Two failures then a success = three GETs of that URL.
    [ "$(server_request_count "${BATS_FILE_TMPDIR}/server.log" "/flaky/2/dist.json")" -eq 3 ]
}

@test "nu: retry: exhausted attempts still exit 3, after exactly 3 tries" {
    OCX_INSTALL_DIST_URL="${FIXTURE_URL}/flaky/99/dist.json" run nu "$INSTALL_NU"
    [ "$status" -eq 3 ]
    # install.nu's fetch loop errors directly on exhaustion ("failed to fetch
    # <url>") rather than wrapping it in a "latest version" message like sh/fish.
    echo "$output" | grep -qi 'failed to fetch'
    [ "$(server_request_count "${BATS_FILE_TMPDIR}/server.log" "/flaky/99/dist.json")" -eq 3 ]
}

@test "nu: retry: the archive download is retried too" {
    # Point the mirror at a flaky prefix so the ARCHIVE fetch (not the manifest)
    # is the one that fails twice.
    OCX_INSTALL_MIRROR_URL="${FIXTURE_URL}/flaky/2/releases/download" run nu "$INSTALL_NU"
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

# --- Embedded configuration block (corporate mirrors) -----------------------

@test "nu: a sed-ed dist URL is used when the env is unset" {
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
    local _copy="${BATS_TEST_TMPDIR}/install-embedded.nu"
    # The embedded manifest URL is dead; setup() still exports the fixture one.
    server_embed_config "$INSTALL_NU" "$_copy" \
        "OCX_INSTALL_DIST_URL=https://127.0.0.1:1/dead/dist.json"
    OCX_INSTALL_VERSION=0.0.0 run nu "$_copy"
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "nu: an embedded managed-config ref is forwarded to 'ocx self setup'" {
    local _copy="${BATS_TEST_TMPDIR}/install-managed.nu"
    server_embed_config "$INSTALL_NU" "$_copy" \
        "OCX_MANAGED_CONFIG=registry.corp.example/ocx/managed-config:v1"
    OCX_INSTALL_VERSION=0.0.0 run nu "$_copy"
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path --managed-config registry.corp.example/ocx/managed-config:v1" "$OCX_STUB_ARGV"
}

@test "nu: OCX_INSTALL_CA_BUNDLE as an inline PEM block is materialized" {
    local _copy="${BATS_TEST_TMPDIR}/install-ca.nu"
    server_embed_config "$INSTALL_NU" "$_copy" \
        "OCX_INSTALL_CA_BUNDLE=$(server_ca_bundle_inline)"
    # Drop the CURL_CA_BUNDLE that setup() exports: the install can only succeed
    # if the embedded PEM really reaches curl.
    unset CURL_CA_BUNDLE
    OCX_INSTALL_VERSION=0.0.0 run nu "$_copy"
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
    # SSL_CERT_FILE names the materialized temp file; OCX_EXTRA_CA_CERTS carries
    # the PEM text AS SUPPLIED (ocx sniffs it the same way and persists it).
    grep -qE -- '^SSL_CERT_FILE=/.+' "$OCX_STUB_ENV"
    grep -qxF -- 'OCX_EXTRA_CA_CERTS=# Corp Root CA' "$OCX_STUB_ENV"
    grep -qF -- '-----BEGIN CERTIFICATE-----' "$OCX_STUB_ENV"
}

@test "nu: OCX_INSTALL_CA_BUNDLE neither a file nor inline PEM → exit 2" {
    OCX_INSTALL_CA_BUNDLE="${BATS_TEST_TMPDIR}/no-such-ca.pem" \
        OCX_INSTALL_VERSION=0.0.0 run nu "$INSTALL_NU"
    [ "$status" -eq 2 ]
}

@test "nu: no CA bundle - the fixture cert is rejected (negative control)" {
    # Without CURL_CA_BUNDLE nothing trusts the fixture's self-signed cert. This
    # is what makes the OCX_INSTALL_CA_BUNDLE success above meaningful.
    unset CURL_CA_BUNDLE
    OCX_INSTALL_VERSION=0.0.0 run nu "$INSTALL_NU"
    [ "$status" -eq 3 ]
}

@test "nu: OCX_INSTALL_CA_BUNDLE is handed to 'ocx self setup' as OCX_EXTRA_CA_CERTS + SSL_CERT_FILE" {
    unset CURL_CA_BUNDLE
    OCX_INSTALL_CA_BUNDLE="$(server_ca_bundle)" OCX_INSTALL_VERSION=0.0.0 run nu "$INSTALL_NU"
    [ "$status" -eq 0 ]
    # Second hop: `ocx self setup` pulls the package store itself. One bundle
    # must cover both: OCX_EXTRA_CA_CERTS (persisted, every OS) as supplied, and
    # SSL_CERT_FILE for an older ocx (Linux only).
    grep -qxF -- "OCX_EXTRA_CA_CERTS=$(server_ca_bundle)" "$OCX_STUB_ENV"
    grep -qxF -- "SSL_CERT_FILE=$(server_ca_bundle)" "$OCX_STUB_ENV"
}

@test "nu: a large manifest over the ^curl CA path does not deadlock" {
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

# --- Helpers for the tests below ---------------------------------------------

# Start a throwaway fixture server on ROOT; sets SRV_PID, SRV_PORT, SRV_URL.
_serve() {
    local _info
    _info=$(server_start "$1" "${BATS_TEST_TMPDIR}/$2.log")
    SRV_PID="${_info% *}"
    SRV_PORT="${_info#* }"
    SRV_URL="https://127.0.0.1:${SRV_PORT}"
}

# Serve ROOT, run the installer pinned to 0.0.0 against it, stop the server.
_install_from() {
    _serve "$1" srv
    OCX_INSTALL_DIST_URL="${SRV_URL}/dist.json" \
        OCX_INSTALL_MIRROR_URL="${SRV_URL}/releases/download" \
        OCX_INSTALL_VERSION=0.0.0 run nu "$INSTALL_NU"
    server_stop "$SRV_PID"
}

# Pack BUNDLE_DIR (a directory under PARENT) as ROOT's v0.0.0 archive and write
# a manifest whose inline sha256 matches it, so only the archive CONTENT is bad.
_publish_bundle() {
    local _root="$1" _parent="$2" _dir="$3"
    local _file="ocx-${FIXTURE_TARGET}.tar.gz" _sum
    mkdir -p "$_root/releases/download/v0.0.0"
    (cd "$_parent" && tar czf "$_root/releases/download/v0.0.0/${_file}" "$_dir")
    _sum=$(server_sha256 "$_root/releases/download/v0.0.0/${_file}")
    server_write_dist "$_root" "$FIXTURE_TARGET" "$_sum" "$_file"
}

# The installer must leave nothing in TMPDIR, success or failure.
_temp_clean() {
    if [ -n "$(ls -A "$TMPDIR")" ]; then
        ls -A "$TMPDIR" >&2
        return 1
    fi
}

# --- Fail-closed integrity ---------------------------------------------------

@test "nu: a manifest row without a valid sha256 fails closed -> exit 3, before any download" {
    local _t="${BATS_TEST_TMPDIR}/badsha" _bad
    server_build_fixture "$_t" >/dev/null
    local _file="ocx-${FIXTURE_TARGET}.tar.gz"
    # blank, too short, and 64 characters that are not all hex.
    for _bad in "" "abc123" "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"; do
        server_write_dist "$_t" "$FIXTURE_TARGET" "$_bad" "$_file"
        _install_from "$_t"
        [ "$status" -eq 3 ]
        [[ "$output" == *"no valid sha256"* ]] || false
    done
    [ "$(server_request_count "${BATS_TEST_TMPDIR}/srv.log" "releases/download")" -eq 0 ]
    _temp_clean
}

@test "nu: a manifest row with no sha256 field fails closed -> exit 3" {
    local _t="${BATS_TEST_TMPDIR}/nosha"
    server_build_fixture "$_t" >/dev/null
    sed 's/"sha256":"[^"]*",//' "$_t/dist.json" >"$_t/dist.tmp"
    mv "$_t/dist.tmp" "$_t/dist.json"
    run ! grep -q sha256 "$_t/dist.json"
    _install_from "$_t"
    [ "$status" -eq 3 ]
    [[ "$output" == *"no valid sha256"* ]]
}

@test "nu: an uppercase inline sha256 still verifies" {
    local _t="${BATS_TEST_TMPDIR}/upper" _sum
    server_build_fixture "$_t" >/dev/null
    _sum=$(server_sha256 "$_t/releases/download/v0.0.0/ocx-${FIXTURE_TARGET}.tar.gz")
    _sum=$(printf '%s' "$_sum" | tr '[:lower:]' '[:upper:]')
    server_write_dist "$_t" "$FIXTURE_TARGET" "$_sum" "ocx-${FIXTURE_TARGET}.tar.gz"
    _install_from "$_t"
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

# --- Plain-http is refused at script level -----------------------------------

@test "nu: a non-https manifest URL is refused -> exit 3" {
    OCX_INSTALL_DIST_URL="http://127.0.0.1:${FIXTURE_PORT}/dist.json" \
        OCX_INSTALL_VERSION=0.0.0 run nu "$INSTALL_NU"
    [ "$status" -eq 3 ]
    [[ "$output" == *"refusing insecure"* ]]
}

@test "nu: a non-https mirror URL is refused -> exit 3" {
    OCX_INSTALL_MIRROR_URL="http://127.0.0.1:${FIXTURE_PORT}/releases/download" \
        OCX_INSTALL_VERSION=0.0.0 run nu "$INSTALL_NU"
    [ "$status" -eq 3 ]
    [[ "$output" == *"refusing insecure"* ]]
}

# --- Version pin vs latest ---------------------------------------------------

@test "nu: OCX_INSTALL_VERSION wins over a newer 'latest' in the manifest" {
    server_write_decoy_dist "$FIXTURE_DIR"
    OCX_INSTALL_DIST_URL="${FIXTURE_URL}/dist-decoy.json" \
        OCX_INSTALL_VERSION=0.0.0 run nu "$INSTALL_NU"
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "nu: with no pin the decoy manifest resolves 9.9.9 -> exit 3 (control for the pin test)" {
    server_write_decoy_dist "$FIXTURE_DIR"
    OCX_INSTALL_DIST_URL="${FIXTURE_URL}/dist-decoy.json" run nu "$INSTALL_NU"
    [ "$status" -eq 3 ]
    [[ "$output" == *"9.9.9"* ]]
}

# --- CI PATH export ----------------------------------------------------------

@test "nu: GITHUB_PATH receives the bin dir" {
    GITHUB_PATH="${BATS_TEST_TMPDIR}/github-path" OCX_INSTALL_NO_SETUP=1 \
        OCX_INSTALL_VERSION=0.0.0 run nu "$INSTALL_NU"
    [ "$status" -eq 0 ]
    grep -qxF -- "${OCX_HOME}/${BIN_SUBPATH}" "${BATS_TEST_TMPDIR}/github-path"
}

# --- Exit 5 / 6 ---------------------------------------------------------------

@test "nu: exit 5 - a corrupt archive fails to extract" {
    local _t="${BATS_TEST_TMPDIR}/corrupt" _file="ocx-${FIXTURE_TARGET}.tar.gz"
    server_build_fixture "$_t" >/dev/null
    printf 'not a real gzip archive\n' >"$_t/releases/download/v0.0.0/${_file}"
    server_write_dist "$_t" "$FIXTURE_TARGET" \
        "$(server_sha256 "$_t/releases/download/v0.0.0/${_file}")" "$_file"
    _install_from "$_t"
    [ "$status" -eq 5 ]
    _temp_clean
}

@test "nu: exit 5 - an archive without the ocx binary" {
    local _t="${BATS_TEST_TMPDIR}/nobin" _b="${BATS_TEST_TMPDIR}/nobin-bundle"
    mkdir -p "$_b/ocx-${FIXTURE_TARGET}"
    printf 'README\n' >"$_b/ocx-${FIXTURE_TARGET}/README.txt"
    _publish_bundle "$_t" "$_b" "ocx-${FIXTURE_TARGET}"
    _install_from "$_t"
    [ "$status" -eq 5 ]
    [[ "$output" == *"could not find ocx binary"* ]] || false
    _temp_clean
}

@test "nu: exit 6 - 'ocx self setup' failure, with the hand-off argv, and no temp left" {
    local _t="${BATS_TEST_TMPDIR}/bsfail" _b="${BATS_TEST_TMPDIR}/bsfail-bundle"
    mkdir -p "$_b/ocx-${FIXTURE_TARGET}"
    cat >"$_b/ocx-${FIXTURE_TARGET}/ocx" <<'STUB'
#!/bin/sh
if [ -n "${OCX_STUB_ARGV:-}" ]; then
    printf '%s\n' "$*" >>"$OCX_STUB_ARGV"
fi
case "$1" in
    version) echo "0.0.0" ;;
    self) echo "stub self setup failure" >&2; exit 9 ;;
    *) echo "stub ocx" ;;
esac
STUB
    chmod +x "$_b/ocx-${FIXTURE_TARGET}/ocx"
    _publish_bundle "$_t" "$_b" "ocx-${FIXTURE_TARGET}"
    _install_from "$_t"
    [ "$status" -eq 6 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
    _temp_clean
}

@test "nu: a long archive listing (over 64 KiB) does not hang the unsafe-path scan" {
    # `tar --list | lines` in tail position of `try` blocks forever on nu >= 0.112
    # once the listing outgrows the pipe buffer.
    command -v timeout >/dev/null 2>&1 || skip "timeout(1) not available"
    local _t="${BATS_TEST_TMPDIR}/biglist" _b="${BATS_TEST_TMPDIR}/biglist-bundle" _i=0
    mkdir -p "$_b/ocx-${FIXTURE_TARGET}/pad"
    server_stub_body >"$_b/ocx-${FIXTURE_TARGET}/ocx"
    chmod +x "$_b/ocx-${FIXTURE_TARGET}/ocx"
    while [ "$_i" -lt 2500 ]; do
        : >"$_b/ocx-${FIXTURE_TARGET}/pad/padding-file-with-a-deliberately-long-name-${_i}.txt"
        _i=$((_i + 1))
    done
    _publish_bundle "$_t" "$_b" "ocx-${FIXTURE_TARGET}"
    [ "$(tar tzf "$_t/releases/download/v0.0.0/ocx-${FIXTURE_TARGET}.tar.gz" | wc -c)" -gt 131072 ]
    _serve "$_t" srv
    OCX_INSTALL_DIST_URL="${SRV_URL}/dist.json" \
        OCX_INSTALL_MIRROR_URL="${SRV_URL}/releases/download" \
        OCX_INSTALL_VERSION=0.0.0 run timeout 60 nu "$INSTALL_NU"
    server_stop "$SRV_PID"
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

# --- Temp files are removed on every exit ------------------------------------

@test "nu: no temp files remain after a default install" {
    OCX_INSTALL_VERSION=0.0.0 run nu "$INSTALL_NU"
    [ "$status" -eq 0 ]
    _temp_clean
}

@test "nu: no temp files remain after a checksum mismatch (exit 4)" {
    local _t="${BATS_TEST_TMPDIR}/cksum-temp"
    server_build_fixture "$_t" >/dev/null
    server_write_dist "$_t" "$FIXTURE_TARGET" \
        "0000000000000000000000000000000000000000000000000000000000000000" \
        "ocx-${FIXTURE_TARGET}.tar.gz"
    _install_from "$_t"
    [ "$status" -eq 4 ]
    _temp_clean
}

@test "nu: no temp files remain after a pinned-manifest install" {
    local _t="${BATS_TEST_TMPDIR}/pin-temp" _sha
    server_build_fixture "$_t" >/dev/null
    _sha=$(server_publish_dist_snapshot "$_t")
    _serve "$_t" srv
    OCX_INSTALL_DIST_URL="${SRV_URL}/dist/${_sha}.json" \
        OCX_INSTALL_MIRROR_URL="${SRV_URL}/releases/download" \
        OCX_INSTALL_NO_SETUP=1 run nu "$INSTALL_NU"
    server_stop "$SRV_PID"
    [ "$status" -eq 0 ]
    _temp_clean
}

@test "nu: no temp files remain after an altered pinned manifest (exit 4)" {
    local _t="${BATS_TEST_TMPDIR}/pinbad-temp" _sha
    server_build_fixture "$_t" >/dev/null
    _sha=$(server_publish_dist_snapshot "$_t")
    printf '\n' >>"$_t/dist/${_sha}.json"
    _serve "$_t" srv
    OCX_INSTALL_DIST_URL="${SRV_URL}/dist/${_sha}.json" \
        OCX_INSTALL_MIRROR_URL="${SRV_URL}/releases/download" run nu "$INSTALL_NU"
    server_stop "$SRV_PID"
    [ "$status" -eq 4 ]
    _temp_clean
}

@test "nu: no temp files remain after an inline-PEM install" {
    unset CURL_CA_BUNDLE
    OCX_INSTALL_CA_BUNDLE="$(server_ca_bundle_inline)" OCX_INSTALL_VERSION=0.0.0 run nu "$INSTALL_NU"
    [ "$status" -eq 0 ]
    _temp_clean
}

@test "nu: no temp files remain on the idempotent fast path" {
    OCX_INSTALL_NO_SETUP=1 OCX_INSTALL_VERSION=0.0.0 run nu "$INSTALL_NU"
    [ "$status" -eq 0 ]
    OCX_INSTALL_NO_SETUP=1 OCX_INSTALL_VERSION=0.0.0 run nu "$INSTALL_NU"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]] || false
    _temp_clean
}

# --- The documented entry points ---------------------------------------------

# The one-liners from the installer header, with the download swapped for a local
# fetch (args: the `curl` replacement, then the `http get` replacement), so the
# test runs exactly the text users are told to paste. One command per line.
_header_oneliners() {
    local _line _cmd
    while IFS= read -r _line; do
        _cmd="${_line#\#   }"
        _cmd="${_cmd%%   \#*}"
        _cmd="${_cmd/curl -fsSL https:\/\/setup.ocx.sh\/nu/$1}"
        printf '%s\n' "${_cmd/http get https:\/\/setup.ocx.sh\/nu/$2}"
    done < <(grep -E '^#   (curl|nu) .*setup\.ocx\.sh/nu' "$INSTALL_NU")
}

# The POSIX-shell form runs under sh, the in-nu form under nu.
_run_oneliner() {
    case "$1" in
        "nu -c (http get "* | "nu -c (open "*) run nu -c "$1" ;;
        *) run sh -c "$1" ;;
    esac
}

@test "nu: every one-liner the header documents installs" {
    local _cmd _n=0
    while IFS= read -r _cmd; do
        rm -f "$OCX_STUB_ARGV"
        OCX_INSTALL_VERSION=0.0.0 _run_oneliner "$_cmd"
        [ "$status" -eq 0 ]
        grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
        _n=$((_n + 1))
    done < <(_header_oneliners "cat $INSTALL_NU" "open --raw $INSTALL_NU")
    [ "$_n" -eq 2 ]
    _temp_clean
}

@test "nu: every documented one-liner passes the installer's exit code through" {
    local _cmd _n=0
    while IFS= read -r _cmd; do
        __OCX_TESTING_INSTALL_BINARY="${BATS_TEST_TMPDIR}/nope" _run_oneliner "$_cmd"
        [ "$status" -eq 2 ]
        [[ "$output" == *"__OCX_TESTING_INSTALL_BINARY"* ]] || false
        _n=$((_n + 1))
    done < <(_header_oneliners "cat $INSTALL_NU" "open --raw $INSTALL_NU")
    [ "$_n" -eq 2 ]
    _temp_clean
}

@test "nu: every documented one-liner fails and installs nothing when the download fails" {
    local _cmd _n=0
    while IFS= read -r _cmd; do
        rm -f "$OCX_STUB_ARGV"
        OCX_INSTALL_VERSION=0.0.0 _run_oneliner "$_cmd"
        case "$_cmd" in
            "nu -c (open "*) [ "$status" -eq 1 ] ;;
            *) [ "$status" -eq 3 ] ;;
        esac
        [ ! -f "$OCX_STUB_ARGV" ]
        _n=$((_n + 1))
    done < <(_header_oneliners "false" "open --raw ${BATS_TEST_TMPDIR}/nope")
    [ "$_n" -eq 2 ]
}

@test "nu: a cut-off script installs nothing at any cut point" {
    # A cut inside a def is a parse error (1); a cut on a def boundary parses,
    # defines functions and never reaches the entry call (0). Neither installs.
    local _cmd _size _n=0 _cut="${BATS_TEST_TMPDIR}/cut.nu"
    for _size in 4000 12000 20000; do
        head -c "$_size" "$INSTALL_NU" >"$_cut"
        while IFS= read -r _cmd; do
            rm -f "$OCX_STUB_ARGV"
            OCX_INSTALL_VERSION=0.0.0 _run_oneliner "$_cmd"
            case "$status" in 0 | 1) ;; *) false ;; esac
            [ ! -f "$OCX_STUB_ARGV" ]
            [ ! -e "$OCX_HOME/symlinks" ]
            _n=$((_n + 1))
        done < <(_header_oneliners "cat $_cut" "open --raw $_cut")
    done
    [ "$_n" -eq 6 ]
}

@test "nu: a bare 'curl | nu' installs nothing (nu refuses a non-tty stdin)" {
    # Why the header documents `nu -c ...` and not the bare pipe.
    export NU_SRC="$INSTALL_NU"
    OCX_INSTALL_VERSION=0.0.0 run bash -c 'cat "$NU_SRC" | nu'
    [ "$status" -eq 1 ]
    [ ! -f "$OCX_STUB_ARGV" ]
}

# --- libc detection (mirrors install.sh detect_libc) -------------------------
#
# __ocx-detect-libc decides in order: the ldd banner, musl loader files, glibc
# evidence, then exit 7. Its probed paths take a root prefix (a function default,
# not a knob) so a fake tree stands in for the host. The whole-installer exit-7
# path needs a host with no loader at all, which only tests/docker/ has, so these
# tests run the real defs cut out of src/install.nu.

# libc_run ROOT BANNER [CMD]: a PATH ldd prints BANNER on stderr and exits 1, as
# musl's does (empty BANNER = silent). CMD defaults to __ocx-detect-libc ROOT.
libc_run() {
    local _root="$1" _bin="${BATS_TEST_TMPDIR}/libc-bin" _cmd="${3:-}"
    [ -n "$_cmd" ] || _cmd="__ocx-detect-libc '$_root'"
    mkdir -p "$_bin"
    printf '%s' "$2" >"$_bin/ldd.txt"
    cat >"$_bin/ldd" <<'EOF'
#!/bin/sh
cat "$(dirname "$0")/ldd.txt" >&2
exit 1
EOF
    chmod +x "$_bin/ldd"
    sed -n '/^def __ocx-err /,/^}/p;/^def __ocx-detect-libc /,/^}/p;/^def __ocx-detect-target /,/^}/p' \
        "$INSTALL_NU" >"${BATS_TEST_TMPDIR}/libc.nu"
    PATH="$_bin:$PATH" run nu -c "source ${BATS_TEST_TMPDIR}/libc.nu; $_cmd"
}

@test "libc: a musl ldd banner selects musl" {
    libc_run "${BATS_TEST_TMPDIR}/nope" 'musl libc (x86_64)'
    [ "$status" -eq 0 ]
    [ "$output" = musl ]
}

@test "libc: glibc ldd banners select gnu even when a musl loader is present" {
    local _root="${BATS_TEST_TMPDIR}/root" _banner
    mkdir -p "$_root/lib"
    : >"$_root/lib/ld-musl-x86_64.so.1"
    for _banner in "ldd (Debian GLIBC 2.36-9+deb12u7) 2.36" "ldd (GNU libc) 2.39" "ldd (GNU C Library) 2.28"; do
        libc_run "$_root" "$_banner"
        [ "$status" -eq 0 ]
        [ "$output" = gnu ]
    done
}

@test "libc: with no banner a musl loader file selects musl" {
    local _root="${BATS_TEST_TMPDIR}/root"
    mkdir -p "$_root/lib"
    : >"$_root/lib/ld-musl-aarch64.so.1"
    libc_run "$_root" ''
    [ "$status" -eq 0 ]
    [ "$output" = musl ]
}

@test "libc: with no banner /etc/alpine-release selects musl" {
    local _root="${BATS_TEST_TMPDIR}/root"
    mkdir -p "$_root/etc"
    : >"$_root/etc/alpine-release"
    libc_run "$_root" ''
    [ "$status" -eq 0 ]
    [ "$output" = musl ]
}

@test "libc: with no banner a glibc loader selects gnu" {
    local _root="${BATS_TEST_TMPDIR}/root"
    mkdir -p "$_root/lib/x86_64-linux-gnu"
    : >"$_root/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"
    libc_run "$_root" ''
    [ "$status" -eq 0 ]
    [ "$output" = gnu ]
}

@test "libc: no banner and no loader evidence is exit 7, not a guessed glibc" {
    mkdir -p "${BATS_TEST_TMPDIR}/root"
    libc_run "${BATS_TEST_TMPDIR}/root" ''
    [ "$status" -eq 1 ]
    [[ "$output" == *"ocx-exit:7:cannot tell glibc from musl"* ]] || false
}

@test "libc: __ocx-detect-target takes its libc from the ldd banner" {
    libc_run "${BATS_TEST_TMPDIR}/nope" 'musl libc (x86_64)' '__ocx-detect-target'
    [ "$status" -eq 0 ]
    case "$(uname -s)" in
        Linux) [[ "$output" == *-unknown-linux-musl ]] || false ;;
        *) [[ "$output" == *-apple-darwin ]] || false ;;
    esac
}

# --- Source hygiene ----------------------------------------------------------

@test "nu: install.nu is pure ASCII" {
    LC_ALL=C run grep -n '[^[:print:][:space:]]' "$INSTALL_NU"
    [ "$status" -eq 1 ]
}

@test "nu: install.nu header carries Kind, nu-range and Exit lines" {
    sed -n 2,8p "$INSTALL_NU" | grep -qxF '# Kind: INST'
    sed -n 2,8p "$INSTALL_NU" | grep -q '^# nu-range: [0-9][0-9.]*\.\.[0-9][0-9.]*$'
    sed -n 2,8p "$INSTALL_NU" | grep -q '^# Exit: 0 ok, 1 generic, 2 arg/env, 3 network/manifest, 4 checksum, 5 extract, 6 self setup, 7 platform'
}

# --- curl flags are probed (the ^curl path runs when a CA bundle is set) --------

@test "nu: --tlsv1.2 is sent only when curl --help all lists it" {
    local _bin="${BATS_TEST_TMPDIR}/fakebin" _log="${BATS_TEST_TMPDIR}/fetch.log"
    server_fake_curl "$_bin"
    unset CURL_CA_BUNDLE
    OCX_INSTALL_CA_BUNDLE="$(server_ca_bundle)" FAKE_CURL_LOG="$_log" PATH="$_bin:$PATH" \
    OCX_INSTALL_VERSION=0.0.0 run nu "$INSTALL_NU"
    [ "$status" -eq 0 ]
    [ "$(grep -c -e "--proto =https" "$_log")" -eq 2 ]
    [ "$(grep -c -e "--tlsv1.2" "$_log" || true)" -eq 0 ]
    : >"$_log"
    OCX_INSTALL_CA_BUNDLE="$(server_ca_bundle)" FAKE_CURL_TLS12=1 FAKE_CURL_LOG="$_log" PATH="$_bin:$PATH" \
    OCX_INSTALL_VERSION=0.0.0 run nu "$INSTALL_NU"
    [ "$status" -eq 0 ]
    [ "$(grep -c -e "--tlsv1.2" "$_log")" -eq 2 ]
}
