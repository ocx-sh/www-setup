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
        cd "$_root" || { echo "server_start: cd '$_root' failed"; exit 1; }
        # Pre-exec marker: proves the logfile redirect works and records the
        # interpreter + cert state, so an empty log vs. a python traceback is
        # distinguishable when this leg fails (notably on macOS).
        echo "server_start: python3=$(command -v python3) ver=$(python3 -V 2>&1) cert=${_combined} exists=$([ -f "$_combined" ] && echo yes || echo no)"
        OCX_FIXTURE_CERT="$_combined"
        export OCX_FIXTURE_CERT
        exec python3 -u -c '
import http.server, ssl, os, sys, socketserver
cert = os.environ["OCX_FIXTURE_CERT"]

# /flaky/<n>/<path> answers 500 for the first <n> hits of that exact URL, then
# serves <path> normally. This is how the installers retry behaviour is tested:
# it reproduces the real failure (a single edge PoP 500ing while the object is
# fine) without needing a live CDN. The counter is keyed by the full path and
# lives on the class, because BaseHTTPRequestHandler builds a NEW instance per
# request, so instance state would reset every time.
class _Handler(http.server.SimpleHTTPRequestHandler):
    hits = {}

    def do_GET(self):
        if self.path.startswith("/flaky/"):
            rest = self.path[len("/flaky/"):]
            count, _, target = rest.partition("/")
            try:
                limit = int(count)
            except ValueError:
                self.send_error(400, "bad flaky count")
                return
            seen = _Handler.hits.get(self.path, 0)
            _Handler.hits[self.path] = seen + 1
            if seen < limit:
                self.send_error(500, "flaky fixture failure %d/%d" % (seen + 1, limit))
                return
            self.path = "/" + target
        return http.server.SimpleHTTPRequestHandler.do_GET(self)

class _Srv(http.server.HTTPServer):
    # Skip HTTPServer.server_bind getfqdn() reverse-DNS lookup: it blocks past
    # the 10s startup timeout on macOS runners (no /etc/hosts fast-path), so the
    # server never reached the port print. Bind only; no name resolution.
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = self.server_address[0]
        self.server_port = self.server_address[1]
httpd = _Srv(("127.0.0.1", 0), _Handler)
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
    for _ in $(seq 1 100); do
        _port=$(grep -oE 'port [0-9]+' "$_logfile" 2>/dev/null | head -1 | awk '{print $2}')
        [ -n "$_port" ] && break
        sleep 0.1
    done
    [ -z "$_port" ] && {
        # Surface WHY the server never reported a port (python missing, ssl/cert
        # load failure, …) instead of a bare exit 1 from setup_file. Goes to fd 2
        # so bats captures it in the failing test's diagnostic block.
        {
            echo "server_start: HTTPS fixture server did not report a port within 10s"
            echo "server_start: python3=$(command -v python3 || echo MISSING)"
            echo "server_start: --- server log ($_logfile) ---"
            cat "$_logfile" 2>/dev/null || echo "(no log)"
            echo "server_start: --- end server log ---"
        } >&2
        kill "$_pid" 2>/dev/null
        return 1
    }
    printf '%s %s\n' "$_pid" "$_port"
}

server_stop() {
    [ -n "${1:-}" ] && kill "$1" 2>/dev/null || true
}

