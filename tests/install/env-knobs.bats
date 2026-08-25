#!/usr/bin/env bats
# Bats tests for src/install.sh env-var knobs and the thin `ocx self setup`
# hand-off. Requires: bats-core >= 1.5, python3, tar, sha256sum or shasum.

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
    # The fixture server speaks HTTPS (the installer enforces TLS). Trust the
    # vendored localhost test cert via CURL_CA_BUNDLE.
    export CURL_CA_BUNDLE
    CURL_CA_BUNDLE="$(server_ca_bundle)"
    # Record every fixture-stub invocation so tests can assert the exact
    # `ocx self setup` hand-off argv.
    export OCX_STUB_ARGV="${BATS_TEST_TMPDIR}/stub-argv.log"
    # Record the SSL_CERT_FILE the installer hands down to `ocx self setup`.
    export OCX_STUB_ENV="${BATS_TEST_TMPDIR}/stub-env.log"
    # The installer resolves latest + the per-target checksum/URL from the
    # self-hosted dist.json. The dist.json `url` is a dummy; OCX_INSTALL_MIRROR_URL
    # rewrites the download host to the fixture server.
    export OCX_INSTALL_DIST_URL="${FIXTURE_URL}/dist.json"
    export OCX_INSTALL_MIRROR_URL="${FIXTURE_URL}/releases/download"
    unset GITHUB_PATH
    unset OCX_INSTALL_NO_SETUP OCX_INSTALL_VERSION
    unset __OCX_TESTING_INSTALL_BINARY
    unset OCX_INSTALL_CA_BUNDLE OCX_MANAGED_CONFIG SSL_CERT_FILE SSL_CERT_DIR
}

@test "default install hands off to 'ocx self setup <version>'" {
    run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    # The hand-off MUST be `ocx self setup 0.0.0 --no-modify-path` (version is a
    # positional to `self setup`; OCX_NO_MODIFY_PATH=1 adds the flag).
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
    # The obsolete bootstrap command must NOT appear.
    ! grep -q -- "--remote package install" "$OCX_STUB_ARGV"
    ! grep -q -- "--remote install" "$OCX_STUB_ARGV"
}

