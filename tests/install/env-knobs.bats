#!/usr/bin/env bats
# Kind: TEST. Dialect: bash 3.2 under bats; runs src/install.sh on the sh of the CI leg.
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
    server_write_decoy_dist "$FIXTURE_DIR"
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
    unset OCX_INSTALL_CA_BUNDLE OCX_MANAGED_CONFIG SSL_CERT_FILE SSL_CERT_DIR OCX_EXTRA_CA_CERTS
    unset FAKE_CURL_LOG FAKE_CURL_TLS12 FAKE_CURL_HANG FAKE_WGET_LOG FAKE_WGET_UNVALIDATED OCX_STUB_ARGV_LINES
}

@test "default install hands off to 'ocx self setup <version>'" {
    run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    # The hand-off MUST be `ocx self setup 0.0.0 --no-modify-path` (version is a
    # positional to `self setup`; OCX_NO_MODIFY_PATH=1 adds the flag).
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
    # The obsolete bootstrap command must NOT appear.
    run ! grep -q -- "--remote package install" "$OCX_STUB_ARGV"
    run ! grep -q -- "--remote install" "$OCX_STUB_ARGV"
}

# The decoy manifest names 9.9.9 as latest with no row for this target, so only a
# honoured pin can install: an ignored one resolves 9.9.9 and exits 3.
@test "OCX_INSTALL_VERSION pins the version (no flag)" {
    OCX_INSTALL_DIST_URL="${FIXTURE_URL}/dist-decoy.json" OCX_INSTALL_VERSION=0.0.0 run sh "$INSTALL_SH"
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "--version pins the version against a newer latest" {
    OCX_INSTALL_DIST_URL="${FIXTURE_URL}/dist-decoy.json" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "no pin: the manifest's latest is installed (decoy 9.9.9 has no row for this target)" {
    OCX_INSTALL_DIST_URL="${FIXTURE_URL}/dist-decoy.json" run sh "$INSTALL_SH"
    [ "$status" -eq 3 ]
    [[ "$output" == *"no published artifact for ocx v9.9.9"* ]] || false
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
    [ "${lines[${#lines[@]} - 1]}" = "${OCX_HOME}/${BIN_SUBPATH}" ]
}

@test "OCX_INSTALL_QUIET=1 suppresses stderr informational logs" {
    OCX_INSTALL_QUIET=1 run --separate-stderr sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    if echo "$stderr" | grep -q 'Detected platform'; then
        false
    fi
}

@test "stderr discipline: stdout is empty on success without PRINT_PATH" {
    run --separate-stderr sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [ -z "$output" ]
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
    [ "${lines[${#lines[@]} - 1]}" = "${OCX_HOME}/${BIN_SUBPATH}" ]
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
    [ "${lines[${#lines[@]} - 1]}" = "${OCX_HOME}/${BIN_SUBPATH}" ]
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
    run ! grep -q -- "--managed-config" "$OCX_STUB_ARGV"
}

# --- OCX_INSTALL_CA_BUNDLE --------------------------------------------------

@test "no CA bundle: the fixture cert is rejected (negative control)" {
    # Without CURL_CA_BUNDLE nothing trusts the fixture's self-signed cert. This
    # is what makes every OCX_INSTALL_CA_BUNDLE success below meaningful.
    unset CURL_CA_BUNDLE
    run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 3 ]
}

@test "OCX_INSTALL_CA_BUNDLE: a CA file path is honored for downloads" {
    # Drop the CURL_CA_BUNDLE that setup() exports: the install can only succeed
    # if the knob really reaches curl/wget.
    unset CURL_CA_BUNDLE
    OCX_INSTALL_CA_BUNDLE="$(server_ca_bundle)" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
    # Second hop: `ocx self setup` pulls the package store itself. One bundle
    # must cover both: OCX_EXTRA_CA_CERTS (persisted, every OS) as supplied, and
    # SSL_CERT_FILE for an older ocx (Linux only).
    grep -qxF -- "OCX_EXTRA_CA_CERTS=$(server_ca_bundle)" "$OCX_STUB_ENV"
    grep -qxF -- "SSL_CERT_FILE=$(server_ca_bundle)" "$OCX_STUB_ENV"
}

@test "OCX_INSTALL_CA_BUNDLE: wget honors the CA bundle too" {
    server_have_gnu_wget || skip "GNU wget not installed (BusyBox wget lacks the flags)"
    unset CURL_CA_BUNDLE
    OCX_INSTALL_DOWNLOADER=wget OCX_INSTALL_CA_BUNDLE="$(server_ca_bundle)" \
        run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
    grep -qxF -- "OCX_EXTRA_CA_CERTS=$(server_ca_bundle)" "$OCX_STUB_ENV"
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
    [ "$status" -eq 3 ]
}

@test "OCX_INSTALL_CA_BUNDLE: an existing SSL_CERT_FILE / OCX_EXTRA_CA_CERTS is not overridden" {
    unset CURL_CA_BUNDLE
    cp "$(server_ca_bundle)" "${BATS_TEST_TMPDIR}/preset-ca.pem"
    SSL_CERT_FILE="${BATS_TEST_TMPDIR}/preset-ca.pem" \
        OCX_EXTRA_CA_CERTS="${BATS_TEST_TMPDIR}/preset-ca.pem" \
        OCX_INSTALL_CA_BUNDLE="$(server_ca_bundle)" \
        run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "SSL_CERT_FILE=${BATS_TEST_TMPDIR}/preset-ca.pem" "$OCX_STUB_ENV"
    grep -qxF -- "OCX_EXTRA_CA_CERTS=${BATS_TEST_TMPDIR}/preset-ca.pem" "$OCX_STUB_ENV"
}

@test "OCX_INSTALL_CA_BUNDLE: an inline PEM block is materialized" {
    local _copy="${BATS_TEST_TMPDIR}/install-ca.sh"
    server_embed_config "$INSTALL_SH" "$_copy" \
        "OCX_INSTALL_CA_BUNDLE=$(server_ca_bundle_inline)"
    unset CURL_CA_BUNDLE
    run sh "$_copy" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
    # SSL_CERT_FILE names the materialized temp file; OCX_EXTRA_CA_CERTS carries
    # the PEM text AS SUPPLIED (ocx sniffs it the same way and persists it).
    grep -qE -- '^SSL_CERT_FILE=/.+' "$OCX_STUB_ENV"
    grep -qxF -- 'OCX_EXTRA_CA_CERTS=# Corp Root CA' "$OCX_STUB_ENV"
    grep -qF -- '-----BEGIN CERTIFICATE-----' "$OCX_STUB_ENV"
}

@test "OCX_INSTALL_CA_BUNDLE: neither a file nor inline PEM → exit 2" {
    OCX_INSTALL_CA_BUNDLE="${BATS_TEST_TMPDIR}/no-such-ca.pem" \
        run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 2 ]
}

