#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

# shellcheck disable=SC3043  # `local` verified at runtime by has_local()
# install.sh — OCX installer for Unix and macOS (bash/zsh/ash/ksh/dash)
# https://ocx.sh
#
# This is a THIN BOOTSTRAP. It detects the platform, resolves the release from
# the self-hosted distribution manifest (dist.json), downloads + verifies the
# archive against the manifest's inline sha256, then hands off to the downloaded
# binary's `ocx self setup`. `ocx self setup` owns everything that touches the
# machine — the package-store self-install, the per-shell env shims under
# $OCX_HOME, and the managed shell-profile activation blocks. Run
# `ocx self setup --help` for the full setup contract.
#
# Usage:
#   curl -fsSL https://setup.ocx.sh/sh | sh
#   curl -fsSL https://setup.ocx.sh/sh | sh -s -- --no-modify-path
#   OCX_INSTALL_VERSION=0.5.0 curl -fsSL https://setup.ocx.sh/sh | sh
#
# Stdout/stderr contract (load-bearing):
#   - All informational/warning/error messages go to STDERR.
#   - STDOUT is silent on success unless OCX_INSTALL_PRINT_PATH is truthy, in
#     which case the FINAL stdout line is the absolute path to the OCX bin dir.
#
# Exit codes:
#   0  success
#   1  generic / legacy
#   2  argument or environment validation
#   3  network / download / manifest failure
#   4  checksum mismatch
#   5  archive extraction failure
#   6  'ocx self setup' failure
#   7  unsupported platform / architecture

set -eu

has_local() { local _ 2>/dev/null; }
has_local || alias local=typeset

# --- Configuration (env-driven) ---------------------------------------------
#
# Tier 1 — shared OCX env (read by the binary too): OCX_HOME, OCX_NO_MODIFY_PATH.
# Plus standard externals NO_COLOR, TMPDIR.
#
# Tier 2 — installer-only knobs, all OCX_INSTALL_* with a strict grammar:
#   values (bare nouns):  OCX_INSTALL_VERSION (empty = latest), OCX_INSTALL_REPO
#   endpoints (_URL):     OCX_INSTALL_DIST_URL, OCX_INSTALL_MIRROR_URL
#   opt-outs (NO_):       OCX_INSTALL_NO_SETUP, OCX_INSTALL_NO_SMOKETEST
#   opt-ins (bare verb):  OCX_INSTALL_FORCE, OCX_INSTALL_QUIET, OCX_INSTALL_PRINT_PATH
#   sh-only:              OCX_INSTALL_DOWNLOADER (curl|wget)

OCX_INSTALL_REPO="${OCX_INSTALL_REPO:-ocx-sh/ocx}"
# Self-hosted distribution manifest (Node-dist-style; newest-first releases with
# inline per-target sha256 + download URL). Resolved over the HTTPS-enforced
# downloader — no GitHub API, no token. See get_latest_version / dist_row.
OCX_INSTALL_DIST_URL="${OCX_INSTALL_DIST_URL:-https://setup.ocx.sh/dist.json}"
# Artifact host override: when set, the per-target download URL from dist.json is
# rewritten to ${OCX_INSTALL_MIRROR_URL%/}/<tag>/<filename>. Empty = use the
# manifest's URL verbatim (GitHub Releases).
OCX_INSTALL_MIRROR_URL="${OCX_INSTALL_MIRROR_URL:-}"
# Pin a specific version (empty = resolve latest stable from the manifest). This
# is the portable pinning channel across every shell's `curl | <shell>` arg
# quirks; --version is sugar where the dialect parses it cleanly.
OCX_INSTALL_VERSION="${OCX_INSTALL_VERSION:-}"

# Behavioral knobs (truthy: 1 true yes TRUE YES True Yes)
OCX_INSTALL_NO_SETUP="${OCX_INSTALL_NO_SETUP:-0}"
OCX_INSTALL_NO_SMOKETEST="${OCX_INSTALL_NO_SMOKETEST:-0}"
OCX_INSTALL_PRINT_PATH="${OCX_INSTALL_PRINT_PATH:-0}"
OCX_INSTALL_FORCE="${OCX_INSTALL_FORCE:-0}"
OCX_INSTALL_QUIET="${OCX_INSTALL_QUIET:-0}"
OCX_INSTALL_DOWNLOADER="${OCX_INSTALL_DOWNLOADER:-}"

