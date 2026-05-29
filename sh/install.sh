#!/bin/sh
# shellcheck disable=SC3043  # `local` verified at runtime by has_local()
# install.sh — OCX installer for Unix and macOS
# https://ocx.sh
#
# Usage:
#   curl -fsSL https://setup.ocx.sh/sh | sh
#   curl -fsSL https://setup.ocx.sh/sh | sh -s -- --no-modify-path
#   curl -fsSL https://setup.ocx.sh/sh | sh -s -- --version 0.5.0
#
# Stdout/stderr contract (v2):
#   - All informational/warning/error messages go to STDERR.
#   - STDOUT is silent on success unless OCX_INSTALL_PRINT_PATH=1, in which
#     case the FINAL stdout line is the absolute path to the OCX bin dir.
#
# Exit codes:
#   0  success
#   1  generic / legacy
#   2  argument or environment validation
#   3  network / download / API failure
#   4  checksum mismatch
#   5  archive extraction failure
#   6  bootstrap ('ocx --remote package install') failure
#   7  unsupported platform / architecture

set -eu

has_local() { local _ 2>/dev/null; }
has_local || alias local=typeset

# --- Configuration (env-driven, Bazelisk-style) ---

OCX_INSTALL_REPO="${OCX_INSTALL_REPO:-ocx-sh/ocx}"
OCX_INSTALL_BASE_URL="${OCX_INSTALL_BASE_URL:-https://github.com/${OCX_INSTALL_REPO}/releases/download}"
OCX_INSTALL_API_URL="${OCX_INSTALL_API_URL:-https://api.github.com/repos/${OCX_INSTALL_REPO}/releases}"

# URL templates: placeholders {version}, {tag}, {target}, {ext}.
# Built via intermediate vars because '{tag}' literals inside ${VAR:-default}
# get eaten by the shell's brace-balanced default-value parser.
_default_format_url="${OCX_INSTALL_BASE_URL}/{tag}/ocx-{target}.{ext}"
_default_checksum_format_url="${OCX_INSTALL_BASE_URL}/{tag}/sha256.sum"
OCX_INSTALL_FORMAT_URL="${OCX_INSTALL_FORMAT_URL:-$_default_format_url}"
OCX_INSTALL_CHECKSUM_FORMAT_URL="${OCX_INSTALL_CHECKSUM_FORMAT_URL:-$_default_checksum_format_url}"
unset _default_format_url _default_checksum_format_url

# Behavioral knobs (truthy: 1, true, yes, TRUE, YES)
#
# OCX_INSTALL_SKIP_SELF_INIT: when truthy, place the extracted ocx binary at the
# canonical bin dir as a PLAIN directory (no package-store symlinks/manifests),
# put it on PATH and emit it for print-path, and SKIP both the networked
# 'ocx --remote package install' bootstrap AND env-shim/self-activate generation.
# This is binary-on-PATH only: 'ocx self update' will NOT manage such an install.
# It is the CI/GitLab path. Profile modification stays controlled by
# OCX_NO_MODIFY_PATH independently.
OCX_INSTALL_SKIP_SELF_INIT="${OCX_INSTALL_SKIP_SELF_INIT:-0}"
OCX_INSTALL_PRINT_PATH="${OCX_INSTALL_PRINT_PATH:-0}"
OCX_INSTALL_FORCE="${OCX_INSTALL_FORCE:-0}"
OCX_INSTALL_QUIET="${OCX_INSTALL_QUIET:-0}"
OCX_INSTALL_NO_BIN_SMOKETEST="${OCX_INSTALL_NO_BIN_SMOKETEST:-0}"
OCX_INSTALL_DOWNLOADER="${OCX_INSTALL_DOWNLOADER:-}"

# --- Truthy helper ---

is_truthy() {
    case "$1" in
        1 | true | yes | TRUE | YES | True | Yes) return 0 ;;
        *) return 1 ;;
    esac
}

# --- Output helpers (all go to STDERR) ---

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

# Replace $HOME prefix with ~ for user-facing display
tildify() {
    echo "$1" | sed "s|^${HOME}|~|"
}

# --- Core utilities ---

check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

need_cmd() {
    if ! check_cmd "$1"; then
        err "required command not found: $1" 2
    fi
}

ensure() {
    if ! "$@"; then err "command failed: $*"; fi
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

test_windows_posix() {
    case "$(uname)" in
        CYGWIN* | MSYS* | MINGW*) return 0 ;;
        *) return 1 ;;
    esac
}

# Convert a POSIX path to a native Windows path on Cygwin/MSYS/MinGW (where the
# path is embedded into env files consumed by native tooling). No-op elsewhere.
to_native_path() {
    if test_windows_posix && check_cmd cygpath; then
        cygpath -w "$1"
    else
        printf '%s' "$1"
    fi
}