# server_request_count LOGFILE PATH_SUBSTRING
#
# Count how many GETs the fixture server received for a path. The python
# handler's default access log already lands in LOGFILE (server_start redirects
# both streams there), so this needs no extra plumbing — it is what lets a test
# assert "the installer really did try 3 times".
server_request_count() {
    local _logfile="$1" _needle="$2"
    grep -c "\"GET [^\"]*${_needle}" "$_logfile" 2>/dev/null || true
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

# Portable sha256 of a file: coreutils sha256sum (Linux) or BSD/macOS shasum.
# Echoes the bare hex digest.
server_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
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
# `ocx self setup` takes the CA as OCX_EXTRA_CA_CERTS (persisted; path or PEM
# text) and, for older ocx, SSL_CERT_FILE (a path); record what the installer
# handed down so the CA tests can assert BOTH hops are covered. An inline PEM
# spans lines — the log is grepped line-wise, so that is fine.
if [ -n "${OCX_STUB_ENV:-}" ]; then
    printf 'SSL_CERT_FILE=%s\n' "${SSL_CERT_FILE:-}" >>"$OCX_STUB_ENV"
    printf 'OCX_EXTRA_CA_CERTS=%s\n' "${OCX_EXTRA_CA_CERTS:-}" >>"$OCX_STUB_ENV"
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

# Publish the fixture's dist.json as a content-addressed snapshot at
# dist/<sha256>.json — the layout scripts/publish-dist.sh and `ocx-mirror dist
# sync` both emit — and echo the digest.
#
# Pointing OCX_INSTALL_DIST_URL at the snapshot PINS the manifest: the installer
# recognises the 64-hex basename and verifies the served body against it, so a
# mirror that altered the manifest is caught (exit 4) instead of trusted.
server_publish_dist_snapshot() {
    local _root="$1" _sha
    _sha=$(server_sha256 "$_root/dist.json")
    mkdir -p "$_root/dist"
    cp "$_root/dist.json" "$_root/dist/${_sha}.json"
    echo "$_sha"
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

    local _file="ocx-${_target}.tar.gz"
    local _archive="$_srv/releases/download/v0.0.0/${_file}"
    if [ "$_layout" = "flat" ]; then
        (cd "$_build" && tar czf "$_archive" "ocx")
    else
        (cd "$_build" && tar czf "$_archive" "ocx-${_target}")
    fi

    local _sum
    _sum=$(server_sha256 "$_archive")

    server_write_dist "$_srv" "$_target" "$_sum" "$_file"

    echo "$_target"
}

# server_embed_config <src-installer> <dest> [TOKEN=VALUE ...]
#
# Copy an installer and substitute its embedded-configuration placeholders,
# exactly the way a corporate mirror patches its own copy. TOKEN is the bare
# environment-variable name (e.g. OCX_INSTALL_DIST_URL); the @...@ wrapper is
# added here. The substitution is a plain literal replace over the whole file —
# the point of the token contract is that ONE such command works on every
# dialect, so the suites must not special-case per shell.
#
# A VALUE may contain newlines (an inline PEM block) — every dialect's
# single-quoted literal spans lines.
server_embed_config() {
    local _src="$1" _dest="$2"
    shift 2
    cp "$_src" "$_dest"
    local _pair _token _value
    for _pair in "$@"; do
        _token="${_pair%%=*}"
        _value="${_pair#*=}"
        SRC="$_dest" TOKEN="@${_token}@" VALUE="$_value" python3 - <<'PY'
import os
p = os.environ['SRC']
with open(p, encoding='utf-8') as f:
    s = f.read()
token = os.environ['TOKEN']
assert token in s, 'placeholder %s not found in %s' % (token, p)
with open(p, 'w', encoding='utf-8') as f:
    f.write(s.replace(token, os.environ['VALUE']))
PY
    done
}

# True when a GNU wget is on PATH. The installers' wget branch uses GNU-only
# flags (--secure-protocol, --https-only, --ca-certificate); Alpine ships
# BusyBox wget, which has none of them, so wget-backend tests must gate on this
# rather than on `command -v wget`.
server_have_gnu_wget() {
    command -v wget >/dev/null 2>&1 || return 1
    wget --version 2>&1 | head -n 1 | grep -q 'GNU Wget'
}

# server_path_without_curl
#
# Echo a PATH whose entries mirror the current PATH except that `curl` is
# absent. Forcing a dialect's wget fallback needs curl to be genuinely
# unreachable — `command -v curl` skips non-executables and keeps searching, so
# shadowing it does not work. A symlink farm does. Built once per .bats file.
server_path_without_curl() {
    local _farm="${BATS_FILE_TMPDIR}/nocurl-bin"
    if [ ! -d "$_farm" ]; then
        mkdir -p "$_farm"
        local _dir _f _b
        while IFS= read -r _dir; do
            [ -n "$_dir" ] && [ -d "$_dir" ] || continue
            for _f in "$_dir"/*; do
                [ -x "$_f" ] || continue
                _b="${_f##*/}"
                # An `if`, not `[ ... ] && continue`: bats runs test code under
                # `set -e`, where a bare `&&` list that evaluates false is itself
                # a failing command.
                if [ "$_b" != "curl" ] && [ ! -e "$_farm/$_b" ]; then
                    ln -s "$_f" "$_farm/$_b" 2>/dev/null || true
                fi
            done
        done <<<"${PATH//:/$'\n'}"
    fi
    printf '%s' "$_farm"
}

# server_pad_dist ROOT [BYTES]
#
# Write ROOT/dist-big.json: the fixture manifest plus a filler member large
# enough to exceed a pipe buffer (default 200 KiB; the real setup.ocx.sh
# manifest is ~73 KiB, the fixture one a few hundred bytes).
#
# Size is load-bearing, not cosmetic. A downloader that leaves the response on
# an undrained stream deadlocks only once the body outgrows the 64 KiB pipe
# buffer — small fixtures fit and hide the bug entirely. The filler carries no
# braces, so the jq-free `{[^{}]*}` parses in sh/fish are unaffected.
server_pad_dist() {
    local _root="$1" _bytes="${2:-200000}" _pad=xxxxxxxxxxxxxxxx
    # Doubled in the shell and emitted with the printf BUILTIN: a 200 KiB sed
    # expression blows ARG_MAX (status 126, "Argument list too long"), and
    # `tr '\0' 'x'` over /dev/zero is not portable to BSD tr on the macOS leg.
    while [ ${#_pad} -lt "$_bytes" ]; do _pad="${_pad}${_pad}"; done
    _pad="${_pad:0:$_bytes}"
    {
        printf '{\n  "_pad": "%s",\n' "$_pad"
        # Everything after the opening brace of the real manifest.
        sed '1d' "$_root/dist.json"
    } >"$_root/dist-big.json"
}

# server_ca_bundle_inline
#
# Echo the fixture CA cert with the comment header a real distro bundle carries
# (Fedora/RHEL's extracted tls-ca-bundle.pem opens with `# <name>` lines). Used
# for the inline-PEM scenarios so they exercise detection by CONTENT rather than
# by a leading `-----BEGIN` marker, which a real bundle does not have.
server_ca_bundle_inline() {
    printf '# Corp Root CA\n#\n# Issuer: Corp Internal Root\n'
    cat "$(server_ca_bundle)"
}
