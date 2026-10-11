#!/usr/bin/env bats
# Per-shell suite for src/install.fish against the shared HTTPS fixture.
# Needs fish: skips when absent unless OCX_TEST_REQUIRE_SHELLS is set (CI).

bats_require_minimum_version 1.5.0

load ../helpers/server

INSTALL_FISH="${BATS_TEST_DIRNAME}/../../../src/install.fish"
BIN_SUBPATH="symlinks/ocx.sh/ocx/cli/current/content/bin"

setup_file() {
    export FIXTURE_DIR="${BATS_FILE_TMPDIR}/srv"
    FIXTURE_TARGET=$(server_build_fixture "$FIXTURE_DIR")
    export FIXTURE_TARGET
    # No release rows: platform detection runs, then the install stops at the
    # missing (version,target) row (exit 3) on every host, whatever the stubs name.
    printf '{"schema":1,"latest":{"version":"0.0.0","channel":"stable"},"releases":[]}\n' >"$FIXTURE_DIR/dist-norows.json"
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
    server_require_shell fish
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

@test "fish: default install hands off to 'ocx self setup <version>'" {
    run fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "fish: OCX_INSTALL_VERSION pins the version" {
    OCX_INSTALL_VERSION=0.0.0 run fish "$INSTALL_FISH"
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "fish: OCX_INSTALL_NO_SETUP places the binary and skips setup" {
    OCX_INSTALL_NO_SETUP=1 run fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 0 ]
    [ -x "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
    [ ! -f "$OCX_STUB_ARGV" ] || ! grep -q -- "self setup" "$OCX_STUB_ARGV"
}

@test "fish: OCX_INSTALL_PRINT_PATH emits bin dir as final stdout line" {
    OCX_INSTALL_PRINT_PATH=1 OCX_INSTALL_QUIET=1 run --separate-stderr fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 0 ]
    [ "${lines[${#lines[@]} - 1]}" = "${OCX_HOME}/${BIN_SUBPATH}" ]
}

@test "fish: stdout silent on success without PRINT_PATH" {
    run --separate-stderr fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "fish: ocx self setup output goes to stderr, stdout stays silent" {
    run --separate-stderr fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    echo "$stderr" | grep -qF 'ocx-stub: self setup result'
}

@test "fish: with PRINT_PATH stdout is exactly the bin dir, self setup output on stderr" {
    OCX_INSTALL_PRINT_PATH=1 run --separate-stderr fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 0 ]
    [ "$output" = "${OCX_HOME}/${BIN_SUBPATH}" ]
    [ "${#lines[@]}" -eq 1 ]
    echo "$stderr" | grep -qF 'ocx-stub: self setup result'
}

@test "fish: no row for the version → exit 3" {
    run fish "$INSTALL_FISH" --version 9.9.9
    [ "$status" -eq 3 ]
}

@test "fish: checksum mismatch → exit 4" {
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
        run fish "$INSTALL_FISH" --version 0.0.0
    server_stop "$_pid"
    [ "$status" -eq 4 ]
}

@test "fish: invalid version → exit 2" {
    run fish "$INSTALL_FISH" --version "foo;rm"
    [ "$status" -eq 2 ]
}

@test "fish: __OCX_TESTING_INSTALL_BINARY records '--offline self setup'" {
    local _localbin="${BATS_TEST_TMPDIR}/local-ocx"
    server_stub_body >"$_localbin"
    chmod +x "$_localbin"
    __OCX_TESTING_INSTALL_BINARY="$_localbin" run fish "$INSTALL_FISH"
    [ "$status" -eq 0 ]
    [ -x "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
    grep -qxF -- "--offline self setup --no-modify-path" "$OCX_STUB_ARGV"
}

@test "fish: __OCX_TESTING_INSTALL_BINARY non-file → exit 2" {
    __OCX_TESTING_INSTALL_BINARY="${BATS_TEST_TMPDIR}/nope" run fish "$INSTALL_FISH"
    [ "$status" -eq 2 ]
}

@test "fish: pinned manifest dist/<sha256>.json installs and is digest-verified" {
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
        run fish "$INSTALL_FISH"
    server_stop "$_pid"
    [ "$status" -eq 0 ]
    [ -x "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
}

@test "fish: pinned manifest with an altered body → exit 4" {
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
        run fish "$INSTALL_FISH"
    server_stop "$_pid"
    [ "$status" -eq 4 ]
}

# Retry. The real incident: one CDN edge PoP answered 500 for dist.json while
# every other PoP served it fine, and a single unretried GET aborted the whole
# install with exit 3.
@test "fish: retry: a transient 500 on the manifest is retried and the install succeeds" {
    OCX_INSTALL_DIST_URL="${FIXTURE_URL}/flaky/2/dist.json" run fish "$INSTALL_FISH"
    [ "$status" -eq 0 ]
    # Two failures then a success = three GETs of that URL.
    [ "$(server_request_count "${BATS_FILE_TMPDIR}/server.log" "/flaky/2/dist.json")" -eq 3 ]
}

@test "fish: retry: exhausted attempts still exit 3, after exactly 3 tries" {
    OCX_INSTALL_DIST_URL="${FIXTURE_URL}/flaky/99/dist.json" run fish "$INSTALL_FISH"
    [ "$status" -eq 3 ]
    echo "$output" | grep -qi 'latest version'
    [ "$(server_request_count "${BATS_FILE_TMPDIR}/server.log" "/flaky/99/dist.json")" -eq 3 ]
}

@test "fish: retry: the archive download is retried too" {
    # Point the mirror at a flaky prefix so the ARCHIVE fetch (not the manifest)
    # is the one that fails twice.
    OCX_INSTALL_MIRROR_URL="${FIXTURE_URL}/flaky/2/releases/download" run fish "$INSTALL_FISH"
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

# --- Embedded configuration block (corporate mirrors) -----------------------

@test "fish: a sed-ed dist URL is used when the env is unset" {
    local _copy="${BATS_TEST_TMPDIR}/install-embedded.fish"
    server_embed_config "$INSTALL_FISH" "$_copy" \
        "OCX_INSTALL_DIST_URL=${FIXTURE_URL}/dist.json" \
        "OCX_INSTALL_MIRROR_URL=${FIXTURE_URL}/releases/download"
    unset OCX_INSTALL_DIST_URL OCX_INSTALL_MIRROR_URL
    run fish "$_copy" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "fish: the environment wins over the embedded value" {
    local _copy="${BATS_TEST_TMPDIR}/install-embedded.fish"
    # The embedded manifest URL is dead; setup() still exports the fixture one.
    server_embed_config "$INSTALL_FISH" "$_copy" \
        "OCX_INSTALL_DIST_URL=https://127.0.0.1:1/dead/dist.json"
    run fish "$_copy" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "fish: an embedded managed-config ref is forwarded to 'ocx self setup'" {
    local _copy="${BATS_TEST_TMPDIR}/install-managed.fish"
    server_embed_config "$INSTALL_FISH" "$_copy" \
        "OCX_MANAGED_CONFIG=registry.corp.example/ocx/managed-config:v1"
    run fish "$_copy" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path --managed-config registry.corp.example/ocx/managed-config:v1" "$OCX_STUB_ARGV"
}

@test "fish: OCX_INSTALL_CA_BUNDLE as an inline PEM block is materialized" {
    local _copy="${BATS_TEST_TMPDIR}/install-ca.fish"
    server_embed_config "$INSTALL_FISH" "$_copy" \
        "OCX_INSTALL_CA_BUNDLE=$(server_ca_bundle_inline)"
    # Drop the CURL_CA_BUNDLE that setup() exports: the install can only succeed
    # if the embedded PEM really reaches curl.
    unset CURL_CA_BUNDLE
    run fish "$_copy" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
    # SSL_CERT_FILE names the materialized temp file; OCX_EXTRA_CA_CERTS carries
    # the PEM text AS SUPPLIED (ocx sniffs it the same way and persists it).
    grep -qE -- '^SSL_CERT_FILE=/.+' "$OCX_STUB_ENV"
    grep -qxF -- 'OCX_EXTRA_CA_CERTS=# Corp Root CA' "$OCX_STUB_ENV"
    grep -qF -- '-----BEGIN CERTIFICATE-----' "$OCX_STUB_ENV"
}

@test "fish: OCX_INSTALL_CA_BUNDLE neither a file nor inline PEM → exit 2" {
    OCX_INSTALL_CA_BUNDLE="${BATS_TEST_TMPDIR}/no-such-ca.pem" \
        run fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 2 ]
}

@test "fish: no CA bundle - the fixture cert is rejected (negative control)" {
    # Without CURL_CA_BUNDLE nothing trusts the fixture's self-signed cert. This
    # is what makes the OCX_INSTALL_CA_BUNDLE success above meaningful.
    unset CURL_CA_BUNDLE
    run fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 3 ]
}

@test "fish: OCX_INSTALL_CA_BUNDLE is handed to 'ocx self setup' as OCX_EXTRA_CA_CERTS + SSL_CERT_FILE" {
    unset CURL_CA_BUNDLE
    OCX_INSTALL_CA_BUNDLE="$(server_ca_bundle)" run fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 0 ]
    # Second hop: `ocx self setup` pulls the package store itself. One bundle
    # must cover both: OCX_EXTRA_CA_CERTS (persisted, every OS) as supplied, and
    # SSL_CERT_FILE for an older ocx (Linux only).
    grep -qxF -- "OCX_EXTRA_CA_CERTS=$(server_ca_bundle)" "$OCX_STUB_ENV"
    grep -qxF -- "SSL_CERT_FILE=$(server_ca_bundle)" "$OCX_STUB_ENV"
}

@test "fish: OCX_INSTALL_CA_BUNDLE reaches the wget fallback" {
    server_have_gnu_wget || skip "GNU wget not installed (BusyBox wget lacks the flags)"
    # install.fish picks curl when present; make it genuinely unreachable so the
    # wget branch (and its --ca-certificate) is the one under test.
    unset CURL_CA_BUNDLE
    PATH="$(server_path_without_curl)" OCX_INSTALL_CA_BUNDLE="$(server_ca_bundle)" \
        run fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

# --- Helpers for the contract tests below -------------------------------------

# _serve ROOT NAME: serve a fixture tree under ROOT; sets _SRV_PID and _SRV_URL.
_serve() {
    local _info
    _info=$(server_start "$1" "${BATS_TEST_TMPDIR}/$2.log")
    _SRV_PID="${_info% *}"
    _SRV_URL="https://127.0.0.1:${_info#* }"
}

# _tmpdir: an empty TMPDIR that the installer must leave empty again.
_tmpdir() {
    mkdir -p "${BATS_TEST_TMPDIR}/tmp"
    printf '%s' "${BATS_TEST_TMPDIR}/tmp"
}

# _publish_archive ROOT ARCHIVE: write a manifest whose sha256 matches ARCHIVE.
_publish_archive() {
    local _sum
    _sum=$(server_sha256 "$2")
    server_write_dist "$1" "$FIXTURE_TARGET" "$_sum" "ocx-${FIXTURE_TARGET}.tar.gz"
}

@test "fish: exit 5 on a corrupt archive whose checksum is valid" {
    local _t="${BATS_TEST_TMPDIR}/corrupt"
    server_build_fixture "$_t" >/dev/null
    local _a="$_t/releases/download/v0.0.0/ocx-${FIXTURE_TARGET}.tar.gz"
    printf 'not a real archive\n' >"$_a"
    _publish_archive "$_t" "$_a"
    _serve "$_t" corrupt
    OCX_INSTALL_DIST_URL="${_SRV_URL}/dist.json" OCX_INSTALL_MIRROR_URL="${_SRV_URL}/releases/download" \
        run fish "$INSTALL_FISH" --version 0.0.0
    server_stop "$_SRV_PID"
    [ "$status" -eq 5 ]
}

@test "fish: exit 5 when the archive holds no ocx binary" {
    local _t="${BATS_TEST_TMPDIR}/nobin"
    mkdir -p "$_t/releases/download/v0.0.0" "${BATS_TEST_TMPDIR}/empty-bundle/ocx-${FIXTURE_TARGET}"
    printf 'README\n' >"${BATS_TEST_TMPDIR}/empty-bundle/ocx-${FIXTURE_TARGET}/README.txt"
    local _a="$_t/releases/download/v0.0.0/ocx-${FIXTURE_TARGET}.tar.gz"
    (cd "${BATS_TEST_TMPDIR}/empty-bundle" && tar czf "$_a" "ocx-${FIXTURE_TARGET}")
    _publish_archive "$_t" "$_a"
    _serve "$_t" nobin
    OCX_INSTALL_DIST_URL="${_SRV_URL}/dist.json" OCX_INSTALL_MIRROR_URL="${_SRV_URL}/releases/download" \
        TMPDIR="$(_tmpdir)" run fish "$INSTALL_FISH" --version 0.0.0
    server_stop "$_SRV_PID"
    [ "$status" -eq 5 ]
    [ -z "$(ls -A "${BATS_TEST_TMPDIR}/tmp")" ]
}

@test "fish: exit 6 when 'ocx self setup' fails, after the recorded hand-off argv" {
    local _t="${BATS_TEST_TMPDIR}/setupfail" _b="${BATS_TEST_TMPDIR}/build-setupfail/ocx-${FIXTURE_TARGET}"
    mkdir -p "$_t/releases/download/v0.0.0" "$_b"
    cat >"$_b/ocx" <<'STUB'
#!/bin/sh
[ -n "${OCX_STUB_ARGV:-}" ] && printf '%s\n' "$*" >>"$OCX_STUB_ARGV"
case "$1" in
    version) echo 0.0.0 ;;
    self) echo "stub self setup failure" >&2; exit 9 ;;
esac
STUB
    chmod +x "$_b/ocx"
    local _a="$_t/releases/download/v0.0.0/ocx-${FIXTURE_TARGET}.tar.gz"
    (cd "${BATS_TEST_TMPDIR}/build-setupfail" && tar czf "$_a" "ocx-${FIXTURE_TARGET}")
    _publish_archive "$_t" "$_a"
    _serve "$_t" setupfail
    OCX_INSTALL_DIST_URL="${_SRV_URL}/dist.json" OCX_INSTALL_MIRROR_URL="${_SRV_URL}/releases/download" \
        TMPDIR="$(_tmpdir)" run fish "$INSTALL_FISH" --version 0.0.0
    server_stop "$_SRV_PID"
    [ "$status" -eq 6 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
    [ -z "$(ls -A "${BATS_TEST_TMPDIR}/tmp")" ]
}

@test "fish: an explicit pin is honoured even when the manifest's latest is another version" {
    server_write_decoy_dist "$FIXTURE_DIR"
    OCX_INSTALL_DIST_URL="${FIXTURE_URL}/dist-decoy.json" OCX_INSTALL_VERSION=0.0.0 run fish "$INSTALL_FISH"
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "fish: --version wins over the decoy latest in the manifest" {
    server_write_decoy_dist "$FIXTURE_DIR"
    OCX_INSTALL_DIST_URL="${FIXTURE_URL}/dist-decoy.json" run fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "fish: without a pin the decoy latest is resolved and has no row for this target (exit 3)" {
    server_write_decoy_dist "$FIXTURE_DIR"
    OCX_INSTALL_DIST_URL="${FIXTURE_URL}/dist-decoy.json" run fish "$INSTALL_FISH"
    [ "$status" -eq 3 ]
}

@test "fish: GITHUB_PATH receives the bin dir" {
    GITHUB_PATH="${BATS_TEST_TMPDIR}/github-path" run fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "${OCX_HOME}/${BIN_SUBPATH}" "${BATS_TEST_TMPDIR}/github-path"
}

@test "fish: an OCX_HOME containing a space takes the idempotent fast path" {
    export OCX_HOME="${BATS_TEST_TMPDIR}/my home/.ocx"
    OCX_INSTALL_NO_SETUP=1 run fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 0 ]
    OCX_INSTALL_NO_SETUP=1 run fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]] || false
    [[ "$output" != *"Unknown command"* ]]
}

@test "fish: the temp dir is empty after a successful install" {
    TMPDIR="$(_tmpdir)" run fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 0 ]
    [ -z "$(ls -A "${BATS_TEST_TMPDIR}/tmp")" ]
}

@test "fish: the temp dir is empty after the idempotent fast path" {
    OCX_INSTALL_NO_SETUP=1 run fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 0 ]
    OCX_INSTALL_NO_SETUP=1 TMPDIR="$(_tmpdir)" run fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]] || false
    [ -z "$(ls -A "${BATS_TEST_TMPDIR}/tmp")" ]
}