# TTY/color detection — bold-only, respects NO_COLOR (https://no-color.org/)
# Color goes to stderr alongside the text it decorates.
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    _bold=$(tput bold 2>/dev/null || echo "")
    _reset=$(tput sgr0 2>/dev/null || echo "")
else
    _bold=""
    _reset=""
fi

# Substitute {version}, {tag}, {target}, {ext} placeholders in a URL template.
# Args: $1=template, $2=version, $3=tag, $4=target, $5=ext
format_url() {
    printf '%s' "$1" |
        sed -e "s|{version}|$2|g" \
            -e "s|{tag}|$3|g" \
            -e "s|{target}|$4|g" \
            -e "s|{ext}|$5|g"
}

# --- Usage ---

usage() {
    cat >&2 <<'EOF'
OCX installer — https://ocx.sh

USAGE:
    curl -fsSL https://setup.ocx.sh/sh | sh
    curl -fsSL https://setup.ocx.sh/sh | sh -s -- [OPTIONS]

OPTIONS:
    --version <VERSION>   Install a specific version (e.g., 0.5.0)
    --no-modify-path      Don't modify shell profile files
    -h, --help            Print this help message

ENVIRONMENT (user-facing):
    OCX_HOME                  Installation directory (default: ~/.ocx)
    OCX_NO_MODIFY_PATH        Set to 1/true/yes to skip shell profile modification
    GITHUB_TOKEN              GitHub API token (avoids rate limits)
    NO_COLOR                  Disable colored output (https://no-color.org/)

ENVIRONMENT (CI / mirror configuration, Bazelisk-style):
    OCX_INSTALL_REPO              GitHub owner/repo (default: ocx-sh/ocx)
    OCX_INSTALL_BASE_URL          Release-asset base URL
    OCX_INSTALL_API_URL           Release-list API URL (latest version lookup)
    OCX_INSTALL_FORMAT_URL        Template: placeholders {version},{tag},{target},{ext}
    OCX_INSTALL_CHECKSUM_FORMAT_URL  Template for sha256.sum URL
    OCX_INSTALL_SKIP_SELF_INIT    1 = drop binary on PATH only; skip 'ocx --remote
                                  package install' bootstrap + env-shim generation
    OCX_INSTALL_PRINT_PATH        1 = emit absolute bin dir on final stdout line
    OCX_INSTALL_FORCE             1 = reinstall even if same version is present
    OCX_INSTALL_QUIET             1 = suppress informational logs (warn/err remain)
    OCX_INSTALL_NO_BIN_SMOKETEST  1 = skip post-extract '$bin version' check
    OCX_INSTALL_DOWNLOADER        Force 'curl' or 'wget' (default: auto-detect)
EOF
}

# --- Platform detection ---

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

# --- Download utilities ---

# wget TLS fail-closed gate: refuse to proceed over plaintext. wget has no
# universal "https-only" flag, so we reject non-https URLs ourselves before
# any request leaves the machine.
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
        # --https-only refuses a redirect to http:// (assert_https_url only
        # vets the INITIAL URL; wget follows up to 20 redirects). TLSv1_2 floor.
        wget --secure-protocol=TLSv1_2 --https-only -q -O "$_dest" "$_url"
    fi
}

download() {
    if [ "$_downloader" = "curl" ]; then
        curl --proto '=https' --tlsv1.2 -fsSL "$1"
    else
        assert_https_url "$1"
        # See download_to_file: --https-only blocks redirect downgrade to http.
        wget --secure-protocol=TLSv1_2 --https-only -qO- "$1"
    fi
}

# Write the GitHub auth credential to a 0600 temp file so the token never
# appears in the process argument list (visible via 'ps'). curl reads it via
# '-H @file'; wget reads it via '--config' (wgetrc 'header =' directive).
# The file is removed by the caller.
write_token_header_file() {
    local _hdr
    _hdr=$(mktemp "${_tmpdir:-/tmp}/ocx-hdr.XXXXXX") || err "failed to create temp header file" 3
    chmod 600 "$_hdr"
    if [ "$_downloader" = "curl" ]; then
        printf 'Authorization: token %s\n' "${GITHUB_TOKEN}" >"$_hdr"
    else
        printf 'header = Authorization: token %s\n' "${GITHUB_TOKEN}" >"$_hdr"
    fi
    printf '%s' "$_hdr"
}

