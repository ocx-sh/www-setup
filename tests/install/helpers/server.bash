# Shared Bats helpers for the fixture HTTPS server.
# Sourced via `load helpers/server` from individual .bats files.
#
# NOTE: tests/install/fixtures/ is intentionally EMPTY. There are no static
# tarballs checked in. Every fixture tree (archive + dist.json manifest) is built
# at runtime by server_build_fixture below, then served by server_start over
# HTTPS (python3 + ssl). See .claude/rules/testing-bash.md.
#
# The fixture server speaks HTTPS, not plain HTTP, because the installers enforce
# TLS on every download (curl '--proto =https'; wget assert_https_url). A static,
# long-lived self-signed cert for 127.0.0.1 lives next to this file
# (localhost-cert.pem / localhost-combined.pem). Tests trust THAT specific cert
# via CURL_CA_BUNDLE — this establishes trust for the localhost test fixture
# only; it does NOT disable TLS verification.

# Directory containing this helper (and the vendored test cert). Located from
# this file's own path (BASH_SOURCE) so suites at any depth under tests/install/
# (e.g. tests/install/fish/) resolve the cert correctly.
_server_helper_dir() {
    (cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
}

# Path to the CA cert tests should trust (export as CURL_CA_BUNDLE).
server_ca_bundle() {
    printf '%s/localhost-cert.pem' "$(_server_helper_dir)"
}

server_start() {
    local _root="$1" _logfile="$2"
    local _combined
    _combined="$(_server_helper_dir)/localhost-combined.pem"
    (
        cd "$_root" || exit 1
        OCX_FIXTURE_CERT="$_combined"
        export OCX_FIXTURE_CERT
        exec python3 -u -c '
import http.server, ssl, os, sys
cert = os.environ["OCX_FIXTURE_CERT"]
httpd = http.server.HTTPServer(("127.0.0.1", 0), http.server.SimpleHTTPRequestHandler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
sys.stderr.write("Serving HTTPS on 127.0.0.1 port %d\n" % httpd.socket.getsockname()[1])
sys.stderr.flush()
httpd.serve_forever()
'
    ) >"$_logfile" 2>&1 <&- 3>&- &
    local _pid=$!
    local _port=""
    for _ in $(seq 1 50); do
        _port=$(grep -oE 'port [0-9]+' "$_logfile" 2>/dev/null | head -1 | awk '{print $2}')
        [ -n "$_port" ] && break
        sleep 0.1
    done
    [ -z "$_port" ] && {
        kill "$_pid" 2>/dev/null
        return 1
    }
    printf '%s %s\n' "$_pid" "$_port"
}

server_stop() {
    [ -n "${1:-}" ] && kill "$1" 2>/dev/null || true
}

server_detect_target() {
    local _arch _libc
    case "$(uname -m)" in
        x86_64 | amd64) _arch=x86_64 ;;
        aarch64 | arm64) _arch=aarch64 ;;
        *)
            echo "unsupported-arch"
            return 1
            ;;
    esac
    case "$(uname -s)" in
        Linux)
            _libc=gnu
            if command -v ldd >/dev/null && ldd --version 2>&1 | grep -qi musl; then _libc=musl; fi
            if ls /lib/ld-musl-*.so.1 >/dev/null 2>&1; then _libc=musl; fi
            [ -f /etc/alpine-release ] && _libc=musl
            echo "${_arch}-unknown-linux-${_libc}"
            ;;
        Darwin) echo "${_arch}-apple-darwin" ;;
        *)
            echo "unsupported-os"
            return 1
            ;;
    esac
}