@test "fish: the temp dir is empty after a checksum mismatch (exit 4)" {
    local _t="${BATS_TEST_TMPDIR}/cksum-tmp"
    server_build_fixture "$_t" >/dev/null
    server_write_dist "$_t" "$FIXTURE_TARGET" \
        "0000000000000000000000000000000000000000000000000000000000000000" "ocx-${FIXTURE_TARGET}.tar.gz"
    _serve "$_t" cksum-tmp
    OCX_INSTALL_DIST_URL="${_SRV_URL}/dist.json" OCX_INSTALL_MIRROR_URL="${_SRV_URL}/releases/download" \
        TMPDIR="$(_tmpdir)" run fish "$INSTALL_FISH" --version 0.0.0
    server_stop "$_SRV_PID"
    [ "$status" -eq 4 ]
    [ -z "$(ls -A "${BATS_TEST_TMPDIR}/tmp")" ]
}

@test "fish: the temp dir is empty after a pinned manifest with an altered body (exit 4)" {
    local _t="${BATS_TEST_TMPDIR}/pin-tmp" _sha
    server_build_fixture "$_t" >/dev/null
    _sha=$(server_publish_dist_snapshot "$_t")
    printf '\n' >>"$_t/dist/${_sha}.json"
    _serve "$_t" pin-tmp
    OCX_INSTALL_DIST_URL="${_SRV_URL}/dist/${_sha}.json" OCX_INSTALL_MIRROR_URL="${_SRV_URL}/releases/download" \
        TMPDIR="$(_tmpdir)" run fish "$INSTALL_FISH"
    server_stop "$_SRV_PID"
    [ "$status" -eq 4 ]
    [ -z "$(ls -A "${BATS_TEST_TMPDIR}/tmp")" ]
}