download_api() {
    local _url="$1" _hdr _out _rc

    if [ -n "${GITHUB_TOKEN:-}" ]; then
        _hdr=$(write_token_header_file)
        # Register the 0600 token file for trap cleanup so it is removed even if
        # the shell aborts here (defence-in-depth alongside the inline rm). The
        # curl/wget call is wrapped as an 'if' CONDITION so that a download
        # failure under 'set -e' does NOT abort at the assignment and leak the
        # token file — the assignment status is captured cleanly via $?.
        _api_hdr_file="$_hdr"
        _rc=0
        if [ "$_downloader" = "curl" ]; then
            if ! _out=$(curl --proto '=https' --tlsv1.2 -fsSL -H "@${_hdr}" "$_url"); then
                _rc=$?
            fi
        else
            assert_https_url "$_url"
            # --https-only blocks a redirect downgrade to http:// (token would
            # otherwise leak over plaintext); TLSv1_2 floor matches curl.
            if ! _out=$(wget --secure-protocol=TLSv1_2 --https-only -q \
                --config="$_hdr" -O- "$_url"); then
                _rc=$?
            fi
        fi
        ignore rm -f "$_hdr"
        _api_hdr_file=""
        [ "$_rc" -eq 0 ] || return "$_rc"
        printf '%s' "$_out"
    else
        download "$_url"
    fi
}

# --- Checksum verification ---

verify_checksum() {
    local _dir="$1" _file="$2" _sha_cmd _expected _actual

    if check_cmd sha256sum; then
        _sha_cmd="sha256sum"
    elif check_cmd shasum; then
        _sha_cmd="shasum -a 256"
    else
        warn "neither sha256sum nor shasum found — SKIPPING CHECKSUM VERIFICATION"
        warn "install coreutils or set PATH to include sha256sum for verified downloads"
        return 0
    fi

    # Exact field match: second column equals the file (stripping a leading '*'
    # that some sha256sum variants prepend for binary mode). Avoids the
    # substring collisions a loose 'grep -F' would allow.
    _expected=$(awk -v f="$_file" '{ n=$2; sub(/^\*/, "", n); if (n == f) { print $1; exit } }' "$_dir/sha256.sum")
    if [ -z "$_expected" ]; then
        err "checksum for $_file not found in sha256.sum" 4
    fi

    # shellcheck disable=SC2086
    _actual=$(cd "$_dir" && $_sha_cmd "$_file" | awk '{print $1}')

    if [ "$_expected" != "$_actual" ]; then
        err "checksum mismatch for $_file
  expected: $_expected
  got:      $_actual" 4
    fi

    say "Checksum verified."
}

# --- Safe archive extraction ---