# Emit the body of a fixture `ocx` stub binary that:
#   * answers `version` with 0.0.0 and `about` with a plausible banner,
#   * answers `self setup [...]` and `--offline self setup [...]` by recording
#     argv and exiting 0 (the installer hands off to `ocx self setup` now),
#   * records its full argv to $OCX_STUB_ARGV (one line per invocation) when that
#     env var is set, so the hand-off call site can be asserted exactly.
#
# The thin installer no longer writes shell shims or runs the old
# `--remote package install` bootstrap — `ocx self setup` owns all of that. The
# argv recording is what proves the installer invoked `self setup` with the
# resolved version (and the global `--offline` pre-flag on the test-hatch path).
server_stub_body() {
    cat <<'STUB'
#!/bin/sh
# Fixture ocx stub — records argv and emits plausible OCX CLI output.
if [ -n "${OCX_STUB_ARGV:-}" ]; then
    printf '%s\n' "$*" >>"$OCX_STUB_ARGV"
fi
case "$1" in
    version)
        echo "0.0.0"
        ;;
    about)
        echo "ocx 0.0.0"
        echo "registry: ocx.sh"
        ;;
    --offline)
        # Global pre-flag, then `self setup` (the test-hatch hand-off).
        shift
        if [ "$1" = "self" ] && [ "$2" = "setup" ]; then
            echo "ocx self setup (offline) ok" >&2
            exit 0
        fi
        echo "stub ocx"
        ;;
    self)
        # `ocx self setup <version> [--no-modify-path]` (the default hand-off).
        if [ "$2" = "setup" ]; then
            echo "ocx self setup ok" >&2
            exit 0
        fi
        echo "stub ocx"
        ;;
    *)
        echo "stub ocx"
        ;;
esac
STUB
}

# Write a single-release dist.json under $1.
#
# Args: $1 root, $2 target, $3 sha256 (inline checksum), $4 filename.
# The `url` is a fixed DUMMY (example.invalid) — tests redirect the download to
# the fixture server via OCX_INSTALL_MIRROR_URL, which rewrites the host to
# ${FIXTURE_URL}/releases/download while keeping <tag>/<filename>. (One dedicated
# test finalizes the url to the real fixture to exercise URL passthrough.)
server_write_dist() {
    local _root="$1" _target="$2" _sha="$3" _file="$4"
    cat >"$_root/dist.json" <<EOF
{
  "schema": 1,
  "latest": {"version":"0.0.0","channel":"stable"},
  "latest_next": null,
  "releases": [
    {"version":"0.0.0","channel":"stable","tag":"v0.0.0","target":"${_target}","filename":"${_file}","sha256":"${_sha}","url":"https://example.invalid/ocx/releases/download/v0.0.0/${_file}"}
  ]
}
EOF
}

# Rewrite the dummy dist.json url to point at the real fixture server (for the
# one test that exercises URL passthrough without OCX_INSTALL_MIRROR_URL).
server_finalize_dist_url() {
    local _root="$1" _base="$2" _tmp
    _tmp="${_root}/dist.json.tmp"
    sed "s|https://example.invalid/ocx/releases/download|${_base}|g" \
        "$_root/dist.json" >"$_tmp"
    mv "$_tmp" "$_root/dist.json"
}

# Build a release fixture tree under $1.
#
# Args:
#   $1  fixture server root
#   $2  archive layout: "nested" (default; binary at ocx-<target>/ocx) or
#       "flat" (binary at archive root — the real cargo-dist release layout)
#
# Echoes the detected target triple on success.
server_build_fixture() {
    local _srv="$1" _layout="${2:-nested}" _target
    _target=$(server_detect_target)
    mkdir -p "$_srv/releases/download/v0.0.0"

    local _build="${BATS_FILE_TMPDIR}/build-${_layout}"
    rm -rf "$_build"
    mkdir -p "$_build"

    local _binsrc
    if [ "$_layout" = "flat" ]; then
        _binsrc="$_build/ocx"
    else
        mkdir -p "$_build/ocx-${_target}"
        _binsrc="$_build/ocx-${_target}/ocx"
    fi
    server_stub_body >"$_binsrc"
    chmod +x "$_binsrc"

    local _file="ocx-${_target}.tar.xz"
    local _archive="$_srv/releases/download/v0.0.0/${_file}"
    if [ "$_layout" = "flat" ]; then
        (cd "$_build" && tar cJf "$_archive" "ocx")
    else
        (cd "$_build" && tar cJf "$_archive" "ocx-${_target}")
    fi

    local _sum
    _sum=$(sha256sum "$_archive" | awk '{print $1}')

    server_write_dist "$_srv" "$_target" "$_sum" "$_file"

    echo "$_target"
}