# --- Truthy helper ----------------------------------------------------------

is_truthy() {
    case "$1" in
        1 | true | yes | TRUE | YES | True | Yes) return 0 ;;
        *) return 1 ;;
    esac
}

# --- Output helpers (all go to STDERR) --------------------------------------

say() {
    is_truthy "$OCX_INSTALL_QUIET" && return 0
    printf 'ocx-install: %s\n' "$1" >&2
}

warn() {
    printf 'ocx-install: warning: %s\n' "$1" >&2
}

# err [msg] [exit_code]
err() {
    printf 'ocx-install: error: %s\n' "$1" >&2
    exit "${2:-1}"
}

# Replace $HOME prefix with ~ for user-facing display.
tildify() {
    echo "$1" | sed "s|^${HOME}|~|"
}

# --- Core utilities ---------------------------------------------------------

check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

need_cmd() {
    if ! check_cmd "$1"; then
        err "required command not found: $1" 2
    fi
}

ignore() {
    "$@" || true
}

get_home() {
    if [ -n "${HOME:-}" ]; then
        echo "$HOME"
    elif [ -n "${USER:-}" ]; then
        getent passwd "$USER" | cut -d: -f6
    else
        getent passwd "$(id -un)" | cut -d: -f6
    fi
}

HOME="${HOME:-$(get_home)}"

# TTY/color detection — bold-only, respects NO_COLOR (https://no-color.org/).
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    _bold=$(tput bold 2>/dev/null || echo "")
    _reset=$(tput sgr0 2>/dev/null || echo "")
else
    _bold=""
    _reset=""
fi

# Canonical CLI bin dir relative to OCX_HOME (the real on-disk store layout).
OCX_BIN_SUBPATH="symlinks/ocx.sh/ocx/cli/current/content/bin"

# --- Usage ------------------------------------------------------------------

usage() {
    cat >&2 <<'EOF'
OCX installer — https://ocx.sh

USAGE:
    curl -fsSL https://setup.ocx.sh/sh | sh
    curl -fsSL https://setup.ocx.sh/sh | sh -s -- [OPTIONS]

OPTIONS:
    --version <VERSION>   Install a specific version (e.g., 0.5.0).
                          Equivalent to OCX_INSTALL_VERSION=<VERSION>.
    --no-modify-path      Don't modify shell profile files (forwarded to
                          `ocx self setup`).
    -h, --help            Print this help message.

ENVIRONMENT (user-facing):
    OCX_HOME                  Installation directory (default: ~/.ocx)
    OCX_NO_MODIFY_PATH        Truthy to skip shell profile modification
    NO_COLOR                  Disable colored output (https://no-color.org/)

ENVIRONMENT (installer knobs):
    OCX_INSTALL_VERSION       Pin a version (empty = latest stable)
    OCX_INSTALL_REPO          GitHub owner/repo (default: ocx-sh/ocx)
    OCX_INSTALL_DIST_URL      Distribution manifest URL (latest + checksums)
    OCX_INSTALL_MIRROR_URL    Artifact host override (rewrites the download URL)
    OCX_INSTALL_NO_SETUP      Truthy = place binary on PATH only; skip
                              `ocx self setup` (env shims + profile blocks)
    OCX_INSTALL_NO_SMOKETEST  Truthy = skip the post-extract `$bin version` check
    OCX_INSTALL_FORCE         Truthy = reinstall even if same version is present
    OCX_INSTALL_QUIET         Truthy = suppress informational logs
    OCX_INSTALL_PRINT_PATH    Truthy = emit absolute bin dir on final stdout line
    OCX_INSTALL_DOWNLOADER    Force 'curl' or 'wget' (default: auto-detect)
EOF
}

# --- Platform detection -----------------------------------------------------