# Two-pass extraction. Pass 1: list the archive and reject any entry that would
# escape the destination via an absolute path, a ".." traversal component, or a
# symlink/hardlink whose target escapes the tree. Pass 2: extract with
# ownership/permission/overwrite hardening flags. We do NOT rely on tar's own
# ".." rejection as the primary guard — the scans below are authoritative.
#
# Pass 1 runs over 'tar --list' (member NAMES only, one per line, no column
# parsing) so that names containing spaces (e.g. "keep/../../pwned thing")
# cannot smuggle a ".." past a substring-after-last-space parse. The grep
# pattern matches ".." only as a whole path component, or a leading "/", so
# legitimate names like "ocx..notes" are not false-rejected.
#
# Pass 2 runs over 'tar -tvf' to expose symlink/hardlink targets ("link ->
# target"), field-splitting on ' -> ' and rejoining fields 2..NF so targets that
# themselves contain ' -> ' survive intact, then walking '/'-split components and
# tracking depth so absolute, parent-prefix, AND middle-relative escapes
# (e.g. "subdir/../../etc/passwd") are all caught.
safe_extract() {
    local _archive="$1" _dest="$2" _bad_entry _bad_target

    # Pass 1: member-name traversal scan. Reject ".." as a whole path component
    # (delimited by start-of-string, "/", or end-of-string) or any leading "/".
    _bad_entry=$(tar --list -f "$_archive" 2>/dev/null |
        grep -E '(^|/)\.\.(/|$)|^/' || true)
    if [ -n "$_bad_entry" ]; then
        err "archive contains unsafe path: $_bad_entry" 5
    fi

    # Pass 2: symlink/hardlink target escape scan.
    _bad_target=$(tar -tvf "$_archive" 2>/dev/null |
        awk -F ' -> ' '
            /->/ {
                target = ""
                for (i = 2; i <= NF; i++) target = target (i == 2 ? "" : " -> ") $i
                # Absolute target — always rejected.
                if (substr(target, 1, 1) == "/") { print target; next }
                # Walk components, tracking resolved depth from the link dir.
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
        --no-same-owner --no-same-permissions --no-overwrite-dir 2>/dev/null ||
        err "failed to extract ${_archive} — ensure tar and xz-utils are installed" 5
}

# --- Version resolution ---

get_latest_version() {
    local _release_info _tag

    _release_info=$(download_api "${OCX_INSTALL_API_URL}/latest") || {
        if [ -z "${GITHUB_TOKEN:-}" ]; then
            err "failed to fetch latest release from GitHub
  This may be a rate-limit issue. Try setting GITHUB_TOKEN:
    export GITHUB_TOKEN=ghp_...
    curl -fsSL https://setup.ocx.sh/sh | sh" 3
        else
            err "failed to fetch latest release from GitHub — check your internet connection and token" 3
        fi
    }

    _tag=$(printf '%s' "$_release_info" |
        grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' |
        head -1 |
        grep -o '"[^"]*"$' |
        tr -d '"')

    if [ -z "$_tag" ]; then
        err "could not determine latest version from GitHub" 3
    fi

    printf '%s' "$_tag" | sed 's/^v//'
}

# --- Shell environment files ---

# Canonical CLI bin dir relative to OCX_HOME (real on-disk store layout):
#   $OCX_HOME/symlinks/ocx.sh/ocx/cli/current/content/bin
OCX_BIN_SUBPATH="symlinks/ocx.sh/ocx/cli/current/content/bin"

# Remove the legacy extensionless "$OCX_HOME/env" file. Earlier installers wrote
# it; it is now superseded by per-shell env.* shims and is known-stale.
remove_legacy_env_file() {
    local _ocx_home="${OCX_HOME:-$HOME/.ocx}"
    if [ -f "$_ocx_home/env" ]; then
        ignore rm -f "$_ocx_home/env"
    fi
}

# Generate the managed per-shell env shims. Each is a thin shim that, at shell
# startup, delegates to 'ocx self activate --shell=<shell>' (PATH prepend +
# completions + 'ocx --global env'), guarded by _OCX_ENV_LOADED so re-sourcing
# is a no-op. The native path of the bin dir is baked in so PATH works even
# before the binary itself runs.
create_env_file() {
    local _ocx_home="${OCX_HOME:-$HOME/.ocx}"
    local _bin_dir _bin_native _bin_native_nu_activate

    mkdir -p "$_ocx_home"
    _bin_dir="${_ocx_home}/${OCX_BIN_SUBPATH}"
    _bin_native=$(to_native_path "$_bin_dir")

    # nushell `source` needs a parse-time-constant LITERAL path that exists at
    # parse time; env.nu sources this stable file. Generate it (real activation
    # output when the binary runs, empty otherwise) so the literal is always
    # present and never a parse error.
    _bin_native_nu_activate=$(to_native_path "$_ocx_home/activate.nu")
    if [ -x "$_bin_dir/ocx" ]; then
        "$_bin_dir/ocx" self activate --shell=nushell >"$_ocx_home/activate.nu" 2>/dev/null ||
            : >"$_ocx_home/activate.nu"
    else
        : >"$_ocx_home/activate.nu"
    fi

    remove_legacy_env_file

    # POSIX (sh/dash/bash/zsh/ksh) -> env.sh
    cat >"$_ocx_home/env.sh" <<ENVEOF
#!/bin/sh
# OCX shell environment — generated by install.sh
# Sourced by your shell profile to add OCX to PATH and enable completions.
# Manual changes will be overwritten on reinstall.
if [ -z "\${_OCX_ENV_LOADED:-}" ]; then
  _OCX_ENV_LOADED=1
  export _OCX_ENV_LOADED
  case ":\${PATH}:" in
    *:"${_bin_native}":*) ;;
    *) export PATH="${_bin_native}:\${PATH}" ;;
  esac
  _ocx_bin="${_bin_native}/ocx"
  if [ -x "\$_ocx_bin" ]; then
    eval "\$("\$_ocx_bin" self activate --shell=sh 2>/dev/null)" 2>/dev/null || true
  fi
  unset _ocx_bin
fi
ENVEOF

    # fish -> env.fish
    cat >"$_ocx_home/env.fish" <<ENVEOF
# OCX shell environment — generated by install.sh
if not set -q _OCX_ENV_LOADED
  set -gx _OCX_ENV_LOADED 1
  if not contains "${_bin_native}" \$PATH
    set -gx PATH "${_bin_native}" \$PATH
  end
  set -l _ocx_bin "${_bin_native}/ocx"
  if test -x "\$_ocx_bin"
    "\$_ocx_bin" self activate --shell=fish 2>/dev/null | source
  end
end
ENVEOF

    # nushell -> env.nu
    #
    # nushell evaluates `source` at PARSE time and requires a parse-time-constant
    # LITERAL path that ALREADY EXISTS — you cannot `source` a variable, a
    # runtime-saved temp file, or a conditionally-present path (all are parse
    # errors that abort the whole file before the PATH prepend runs). So the old
    # "self activate | save tempfile; source tempfile" dance is fundamentally
    # impossible in nushell.
    #
    # Instead: PATH-prepend directly in the shim (the load-bearing activation),
    # and source a STABLE pre-generated activation file at a literal path
    # ($OCX_HOME/activate.nu, written by create_nu_config at install time). That
    # file carries the completions + `ocx --global env` that `self activate`
    # emits. The shim is robust even if the binary is missing (PATH prepend is
    # unconditional); the `source` literal is guaranteed present because
    # create_nu_config always (re)writes activate.nu next to env.nu.
    cat >"$_ocx_home/env.nu" <<ENVEOF
# OCX shell environment — generated by install.sh
# Manual changes will be overwritten on reinstall.
if (\$env._OCX_ENV_LOADED? | default '') != '' { return }
\$env._OCX_ENV_LOADED = '1'

if ("${_bin_native}" not-in \$env.PATH) {
  \$env.PATH = (\$env.PATH | prepend "${_bin_native}")
}

# The activation body (completions + \`ocx --global env\`) is best-effort: on a
# fresh store it can fail (no global toolchain, or its \`nu -c \$in\` subprocess
# cannot find \`nu\` on PATH). Wrap in \`try\` so such a failure does NOT abort the
# autoload and undo the PATH prepend above. \`source\` parses fine (the literal
# file is pre-generated by install.sh); only its runtime body is guarded.
try { source "${_bin_native_nu_activate}" }
ENVEOF

    # elvish -> env.elv
    #
    # The previous shim called `path:is-regular` WITHOUT `use path`; on elvish
    # 0.20.1/0.21.0 that throws `exec: "path:is-regular": executable file not
    # found` and aborts the shim before PATH is set. Two fixes, mirroring the
    # real ocx CLI installer's verified env.elv:
    #   1. Probe the binary with `?(test -x $_ocx_bin)` (external `test`, no
    #      `path:` module dependency) instead of `path:is-regular`.
    #   2. The `self activate --shell=elvish` output sets
    #      `edit:completion:arg-completer[ocx]`, a variable that exists ONLY in
    #      interactive elvish. In a non-interactive `-c` run that line throws
    #      "cannot find variable $edit:...". Wrapping the eval in `?(...)` (or a
    #      try) lets the PATH prepend (already done above) survive while the
    #      completion injection is best-effort — completions still load in a
    #      real interactive session where $edit: is present.
    cat >"$_ocx_home/env.elv" <<ENVEOF
# OCX shell environment — generated by install.sh
# Manual changes will be overwritten on reinstall.
if (has-env _OCX_ENV_LOADED) {
  return
}
set-env _OCX_ENV_LOADED 1

if (not (has-value \$paths "${_bin_native}")) {
  set paths = ["${_bin_native}" \$@paths]
}

var _ocx_bin = "${_bin_native}/ocx"
if ?(test -x \$_ocx_bin) {
  try {
    eval (e:\$_ocx_bin self activate --shell=elvish 2>/dev/null | slurp)
  } catch _ {
    # Completion injection requires interactive elvish (the edit: namespace);
    # ignore the failure in non-interactive sessions. PATH is already set.
  }
}
ENVEOF

    # powershell -> env.ps1
    cat >"$_ocx_home/env.ps1" <<ENVEOF
# OCX shell environment — generated by install.sh
if (-not \$env:_OCX_ENV_LOADED) {
  \$env:_OCX_ENV_LOADED = "1"
  if (\$env:PATH -notlike "*${_bin_native}*") {
    \$env:PATH = "${_bin_native}" + [IO.Path]::PathSeparator + \$env:PATH
  }
  \$_ocx_bin = "${_bin_native}/ocx"
  if (Test-Path \$_ocx_bin) {
    & \$_ocx_bin self activate --shell=powershell | Out-String | Invoke-Expression
  }
}
ENVEOF
}