@test "fish: SIGTERM mid-install exits 143 and removes the temp files" {
    local _tmp _i _rc=0
    _tmp="$(_tmpdir)"
    TMPDIR="$_tmp" OCX_INSTALL_DIST_URL="${FIXTURE_URL}/flaky/98/dist.json" \
        fish "$INSTALL_FISH" --version 0.0.0 >"${BATS_TEST_TMPDIR}/sig.out" 2>&1 3>&- &
    local _pid=$!
    # The first failed attempt means the manifest temp file exists and fish is
    # inside the retry sleep.
    for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        if [ "$(server_request_count "${BATS_FILE_TMPDIR}/server.log" "/flaky/98/dist.json")" -ge 1 ]; then break; fi
        sleep 0.25
    done
    kill -TERM "$_pid"
    wait "$_pid" || _rc=$?
    [ "$_rc" -eq 143 ]
    [ -z "$(ls -A "$_tmp")" ]
    # It died on the signal: no third attempt, no exit 3.
    [ "$(server_request_count "${BATS_FILE_TMPDIR}/server.log" "/flaky/98/dist.json")" -lt 3 ]
}

# --- Integrity fails closed ---------------------------------------------------

@test "fish: a manifest row with a blank sha256 exits 3 and installs nothing" {
    local _t="${BATS_TEST_TMPDIR}/blank-sha"
    server_build_fixture "$_t" >/dev/null
    server_write_dist "$_t" "$FIXTURE_TARGET" "" "ocx-${FIXTURE_TARGET}.tar.gz"
    _serve "$_t" blank-sha
    OCX_INSTALL_DIST_URL="${_SRV_URL}/dist.json" OCX_INSTALL_MIRROR_URL="${_SRV_URL}/releases/download" \
        run fish "$INSTALL_FISH" --version 0.0.0
    server_stop "$_SRV_PID"
    [ "$status" -eq 3 ]
    [[ "$output" == *"no valid sha256"* ]] || false
    [ ! -f "$OCX_STUB_ARGV" ]
}