detect_target() {
    local _os _arch _libc

    _os=$(uname -s)
    case "$_os" in
        Linux | Darwin) ;;
        *) err "unsupported operating system: $_os (expected Linux or macOS)" 7 ;;
    esac

    _arch=$(uname -m)
    case "$_arch" in
        x86_64 | amd64) _arch="x86_64" ;;
        aarch64 | arm64) _arch="aarch64" ;;
        *) err "unsupported architecture: $_arch (expected x86_64 or aarch64)" 7 ;;
    esac

    if [ "$_os" = "Darwin" ] && [ "$_arch" = "x86_64" ]; then
        if sysctl -n hw.optional.arm64 2>/dev/null | grep -q '1'; then
            say "Detected Apple Silicon running under Rosetta — using native arm64 binary."
            _arch="aarch64"
        fi
    fi

    case "$_os" in
        Linux)
            _libc="gnu"
            if check_cmd ldd; then
                case "$(ldd --version 2>&1 || true)" in
                    *musl*) _libc="musl" ;;
                esac
            elif ls /lib/ld-musl-*.so.1 >/dev/null 2>&1; then
                _libc="musl"
            elif [ -f /etc/alpine-release ]; then
                _libc="musl"
            fi
            echo "${_arch}-unknown-linux-${_libc}"
            ;;
        Darwin)
            echo "${_arch}-apple-darwin"
            ;;
        *)
            err "unsupported operating system: $_os" 7
            ;;
    esac
}

# --- Download utilities -----------------------------------------------------

# Fail closed on plaintext: wget has no universal "https-only" flag, so we
# reject non-https URLs ourselves before any request leaves the machine.
assert_https_url() {
    case "$1" in
        https://*) return 0 ;;
        *) err "refusing insecure (non-https) URL: $1" 3 ;;
    esac
}

detect_downloader() {
    if [ -n "$OCX_INSTALL_DOWNLOADER" ]; then
        case "$OCX_INSTALL_DOWNLOADER" in
            curl | wget)
                if ! check_cmd "$OCX_INSTALL_DOWNLOADER"; then
                    err "OCX_INSTALL_DOWNLOADER=$OCX_INSTALL_DOWNLOADER but '$OCX_INSTALL_DOWNLOADER' not on PATH" 2
                fi
                _downloader="$OCX_INSTALL_DOWNLOADER"
                return
                ;;
            *)
                err "OCX_INSTALL_DOWNLOADER must be 'curl' or 'wget' (got: $OCX_INSTALL_DOWNLOADER)" 2
                ;;
        esac
    fi

    if check_cmd curl; then
        if curl --version 2>&1 | head -1 | grep -qF 'snap'; then
            warn "detected snap-packaged curl (may have sandbox restrictions)"
            if check_cmd wget; then
                _downloader="wget"
                return
            fi
            warn "no wget fallback — continuing with snap curl"
        fi
        _downloader="curl"
    elif check_cmd wget; then
        _downloader="wget"
    else
        err "either curl or wget is required to download OCX" 2
    fi
}

download_to_file() {
    local _url="$1" _dest="$2"

    if [ "$_downloader" = "curl" ]; then
        curl --proto '=https' --tlsv1.2 -fsSL -o "$_dest" "$_url"
    else
        assert_https_url "$_url"
        # --https-only refuses a redirect to http:// (assert_https_url only vets
        # the INITIAL URL; wget follows up to 20 redirects). TLSv1_2 floor.
        wget --secure-protocol=TLSv1_2 --https-only -q -O "$_dest" "$_url"
    fi
}

download() {
    if [ "$_downloader" = "curl" ]; then
        curl --proto '=https' --tlsv1.2 -fsSL "$1"
    else
        assert_https_url "$1"
        wget --secure-protocol=TLSv1_2 --https-only -qO- "$1"
    fi
}

# --- Checksum verification --------------------------------------------------

# verify_checksum <file_path> <expected_sha256>
# The expected hash comes inline from dist.json — no separate sha256.sum fetch.
verify_checksum() {
    local _file="$1" _expected="$2" _sha_cmd _actual

    if check_cmd sha256sum; then
        _sha_cmd="sha256sum"
    elif check_cmd shasum; then
        _sha_cmd="shasum -a 256"
    else
        warn "neither sha256sum nor shasum found — SKIPPING CHECKSUM VERIFICATION"
        warn "install coreutils or set PATH to include sha256sum for verified downloads"
        return 0
    fi

    # shellcheck disable=SC2086
    _actual=$($_sha_cmd "$_file" | awk '{print $1}')

    # Normalize to lowercase for a case-insensitive compare.
    _expected=$(printf '%s' "$_expected" | tr 'A-F' 'a-f')
    _actual=$(printf '%s' "$_actual" | tr 'A-F' 'a-f')

    if [ "$_expected" != "$_actual" ]; then
        err "checksum mismatch for $(basename "$_file")
  expected: $_expected
  got:      $_actual" 4
    fi

    say "Checksum verified."
}

