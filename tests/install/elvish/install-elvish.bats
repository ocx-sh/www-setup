#!/usr/bin/env bats
# Per-shell suite for src/install.elv against the shared HTTPS fixture.
# Skips when elvish is absent unless OCX_TEST_REQUIRE_SHELLS is set. Floor 0.20.1.

bats_require_minimum_version 1.5.0

load ../helpers/server

INSTALL_ELV="${BATS_TEST_DIRNAME}/../../../src/install.elv"
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
    server_require_shell elvish
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

@test "elvish: default install hands off to 'ocx self setup <version>'" {
    run elvish "$INSTALL_ELV" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "elvish: OCX_INSTALL_VERSION pins the version" {
    OCX_INSTALL_VERSION=0.0.0 run elvish "$INSTALL_ELV"
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "elvish: OCX_INSTALL_NO_SETUP places the binary and skips setup" {
    OCX_INSTALL_NO_SETUP=1 run elvish "$INSTALL_ELV" --version 0.0.0
    [ "$status" -eq 0 ]
    [ -x "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
    [ ! -f "$OCX_STUB_ARGV" ] || ! grep -q -- "self setup" "$OCX_STUB_ARGV"
}

@test "elvish: OCX_INSTALL_PRINT_PATH emits bin dir as final stdout line" {
    OCX_INSTALL_PRINT_PATH=1 OCX_INSTALL_QUIET=1 \
        run --separate-stderr elvish "$INSTALL_ELV" --version 0.0.0
    [ "$status" -eq 0 ]
    [ "${lines[${#lines[@]} - 1]}" = "${OCX_HOME}/${BIN_SUBPATH}" ]
}

@test "elvish: stdout silent on success without PRINT_PATH" {
    run --separate-stderr elvish "$INSTALL_ELV" --version 0.0.0
    [ "$status" -eq 0 ]
    [ -z "$stdout" ]
}

@test "elvish: no row for the version → exit 3" {
    run elvish "$INSTALL_ELV" --version 9.9.9
    [ "$status" -eq 3 ]
}

@test "elvish: checksum mismatch → exit 4" {
    local _t="${BATS_TEST_TMPDIR}/cksum"
    server_build_fixture "$_t" >/dev/null
    server_write_dist "$_t" "$FIXTURE_TARGET" \
        "0000000000000000000000000000000000000000000000000000000000000000" \
        "ocx-${FIXTURE_TARGET}.tar.gz"
    local _info _pid _port
    _info=$(server_start "$_t" "${BATS_TEST_TMPDIR}/ck.log")
    _pid="${_info% *}"
    _port="${_info#* }"
    OCX_INSTALL_DIST_URL="https://127.0.0.1:${_port}/dist.json" \
        OCX_INSTALL_MIRROR_URL="https://127.0.0.1:${_port}/releases/download" \
        run elvish "$INSTALL_ELV" --version 0.0.0
    server_stop "$_pid"
    [ "$status" -eq 4 ]
}

@test "elvish: invalid version → exit 2" {
    run elvish "$INSTALL_ELV" --version "foo;rm"
    [ "$status" -eq 2 ]
}

@test "elvish: __OCX_TESTING_INSTALL_BINARY records '--offline self setup'" {
    local _localbin="${BATS_TEST_TMPDIR}/local-ocx"
    server_stub_body >"$_localbin"
    chmod +x "$_localbin"
    __OCX_TESTING_INSTALL_BINARY="$_localbin" run elvish "$INSTALL_ELV"
    [ "$status" -eq 0 ]
    [ -x "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
    grep -qxF -- "--offline self setup --no-modify-path" "$OCX_STUB_ARGV"
}

@test "elvish: __OCX_TESTING_INSTALL_BINARY non-file → exit 2" {
    __OCX_TESTING_INSTALL_BINARY="${BATS_TEST_TMPDIR}/nope" run elvish "$INSTALL_ELV"
    [ "$status" -eq 2 ]
}

@test "elvish: pinned manifest dist/<sha256>.json installs and is digest-verified" {
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
        run elvish "$INSTALL_ELV"
    server_stop "$_pid"
    [ "$status" -eq 0 ]
    [ -x "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
}

@test "elvish: pinned manifest with an altered body → exit 4" {
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
        run elvish "$INSTALL_ELV"
    server_stop "$_pid"
    [ "$status" -eq 4 ]
}

# Retry. The real incident: one CDN edge PoP answered 500 for dist.json while
# every other PoP served it fine, and a single unretried GET aborted the whole
# install with exit 3.
@test "elvish: retry: a transient 500 on the manifest is retried and the install succeeds" {
    OCX_INSTALL_DIST_URL="${FIXTURE_URL}/flaky/2/dist.json" run elvish "$INSTALL_ELV"
    [ "$status" -eq 0 ]
    # Two failures then a success = three GETs of that URL.
    [ "$(server_request_count "${BATS_FILE_TMPDIR}/server.log" "/flaky/2/dist.json")" -eq 3 ]
}

@test "elvish: retry: exhausted attempts still exit 3, after exactly 3 tries" {
    OCX_INSTALL_DIST_URL="${FIXTURE_URL}/flaky/99/dist.json" run elvish "$INSTALL_ELV"
    [ "$status" -eq 3 ]
    # install.elv's fetch loop errors directly on exhaustion ("failed to fetch
    # <url>") rather than wrapping it in a "latest version" message like sh/fish.
    echo "$output" | grep -qi 'failed to fetch'
    [ "$(server_request_count "${BATS_FILE_TMPDIR}/server.log" "/flaky/99/dist.json")" -eq 3 ]
}

@test "elvish: retry: the archive download is retried too" {
    # Point the mirror at a flaky prefix so the ARCHIVE fetch (not the manifest)
    # is the one that fails twice.
    OCX_INSTALL_MIRROR_URL="${FIXTURE_URL}/flaky/2/releases/download" run elvish "$INSTALL_ELV"
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

# --- Embedded configuration block (corporate mirrors) -----------------------

@test "elvish: a sed-ed dist URL is used when the env is unset" {
    local _copy="${BATS_TEST_TMPDIR}/install-embedded.elv"
    server_embed_config "$INSTALL_ELV" "$_copy" \
        "OCX_INSTALL_DIST_URL=${FIXTURE_URL}/dist.json" \
        "OCX_INSTALL_MIRROR_URL=${FIXTURE_URL}/releases/download"
    unset OCX_INSTALL_DIST_URL OCX_INSTALL_MIRROR_URL
    run elvish "$_copy" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "elvish: the environment wins over the embedded value" {
    local _copy="${BATS_TEST_TMPDIR}/install-embedded.elv"
    # The embedded manifest URL is dead; setup() still exports the fixture one.
    server_embed_config "$INSTALL_ELV" "$_copy" \
        "OCX_INSTALL_DIST_URL=https://127.0.0.1:1/dead/dist.json"
    run elvish "$_copy" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "elvish: an embedded managed-config ref is forwarded to 'ocx self setup'" {
    local _copy="${BATS_TEST_TMPDIR}/install-managed.elv"
    server_embed_config "$INSTALL_ELV" "$_copy" \
        "OCX_MANAGED_CONFIG=registry.corp.example/ocx/managed-config:v1"
    run elvish "$_copy" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path --managed-config registry.corp.example/ocx/managed-config:v1" "$OCX_STUB_ARGV"
}

@test "elvish: OCX_INSTALL_CA_BUNDLE as an inline PEM block is materialized" {
    local _copy="${BATS_TEST_TMPDIR}/install-ca.elv"
    server_embed_config "$INSTALL_ELV" "$_copy" \
        "OCX_INSTALL_CA_BUNDLE=$(server_ca_bundle_inline)"
    # Drop the CURL_CA_BUNDLE that setup() exports: the install can only succeed
    # if the embedded PEM really reaches curl.
    unset CURL_CA_BUNDLE
    run elvish "$_copy" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
    # SSL_CERT_FILE names the materialized temp file; OCX_EXTRA_CA_CERTS carries
    # the PEM text AS SUPPLIED (ocx sniffs it the same way and persists it).
    grep -qE -- '^SSL_CERT_FILE=/.+' "$OCX_STUB_ENV"
    grep -qxF -- 'OCX_EXTRA_CA_CERTS=# Corp Root CA' "$OCX_STUB_ENV"
    grep -qF -- '-----BEGIN CERTIFICATE-----' "$OCX_STUB_ENV"
}

@test "elvish: OCX_INSTALL_CA_BUNDLE neither a file nor inline PEM → exit 2" {
    OCX_INSTALL_CA_BUNDLE="${BATS_TEST_TMPDIR}/no-such-ca.pem" \
        run elvish "$INSTALL_ELV" --version 0.0.0
    [ "$status" -eq 2 ]
}

@test "elvish: no CA bundle - the fixture cert is rejected (negative control)" {
    # Without CURL_CA_BUNDLE nothing trusts the fixture's self-signed cert. This
    # is what makes the OCX_INSTALL_CA_BUNDLE success above meaningful.
    unset CURL_CA_BUNDLE
    run elvish "$INSTALL_ELV" --version 0.0.0
    [ "$status" -eq 3 ]
}

@test "elvish: OCX_INSTALL_CA_BUNDLE is handed to 'ocx self setup' as OCX_EXTRA_CA_CERTS + SSL_CERT_FILE" {
    unset CURL_CA_BUNDLE
    OCX_INSTALL_CA_BUNDLE="$(server_ca_bundle)" run elvish "$INSTALL_ELV" --version 0.0.0
    [ "$status" -eq 0 ]
    # Second hop: `ocx self setup` pulls the package store itself. One bundle
    # must cover both: OCX_EXTRA_CA_CERTS (persisted, every OS) as supplied, and
    # SSL_CERT_FILE for an older ocx (Linux only).
    grep -qxF -- "OCX_EXTRA_CA_CERTS=$(server_ca_bundle)" "$OCX_STUB_ENV"
    grep -qxF -- "SSL_CERT_FILE=$(server_ca_bundle)" "$OCX_STUB_ENV"
}

# --- Helpers for the scenarios below ----------------------------------------

# Serve ROOT on its own port; sets SRV_PID, SRV_PORT, SRV_URL.
start_srv() {
    local _info
    _info=$(server_start "$1" "$2")
    SRV_PID="${_info% *}"
    SRV_PORT="${_info#* }"
    SRV_URL="https://127.0.0.1:${SRV_PORT}"
}

# A fresh TMPDIR for one run, so a leaked temp path shows up as a file in it.
fresh_tmpdir() {
    TD="${BATS_TEST_TMPDIR}/tmpdir"
    rm -rf "$TD"
    mkdir -p "$TD"
}

# Print the source of `fn NAME` (it closes with a column-0 brace).
extract_fn() {
    awk -v n="$1" '$0 ~ ("^fn " n " ") { p = 1 } p { print } p && /^}/ { exit }' "$INSTALL_ELV"
}

# --- Exit 5 / 6 -------------------------------------------------------------

@test "elvish: exit 5: corrupt archive fails to extract and leaves no temp dir" {
    local _t="${BATS_TEST_TMPDIR}/extract"
    server_build_fixture "$_t" >/dev/null
    local _file="ocx-${FIXTURE_TARGET}.tar.gz"
    printf 'not a real gzip archive\n' >"$_t/releases/download/v0.0.0/${_file}"
    server_write_dist "$_t" "$FIXTURE_TARGET" \
        "$(server_sha256 "$_t/releases/download/v0.0.0/${_file}")" "$_file"
    start_srv "$_t" "${BATS_TEST_TMPDIR}/e.log"
    fresh_tmpdir
    TMPDIR="$TD" OCX_INSTALL_DIST_URL="${SRV_URL}/dist.json" \
        OCX_INSTALL_MIRROR_URL="${SRV_URL}/releases/download" \
        run elvish "$INSTALL_ELV" --version 0.0.0
    server_stop "$SRV_PID"
    [ "$status" -eq 5 ]
    [ -z "$(ls -A "$TD")" ]
}

@test "elvish: exit 5: archive without an ocx binary leaves no temp dir" {
    local _t="${BATS_TEST_TMPDIR}/missing"
    mkdir -p "$_t/releases/download/v0.0.0"
    local _empty="${BATS_TEST_TMPDIR}/empty-bundle"
    mkdir -p "$_empty/ocx-${FIXTURE_TARGET}"
    printf 'README\n' >"$_empty/ocx-${FIXTURE_TARGET}/README.txt"
    local _file="ocx-${FIXTURE_TARGET}.tar.gz"
    (cd "$_empty" && tar czf "$_t/releases/download/v0.0.0/${_file}" "ocx-${FIXTURE_TARGET}")
    server_write_dist "$_t" "$FIXTURE_TARGET" \
        "$(server_sha256 "$_t/releases/download/v0.0.0/${_file}")" "$_file"
    start_srv "$_t" "${BATS_TEST_TMPDIR}/m.log"
    fresh_tmpdir
    TMPDIR="$TD" OCX_INSTALL_DIST_URL="${SRV_URL}/dist.json" \
        OCX_INSTALL_MIRROR_URL="${SRV_URL}/releases/download" \
        run elvish "$INSTALL_ELV" --version 0.0.0
    server_stop "$SRV_PID"
    [ "$status" -eq 5 ]
    [ -z "$(ls -A "$TD")" ]
}

@test "elvish: exit 6: 'ocx self setup' failure keeps the hand-off argv and leaves no temp dir" {
    local _t="${BATS_TEST_TMPDIR}/bsfail"
    mkdir -p "$_t/releases/download/v0.0.0"
    local _build="${BATS_TEST_TMPDIR}/build-bsfail/ocx-${FIXTURE_TARGET}"
    mkdir -p "$_build"
    cat >"$_build/ocx" <<'STUB'
#!/bin/sh
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
    local _file="ocx-${FIXTURE_TARGET}.tar.gz"
    (cd "${BATS_TEST_TMPDIR}/build-bsfail" && tar czf "$_t/releases/download/v0.0.0/${_file}" "ocx-${FIXTURE_TARGET}")
    server_write_dist "$_t" "$FIXTURE_TARGET" \
        "$(server_sha256 "$_t/releases/download/v0.0.0/${_file}")" "$_file"
    start_srv "$_t" "${BATS_TEST_TMPDIR}/bs.log"
    fresh_tmpdir
    TMPDIR="$TD" OCX_INSTALL_DIST_URL="${SRV_URL}/dist.json" \
        OCX_INSTALL_MIRROR_URL="${SRV_URL}/releases/download" \
        run elvish "$INSTALL_ELV" --version 0.0.0
    server_stop "$SRV_PID"
    [ "$status" -eq 6 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
    run ! grep -q -- "--remote package install" "$OCX_STUB_ARGV"
    [ -z "$(ls -A "$TD")" ]
}

# --- Temp cleanup -----------------------------------------------------------

@test "elvish: temp dir is empty after a successful install and after the idempotent fast path" {
    fresh_tmpdir
    TMPDIR="$TD" OCX_INSTALL_NO_SETUP=1 run elvish "$INSTALL_ELV" --version 0.0.0
    [ "$status" -eq 0 ]
    [ -z "$(ls -A "$TD")" ]
    # Second run takes the fast path (binary already at the requested version).
    TMPDIR="$TD" OCX_INSTALL_NO_SETUP=1 run elvish "$INSTALL_ELV" --version 0.0.0
    [ "$status" -eq 0 ]
    [ -z "$(ls -A "$TD")" ]
}

@test "elvish: temp dir is empty after a checksum mismatch (exit 4)" {
    local _t="${BATS_TEST_TMPDIR}/cksum-tmp"
    server_build_fixture "$_t" >/dev/null
    server_write_dist "$_t" "$FIXTURE_TARGET" \
        "0000000000000000000000000000000000000000000000000000000000000000" \
        "ocx-${FIXTURE_TARGET}.tar.gz"
    start_srv "$_t" "${BATS_TEST_TMPDIR}/ck-tmp.log"
    fresh_tmpdir
    TMPDIR="$TD" OCX_INSTALL_DIST_URL="${SRV_URL}/dist.json" \
        OCX_INSTALL_MIRROR_URL="${SRV_URL}/releases/download" \
        run elvish "$INSTALL_ELV" --version 0.0.0
    server_stop "$SRV_PID"
    [ "$status" -eq 4 ]
    [ -z "$(ls -A "$TD")" ]
}

@test "elvish: temp dir is empty after a pinned manifest with an altered body (exit 4)" {
    local _t="${BATS_TEST_TMPDIR}/pin-bad-tmp"
    server_build_fixture "$_t" >/dev/null
    local _sha
    _sha=$(server_publish_dist_snapshot "$_t")
    printf '\n' >>"$_t/dist/${_sha}.json"
    start_srv "$_t" "${BATS_TEST_TMPDIR}/pin-bad-tmp.log"
    fresh_tmpdir
    TMPDIR="$TD" OCX_INSTALL_DIST_URL="${SRV_URL}/dist/${_sha}.json" \
        OCX_INSTALL_MIRROR_URL="${SRV_URL}/releases/download" \
        run elvish "$INSTALL_ELV"
    server_stop "$SRV_PID"
    [ "$status" -eq 4 ]
    [ -z "$(ls -A "$TD")" ]
}

@test "elvish: temp dir is empty after an install with an inline PEM CA bundle" {
    local _copy="${BATS_TEST_TMPDIR}/install-ca.elv"
    server_embed_config "$INSTALL_ELV" "$_copy" \
        "OCX_INSTALL_CA_BUNDLE=$(server_ca_bundle_inline)"
    unset CURL_CA_BUNDLE
    fresh_tmpdir
    TMPDIR="$TD" run elvish "$_copy" --version 0.0.0
    [ "$status" -eq 0 ]
    [ -z "$(ls -A "$TD")" ]
}

# --- Integrity fails closed -------------------------------------------------

@test "elvish: no sha256 tool on PATH → exit 2, nothing is installed" {
    local _farm="${BATS_TEST_TMPDIR}/farm" _t _p
    mkdir -p "$_farm"
    for _t in curl tar xz gzip mktemp rm cp chmod sleep mkdir cat; do
        _p=$(command -v "$_t") && ln -s "$_p" "$_farm/$_t"
    done
    local _elv
    _elv=$(command -v elvish)
    OCX_INSTALL_NO_SETUP=1 PATH="$_farm" run "$_elv" "$INSTALL_ELV" --version 0.0.0
    [ "$status" -eq 2 ]
    echo "$output" | grep -q 'cannot verify'
    [ ! -e "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
}

@test "elvish: a manifest row with a blank sha256 → exit 3, nothing is installed" {
    local _t="${BATS_TEST_TMPDIR}/blank-sha"
    server_build_fixture "$_t" >/dev/null
    server_write_dist "$_t" "$FIXTURE_TARGET" "" "ocx-${FIXTURE_TARGET}.tar.gz"
    start_srv "$_t" "${BATS_TEST_TMPDIR}/blank.log"
    OCX_INSTALL_NO_SETUP=1 OCX_INSTALL_DIST_URL="${SRV_URL}/dist.json" \
        OCX_INSTALL_MIRROR_URL="${SRV_URL}/releases/download" \
        run elvish "$INSTALL_ELV" --version 0.0.0
    server_stop "$SRV_PID"
    [ "$status" -eq 3 ]
    echo "$output" | grep -q 'no valid sha256'
    [ ! -e "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
}

@test "elvish: a manifest row with NO sha256 field at all → exit 3, nothing is installed" {
    local _t="${BATS_TEST_TMPDIR}/absent-sha"
    server_build_fixture "$_t" >/dev/null
    server_write_dist "$_t" "$FIXTURE_TARGET" \
        "$(server_sha256 "$_t/releases/download/v0.0.0/ocx-${FIXTURE_TARGET}.tar.gz")" \
        "ocx-${FIXTURE_TARGET}.tar.gz"
    # Drop the key itself, not just its value: the row must carry no "sha256" at all.
    sed 's/"sha256":"[^"]*",//' "$_t/dist.json" >"$_t/dist.new"
    mv "$_t/dist.new" "$_t/dist.json"
    [ "$(grep -c sha256 "$_t/dist.json")" = 0 ]
    start_srv "$_t" "${BATS_TEST_TMPDIR}/absent.log"
    OCX_INSTALL_NO_SETUP=1 OCX_INSTALL_DIST_URL="${SRV_URL}/dist.json" \
        OCX_INSTALL_MIRROR_URL="${SRV_URL}/releases/download" \
        run elvish "$INSTALL_ELV" --version 0.0.0
    server_stop "$SRV_PID"
    [ "$status" -eq 3 ]
    echo "$output" | grep -q 'no valid sha256'
    [ ! -e "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
}

@test "elvish: a manifest row with a non-hex sha256 → exit 3" {
    local _t="${BATS_TEST_TMPDIR}/junk-sha"
    server_build_fixture "$_t" >/dev/null
    server_write_dist "$_t" "$FIXTURE_TARGET" "not-a-digest" "ocx-${FIXTURE_TARGET}.tar.gz"
    start_srv "$_t" "${BATS_TEST_TMPDIR}/junk.log"
    OCX_INSTALL_DIST_URL="${SRV_URL}/dist.json" \
        OCX_INSTALL_MIRROR_URL="${SRV_URL}/releases/download" \
        run elvish "$INSTALL_ELV" --version 0.0.0
    server_stop "$SRV_PID"
    [ "$status" -eq 3 ]
    echo "$output" | grep -q 'no valid sha256'
}

# --- https only -------------------------------------------------------------

@test "elvish: an http manifest URL is refused before any request → exit 3" {
    OCX_INSTALL_DIST_URL="http://127.0.0.1:${FIXTURE_PORT}/never-fetched/dist.json" \
        run elvish "$INSTALL_ELV" --version 0.0.0
    [ "$status" -eq 3 ]
    echo "$output" | grep -q 'non-https'
    [ "$(server_request_count "${BATS_FILE_TMPDIR}/server.log" "never-fetched")" -eq 0 ]
}

@test "elvish: an http mirror URL is refused before any request → exit 3" {
    OCX_INSTALL_MIRROR_URL="http://127.0.0.1:${FIXTURE_PORT}/never-fetched" \
        run elvish "$INSTALL_ELV" --version 0.0.0
    [ "$status" -eq 3 ]
    echo "$output" | grep -q 'non-https'
    [ "$(server_request_count "${BATS_FILE_TMPDIR}/server.log" "never-fetched")" -eq 0 ]
}

# --- Version pin ------------------------------------------------------------

@test "elvish: a pinned version is honoured when the manifest's latest is something else" {
    local _t="${BATS_TEST_TMPDIR}/decoy"
    server_build_fixture "$_t" >/dev/null
    server_write_decoy_dist "$_t"
    start_srv "$_t" "${BATS_TEST_TMPDIR}/decoy.log"
    OCX_INSTALL_DIST_URL="${SRV_URL}/dist-decoy.json" \
        OCX_INSTALL_MIRROR_URL="${SRV_URL}/releases/download" \
        run elvish "$INSTALL_ELV" --version 0.0.0
    local _pinned=$status
    # Unpinned, the same manifest resolves the decoy latest 9.9.9 (no row → 3).
    OCX_INSTALL_DIST_URL="${SRV_URL}/dist-decoy.json" \
        OCX_INSTALL_MIRROR_URL="${SRV_URL}/releases/download" \
        run elvish "$INSTALL_ELV"
    local _latest=$status
    server_stop "$SRV_PID"
    [ "$_pinned" -eq 0 ]
    [ "$_latest" -eq 3 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

# --- CI PATH export ---------------------------------------------------------

@test "elvish: GITHUB_PATH receives the bin dir" {
    local _gh="${BATS_TEST_TMPDIR}/github-path"
    GITHUB_PATH="$_gh" OCX_INSTALL_NO_SETUP=1 run elvish "$INSTALL_ELV" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "${OCX_HOME}/${BIN_SUBPATH}" "$_gh"
}

# --- Unit checks on installer functions -------------------------------------

@test "elvish: musl detection sees a loader in the lib dir and tolerates an empty one" {
    local _lib="${BATS_TEST_TMPDIR}/lib" _script="${BATS_TEST_TMPDIR}/musl.elv"
    mkdir -p "$_lib"
    {
        printf 'use str\n'
        extract_fn ocx-has-musl-loader
        # shellcheck disable=SC2016 # elvish source text: $args is for elvish, not this shell
        printf 'if (ocx-has-musl-loader $args[0]) { echo musl } else { echo gnu }\n'
    } >"$_script"
    run elvish "$_script" "$_lib"
    [ "$status" -eq 0 ]
    [ "$output" = "gnu" ]
    : >"$_lib/ld-musl-x86_64.so.1"
    run elvish "$_script" "$_lib"
    [ "$status" -eq 0 ]
    [ "$output" = "musl" ]
    run elvish "$_script" "${BATS_TEST_TMPDIR}/no-such-dir"
    [ "$status" -eq 0 ]
    [ "$output" = "gnu" ]
}

@test "elvish: the Windows certutil path yields one lowercase-able hex string" {
    local _bin="${BATS_TEST_TMPDIR}/fakebin" _script="${BATS_TEST_TMPDIR}/certutil.elv"
    local _hash="ABCDEF0123456789abcdef0123456789ABCDEF0123456789abcdef0123456789"
    local _want="abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
    mkdir -p "$_bin"
    cat >"$_bin/certutil" <<'STUB'
#!/bin/sh
# Mimic certutil -hashfile: CRLF lines, the digest alone on the middle one.
printf 'SHA256 hash of %s:\r\n%s\r\nCertUtil: -hashfile command completed successfully.\r\n' "$2" "$FAKE_HASH"
STUB
    chmod +x "$_bin/certutil"
    {
        printf 'use str\nuse re\n'
        extract_fn ocx-certutil-digest
        printf 'echo (str:to-lower (ocx-certutil-digest x))\n'
    } >"$_script"
    PATH="$_bin:$PATH" FAKE_HASH="$_hash" run elvish "$_script"
    [ "$status" -eq 0 ]
    [ "$output" = "$_want" ]
    # Older certutil spaces the digest in byte pairs.
    local _spaced
    _spaced=$(printf '%s' "$_hash" | sed 's/../& /g')
    PATH="$_bin:$PATH" FAKE_HASH="$_spaced" run elvish "$_script"
    [ "$status" -eq 0 ]
    [ "$output" = "$_want" ]
}

# Windows checksum, end to end: the real ocx-verify-checksum with the platform
# forced to windows (its `$platform:os` read becomes `$fake-os`; the substitution
# is asserted so it cannot silently stop applying) and a certutil stub that
# prints genuine certutil output for the archive: CRLF lines, an UPPERCASE
# digest alone between two status lines. Main's one-pipeline re:find died here
# with an arity/type exception on every real Windows install.
_certutil_stub() {
    mkdir -p "$1"
    cat >"$1/certutil" <<'STUB'
#!/bin/sh
# certutil -hashfile FILE SHA256
printf 'SHA256 hash of %s:\r\n%s\r\nCertUtil: -hashfile command completed successfully.\r\n' "$2" "$FAKE_HASH"
STUB
    chmod +x "$1/certutil"
}

_windows_verify_script() {
    {
        printf 'use str\nuse re\nuse platform\nvar tmp-paths = []\nvar fake-os = windows\n'
        local _f
        for _f in ocx-truthy ocx-env ocx-quiet ocx-say ocx-warn ocx-cleanup ocx-err ocx-certutil-digest; do
            extract_fn "$_f"
        done
        # shellcheck disable=SC2016 # elvish source text: $platform:os / $fake-os are for elvish
        extract_fn ocx-verify-checksum | sed 's/\$platform:os/$fake-os/'
        # shellcheck disable=SC2016 # elvish source text: $args is for elvish, not this shell
        printf 'ocx-verify-checksum $args[0] $args[1]\n'
    } >"$1"
    # shellcheck disable=SC2016 # literal elvish text
    grep -q 'eq \$fake-os windows' "$1"
}

@test "elvish: Windows checksum end to end: a real certutil-format digest verifies" {
    local _bin="${BATS_TEST_TMPDIR}/winbin" _script="${BATS_TEST_TMPDIR}/winverify.elv"
    local _file="${BATS_TEST_TMPDIR}/payload.zip" _sum
    printf 'archive bytes' >"$_file"
    _sum=$(server_sha256 "$_file")
    _certutil_stub "$_bin"
    _windows_verify_script "$_script"
    PATH="$_bin:$PATH" FAKE_HASH="$(printf '%s' "$_sum" | tr 'a-f' 'A-F')" run elvish "$_script" "$_file" "$_sum"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'Checksum verified'
    # Negative control: the same stub against a wrong expected digest must fail
    # closed with 4, or the success above proves nothing.
    PATH="$_bin:$PATH" FAKE_HASH="$(printf '%s' "$_sum" | tr 'a-f' 'A-F')" \
        run elvish "$_script" "$_file" "0000000000000000000000000000000000000000000000000000000000000000"
    [ "$status" -eq 4 ]
    echo "$output" | grep -q 'checksum mismatch'
}

# ocx-detect-target itself (not a helper), run against the real host. The host
# kind is decided from evidence outside the installer: alpine-release, or ldd
# naming musl. Both arms always run; there is no skip.
_detect_target_script() {
    {
        printf 'use str\nuse os\nuse platform\nvar tmp-paths = []\n'
        local _f
        for _f in ocx-cleanup ocx-err ocx-has-musl-loader ocx-has-gnu-loader ocx-ldd-output ocx-detect-libc ocx-detect-target; do
            extract_fn "$_f"
        done
        printf 'echo (ocx-detect-target)\n'
    } >"$1"
}

# Fails (status 1, with the value on stderr) unless $1 ends in $2.
_assert_suffix() {
    case "$1" in
        *"$2") return 0 ;;
    esac
    printf 'want a value ending in %s, got: %s\n' "$2" "$1" >&2
    return 1
}

_host_is_musl() {
    [ -e /etc/alpine-release ] && return 0
    ldd --version 2>&1 | grep -qi musl
}

teardown() {
    if [ -e /etc/alpine-release.qg4-hidden ]; then
        mv /etc/alpine-release.qg4-hidden /etc/alpine-release
    fi
}

@test "elvish: ocx-detect-target reports the host libc, musl even without /etc/alpine-release" {
    local _script="${BATS_TEST_TMPDIR}/detect.elv"
    _detect_target_script "$_script"
    if [ "$(uname -s)" = Darwin ]; then
        run elvish "$_script"
        [ "$status" -eq 0 ]
        _assert_suffix "$output" -apple-darwin
    elif _host_is_musl; then
        run elvish "$_script"
        [ "$status" -eq 0 ]
        _assert_suffix "$output" -unknown-linux-musl
        # Hide the Alpine marker (the container user is root): the loader and
        # ldd must still say musl. Main's `glob` call is not an elvish builtin,
        # so without the marker it fell through to gnu.
        if [ -e /etc/alpine-release ]; then
            mv /etc/alpine-release /etc/alpine-release.qg4-hidden
        fi
        run elvish "$_script"
        [ "$status" -eq 0 ]
        _assert_suffix "$output" -unknown-linux-musl
        # And with ldd gone as well, the loader file alone decides.
        PATH="$(server_path_without ldd)" run elvish "$_script"
        [ "$status" -eq 0 ]
        _assert_suffix "$output" -unknown-linux-musl
    else
        run elvish "$_script"
        [ "$status" -eq 0 ]
        _assert_suffix "$output" -unknown-linux-gnu
        # Control: with ldd gone, the glibc loader file alone says gnu.
        PATH="$(server_path_without ldd)" run elvish "$_script"
        [ "$status" -eq 0 ]
        _assert_suffix "$output" -unknown-linux-gnu
    fi
}

# ocx-detect-libc against a synthetic root with `ocx-ldd-output` replaced by the
# FAKE_LDD text. Mirrors install.sh's order: ldd, then musl loader or
# alpine-release, then glibc loader, then exit 7.
_libc_case() {
    local _script="${BATS_TEST_TMPDIR}/libc.elv"
    {
        printf 'use str\nuse os\nuse platform\nvar tmp-paths = []\n'
        local _f
        for _f in ocx-cleanup ocx-err ocx-has-musl-loader ocx-has-gnu-loader ocx-ldd-output ocx-detect-libc; do
            extract_fn "$_f"
        done
        # shellcheck disable=SC2016 # elvish source text
        printf 'set ocx-ldd-output~ = { if (has-env FAKE_LDD) { get-env FAKE_LDD } else { put "" } }\n'
        # shellcheck disable=SC2016 # elvish source text
        printf 'echo (ocx-detect-libc $args[0])\n'
    } >"$_script"
    FAKE_LDD="$1" run elvish "$_script" "$2"
}

@test "elvish: libc detection follows install.sh's order and exits 7 when undecidable" {
    local _r="${BATS_TEST_TMPDIR}/root"
    rm -rf "$_r"
    mkdir -p "$_r/lib" "$_r/lib64" "$_r/etc"

    # 1. ldd output wins over every file.
    : >"$_r/lib64/ld-linux-x86-64.so.2"
    _libc_case "musl libc (x86_64)" "$_r"
    [ "$status" -eq 0 ]
    [ "$output" = musl ]
    rm "$_r/lib64/ld-linux-x86-64.so.2"
    : >"$_r/lib/ld-musl-x86_64.so.1"
    _libc_case "ldd (Ubuntu GLIBC 2.39-0ubuntu8) 2.39" "$_r"
    [ "$status" -eq 0 ]
    [ "$output" = gnu ]
    rm "$_r/lib/ld-musl-x86_64.so.1"

    # 2. No ldd text: alpine-release says musl.
    : >"$_r/etc/alpine-release"
    _libc_case "" "$_r"
    [ "$status" -eq 0 ]
    [ "$output" = musl ]
    rm "$_r/etc/alpine-release"

    # 3. A musl loader beats a glibc loader.
    : >"$_r/lib/ld-musl-x86_64.so.1"
    : >"$_r/lib64/ld-linux-x86-64.so.2"
    _libc_case "" "$_r"
    [ "$status" -eq 0 ]
    [ "$output" = musl ]
    rm "$_r/lib/ld-musl-x86_64.so.1" "$_r/lib64/ld-linux-x86-64.so.2"

    # 4. glibc loaders, in lib64 and in a multiarch dir.
    : >"$_r/lib64/ld-linux-x86-64.so.2"
    _libc_case "" "$_r"
    [ "$status" -eq 0 ]
    [ "$output" = gnu ]
    rm "$_r/lib64/ld-linux-x86-64.so.2"
    mkdir -p "$_r/lib/x86_64-linux-gnu"
    : >"$_r/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"
    _libc_case "" "$_r"
    [ "$status" -eq 0 ]
    [ "$output" = gnu ]
    rm "$_r/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"

    # 5. Nothing decides: exit 7, never a silent glibc guess.
    _libc_case "" "$_r"
    [ "$status" -eq 7 ]
    echo "$output" | grep -q 'cannot tell glibc from musl'
}

# --- Entry points -----------------------------------------------------------

# The one-liners from the installer header, with `curl ...` swapped for a local
# fetch command (`cat FILE`, or `false` for a failed download), so the test runs
# exactly the text users are told to paste. Prints one command per line.
_header_oneliners() {
    local _fetch="$1" _line _cmd
    while IFS= read -r _line; do
        _cmd="${_line#\#   }"
        _cmd="${_cmd%%   \#*}"
        printf '%s\n' "${_cmd/curl -fsSL https:\/\/setup.ocx.sh\/elvish/${_fetch}}"
    done < <(grep -E '^#   (curl|elvish) .*setup\.ocx\.sh/elvish' "$INSTALL_ELV")
}

# Run one header one-liner: the POSIX-shell form under sh, the in-elvish form
# under elvish (its parens would be a syntax error in sh).
_run_oneliner() {
    case "$1" in
        "elvish -c (e:"*) run elvish -c "$1" ;;
        *) run sh -c "$1" ;;
    esac
}

@test "elvish: every one-liner the header documents installs" {
    local _cmd _n=0
    while IFS= read -r _cmd; do
        rm -f "$OCX_STUB_ARGV"
        _run_oneliner "$_cmd"
        [ "$status" -eq 0 ]
        grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
        _n=$((_n + 1))
    done < <(_header_oneliners "cat $INSTALL_ELV")
    [ "$_n" -eq 2 ]
}

@test "elvish: every documented one-liner fails and installs nothing when the download fails" {
    local _cmd _n=0
    while IFS= read -r _cmd; do
        rm -f "$OCX_STUB_ARGV"
        _run_oneliner "$_cmd"
        case "$_cmd" in
            "elvish -c (e:"*) [ "$status" -eq 2 ] ;;
            *) [ "$status" -eq 3 ] ;;
        esac
        [ ! -f "$OCX_STUB_ARGV" ]
        _n=$((_n + 1))
    done < <(_header_oneliners "false")
    [ "$_n" -eq 2 ]
}

@test "elvish: a bare 'curl | elvish' installs nothing (elvish reads stdin as a REPL)" {
    run sh -c 'cat "$1" | elvish' _ "$INSTALL_ELV"
    # elvish treats stdin as a REPL: it reports parse errors and still exits 0.
    [ "$status" -eq 0 ]
    [ ! -f "$OCX_STUB_ARGV" ]
}

@test "elvish: the installer is pure ASCII and declares kind, exit table and floor" {
    LC_ALL=C run ! grep -n '[^[:print:][:space:]]' "$INSTALL_ELV"
    head -n 8 "$INSTALL_ELV" | grep -qx '# Kind: INST'
    head -n 8 "$INSTALL_ELV" | grep -q '^# Exit: 0 '
    head -n 8 "$INSTALL_ELV" | grep -q '^# elvish-floor: 0\.20\.1'
}

# --- curl flags are probed; openssl is an accepted SHA-256 tool --------------

@test "elvish: --tlsv1.2 is sent only when curl --help all lists it" {
    local _bin="${BATS_TEST_TMPDIR}/fakebin" _log="${BATS_TEST_TMPDIR}/fetch.log"
    server_fake_curl "$_bin"
    FAKE_CURL_LOG="$_log" PATH="$_bin:$PATH" run elvish "$INSTALL_ELV" --version 0.0.0
    [ "$status" -eq 0 ]
    [ "$(grep -c -e "--proto =https" "$_log")" -eq 2 ]
    [ "$(grep -c -e "--tlsv1.2" "$_log" || true)" -eq 0 ]
    : >"$_log"
    FAKE_CURL_TLS12=1 FAKE_CURL_LOG="$_log" PATH="$_bin:$PATH" run elvish "$INSTALL_ELV" --version 0.0.0
    [ "$status" -eq 0 ]
    [ "$(grep -c -e "--tlsv1.2" "$_log")" -eq 2 ]
}

@test "elvish: only openssl on PATH: the archive is still verified (installs)" {
    command -v openssl >/dev/null
    PATH="$(server_path_without sha256sum shasum)" run elvish "$INSTALL_ELV" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "elvish: only openssl on PATH: a swapped archive digest -> exit 4 (negative control)" {
    command -v openssl >/dev/null
    local _t="${BATS_TEST_TMPDIR}/ossl-ck"
    server_build_fixture "$_t" >/dev/null
    server_write_dist "$_t" "$FIXTURE_TARGET" \
        "0000000000000000000000000000000000000000000000000000000000000000" \
        "ocx-${FIXTURE_TARGET}.tar.gz"
    start_srv "$_t" "${BATS_TEST_TMPDIR}/ossl-ck.log"
    PATH="$(server_path_without sha256sum shasum)" \
    OCX_INSTALL_DIST_URL="${SRV_URL}/dist.json" \
    OCX_INSTALL_MIRROR_URL="${SRV_URL}/releases/download" \
        run elvish "$INSTALL_ELV" --version 0.0.0
    server_stop "$SRV_PID"
    [ "$status" -eq 4 ]
}