# --- GITHUB_PATH (the CI PATH hand-off setup-ocx relies on) -----------------

@test "GITHUB_PATH receives the bin dir after a default install" {
    local _gp="${BATS_TEST_TMPDIR}/github_path"
    GITHUB_PATH="$_gp" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "${OCX_HOME}/${BIN_SUBPATH}" "$_gp"
}

@test "GITHUB_PATH receives the bin dir after a NO_SETUP install" {
    local _gp="${BATS_TEST_TMPDIR}/github_path"
    GITHUB_PATH="$_gp" OCX_INSTALL_NO_SETUP=1 run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "${OCX_HOME}/${BIN_SUBPATH}" "$_gp"
}

@test "GITHUB_PATH is also written on the idempotent fast path" {
    local _gp="${BATS_TEST_TMPDIR}/github_path"
    OCX_INSTALL_NO_SETUP=1 run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    GITHUB_PATH="$_gp" OCX_INSTALL_NO_SETUP=1 run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]] || false
    grep -qxF -- "${OCX_HOME}/${BIN_SUBPATH}" "$_gp"
}

@test "an unwritable GITHUB_PATH warns and does not fail the install" {
    GITHUB_PATH="${BATS_TEST_TMPDIR}/no-such-dir/github_path" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [[ "$output" == *"failed to write to \$GITHUB_PATH"* ]] || false
}

# --- Temp files are removed on every exit -----------------------------------