@test "fish: no sha256 tool on PATH exits 2 and installs nothing" {
    PATH="$(server_path_without sha256sum shasum openssl)" run fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 2 ]
    [[ "$output" == *"sha256sum"* ]] || false
    [ ! -f "$OCX_STUB_ARGV" ]
}

# --- Transport: https only, on every backend ------------------------------------

@test "fish: a non-https manifest URL is refused with exit 3 before any request (wget backend)" {
    PATH="$(server_path_without_curl)" OCX_INSTALL_DIST_URL="http://127.0.0.1:1/dist.json" \
        run fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 3 ]
    [[ "$output" == *"non-https"* ]]
}

@test "fish: a non-https manifest URL is refused with exit 3 before any request (curl backend)" {
    OCX_INSTALL_DIST_URL="http://127.0.0.1:1/dist.json" run fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 3 ]
    [[ "$output" == *"non-https"* ]]
}

@test "fish: a non-https mirror URL is refused with exit 3" {
    OCX_INSTALL_MIRROR_URL="http://127.0.0.1:1/releases/download" run fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 3 ]
    [[ "$output" == *"non-https"* ]]
}

# --- Flag probes: only pass what the installed downloader lists -----------------

# _stub_downloader NAME: a PATH dir whose wget behaves like BusyBox's (rejects
# --https-only, --secure-protocol, --ca-certificate) or whose curl lacks
# --tlsv1.2; either delegates the actual transfer to the real curl.
_stub_downloader() {
    local _dir="${BATS_TEST_TMPDIR}/stub-$1" _real
    _real="$(command -v curl)"
    mkdir -p "$_dir"
    if [ "$1" = wget ]; then
        cat >"$_dir/wget" <<STUB
#!/bin/sh
case "\$1" in --help) echo "BusyBox v1.37.0 multi-call binary."; echo "Usage: wget [-qc] [-O FILE] URL"; exit 0 ;; esac
out=; url=
while [ \$# -gt 0 ]; do
    case "\$1" in
        --https-only | --secure-protocol* | --ca-certificate*) echo "wget: unrecognized option: \$1" >&2; exit 1 ;;
        -O) out="\$2"; shift ;;
        -q) ;;
        *) url="\$1" ;;
    esac
    shift