# --- Safe archive extraction ------------------------------------------------

# Two-pass extraction. Pass 1: reject any member that escapes the destination
# via an absolute path or a ".." traversal component. Pass 2: reject any
# symlink/hardlink whose target escapes the tree. Then extract with
# ownership/permission hardening flags. The scans are authoritative; the inline
# checksum is the primary integrity guard. NB: only flags accepted by BOTH GNU
# tar and macOS bsdtar are used — --no-overwrite-dir is GNU-only and would abort
# bsdtar, and the fresh mktemp dest has no pre-existing dirs for it to protect.
safe_extract() {
    local _archive="$1" _dest="$2" _bad_entry _bad_target

    _bad_entry=$(tar --list -f "$_archive" 2>/dev/null |
        grep -E '(^|/)\.\.(/|$)|^/' || true)
    if [ -n "$_bad_entry" ]; then
        err "archive contains unsafe path: $_bad_entry" 5
    fi

    _bad_target=$(tar -tvf "$_archive" 2>/dev/null |
        awk -F ' -> ' '
            /->/ {
                target = ""
                for (i = 2; i <= NF; i++) target = target (i == 2 ? "" : " -> ") $i
                if (substr(target, 1, 1) == "/") { print target; next }
                n = split(target, parts, "/")
                depth = 0
                for (j = 1; j <= n; j++) {
                    if (parts[j] == "" || parts[j] == ".") continue
                    if (parts[j] == "..") {
                        depth--
                        if (depth < 0) { print target; next }
                    } else {
                        depth++
                    }
                }
            }
        ' || true)
    if [ -n "$_bad_target" ]; then
        err "archive contains escaping link target: $_bad_target" 5
    fi

    tar xf "$_archive" -C "$_dest" \
        --no-same-owner --no-same-permissions 2>/dev/null ||
        err "failed to extract ${_archive} — ensure tar is installed" 5
}

# --- Distribution manifest (dist.json) --------------------------------------
#
# dist.json is a single JSON object with FLAT leaf objects (no nested braces):
#   {"schema":1,
#    "latest":{"version":"0.5.0","channel":"stable"},
#    "latest_next":{"version":"0.6.0-rc.1","channel":"next"},
#    "releases":[
#      {"version":"0.5.0","channel":"stable","tag":"v0.5.0","target":"…",
#       "filename":"ocx-….tar.gz","sha256":"…","url":"https://…"}, …]}
# We own the format, so a jq-free POSIX parse is safe: `grep -o '{[^{}]*}'`
# extracts each flat leaf object (it skips the outer container brace because
# `[^{}]` excludes both braces). No GitHub API, no token.

# Resolve the latest STABLE version: the first leaf object whose channel is
# stable (the `latest` pointer, emitted first; newest-first regardless).
get_latest_version() {
    local _dist="$1" _version

    _version=$(printf '%s' "$_dist" |
        grep -o '{[^{}]*}' |
        grep '"channel"[[:space:]]*:[[:space:]]*"stable"' |
        head -1 |
        sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        head -1 |
        sed 's/^v//')

    if [ -z "$_version" ]; then
        err "failed to determine the latest version: no stable release in the manifest at ${OCX_INSTALL_DIST_URL}" 3
    fi
    printf '%s' "$_version"
}

# Echo the FLAT release row matching (version,target), or empty.
dist_row() {
    local _dist="$1" _version="$2" _target="$3"
    printf '%s' "$_dist" |
        grep -o '{[^{}]*}' |
        grep "\"version\"[[:space:]]*:[[:space:]]*\"${_version}\"" |
        grep "\"target\"[[:space:]]*:[[:space:]]*\"${_target}\"" |
        head -1
}

# Extract a string field from a flat JSON object.
json_field() {
    printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

# --- Hand off to `ocx self setup` -------------------------------------------

# Run the downloaded binary's `ocx self setup`. Global pre-flags (e.g. --offline)
# precede the subcommand; subcommand args/flags (the version positional,
# --no-modify-path) follow it — clap parses them at different levels. _pre and
# _post are space-separated flag lists; either may be empty.
run_self_setup() {
    # shellcheck disable=SC2086  # deliberate word-split of the flag lists
    local _bin="$1" _pre="$2" _post="$3"

    say "Running ocx self setup..."
    # shellcheck disable=SC2086
    if ! "$_bin" $_pre self setup $_post; then
        err "'ocx self setup' failed — see the output above for details" 6
    fi
}

# Export the OCX bin directory to GITHUB_PATH for GitHub Actions.
export_github_path() {
    local _install_path="${OCX_HOME:-$HOME/.ocx}/${OCX_BIN_SUBPATH}"
    if [ -n "${GITHUB_PATH:-}" ]; then
        printf '%s\n' "$_install_path" >>"$GITHUB_PATH" ||
            warn "failed to write to \$GITHUB_PATH"
    fi
}

# Place the extracted binary at the canonical bin dir (no `ocx self setup`).
# Binary-on-PATH only: 'ocx self update' will NOT manage such an install. The
# OCX_INSTALL_NO_SETUP / CI / air-gapped path.
place_binary() {
    local _bin="$1" _ocx_home="$2" _bin_dir="$2/$OCX_BIN_SUBPATH"
    mkdir -p "$_bin_dir"
    cp -f "$_bin" "$_bin_dir/ocx"
    chmod +x "$_bin_dir/ocx"
    say "Installed to $(tildify "${_bin_dir}/ocx")"
}

# --- Test-mode install (internal, test-only) --------------------------------

# Install a pre-built ocx binary as the candidate, bypassing download + checksum
# + extract. Driven by the internal, UNDOCUMENTED __OCX_TESTING_INSTALL_BINARY
# (double-underscore = test-only, never a public knob; absent from usage()). The
# test suites own this hatch.
install_local_test_binary() {
    local _src="$1" _ocx_home="$2" _bin_dir

    [ -f "$_src" ] || err "__OCX_TESTING_INSTALL_BINARY does not point to a file: $_src" 2

    _bin_dir="$_ocx_home/$OCX_BIN_SUBPATH"
    say "Test mode: installing local binary as the candidate (no download)."
    mkdir -p "$_bin_dir"
    cp -f "$_src" "$_bin_dir/ocx"
    chmod +x "$_bin_dir/ocx"
    say "Installed to $(tildify "${_bin_dir}/ocx")"
}

# --- OCX_HOME validation ----------------------------------------------------

# $OCX_HOME reaches the per-shell env shims and the profile blocks written by
# `ocx self setup`. Harden it: require an absolute path, reject ".." traversal,
# reject shell metacharacters that could break out of the quoting downstream.
assert_safe_ocx_home() {
    local _home="$1"

    case "$_home" in
        /*) ;;
        *) err "OCX_HOME must be an absolute path (got: $_home)" 2 ;;
    esac
    case "$_home" in
        */../* | */..) err "OCX_HOME must not contain '..' (got: $_home)" 2 ;;
        ../*) err "OCX_HOME must not contain '..' (got: $_home)" 2 ;;
    esac
    case "$_home" in
        *'"'* | *'$'* | *'`'* | *';'* | *'&'* | *'|'* | *'<'* | *'>'* | *'('* | *')'* | *'
'*)
            err "OCX_HOME contains characters unsafe for shell embedding (got: $_home)" 2
            ;;
    esac
    case "$_home" in
        *\\*) err "OCX_HOME contains characters unsafe for shell embedding (got: $_home)" 2 ;;
    esac
}

# --- Temp directory cleanup -------------------------------------------------

cleanup() {
    if [ -n "${_tmpdir:-}" ]; then
        ignore rm -rf "$_tmpdir"
    fi
}

# --- Success banner ---------------------------------------------------------

print_success() {
    local _version="$1" _ocx_home

    is_truthy "$OCX_INSTALL_QUIET" && return 0
    _ocx_home="${OCX_HOME:-$HOME/.ocx}"

    printf '\n  %socx %s installed successfully!%s\n' "$_bold" "$_version" "$_reset" >&2
    cat >&2 <<EOF

  Restart your shell, then verify with:

    ocx about

  To uninstall, remove the OCX home directory:

    rm -rf $_ocx_home

EOF
}

# --- Main -------------------------------------------------------------------

main() {
    local _no_modify_path _version _target _tmpdir _bin _ocx_home _bin_dir
    local _dist _row _sha _url _filename _tag _archive _old_version _post

    _no_modify_path="${OCX_NO_MODIFY_PATH:-0}"
    _version="$OCX_INSTALL_VERSION"

    while [ $# -gt 0 ]; do
        case "$1" in
            --no-modify-path) _no_modify_path=1 ;;
            --version)
                if [ $# -lt 2 ]; then
                    err "--version requires a value" 2
                fi
                _version="$2"
                shift
                ;;
            --version=*) _version="${1#--version=}" ;;
            -h | --help)
                usage
                exit 0
                ;;
            *) err "unknown option: $1 (use --help for usage)" 2 ;;
        esac
        shift
    done

    if is_truthy "$_no_modify_path"; then
        _no_modify_path=1
    else
        _no_modify_path=0
    fi

    _ocx_home="${OCX_HOME:-$HOME/.ocx}"
    assert_safe_ocx_home "$_ocx_home"
    _bin_dir="${_ocx_home}/${OCX_BIN_SUBPATH}"

    # `ocx self setup` post-flags (--no-modify-path keyed off OCX_NO_MODIFY_PATH
    # truthy OR the --no-modify-path flag). In OCX_INSTALL_NO_SETUP mode setup is
    # not run, so OCX_NO_MODIFY_PATH is a no-op there (documented).
    _post=""
    if [ "$_no_modify_path" = "1" ]; then
        _post="--no-modify-path"
    fi

    # --- Internal test-mode hatch (UNDOCUMENTED) ---------------------------
    # Install a locally-built binary as the candidate; skip download + checksum
    # + extract + the network manifest probe entirely. The version is derived
    # from the binary itself, so this path bypasses the semver validation below.
    if [ -n "${__OCX_TESTING_INSTALL_BINARY:-}" ]; then
        install_local_test_binary "$__OCX_TESTING_INSTALL_BINARY" "$_ocx_home"
        if is_truthy "$OCX_INSTALL_NO_SETUP"; then
            say "Skipping 'ocx self setup' (OCX_INSTALL_NO_SETUP)."
        else
            # Candidate present, no registry reachable -> --offline. No version
            # positional (the candidate is 'local', not a published version).
            run_self_setup "$_bin_dir/ocx" "--offline" "$_post"
        fi
        export_github_path
        if is_truthy "$OCX_INSTALL_PRINT_PATH"; then
            printf '%s\n' "$_bin_dir"
        fi
        return 0
    fi

    need_cmd uname
    need_cmd mktemp
    need_cmd tar
    detect_downloader

    _target=$(detect_target)
    say "Detected platform: $_target"

    # Fetch the manifest once; reuse for latest-resolution AND row-resolution.
    _dist=$(download "$OCX_INSTALL_DIST_URL") ||
        err "failed to fetch the latest version from ${OCX_INSTALL_DIST_URL}
  Check your internet connection, or pin a version with OCX_INSTALL_VERSION." 3
    [ -n "$_dist" ] ||
        err "failed to determine the latest version: empty manifest at ${OCX_INSTALL_DIST_URL}" 3

    if [ -z "$_version" ]; then
        say "Resolving latest version..."
        _version=$(get_latest_version "$_dist")
    fi

    if echo "$_version" | grep -q '[^0-9a-zA-Z.+-]'; then
        err "invalid version format: $_version (expected semver like 1.2.3 or 1.0.0-rc.1)" 2
    elif echo "$_version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]'; then
        : # valid
    else
        err "invalid version format: $_version (expected semver like 1.2.3)" 2
    fi

    # Idempotent fast-path: same version already present at the canonical bin
    # dir (unless OCX_INSTALL_FORCE).
    _old_version=""
    if [ -x "$_bin_dir/ocx" ]; then
        _old_version=$("$_bin_dir/ocx" version 2>/dev/null || echo "")
    fi
    if [ -n "$_old_version" ] && [ "$_old_version" = "$_version" ] && ! is_truthy "$OCX_INSTALL_FORCE"; then
        say "ocx v${_version} already installed at $(tildify "$_bin_dir/ocx") (set OCX_INSTALL_FORCE=1 to reinstall)"
        export_github_path
        if is_truthy "$OCX_INSTALL_PRINT_PATH"; then
            printf '%s\n' "$_bin_dir"
        fi
        exit 0
    fi

    # Resolve the (version,target) row -> inline sha256 + download URL.
    _row=$(dist_row "$_dist" "$_version" "$_target")
    [ -n "$_row" ] ||
        err "no published artifact for ocx v${_version} on ${_target} in the manifest at ${OCX_INSTALL_DIST_URL}" 3
    _sha=$(json_field "$_row" sha256)
    _url=$(json_field "$_row" url)
    _filename=$(json_field "$_row" filename)
    _tag=$(json_field "$_row" tag)
    { [ -n "$_url" ] && [ -n "$_filename" ]; } ||
        err "manifest row for v${_version}/${_target} is missing url/filename" 3

    # Artifact host override (mirror): rewrite the host but keep <tag>/<filename>.
    if [ -n "$OCX_INSTALL_MIRROR_URL" ]; then
        _url="${OCX_INSTALL_MIRROR_URL%/}/${_tag}/${_filename}"
    fi

    say "Installing ocx v${_version}..."
    _tmpdir=$(mktemp -d)
    trap cleanup EXIT INT TERM HUP

    _archive="$_tmpdir/$_filename"
    say "Downloading ${_filename}..."
    download_to_file "$_url" "$_archive" ||
        err "failed to download ${_url}
  Ensure v${_version} is a valid release with a binary for ${_target}.
  Available releases: https://github.com/${OCX_INSTALL_REPO}/releases" 3

    if [ -n "$_sha" ]; then
        verify_checksum "$_archive" "$_sha"
    else
        warn "no inline checksum for ${_filename} in the manifest — skipping verification"
    fi

    safe_extract "$_archive" "$_tmpdir"

    # Locate binary: nested (ocx-TARGET/ocx) or flat (ocx at archive root — the
    # real cargo-dist layout).
    if [ -f "$_tmpdir/ocx-${_target}/ocx" ]; then
        _bin="$_tmpdir/ocx-${_target}/ocx"
    elif [ -f "$_tmpdir/ocx" ]; then
        _bin="$_tmpdir/ocx"
    else
        err "could not find ocx binary in archive" 5
    fi
    chmod +x "$_bin"

    if ! is_truthy "$OCX_INSTALL_NO_SMOKETEST"; then
        if ! "$_bin" version >/dev/null 2>&1; then
            warn "binary failed to execute in temp directory ($(dirname "$_bin"))"
            warn "your /tmp may be mounted with noexec — try: TMPDIR=\$HOME/.tmp $0"
        fi
    fi

    if check_cmd ocx; then
        local _existing_ocx
        _existing_ocx=$(command -v ocx)
        case "$_existing_ocx" in
            "${_ocx_home}"/*) ;;
            *)
                warn "an existing ocx was found at $_existing_ocx"
                warn "the new install may be shadowed — check your PATH order"
                ;;
        esac
    fi

    if is_truthy "$OCX_INSTALL_NO_SETUP"; then
        # Binary-on-PATH only: place the binary, skip `ocx self setup`.
        place_binary "$_bin" "$_ocx_home"
    else
        # Hand off: `ocx self setup <version>` installs that version from the
        # registry into the package store and writes the env shims + profile
        # blocks. The version is a positional to `self setup`.
        run_self_setup "$_bin" "" "$_version $_post"
        print_success "$_version"
    fi

    export_github_path
    if is_truthy "$OCX_INSTALL_PRINT_PATH"; then
        printf '%s\n' "$_bin_dir"
    fi
}

main "$@"