@test "OCX_INSTALL_VERSION pins the version (no flag)" {
    OCX_INSTALL_VERSION=0.0.0 run sh "$INSTALL_SH"
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "OCX_INSTALL_NO_SETUP places the binary and skips 'ocx self setup'" {
    OCX_INSTALL_NO_SETUP=1 run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    # Binary on PATH at the canonical location.
    [ -x "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
    # No `self setup` hand-off recorded.
    [ ! -f "$OCX_STUB_ARGV" ] || ! grep -q -- "self setup" "$OCX_STUB_ARGV"
    # The thin installer never writes env shims (ocx self setup owns those).
    [ ! -f "${OCX_HOME}/env.sh" ]
}

@test "OCX_INSTALL_PRINT_PATH=1 emits bin dir as final stdout line" {
    OCX_INSTALL_PRINT_PATH=1 OCX_INSTALL_QUIET=1 run --separate-stderr sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [ "${lines[${#lines[@]}-1]}" = "${OCX_HOME}/${BIN_SUBPATH}" ]
}

@test "OCX_INSTALL_QUIET=1 suppresses stderr informational logs" {
    OCX_INSTALL_QUIET=1 run --separate-stderr sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    ! echo "$stderr" | grep -q 'Detected platform' || false
}

@test "stderr discipline: stdout is empty on success without PRINT_PATH" {
    run --separate-stderr sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [ -z "$stdout" ]
}

@test "url passthrough: dist.json url is used when no mirror override" {
    # Finalize a per-test fixture's dist.json url to the real fixture server and
    # drop OCX_INSTALL_MIRROR_URL, proving the manifest url drives the download.
    local _t="${BATS_TEST_TMPDIR}/passthrough"
    server_build_fixture "$_t" >/dev/null
    local _info _pid _port
    _info=$(server_start "$_t" "${BATS_TEST_TMPDIR}/pt.log")
    _pid="${_info% *}"
    _port="${_info#* }"
    server_finalize_dist_url "$_t" "https://127.0.0.1:${_port}/releases/download"
    OCX_INSTALL_DIST_URL="https://127.0.0.1:${_port}/dist.json" \
        OCX_INSTALL_MIRROR_URL="" \
        OCX_INSTALL_NO_SETUP=1 \
        run sh "$INSTALL_SH" --version 0.0.0
    server_stop "$_pid"
    [ "$status" -eq 0 ]
    [ -x "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
}

@test "pinned manifest: dist/<sha256>.json installs and is digest-verified" {
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
        run sh "$INSTALL_SH"
    server_stop "$_pid"
    [ "$status" -eq 0 ]
    [ -x "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
}

@test "pinned manifest: altered body → exit 4" {
    # The mirror serves a manifest that does not hash to the digest in its own
    # URL. Unverified this would install whatever that manifest named.
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
        run sh "$INSTALL_SH"
    server_stop "$_pid"
    [ "$status" -eq 4 ]
}

@test "no row for the (version,target) → exit 3" {
    # dist.json has only 0.0.0; request a version with no manifest row.
    run sh "$INSTALL_SH" --version 9.9.9
    [ "$status" -eq 3 ]
}

@test "checksum mismatch → exit code 4" {
    local _t="${BATS_TEST_TMPDIR}/cksum"
    server_build_fixture "$_t" >/dev/null
    # Tamper the inline sha256 (archive bytes stay valid) so the download fails
    # verification rather than extraction.
    server_write_dist "$_t" "$FIXTURE_TARGET" \
        "0000000000000000000000000000000000000000000000000000000000000000" \
        "ocx-${FIXTURE_TARGET}.tar.gz"
    local _info _pid _port
    _info=$(server_start "$_t" "${BATS_TEST_TMPDIR}/ck.log")
    _pid="${_info% *}"
    _port="${_info#* }"
    OCX_INSTALL_DIST_URL="https://127.0.0.1:${_port}/dist.json" \
        OCX_INSTALL_MIRROR_URL="https://127.0.0.1:${_port}/releases/download" \
        run sh "$INSTALL_SH" --version 0.0.0
    server_stop "$_pid"
    [ "$status" -eq 4 ]
}

@test "invalid version → exit code 2" {
    run sh "$INSTALL_SH" --version "foo;rm"
    [ "$status" -eq 2 ]
}

@test "unknown flag → exit code 2" {
    run sh "$INSTALL_SH" --bogus
    [ "$status" -eq 2 ]
}

@test "OCX_INSTALL_DOWNLOADER=invalid → exit code 2" {
    OCX_INSTALL_DOWNLOADER=ftp run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 2 ]
}

@test "OCX_INSTALL_FORCE=1 reinstalls when same version is present" {
    # The idempotent fast-path keys off the binary being present at the canonical
    # bin dir, which only OCX_INSTALL_NO_SETUP populates, so this runs in
    # no-setup mode.
    OCX_INSTALL_NO_SETUP=1 sh "$INSTALL_SH" --version 0.0.0 >/dev/null 2>&1
    [ -x "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
    # Second run without FORCE is idempotent (exit 0, fast-path).
    OCX_INSTALL_NO_SETUP=1 OCX_INSTALL_PRINT_PATH=1 run --separate-stderr sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [ "${lines[${#lines[@]}-1]}" = "${OCX_HOME}/${BIN_SUBPATH}" ]
    # FORCE re-runs the full install (still exits 0).
    OCX_INSTALL_NO_SETUP=1 OCX_INSTALL_FORCE=1 run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
}

@test "flat-layout archive (binary at root) installs successfully" {
    local _flat="${BATS_TEST_TMPDIR}/flat"
    local _flat_target
    _flat_target=$(server_build_fixture "$_flat" flat)
    [ "$_flat_target" = "$FIXTURE_TARGET" ]
    local _info _pid _port
    _info=$(server_start "$_flat" "${BATS_TEST_TMPDIR}/flat.log")
    _pid="${_info% *}"
    _port="${_info#* }"
    OCX_INSTALL_NO_SETUP=1 \
        OCX_INSTALL_DIST_URL="https://127.0.0.1:${_port}/dist.json" \
        OCX_INSTALL_MIRROR_URL="https://127.0.0.1:${_port}/releases/download" \
        run sh "$INSTALL_SH" --version 0.0.0
    server_stop "$_pid"
    [ "$status" -eq 0 ]
    [ -x "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
}

@test "latest version resolves via the dist.json manifest" {
    # No --version: the installer reads dist.json and picks the first stable entry
    # (0.0.0).
    OCX_INSTALL_NO_SETUP=1 run sh "$INSTALL_SH"
    [ "$status" -eq 0 ]
    [ -x "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
}

# --- __OCX_TESTING_INSTALL_BINARY (internal test-only download-skip hatch) ---

@test "__OCX_TESTING_INSTALL_BINARY installs a local binary without downloading" {
    local _localbin="${BATS_TEST_TMPDIR}/local-ocx"
    server_stub_body >"$_localbin"
    chmod +x "$_localbin"
    __OCX_TESTING_INSTALL_BINARY="$_localbin" \
        OCX_INSTALL_DIST_URL="https://127.0.0.1:1/dead/dist.json" \
        run sh "$INSTALL_SH"
    [ "$status" -eq 0 ]
    # Binary placed + executable at the canonical bin dir.
    [ -x "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
    # Hand-off used the global --offline pre-flag (candidate present, no registry).
    grep -qxF -- "--offline self setup --no-modify-path" "$OCX_STUB_ARGV"
}

@test "__OCX_TESTING_INSTALL_BINARY + NO_SETUP places binary, no setup" {
    local _localbin="${BATS_TEST_TMPDIR}/local-ocx"
    server_stub_body >"$_localbin"
    chmod +x "$_localbin"
    __OCX_TESTING_INSTALL_BINARY="$_localbin" OCX_INSTALL_NO_SETUP=1 \
        OCX_INSTALL_PRINT_PATH=1 OCX_INSTALL_QUIET=1 \
        run --separate-stderr sh "$INSTALL_SH"
    [ "$status" -eq 0 ]
    [ "${lines[${#lines[@]}-1]}" = "${OCX_HOME}/${BIN_SUBPATH}" ]
    [ ! -f "$OCX_STUB_ARGV" ] || ! grep -q -- "self setup" "$OCX_STUB_ARGV"
}

@test "__OCX_TESTING_INSTALL_BINARY pointing at a non-file → exit 2" {
    __OCX_TESTING_INSTALL_BINARY="${BATS_TEST_TMPDIR}/does-not-exist" \
        run sh "$INSTALL_SH"
    [ "$status" -eq 2 ]
}

# --- Embedded configuration block (corporate mirrors) -----------------------

@test "embedded config: a sed-ed dist URL is used when the env is unset" {
    local _copy="${BATS_TEST_TMPDIR}/install-embedded.sh"
    server_embed_config "$INSTALL_SH" "$_copy" \
        "OCX_INSTALL_DIST_URL=${FIXTURE_URL}/dist.json" \
        "OCX_INSTALL_MIRROR_URL=${FIXTURE_URL}/releases/download"
    unset OCX_INSTALL_DIST_URL OCX_INSTALL_MIRROR_URL
    run sh "$_copy" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "embedded config: the environment wins over the embedded value" {
    local _copy="${BATS_TEST_TMPDIR}/install-embedded.sh"
    # The embedded manifest URL is dead; setup() still exports the fixture one.
    server_embed_config "$INSTALL_SH" "$_copy" \
        "OCX_INSTALL_DIST_URL=https://127.0.0.1:1/dead/dist.json"
    run sh "$_copy" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "embedded config: a managed-config ref is forwarded to 'ocx self setup'" {
    local _copy="${BATS_TEST_TMPDIR}/install-managed.sh"
    server_embed_config "$INSTALL_SH" "$_copy" \
        "OCX_MANAGED_CONFIG=registry.corp.example/ocx/managed-config:v1"
    run sh "$_copy" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path --managed-config registry.corp.example/ocx/managed-config:v1" "$OCX_STUB_ARGV"
}

@test "embedded config: OCX_MANAGED_CONFIG in the env suppresses the flag" {
    local _copy="${BATS_TEST_TMPDIR}/install-managed.sh"
    server_embed_config "$INSTALL_SH" "$_copy" \
        "OCX_MANAGED_CONFIG=registry.corp.example/ocx/managed-config:v1"
    # `ocx self setup` reads OCX_MANAGED_CONFIG itself, so the installer must not
    # override it with the embedded default.
    OCX_MANAGED_CONFIG="registry.other.example/ocx/managed-config:v2" run sh "$_copy" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
    ! grep -q -- "--managed-config" "$OCX_STUB_ARGV"
}

# --- OCX_INSTALL_CA_BUNDLE --------------------------------------------------

@test "no CA bundle: the fixture cert is rejected (negative control)" {
    # Without CURL_CA_BUNDLE nothing trusts the fixture's self-signed cert. This
    # is what makes every OCX_INSTALL_CA_BUNDLE success below meaningful.
    unset CURL_CA_BUNDLE
    run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -ne 0 ]
}

@test "OCX_INSTALL_CA_BUNDLE: a CA file path is honored for downloads" {
    # Drop the CURL_CA_BUNDLE that setup() exports: the install can only succeed
    # if the knob really reaches curl/wget.
    unset CURL_CA_BUNDLE
    OCX_INSTALL_CA_BUNDLE="$(server_ca_bundle)" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
    # Second hop: `ocx self setup` pulls the package store itself and reads the
    # host trust store via SSL_CERT_FILE. One bundle must cover both.
    grep -qxF -- "SSL_CERT_FILE=$(server_ca_bundle)" "$OCX_STUB_ENV"
}

@test "OCX_INSTALL_CA_BUNDLE: wget honors the CA bundle too" {
    server_have_gnu_wget || skip "GNU wget not installed (BusyBox wget lacks the flags)"
    unset CURL_CA_BUNDLE
    OCX_INSTALL_DOWNLOADER=wget OCX_INSTALL_CA_BUNDLE="$(server_ca_bundle)" \
        run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
    grep -qxF -- "SSL_CERT_FILE=$(server_ca_bundle)" "$OCX_STUB_ENV"
}

@test "OCX_INSTALL_CA_BUNDLE: wget with an inline PEM block" {
    server_have_gnu_wget || skip "GNU wget not installed (BusyBox wget lacks the flags)"
    local _copy="${BATS_TEST_TMPDIR}/install-ca-wget.sh"
    server_embed_config "$INSTALL_SH" "$_copy" \
        "OCX_INSTALL_CA_BUNDLE=$(server_ca_bundle_inline)"
    unset CURL_CA_BUNDLE
    OCX_INSTALL_DOWNLOADER=wget run sh "$_copy" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "no CA bundle with wget: the fixture cert is rejected (negative control)" {
    server_have_gnu_wget || skip "GNU wget not installed (BusyBox wget lacks the flags)"
    unset CURL_CA_BUNDLE
    OCX_INSTALL_DOWNLOADER=wget run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -ne 0 ]
}

@test "OCX_INSTALL_CA_BUNDLE: an existing SSL_CERT_FILE is not overridden" {
    unset CURL_CA_BUNDLE
    cp "$(server_ca_bundle)" "${BATS_TEST_TMPDIR}/preset-ca.pem"
    SSL_CERT_FILE="${BATS_TEST_TMPDIR}/preset-ca.pem" \
        OCX_INSTALL_CA_BUNDLE="$(server_ca_bundle)" \
        run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "SSL_CERT_FILE=${BATS_TEST_TMPDIR}/preset-ca.pem" "$OCX_STUB_ENV"
}

@test "OCX_INSTALL_CA_BUNDLE: an inline PEM block is materialized" {
    local _copy="${BATS_TEST_TMPDIR}/install-ca.sh"
    server_embed_config "$INSTALL_SH" "$_copy" \
        "OCX_INSTALL_CA_BUNDLE=$(server_ca_bundle_inline)"
    unset CURL_CA_BUNDLE
    run sh "$_copy" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
    # The materialized temp file is what `ocx self setup` is pointed at.
    grep -qE -- '^SSL_CERT_FILE=/.+' "$OCX_STUB_ENV"
}

@test "OCX_INSTALL_CA_BUNDLE: neither a file nor inline PEM → exit 2" {
    OCX_INSTALL_CA_BUNDLE="${BATS_TEST_TMPDIR}/no-such-ca.pem" \
        run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 2 ]
}