# Fish loads env.fish through its conf.d autoload dir.
create_fish_config() {
    local _ocx_home="${OCX_HOME:-$HOME/.ocx}"
    local _fish_conf_dir _env_fish

    _fish_conf_dir="${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d"
    mkdir -p "$_fish_conf_dir"

    _env_fish=$(to_native_path "$_ocx_home/env.fish")

    cat >"$_fish_conf_dir/ocx.fish" <<FISHEOF
# OCX shell environment — generated by install.sh
# Guarded so that deleting \$OCX_HOME does not error on every new fish session.
if test -f "${_env_fish}"
  source "${_env_fish}"
end
FISHEOF
}

# --- Shell profile modification ---

# Emit the profile files OCX should write its source-block into for the active
# shell. Canon targets BOTH the login profile and the interactive rc so the
# env shim loads in either context. One path per line.
detect_profile() {
    local _shell_name _zdotdir

    _shell_name=$(basename "${SHELL:-sh}")

    case "$_shell_name" in
        bash)
            if [ -f "$HOME/.bash_profile" ]; then
                echo "$HOME/.bash_profile"
            else
                echo "$HOME/.profile"
            fi
            echo "$HOME/.bashrc"
            ;;
        zsh)
            _zdotdir="${ZDOTDIR:-$HOME}"
            # Filesystem-root write guard: never write into "/" if ZDOTDIR is
            # empty/misconfigured.
            if [ "$_zdotdir" = "/" ] || [ -z "$_zdotdir" ]; then
                _zdotdir="$HOME"
            fi
            echo "$_zdotdir/.zprofile"
            echo "$_zdotdir/.zshrc"
            ;;
        *)
            echo "$HOME/.profile"
            ;;
    esac
}