@test "temp dir is empty after a successful default install" {
    local _t="${BATS_TEST_TMPDIR}/tmp"
    mkdir -p "$_t"
    TMPDIR="$_t" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [ -z "$(ls -A "$_t")" ]
}

# A guard, not a regression test: the fast path never created a temp dir, so
# this is green on the pre-hardening installer too. Its own TMPDIR keeps the
# first (full) install out of the assertion.
@test "guard: the idempotent fast path leaves its own TMPDIR empty" {
    local _t="${BATS_TEST_TMPDIR}/tmp-first" _t2="${BATS_TEST_TMPDIR}/tmp-fast"
    mkdir -p "$_t" "$_t2"
    OCX_INSTALL_NO_SETUP=1 TMPDIR="$_t" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    OCX_INSTALL_NO_SETUP=1 TMPDIR="$_t2" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]] || false
    [ -z "$(ls -A "$_t2")" ]
}

@test "temp dir is empty after a checksum failure (exit 4)" {
    local _t="${BATS_TEST_TMPDIR}/ck" _tmp="${BATS_TEST_TMPDIR}/tmp"
    mkdir -p "$_tmp"
    server_build_fixture "$_t" >/dev/null
    server_write_dist "$_t" "$FIXTURE_TARGET" \
        "0000000000000000000000000000000000000000000000000000000000000000" \
        "ocx-${FIXTURE_TARGET}.tar.gz"
    local _info _pid _port
    _info=$(server_start "$_t" "${BATS_TEST_TMPDIR}/ck.log")
    _pid="${_info% *}"
    _port="${_info#* }"
    TMPDIR="$_tmp" OCX_INSTALL_DIST_URL="https://127.0.0.1:${_port}/dist.json" \
        OCX_INSTALL_MIRROR_URL="https://127.0.0.1:${_port}/releases/download" \
        run sh "$INSTALL_SH" --version 0.0.0
    server_stop "$_pid"
    [ "$status" -eq 4 ]
    [ -z "$(ls -A "$_tmp")" ]
}

@test "temp files are empty after an install with an inline PEM CA bundle" {
    local _copy="${BATS_TEST_TMPDIR}/install-ca.sh" _t="${BATS_TEST_TMPDIR}/tmp"
    mkdir -p "$_t"
    server_embed_config "$INSTALL_SH" "$_copy" \
        "OCX_INSTALL_CA_BUNDLE=$(server_ca_bundle_inline)"
    unset CURL_CA_BUNDLE
    TMPDIR="$_t" run sh "$_copy" --version 0.0.0
    [ "$status" -eq 0 ]
    [ -z "$(ls -A "$_t")" ]
}

# --- Signals: exit 128+N, stop at once, leave nothing behind ----------------