done
exec "$_real" -fsSL -o "\$out" "\$url"
STUB
    else
        cat >"$_dir/curl" <<STUB
#!/bin/sh
case "\$1" in --help) echo "Usage: curl [options...] <url>"; echo " --proto <protocols>"; exit 0 ;; esac
for a in "\$@"; do
    if [ "\$a" = --tlsv1.2 ]; then echo "curl: option --tlsv1.2: is unknown" >&2; exit 2; fi
done
exec "$_real" "\$@"
STUB
    fi
    chmod +x "$_dir/$1"
    printf '%s' "$_dir"
}

@test "fish: a BusyBox-style wget (no --https-only, --secure-protocol) still installs" {
    local _stub
    _stub="$(_stub_downloader wget)"
    PATH="${_stub}:$(server_path_without_curl)" run fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "fish: OCX_INSTALL_CA_BUNDLE with a wget that lacks --ca-certificate exits 2" {
    local _stub
    _stub="$(_stub_downloader wget)"
    unset CURL_CA_BUNDLE
    PATH="${_stub}:$(server_path_without_curl)" OCX_INSTALL_CA_BUNDLE="$(server_ca_bundle)" \
        run fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 2 ]
    [[ "$output" == *"--ca-certificate"* ]]
}

@test "fish: a curl without --tlsv1.2 still installs" {
    local _stub
    _stub="$(_stub_downloader curl)"
    PATH="${_stub}:${PATH}" run fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "fish: the installer source is pure ASCII" {
    run env LC_ALL=C grep -n '[^[:print:][:space:]]' "$INSTALL_FISH"
    [ "$status" -eq 1 ]
}

@test "fish: the header carries the Kind, Exit and floor lines" {
    head -n 8 "$INSTALL_FISH" | grep -q '^# Kind: INST'
    head -n 8 "$INSTALL_FISH" | grep -q '^# Exit: .*129.*130.*143'
    head -n 8 "$INSTALL_FISH" | grep -q 'fish 3\.6\.0'
}

# --- openssl is an accepted SHA-256 tool (same set as install.sh) ------------------

@test "fish: only openssl on PATH: the archive is still verified (installs)" {
    command -v openssl >/dev/null 2>&1 || skip "openssl not installed"
    PATH="$(server_path_without sha256sum shasum)" run fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "fish: only openssl on PATH: a swapped archive digest -> exit 4 (negative control)" {
    command -v openssl >/dev/null 2>&1 || skip "openssl not installed"
    local _t="${BATS_TEST_TMPDIR}/ossl-ck" _info _pid _port
    server_build_fixture "$_t" >/dev/null
    server_write_dist "$_t" "$FIXTURE_TARGET" \
        "0000000000000000000000000000000000000000000000000000000000000000" \
        "ocx-${FIXTURE_TARGET}.tar.gz"
    _info=$(server_start "$_t" "${BATS_TEST_TMPDIR}/ossl-ck.log")
    _pid="${_info% *}"
    _port="${_info#* }"
    PATH="$(server_path_without sha256sum shasum)" \
    OCX_INSTALL_DIST_URL="https://127.0.0.1:${_port}/dist.json" \
    OCX_INSTALL_MIRROR_URL="https://127.0.0.1:${_port}/releases/download" \
        run fish "$INSTALL_FISH" --version 0.0.0
    server_stop "$_pid"
    [ "$status" -eq 4 ]
}

# --- Signals: exact statuses, every handler ----------------------------------------

# _signal_hang SIG STATUS: signal the whole process group (what a terminal does)
# while a fake curl blocks the manifest fetch, which runs inside an `if`
# condition. fish demotes an `exit` there to status 0, so this is the path that
# proves the status is delivered from normal flow. The temp dir must end empty.
_signal_hang() {
    local _tmp _bin="${BATS_TEST_TMPDIR}/hangbin" _mark="${BATS_TEST_TMPDIR}/hang.log" _rc
    _tmp="$(_tmpdir)"
    server_fake_curl "$_bin"
    _rc=$(FAKE_CURL_HANG=1 FAKE_CURL_LOG="$_mark" TMPDIR="$_tmp" PATH="$_bin:$PATH" \
        server_signal_run "$1" "$_mark" fish "$INSTALL_FISH" --version 0.0.0)
    [ "$_rc" = "$2" ]
    [ -z "$(ls -A "$_tmp")" ]
}

# The statuses hold on every fish from the 3.6.0 floor to current: the handlers
# only record the signal and the exit happens from normal flow.
@test "fish: SIGINT mid-download exits 130 and removes the temp files" {
    _signal_hang INT 130
}

@test "fish: SIGHUP mid-download exits 129 and removes the temp files" {
    _signal_hang HUP 129
}

@test "fish: SIGTERM mid-download exits 143 and removes the temp files" {
    _signal_hang TERM 143
}

# --- Integrity: an absent sha256 field fails closed without reading stdin --------

# _run_idle_stdin OUTFILE CMD...: run CMD with stdin an open pipe that never
# delivers data or EOF (CI, ssh without -n); echo its exit status, or HANG after
# 20s. A `string match` handed an empty list reads stdin and blocks right here.
_run_idle_stdin() {
    python3 - "$@" <<'PY'
import subprocess, sys

with open(sys.argv[1], "w") as out:
    p = subprocess.Popen(sys.argv[2:], stdin=subprocess.PIPE, stdout=out, stderr=subprocess.STDOUT)
    try:
        print(p.wait(timeout=20))
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()
        print("HANG")
PY
}

@test "fish: a manifest row with NO sha256 field exits 3 without reading stdin" {
    local _t="${BATS_TEST_TMPDIR}/absent-sha" _rc
    server_build_fixture "$_t" >/dev/null
    sed 's/"sha256":"[^"]*",//' "$_t/dist.json" >"$_t/dist.tmp"
    mv "$_t/dist.tmp" "$_t/dist.json"
    [ "$(grep -c sha256 "$_t/dist.json" || true)" -eq 0 ]
    _serve "$_t" absent-sha
    _rc=$(OCX_INSTALL_DIST_URL="${_SRV_URL}/dist.json" OCX_INSTALL_MIRROR_URL="${_SRV_URL}/releases/download" \
        _run_idle_stdin "${BATS_TEST_TMPDIR}/idle.out" fish "$INSTALL_FISH" --version 0.0.0)
    server_stop "$_SRV_PID"
    [ "$_rc" = 3 ]
    grep -q 'no valid sha256' "${BATS_TEST_TMPDIR}/idle.out"
    [ ! -f "$OCX_STUB_ARGV" ]
}

# --- Platform detection (fake uname / ldd / find) ---------------------------------

@test "fish: a musl ldd selects the musl target" {
    server_fake_platform "${BATS_TEST_TMPDIR}/plat" Linux x86_64 "musl libc (x86_64)
Version 1.2.5"
    PATH="${BATS_TEST_TMPDIR}/plat:$PATH" OCX_INSTALL_DIST_URL="${FIXTURE_URL}/dist-norows.json" \
        run fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 3 ]
    [[ "$output" == *"Detected platform: x86_64-unknown-linux-musl"* ]] || false
}

@test "fish: glibc ldd banners select the gnu target" {
    local _banner
    for _banner in "ldd (Debian GLIBC 2.36-9+deb12u7) 2.36" "ldd (GNU libc) 2.39" "ldd (GNU C Library) 2.39"; do
        server_fake_platform "${BATS_TEST_TMPDIR}/plat" Linux aarch64 "$_banner"
        PATH="${BATS_TEST_TMPDIR}/plat:$PATH" OCX_INSTALL_DIST_URL="${FIXTURE_URL}/dist-norows.json" \
            run fish "$INSTALL_FISH" --version 0.0.0
        [ "$status" -eq 3 ]
        [[ "$output" == *"Detected platform: aarch64-unknown-linux-gnu"* ]] || false
    done
}

# No ldd banner and no loader file `find` can see: install.sh exits 7 rather than
# guess glibc. /etc/alpine-release is read directly, so on an Alpine host that
# evidence legitimately decides musl instead.
@test "fish: no libc evidence on the host exits 7 instead of guessing glibc" {
    server_fake_platform "${BATS_TEST_TMPDIR}/plat" Linux x86_64 "ldd: not a dynamic executable"
    printf '#!/bin/sh\nexit 0\n' >"${BATS_TEST_TMPDIR}/plat/find"
    chmod +x "${BATS_TEST_TMPDIR}/plat/find"
    PATH="${BATS_TEST_TMPDIR}/plat:$PATH" OCX_INSTALL_DIST_URL="${FIXTURE_URL}/dist-norows.json" \
        run fish "$INSTALL_FISH" --version 0.0.0
    if [ -e /etc/alpine-release ]; then
        [ "$status" -eq 3 ]
        [[ "$output" == *"Detected platform: x86_64-unknown-linux-musl"* ]] || false
    else
        [ "$status" -eq 7 ]
        [[ "$output" == *"cannot tell glibc from musl"* ]] || false
    fi
}

@test "fish: exit 7 on an unsupported architecture" {
    server_fake_platform "${BATS_TEST_TMPDIR}/plat" Linux riscv64
    PATH="${BATS_TEST_TMPDIR}/plat:$PATH" run fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 7 ]
    [[ "$output" == *"unsupported architecture: riscv64"* ]] || false
}