# Strip stale OCX lines from a profile: old extensionless "$OCX_HOME/env" source
# lines and old "$OCX_HOME/init.<shell>" source lines that predate the env.*
# shim layout. Idempotent; leaves the BEGIN/END block (added separately) intact.
remove_legacy_profile_lines() {
    local _profile="$1" _tmp

    [ -f "$_profile" ] || return 0
    grep -q -e '\.ocx/env"' -e '\.ocx/init\.' -e '/env"; then \. ' "$_profile" 2>/dev/null || return 0

    _tmp=$(mktemp "${_tmpdir:-/tmp}/ocx-prof.XXXXXX") || return 0
    grep -v \
        -e '\.ocx/env"' \
        -e '\.ocx/init\.' \
        "$_profile" >"$_tmp" 2>/dev/null || :
    cat "$_tmp" >"$_profile"
    ignore rm -f "$_tmp"
}

# Append the idempotent "# BEGIN ocx" / "# END ocx" source block to a profile.
write_profile_block() {
    local _profile="$1" _source_line="$2"

    remove_legacy_profile_lines "$_profile"

    if [ -f "$_profile" ] && grep -qF '# BEGIN ocx' "$_profile" 2>/dev/null; then
        say "Shell profile already configured ($(tildify "$_profile"))."
        return
    fi

    printf '\n# BEGIN ocx\n%s\n# END ocx\n' "$_source_line" >>"$_profile"
    say "Added OCX to $(tildify "$_profile")"
}

# Skip-self-init profile path: no env.sh shim exists, so write a profile block
# that prepends the canonical bin dir to PATH directly. Targets login +
# interactive profiles like modify_shell_profile.
modify_shell_profile_binary_only() {
    local _ocx_home="$1" _bin_dir _bin_native _source_line _profile

    _bin_dir="$_ocx_home/$OCX_BIN_SUBPATH"
    _bin_native=$(to_native_path "$_bin_dir")
    _source_line="case \":\${PATH}:\" in *:\"$_bin_native\":*) ;; *) export PATH=\"$_bin_native:\${PATH}\" ;; esac"

    detect_profile | while IFS= read -r _profile; do
        [ -n "$_profile" ] || continue
        write_profile_block "$_profile" "$_source_line"
    done
}

modify_shell_profile() {
    local _profile _source_line _ocx_home _env_path _shell_name

    _ocx_home="${OCX_HOME:-$HOME/.ocx}"
    _env_path="$_ocx_home/env.sh"

    if [ "$_ocx_home" = "$HOME/.ocx" ]; then
        # shellcheck disable=SC2016
        _source_line='[ -f "$HOME/.ocx/env.sh" ] && . "$HOME/.ocx/env.sh"'
    else
        _source_line="[ -f \"$_env_path\" ] && . \"$_env_path\""
    fi

    _shell_name=$(basename "${SHELL:-sh}")

    # fish and nushell load their shims through autoload dirs, not a profile
    # block. elvish gets a rc.elv block.
    case "$_shell_name" in
        fish)
            create_fish_config
            say "Created Fish configuration."
            return
            ;;
        nu)
            create_nu_config
            say "Created Nushell configuration."
            return
            ;;
        elvish)
            modify_elvish_rc
            return
            ;;
    esac

    detect_profile | while IFS= read -r _profile; do
        [ -n "$_profile" ] || continue
        write_profile_block "$_profile" "$_source_line"
    done
}

# Nushell loads env.nu through its vendor autoload dir.
#
# nushell's $nu.vendor-autoload-dirs are XDG_DATA-based, NOT XDG_CONFIG:
#   /usr/share/nushell/vendor/autoload,
#   /usr/local/share/nushell/vendor/autoload,
#   $XDG_DATA_HOME/nushell/vendor/autoload  (default ~/.local/share/...).
# Writing to ~/.config/nushell/vendor/autoload (the OLD bug) means the file is
# NEVER autoloaded. Use the per-user XDG_DATA path.
create_nu_config() {
    local _ocx_home="${OCX_HOME:-$HOME/.ocx}"
    local _nu_autoload _env_nu

    _nu_autoload="${XDG_DATA_HOME:-$HOME/.local/share}/nushell/vendor/autoload"
    mkdir -p "$_nu_autoload"

    _env_nu=$(to_native_path "$_ocx_home/env.nu")

    cat >"$_nu_autoload/ocx.nu" <<NUEOF
# OCX shell environment — generated by install.sh
source "${_env_nu}"
NUEOF
}