# A fake curl records its first fetch and then blocks, so the installer is
# provably mid-download (temp dir created) when the signal lands; it answers the
# `--help all` probe without logging. A handler that merely returns lets the
# download loop retry, so exactly ONE logged fetch is the "stopped, not kept
# running" claim, asserted before the status form. SHELL... defaults to sh.
_signal_case() {
    local _sig="$1" _want="$2" _bin="${BATS_TEST_TMPDIR}/fakebin" _t="${BATS_TEST_TMPDIR}/tmp"
    local _log="${BATS_TEST_TMPDIR}/fetch.log" _rc _n
    shift 2
    [ $# -gt 0 ] || set -- sh
    rm -rf "$_t" "$_log"
    mkdir -p "$_t"
    server_fake_curl "$_bin"
    _rc=$(FAKE_CURL_HANG=1 FAKE_CURL_LOG="$_log" TMPDIR="$_t" PATH="$_bin:$PATH" \
        server_signal_run "$_sig" "$_log" "$@" "$INSTALL_SH" --version 0.0.0 2>"${BATS_TEST_TMPDIR}/sig.err")
    _n=0
    if [ -f "$_log" ]; then _n=$(grep -c . "$_log"); fi
    echo "$_sig on $*: status $_rc (want $_want), $_n fetch attempts (want 1)"
    [ "$_n" -eq 1 ]
    [ "$_rc" = "$_want" ]
    [ -z "$(ls -A "$_t")" ]
}

_signal_all() {
    _signal_case TERM 143 "$@"
    _signal_case INT 130 "$@"
    _signal_case HUP 129 "$@"
}

@test "SIGTERM mid-download: exit 143, no retry, temp dir removed" {
    _signal_case TERM 143
}

@test "SIGINT mid-download: exit 130, no retry, temp dir removed" {
    _signal_case INT 130
}

@test "SIGHUP mid-download: exit 129, no retry, temp dir removed" {
    _signal_case HUP 129
}

# The default sh above is whatever /bin/sh is (bash on some hosts); these are
# the other interpreters the installer is documented for.
@test "signals on dash: TERM, INT and HUP exit 143, 130, 129 after one fetch" {
    server_require_shell dash
    _signal_all dash
}

@test "signals on busybox ash: TERM, INT and HUP exit 143, 130, 129 after one fetch" {
    [ "$(uname -s)" != Darwin ] || skip "busybox has no macOS build (the Linux legs run it)"
    server_require_shell busybox
    _signal_all busybox sh
}

@test "signals on ksh: TERM, INT and HUP exit 143, 130, 129 after one fetch" {
    server_require_shell ksh
    _signal_all ksh
}

@test "signals on zsh: TERM, INT and HUP exit 143, 130, 129 after one fetch" {
    server_require_shell zsh
    _signal_all zsh
}

# --- Native zsh: `curl | zsh` is a documented entry point -------------------

# zsh runs an EXIT trap set inside a function when that function returns, so a
# trap bound from main made the installer exit 0 having installed nothing.
@test "zsh: the file form installs, hands off and removes its temp dir" {
    server_require_shell zsh
    local _t="${BATS_TEST_TMPDIR}/tmp"
    mkdir -p "$_t"
    TMPDIR="$_t" run zsh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
    [ -z "$(ls -A "$_t")" ]
}

@test "zsh: the piped form (curl | zsh -s) installs, hands off and removes its temp dir" {
    server_require_shell zsh
    local _t="${BATS_TEST_TMPDIR}/tmp"
    mkdir -p "$_t"
    TMPDIR="$_t" run zsh -s -- --version 0.0.0 <"$INSTALL_SH"
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
    [ -z "$(ls -A "$_t")" ]
}

# File-level traps must still fire on the other shells: a failed install exits
# non-zero and removes its temp dir (dist-norows has no row for this target).
@test "dash, busybox ash, ksh and zsh: a failed install exits 3 and removes its temp dir" {
    local _t="${BATS_TEST_TMPDIR}/tmp" _sh _shells="dash ksh zsh"
    server_require_shell dash
    server_require_shell ksh
    server_require_shell zsh
    # busybox has no macOS build; the Linux legs, which run it, require it.
    if [ "$(uname -s)" != Darwin ]; then
        server_require_shell busybox
        _shells="$_shells busybox"
    fi
    for _sh in $_shells; do
        case "$_sh" in busybox) set -- busybox sh ;; *) set -- "$_sh" ;; esac
        rm -rf "$_t"
        mkdir -p "$_t"
        TMPDIR="$_t" OCX_INSTALL_DIST_URL="${FIXTURE_URL}/dist-norows.json" run "$@" "$INSTALL_SH" --version 0.0.0
        echo "$_sh: status $status"
        [ "$status" -eq 3 ]
        [ -z "$(ls -A "$_t")" ]
    done
}

# --- Integrity fails closed -------------------------------------------------

@test "no SHA-256 tool on PATH: exit 2 before any download" {
    local _bin="${BATS_TEST_TMPDIR}/fakebin" _log="${BATS_TEST_TMPDIR}/fetch.log"
    server_fake_curl "$_bin"
    FAKE_CURL_LOG="$_log" PATH="$_bin:$(server_path_without sha256sum shasum openssl)" \
        run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 2 ]
    [[ "$output" == *"SHA-256"* ]] || false
    [ ! -e "$_log" ]
}