@test "fish: exit 7 on an unsupported operating system" {
    server_fake_platform "${BATS_TEST_TMPDIR}/plat" FreeBSD x86_64
    PATH="${BATS_TEST_TMPDIR}/plat:$PATH" run fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 7 ]
    [[ "$output" == *"unsupported operating system: FreeBSD"* ]] || false
}

# --- BusyBox wget (same contract as install.sh) ------------------------------------

# Fake wget that rejects every option outside -q/-O the way BusyBox does and
# fetches through the real curl; curl itself is hidden so wget is the fallback.
_busybox_path() {
    server_fake_busybox_wget "${BATS_TEST_TMPDIR}/bbbin"
    printf '%s' "${BATS_TEST_TMPDIR}/bbbin:$(server_path_without curl wget)"
}

@test "fish: BusyBox wget installs with only the BusyBox option set, and warns once" {
    local _log="${BATS_TEST_TMPDIR}/wget.log"
    FAKE_WGET_LOG="$_log" PATH="$(_busybox_path)" run fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c 'BusyBox wget:')" -eq 1 ]
    [ "$(grep -c '^-q -O ' "$_log")" -eq 2 ]
    [ "$(grep -c -e ' --[a-z]' "$_log" || true)" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "fish: BusyBox wget without certificate validation refuses an unpinned manifest (exit 4)" {
    local _log="${BATS_TEST_TMPDIR}/wget.log"
    FAKE_WGET_UNVALIDATED=1 FAKE_WGET_LOG="$_log" PATH="$(_busybox_path)" \
        run fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 4 ]
    [[ "$output" == *"did not validate the TLS certificate"* ]] || false
    # Refused on the manifest: the archive was never requested.
    [ "$(grep -c . "$_log")" -eq 1 ]
    [ ! -f "$OCX_STUB_ARGV" ]
}

@test "fish: BusyBox wget without certificate validation still installs from a pinned manifest" {
    local _sha
    _sha=$(server_publish_dist_snapshot "$FIXTURE_DIR")
    FAKE_WGET_UNVALIDATED=1 PATH="$(_busybox_path)" \
    OCX_INSTALL_DIST_URL="${FIXTURE_URL}/dist/${_sha}.json" run fish "$INSTALL_FISH" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

# --- Usage text: fish has no `-s` ----------------------------------------------------

@test "fish: neither the header nor --help advertises a 'fish -s' form" {
    [ "$(head -n 30 "$INSTALL_FISH" | grep -c 'fish -s' || true)" -eq 0 ]
    run fish "$INSTALL_FISH" --help
    [ "$status" -eq 0 ]
    [[ "$output" != *"fish -s"* ]] || false
    [[ "$output" == *"saved file"* ]] || false
}