# Elvish sources env.elv via a BEGIN/END block in rc.elv.
modify_elvish_rc() {
    local _ocx_home="${OCX_HOME:-$HOME/.ocx}"
    local _rc _env_elv _source_line

    _rc="${XDG_CONFIG_HOME:-$HOME/.config}/elvish/rc.elv"
    mkdir -p "$(dirname "$_rc")"

    _env_elv=$(to_native_path "$_ocx_home/env.elv")
    _source_line="eval (slurp < \"${_env_elv}\")"

    if [ -f "$_rc" ] && grep -qF '# BEGIN ocx' "$_rc" 2>/dev/null; then
        say "Shell profile already configured ($(tildify "$_rc"))."
        return
    fi

    printf '\n# BEGIN ocx\n%s\n# END ocx\n' "$_source_line" >>"$_rc"
    say "Added OCX to $(tildify "$_rc")"
}

# --- Bootstrap: OCX installs itself ---

bootstrap_ocx() {
    local _bin="$1" _version="$2"

    say "Bootstrapping OCX into its own package store..."
    # --select is a boolean "set as current" flag; the package id is positional.
    if ! "$_bin" --remote package install --select "ocx.sh/ocx/cli:$_version"; then
        err "bootstrap failed: 'ocx --remote package install --select ocx.sh/ocx/cli:$_version'
  Ensure ocx v${_version} is published to the ocx.sh registry.
  If this is a first install and the registry is not yet populated,
  please wait for the release pipeline to complete.
  To skip the bootstrap step (offline / air-gapped installs), set
  OCX_INSTALL_SKIP_SELF_INIT=1." 6
    fi
}

# Skip-self-init path: place the extracted binary at the canonical bin dir as a
# PLAIN directory (no fabricated package-store symlinks/manifests), so it is on
# PATH for downstream consumers. This is binary-on-PATH only: 'ocx self update'
# will NOT manage such an install. It is the CI/GitLab path.
install_without_bootstrap() {
    local _bin="$1" _ocx_home="$2"
    local _bin_dir="$_ocx_home/$OCX_BIN_SUBPATH"

    say "Installing without self-init (OCX_INSTALL_SKIP_SELF_INIT=1)..."
    mkdir -p "$_bin_dir"
    cp -f "$_bin" "$_bin_dir/ocx"
    chmod +x "$_bin_dir/ocx"
}

# --- Success message ---

print_success() {
    local _version="$1" _ocx_home _env_display _old_version="${2:-}"

    is_truthy "$OCX_INSTALL_QUIET" && return 0

    _ocx_home="${OCX_HOME:-$HOME/.ocx}"
    _env_display=$(tildify "$_ocx_home/env.sh")

    if [ -n "$_old_version" ] && [ "$_old_version" != "$_version" ]; then
        printf '\n  %socx upgraded: %s -> %s%s\n' "$_bold" "$_old_version" "$_version" "$_reset" >&2
    else
        printf '\n  %socx %s installed successfully!%s\n' "$_bold" "$_version" "$_reset" >&2
    fi

    cat >&2 <<EOF

  To get started, restart your shell or run:

    . "$_env_display"

  Then verify with:

    ocx about

  To uninstall, remove the OCX home directory:

    rm -rf $_ocx_home

EOF
}

# --- Temp directory cleanup ---

cleanup() {
    # Remove the 0600 GitHub token header file if download_api was interrupted
    # mid-flight (defence-in-depth: download_api also rm's it inline on the
    # normal path, then clears this var).
    if [ -n "${_api_hdr_file:-}" ]; then
        ignore rm -f "$_api_hdr_file"
    fi
    if [ -n "${_tmpdir:-}" ]; then
        ignore rm -rf "$_tmpdir"
    fi
}

# --- OCX_HOME validation ---

# OCX_HOME is embedded verbatim into the generated env files, and CI may inject
# mirror config alongside it, so harden it: require an absolute path, reject
# ".." traversal, and reject shell metacharacters that could break out of the
# quoting in env.sh / profile source lines.
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

    # Reject shell metacharacters. $_home is embedded literally into the
    # generated env.* shims and the profile source line, so a CI-injected
    # OCX_HOME must not be able to break out of the quoted context. The newline
    # case uses a literal embedded newline inside the pattern (POSIX-portable;
    # avoids the non-POSIX $'\n'). Mirrors canon's metachar set.
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

# --- Main ---