@test "only openssl on PATH: the archive is still verified (installs)" {
    command -v openssl >/dev/null 2>&1 || skip "openssl not installed"
    PATH="$(server_path_without sha256sum shasum)" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "only openssl on PATH: a swapped archive digest → exit 4 (negative control)" {
    command -v openssl >/dev/null 2>&1 || skip "openssl not installed"
    local _t="${BATS_TEST_TMPDIR}/ck"
    server_build_fixture "$_t" >/dev/null
    server_write_dist "$_t" "$FIXTURE_TARGET" \
        "0000000000000000000000000000000000000000000000000000000000000000" \
        "ocx-${FIXTURE_TARGET}.tar.gz"
    local _info _pid _port
    _info=$(server_start "$_t" "${BATS_TEST_TMPDIR}/ck.log")
    _pid="${_info% *}"
    _port="${_info#* }"
    PATH="$(server_path_without sha256sum shasum)" \
    OCX_INSTALL_DIST_URL="https://127.0.0.1:${_port}/dist.json" \
    OCX_INSTALL_MIRROR_URL="https://127.0.0.1:${_port}/releases/download" \
        run sh "$INSTALL_SH" --version 0.0.0
    server_stop "$_pid"
    [ "$status" -eq 4 ]
}

@test "a manifest row with a blank, short or non-hex sha256 → exit 3, nothing installed" {
    local _t="${BATS_TEST_TMPDIR}/badsha" _bad
    server_build_fixture "$_t" >/dev/null
    local _info _pid _port
    _info=$(server_start "$_t" "${BATS_TEST_TMPDIR}/badsha.log")
    _pid="${_info% *}"
    _port="${_info#* }"
    for _bad in "" "abc123" "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"; do
        server_write_dist "$_t" "$FIXTURE_TARGET" "$_bad" "ocx-${FIXTURE_TARGET}.tar.gz"
        OCX_INSTALL_DIST_URL="https://127.0.0.1:${_port}/dist.json" \
            OCX_INSTALL_MIRROR_URL="https://127.0.0.1:${_port}/releases/download" \
            OCX_INSTALL_NO_SETUP=1 run sh "$INSTALL_SH" --version 0.0.0
        if [ "$status" -ne 3 ]; then
            echo "sha256 '${_bad}': status $status, output: $output"
            server_stop "$_pid"
            false
        fi
        [[ "$output" == *"no valid sha256"* ]] || false
        [ ! -e "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
    done
    server_stop "$_pid"
}

# Blank (above) and absent are different bytes in every dialect's parse: the
# field is removed here, not emptied.
@test "a manifest row with NO sha256 field → exit 3, nothing installed" {
    local _t="${BATS_TEST_TMPDIR}/nosha"
    server_build_fixture "$_t" >/dev/null
    sed 's/"sha256":"[^"]*",//' "$_t/dist.json" >"$_t/dist-nosha.json"
    run grep -c sha256 "$_t/dist-nosha.json"
    [ "$output" = 0 ]
    local _info _pid _port
    _info=$(server_start "$_t" "${BATS_TEST_TMPDIR}/nosha.log")
    _pid="${_info% *}"
    _port="${_info#* }"
    OCX_INSTALL_DIST_URL="https://127.0.0.1:${_port}/dist-nosha.json" \
        OCX_INSTALL_MIRROR_URL="https://127.0.0.1:${_port}/releases/download" \
        OCX_INSTALL_NO_SETUP=1 run sh "$INSTALL_SH" --version 0.0.0
    server_stop "$_pid"
    [ "$status" -eq 3 ]
    [[ "$output" == *"no valid sha256"* ]] || false
    [ ! -e "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
}

# --- Header and usage text --------------------------------------------------

@test "sh: the header carries the Kind, Exit and floor lines" {
    head -n 8 "$INSTALL_SH" | grep -q '^# Kind: INST'
    head -n 8 "$INSTALL_SH" | grep -q '^# Exit: .*129.*130.*143'
    head -n 8 "$INSTALL_SH" | grep -q 'POSIX\.1-2017'
}

# `VAR=x curl ... | sh` sets VAR for curl, never for the sh on the right of the
# pipe, so the pin would be silently ignored.
@test "sh: no usage example puts an OCX_ env knob on the curl side of the pipe" {
    run grep -n -E '^[#[:space:]]*(OCX_[A-Z_]+=[^[:space:]]+[[:space:]]+)+curl' "$INSTALL_SH"
    [ "$status" -eq 1 ]
}

# --- Plain http is refused before any request, on the curl path too ---------

@test "an http OCX_INSTALL_DIST_URL is refused before any request (curl)" {
    local _bin="${BATS_TEST_TMPDIR}/fakebin" _log="${BATS_TEST_TMPDIR}/fetch.log"
    server_fake_curl "$_bin"
    FAKE_CURL_LOG="$_log" PATH="$_bin:$PATH" \
        OCX_INSTALL_DIST_URL="http://127.0.0.1:${FIXTURE_PORT}/dist.json" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 3 ]
    [[ "$output" == *"refusing insecure"* ]] || false
    [[ "$output" != *"retrying"* ]] || false
    [ ! -e "$_log" ]
}

@test "an http OCX_INSTALL_MIRROR_URL is refused before the archive request (curl)" {
    local _bin="${BATS_TEST_TMPDIR}/fakebin" _log="${BATS_TEST_TMPDIR}/fetch.log"
    server_fake_curl "$_bin"
    FAKE_CURL_LOG="$_log" PATH="$_bin:$PATH" \
        OCX_INSTALL_MIRROR_URL="http://127.0.0.1:${FIXTURE_PORT}/releases/download" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 3 ]
    [[ "$output" == *"refusing insecure"* ]] || false
    # Only the manifest was fetched; the archive request never left.
    [ "$(grep -c . "$_log")" -eq 1 ]
    [ "$(grep -c 'tar.gz' "$_log" || true)" -eq 0 ]
}

# --- curl flags are probed --------------------------------------------------

@test "curl: --tlsv1.2 is sent only when curl --help all lists it" {
    local _bin="${BATS_TEST_TMPDIR}/fakebin" _log="${BATS_TEST_TMPDIR}/fetch.log"
    server_fake_curl "$_bin"
    FAKE_CURL_LOG="$_log" PATH="$_bin:$PATH" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    # Two fetches (manifest, archive), each with --proto and without the flag.
    [ "$(grep -c -e "--proto =https" "$_log")" -eq 2 ]
    [ "$(grep -c -e "--tlsv1.2" "$_log" || true)" -eq 0 ]
    # Control: the same run with the flag listed sends it on both fetches.
    : >"$_log"
    FAKE_CURL_TLS12=1 FAKE_CURL_LOG="$_log" PATH="$_bin:$PATH" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [ "$(grep -c -e "--tlsv1.2" "$_log")" -eq 2 ]
}

# --- BusyBox wget -----------------------------------------------------------

# The fake wget rejects every option outside -q/-O the way BusyBox does and
# fetches through the real curl; curl itself is hidden so wget is the fallback.
_busybox_path() {
    server_fake_busybox_wget "${BATS_TEST_TMPDIR}/bbbin"
    printf '%s' "${BATS_TEST_TMPDIR}/bbbin:$(server_path_without curl wget)"
}

@test "BusyBox wget: installs with only the BusyBox option set, and warns" {
    local _log="${BATS_TEST_TMPDIR}/wget.log"
    FAKE_WGET_LOG="$_log" PATH="$(_busybox_path)" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [[ "$output" == *"BusyBox wget"* ]] || false
    # Manifest + archive, each exactly `-q -O <dest> <url>`.
    [ "$(grep -c '^-q -O ' "$_log")" -eq 2 ]
    [ "$(grep -c -e ' --[a-z]' "$_log" || true)" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "BusyBox wget without certificate validation: an unpinned manifest → exit 4" {
    local _log="${BATS_TEST_TMPDIR}/wget.log"
    FAKE_WGET_UNVALIDATED=1 FAKE_WGET_LOG="$_log" PATH="$(_busybox_path)" \
        run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 4 ]
    [[ "$output" == *"did not validate the TLS certificate"* ]] || false
    # Refused on the manifest: the archive was never requested.
    [ "$(grep -c . "$_log")" -eq 1 ]
}

@test "BusyBox wget without certificate validation: a pinned manifest installs" {
    local _sha
    _sha=$(server_publish_dist_snapshot "$FIXTURE_DIR")
    FAKE_WGET_UNVALIDATED=1 PATH="$(_busybox_path)" \
    OCX_INSTALL_DIST_URL="${FIXTURE_URL}/dist/${_sha}.json" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "BusyBox wget with OCX_INSTALL_CA_BUNDLE: exit 2 before any request" {
    local _log="${BATS_TEST_TMPDIR}/wget.log"
    FAKE_WGET_LOG="$_log" PATH="$(_busybox_path)" OCX_INSTALL_CA_BUNDLE="$(server_ca_bundle)" \
        run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 2 ]
    [[ "$output" == *"cannot take a CA bundle"* ]] || false
    [ ! -e "$_log" ]
}

# --- Platform detection (stubbed uname / ldd / sysctl) -----------------------

# dist-norows.json (written in setup_file) has no release rows, so detection runs
# and the install then stops at the missing (version,target) row (exit 3) on
# every host, whatever target the stubs name.

@test "platform: a musl ldd selects the musl target" {
    server_fake_platform "${BATS_TEST_TMPDIR}/plat" Linux x86_64 "musl libc (x86_64)
Version 1.2.5"
    PATH="${BATS_TEST_TMPDIR}/plat:$PATH" OCX_INSTALL_DIST_URL="${FIXTURE_URL}/dist-norows.json" \
        run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 3 ]
    [[ "$output" == *"Detected platform: x86_64-unknown-linux-musl"* ]] || false
}

@test "platform: glibc ldd banners select the gnu target" {
    local _banner
    for _banner in "ldd (Debian GLIBC 2.36-9+deb12u7) 2.36" "ldd (GNU libc) 2.39"; do
        server_fake_platform "${BATS_TEST_TMPDIR}/plat" Linux aarch64 "$_banner"
        PATH="${BATS_TEST_TMPDIR}/plat:$PATH" OCX_INSTALL_DIST_URL="${FIXTURE_URL}/dist-norows.json" \
            run sh "$INSTALL_SH" --version 0.0.0
        [ "$status" -eq 3 ]
        [[ "$output" == *"Detected platform: aarch64-unknown-linux-gnu"* ]] || false
    done
}

@test "platform: Apple Silicon under Rosetta gets the native arm64 target" {
    server_fake_platform "${BATS_TEST_TMPDIR}/plat" Darwin x86_64 "" 1
    PATH="${BATS_TEST_TMPDIR}/plat:$PATH" OCX_INSTALL_DIST_URL="${FIXTURE_URL}/dist-norows.json" \
        run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 3 ]
    [[ "$output" == *"Detected platform: aarch64-apple-darwin"* ]] || false
}

@test "platform: a real Intel Mac (sysctl answers 0) keeps the x86_64 target" {
    server_fake_platform "${BATS_TEST_TMPDIR}/plat" Darwin x86_64 "" 0
    PATH="${BATS_TEST_TMPDIR}/plat:$PATH" OCX_INSTALL_DIST_URL="${FIXTURE_URL}/dist-norows.json" \
        run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 3 ]
    [[ "$output" == *"Detected platform: x86_64-apple-darwin"* ]] || false
}

# --- Data handling ----------------------------------------------------------

@test "a backslash escape in the version is rejected with exit 2 on every sh" {
    # dash's echo expands \n, which once split this into two lines and slipped
    # past the character check.
    OCX_INSTALL_VERSION='0.0.0\nfoo' run sh "$INSTALL_SH"
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid version format"* ]] || false
}

@test "a newline in the version is rejected with exit 2" {
    OCX_INSTALL_VERSION=$'0.0.0\nfoo' run sh "$INSTALL_SH"
    [ "$status" -eq 2 ]
}

@test "the success line shortens HOME even when it holds regex metacharacters" {
    local _h="${BATS_TEST_TMPDIR}/h[1]+x"
    mkdir -p "$_h"
    HOME="$_h" OCX_HOME="$_h/.ocx" OCX_INSTALL_NO_SETUP=1 run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [[ "$output" == *"Installed to ~/.ocx/"* ]] || false
}

@test "a managed-config ref with a space reaches 'ocx self setup' as ONE argument" {
    local _copy="${BATS_TEST_TMPDIR}/install-managed.sh"
    server_embed_config "$INSTALL_SH" "$_copy" \
        "OCX_MANAGED_CONFIG=registry.corp.example/ocx/managed config:v1"
    OCX_STUB_ARGV_LINES="${BATS_TEST_TMPDIR}/argv-lines.log" run sh "$_copy" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "registry.corp.example/ocx/managed config:v1" "${BATS_TEST_TMPDIR}/argv-lines.log"
}