main() {
    local _no_modify_path _version _target _tmpdir _archive _tag
    local _archive_url _checksum_url _bin _ocx_home _old_version
    local _bin_dir _ext

    _no_modify_path="${OCX_NO_MODIFY_PATH:-0}"
    _version=""

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

    need_cmd uname
    need_cmd mktemp
    need_cmd tar
    detect_downloader

    _ocx_home="${OCX_HOME:-$HOME/.ocx}"
    assert_safe_ocx_home "$_ocx_home"

    _target=$(detect_target)
    say "Detected platform: $_target"

    if [ -z "$_version" ]; then
        say "Fetching latest version..."
        _version=$(get_latest_version)
    fi

    if echo "$_version" | grep -q '[^0-9a-zA-Z.+-]'; then
        err "invalid version format: $_version (expected semver like 1.2.3 or 1.0.0-rc.1)" 2
    elif echo "$_version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]'; then
        : # valid
    else
        err "invalid version format: $_version (expected semver like 1.2.3)" 2
    fi

    _bin_dir="${_ocx_home}/${OCX_BIN_SUBPATH}"
    _old_version=""
    if [ -x "$_bin_dir/ocx" ]; then
        _old_version=$("$_bin_dir/ocx" version 2>/dev/null || echo "")
    fi

    # Force / idempotent fast-path
    if [ -n "$_old_version" ] && [ "$_old_version" = "$_version" ] && ! is_truthy "$OCX_INSTALL_FORCE"; then
        say "ocx v${_version} already installed at $(tildify "$_bin_dir/ocx") (set OCX_INSTALL_FORCE=1 to reinstall)"
        if is_truthy "$OCX_INSTALL_PRINT_PATH"; then
            printf '%s\n' "$_bin_dir"
        fi
        export_github_path
        exit 0
    fi

    say "Installing ocx v${_version}..."

    _tmpdir=$(mktemp -d)
    trap cleanup EXIT INT TERM HUP

    _ext="tar.xz"
    _tag="v${_version}"
    _archive="ocx-${_target}.${_ext}"
    _archive_url=$(format_url "$OCX_INSTALL_FORMAT_URL" "$_version" "$_tag" "$_target" "$_ext")
    _checksum_url=$(format_url "$OCX_INSTALL_CHECKSUM_FORMAT_URL" "$_version" "$_tag" "$_target" "$_ext")

    say "Downloading ${_archive}..."
    download_to_file "$_archive_url" "$_tmpdir/$_archive" ||
        err "failed to download ${_archive_url}
  Ensure v${_version} is a valid release with a binary for ${_target}.
  Available releases: https://github.com/${OCX_INSTALL_REPO}/releases" 3

    download_to_file "$_checksum_url" "$_tmpdir/sha256.sum" ||
        err "failed to download checksums from ${_checksum_url}" 3

    verify_checksum "$_tmpdir" "$_archive"

    safe_extract "$_tmpdir/$_archive" "$_tmpdir"

    # Keep BOTH layouts: nested (ocx-TARGET/ocx) for older archives and flat
    # (ocx at archive root) which is the real cargo-dist release layout.
    if [ -f "$_tmpdir/ocx-${_target}/ocx" ]; then
        _bin="$_tmpdir/ocx-${_target}/ocx"
    elif [ -f "$_tmpdir/ocx" ]; then
        _bin="$_tmpdir/ocx"
    else
        err "could not find ocx binary in archive" 5
    fi

    chmod +x "$_bin"

    if ! is_truthy "$OCX_INSTALL_NO_BIN_SMOKETEST"; then
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

    if is_truthy "$OCX_INSTALL_SKIP_SELF_INIT"; then
        # CI/GitLab path: drop the binary on PATH only. Skip the networked
        # bootstrap AND env-shim/self-activate generation. Profile modification
        # remains independently controlled by OCX_NO_MODIFY_PATH below.
        install_without_bootstrap "$_bin" "$_ocx_home"
        say "Installed to $(tildify "${_bin_dir}/ocx")"
    else
        bootstrap_ocx "$_bin" "$_version"
        say "Installed to $(tildify "${_bin_dir}/ocx")"

        create_env_file

        if check_cmd fish; then
            create_fish_config
        fi
    fi

    if [ "$_no_modify_path" = "1" ]; then
        say "Skipping shell profile modification (--no-modify-path)."
    elif is_truthy "$OCX_INSTALL_SKIP_SELF_INIT"; then
        # No env.sh shim exists in skip-self-init mode; only the binary is on
        # PATH. Prepend the bin dir directly via the profile source block so
        # interactive shells still find it.
        modify_shell_profile_binary_only "$_ocx_home"
    else
        modify_shell_profile
    fi

    export_github_path

    if ! is_truthy "$OCX_INSTALL_SKIP_SELF_INIT"; then
        print_success "$_version" "$_old_version"
    fi

    if is_truthy "$OCX_INSTALL_PRINT_PATH"; then
        printf '%s\n' "$_bin_dir"
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

main "$@"
