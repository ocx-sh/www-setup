#!/usr/bin/env fish
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
#
# install.fish — OCX installer for the fish shell (Unix + macOS; fish is not
# supported on Windows by design).
# https://ocx.sh
#
# This is a THIN BOOTSTRAP. It detects the platform, resolves the release from
# the self-hosted distribution manifest (dist.json), downloads + verifies the
# archive against the manifest's inline sha256, then hands off to the downloaded
# binary's `ocx self setup`. `ocx self setup` owns everything that touches the
# machine — the package-store self-install, the per-shell env shims under
# $OCX_HOME, and the managed shell-profile activation blocks.
#
# Usage:
#   curl -fsSL https://setup.ocx.sh/fish | fish
#   curl -fsSL https://setup.ocx.sh/fish | fish -s -- --no-modify-path
#   set -x OCX_INSTALL_VERSION 0.5.0; curl -fsSL https://setup.ocx.sh/fish | fish
#
# Stdout/stderr contract (load-bearing):
#   - All informational/warning/error messages go to STDERR.
#   - STDOUT is silent on success unless OCX_INSTALL_PRINT_PATH is truthy, in
#     which case the FINAL stdout line is the absolute path to the OCX bin dir.
#
# Exit codes: 0 ok · 1 generic · 2 arg/env · 3 network/download/manifest ·
#             4 checksum · 5 extract · 6 'ocx self setup' · 7 unsupported platform

# --- Truthy helper ----------------------------------------------------------

function __ocx_is_truthy --argument-names value
    # Case-sensitive match over exactly: 1 true yes TRUE YES True Yes
    switch $value
        case 1 true yes TRUE YES True Yes
            return 0
        case '*'
            return 1
    end
end

# --- Configuration ----------------------------------------------------------

set -q OCX_INSTALL_REPO; or set -g OCX_INSTALL_REPO ocx-sh/ocx
set -q OCX_INSTALL_DIST_URL; or set -g OCX_INSTALL_DIST_URL 'https://setup.ocx.sh/dist.json'
set -q OCX_INSTALL_MIRROR_URL; or set -g OCX_INSTALL_MIRROR_URL ''
set -q OCX_INSTALL_VERSION; or set -g OCX_INSTALL_VERSION ''
set -q OCX_INSTALL_NO_SETUP; or set -g OCX_INSTALL_NO_SETUP 0
set -q OCX_INSTALL_NO_SMOKETEST; or set -g OCX_INSTALL_NO_SMOKETEST 0
set -q OCX_INSTALL_PRINT_PATH; or set -g OCX_INSTALL_PRINT_PATH 0
set -q OCX_INSTALL_FORCE; or set -g OCX_INSTALL_FORCE 0
set -q OCX_INSTALL_QUIET; or set -g OCX_INSTALL_QUIET 0

# Canonical CLI bin dir relative to OCX_HOME (the real on-disk store layout).
set -g OCX_BIN_SUBPATH 'symlinks/ocx.sh/ocx/cli/current/content/bin'

# --- Output helpers (all go to STDERR) --------------------------------------

function __ocx_say --argument-names msg
    __ocx_is_truthy $OCX_INSTALL_QUIET; and return 0
    echo "ocx-install: $msg" >&2
end

function __ocx_warn --argument-names msg
    echo "ocx-install: warning: $msg" >&2
end

# __ocx_err <msg> [code]
function __ocx_err
    echo "ocx-install: error: $argv[1]" >&2
    if set -q argv[2]
        exit $argv[2]
    end
    exit 1
end

# --- Usage ------------------------------------------------------------------

function __ocx_usage
    echo "OCX installer — https://ocx.sh

USAGE:
    curl -fsSL https://setup.ocx.sh/fish | fish
    curl -fsSL https://setup.ocx.sh/fish | fish -s -- [OPTIONS]

OPTIONS:
    --version <VERSION>   Install a specific version (e.g., 0.5.0).
                          Equivalent to OCX_INSTALL_VERSION=<VERSION>.
    --no-modify-path      Don't modify shell profile files.
    -h, --help            Print this help message.

ENVIRONMENT:
    OCX_HOME, OCX_NO_MODIFY_PATH, NO_COLOR
    OCX_INSTALL_VERSION, OCX_INSTALL_REPO, OCX_INSTALL_DIST_URL,
    OCX_INSTALL_MIRROR_URL, OCX_INSTALL_NO_SETUP, OCX_INSTALL_NO_SMOKETEST,
    OCX_INSTALL_FORCE, OCX_INSTALL_QUIET, OCX_INSTALL_PRINT_PATH" >&2
end

# --- Platform detection -----------------------------------------------------

function __ocx_detect_target
    set -l os (uname -s)
    set -l arch (uname -m)

    switch $arch
        case x86_64 amd64
            set arch x86_64
        case aarch64 arm64
            set arch aarch64
        case '*'
            __ocx_err "unsupported architecture: $arch (expected x86_64 or aarch64)" 7
    end

    switch $os
        case Linux
            set -l libc gnu
            if command -q ldd; and ldd --version 2>&1 | string match -qi '*musl*'
                set libc musl
            else if test -f /etc/alpine-release
                set libc musl
            else
                # Glob via `find` (a bare fish glob errors when it matches
                # nothing) to catch non-Alpine musl distros where ldd is absent.
                set -l ldso (find /lib /usr/lib -maxdepth 1 -name 'ld-musl-*.so.1' 2>/dev/null)
                if test -n "$ldso"
                    set libc musl
                end
            end
            echo "$arch-unknown-linux-$libc"
        case Darwin
            # Rosetta: prefer native arm64 on Apple Silicon reporting x86_64.
            if test "$arch" = x86_64; and test (sysctl -n hw.optional.arm64 2>/dev/null) = 1
                set arch aarch64
            end
            echo "$arch-apple-darwin"
        case '*'
            __ocx_err "unsupported operating system: $os (expected Linux or macOS)" 7
    end
end

# --- Download utilities -----------------------------------------------------

function __ocx_assert_https --argument-names url
    string match -q -- 'https://*' $url; and return 0
    __ocx_err "refusing insecure (non-https) URL: $url" 3
end

# __ocx_download <url> -> stdout
function __ocx_download --argument-names url
    if command -q curl
        curl --proto '=https' --tlsv1.2 -fsSL $url
    else if command -q wget
        __ocx_assert_https $url
        wget --secure-protocol=TLSv1_2 --https-only -qO- $url
    else
        __ocx_err "either curl or wget is required to download OCX" 2
    end
end

# __ocx_download_file <url> <dest>
function __ocx_download_file --argument-names url dest
    if command -q curl
        curl --proto '=https' --tlsv1.2 -fsSL -o $dest $url
    else if command -q wget
        __ocx_assert_https $url
        wget --secure-protocol=TLSv1_2 --https-only -q -O $dest $url
    else
        __ocx_err "either curl or wget is required to download OCX" 2
    end
end

# --- Checksum verification --------------------------------------------------

# __ocx_verify_checksum <file> <expected_sha256>
function __ocx_verify_checksum --argument-names file expected
    set -l actual ''
    if command -q sha256sum
        set actual (sha256sum $file | string split ' ')[1]
    else if command -q shasum
        set actual (shasum -a 256 $file | string split ' ')[1]
    else
        __ocx_warn "neither sha256sum nor shasum found — SKIPPING CHECKSUM VERIFICATION"
        return 0
    end
    set -l exp (string lower $expected)
    set actual (string lower $actual)
    if test "$exp" != "$actual"
        __ocx_err "checksum mismatch for "(basename $file)\n"  expected: $exp"\n"  got:      $actual" 4
    end
    __ocx_say "Checksum verified."
end

# --- Safe archive extraction ------------------------------------------------

# Member-name pre-scan (reject absolute paths and ".." components) into a fresh
# temp subdir, then extract with ownership/permission hardening. The inline
# checksum is the primary integrity guard.
function __ocx_safe_extract --argument-names archive dest
    set -l bad (tar --list -f $archive 2>/dev/null | string match -r '(^|/)\.\.(/|$)|^/')
    if test -n "$bad"
        __ocx_err "archive contains unsafe path: $bad" 5
    end
    # Only flags accepted by BOTH GNU tar and macOS bsdtar (--no-overwrite-dir is GNU-only).
    if not tar xf $archive -C $dest --no-same-owner --no-same-permissions 2>/dev/null
        __ocx_err "failed to extract $archive — ensure tar and xz-utils are installed" 5
    end
end

# --- Distribution manifest (dist.json) --------------------------------------
#
# dist.json has FLAT leaf objects, one per line (no nested braces). We parse
# without jq using `string match -r` on each line.

# __ocx_dist_latest <dist> -> latest stable version (or err 3)
function __ocx_dist_latest --argument-names dist
    for line in (string split \n -- $dist)
        if string match -q -- '*"channel"*:*"stable"*' $line
            set -l m (string match -r '"version"\s*:\s*"([^"]*)"' -- $line)
            if test (count $m) -ge 2
                echo (string replace -r '^v' '' $m[2])
                return 0
            end
        end
    end
    __ocx_err "failed to determine the latest version: no stable release in the manifest at $OCX_INSTALL_DIST_URL" 3
end

# __ocx_dist_row <dist> <version> <target> -> the matching flat object line
function __ocx_dist_row --argument-names dist ocxver target
    for line in (string split \n -- $dist)
        if string match -q -- "*\"version\":\"$ocxver\"*" $line; and string match -q -- "*\"target\":\"$target\"*" $line
            echo $line
            return 0
        end
    end
    return 1
end

# __ocx_json_field <object-line> <field> -> string value (or empty)
function __ocx_json_field --argument-names obj field
    set -l m (string match -r "\"$field\"\s*:\s*\"([^\"]*)\"" -- $obj)
    if test (count $m) -ge 2
        echo $m[2]
    end
end

# --- Hand off to `ocx self setup` -------------------------------------------

# __ocx_run_self_setup <bin> <pre...> -- <post...>
# Global pre-flags precede `self setup`; subcommand args/flags follow it.
function __ocx_run_self_setup
    set -l bin $argv[1]
    set -l rest $argv[2..-1]
    set -l sep (contains -i -- -- $rest)
    set -l pre
    set -l post
    if test -n "$sep"
        # pre = everything before the `--`; guard the sep==1 case (no pre) so we
        # never form the reverse range $rest[1..0].
        if test $sep -gt 1
            set pre $rest[1..(math $sep - 1)]
        end
        if test $sep -lt (count $rest)
            set post $rest[(math $sep + 1)..-1]
        end
    else
        set pre $rest
    end
    __ocx_say "Running ocx self setup..."
    if not $bin $pre self setup $post
        __ocx_err "'ocx self setup' failed — see the output above for details" 6
    end
end

function __ocx_export_github_path --argument-names ocx_home
    if set -q GITHUB_PATH
        echo "$ocx_home/$OCX_BIN_SUBPATH" >>$GITHUB_PATH
        or __ocx_warn "failed to write to \$GITHUB_PATH"
    end
end

# --- OCX_HOME validation ----------------------------------------------------

function __ocx_assert_safe_ocx_home --argument-names home
    if not string match -q -- '/*' $home
        __ocx_err "OCX_HOME must be an absolute path (got: $home)" 2
    end
    if string match -q -- '*/../*' $home; or string match -q -- '*/..' $home; or string match -q -- '../*' $home; or test "$home" = '..'
        __ocx_err "OCX_HOME must not contain '..' (got: $home)" 2
    end
    # Reject shell metacharacters. The class needs a LITERAL backslash, which is
    # `\\` in PCRE; fish single-quotes collapse `\\` -> `\`, so we write `\\\\`
    # (four) to land two backslashes in the regex. (A bare `\n` here would instead
    # add the letter `n` to the class — see the fish single-quote rules.)
    if string match -rq -- '["`$;&|<>()\\\\]' $home
        __ocx_err "OCX_HOME contains characters unsafe for shell embedding (got: $home)" 2
    end
end

# --- Main -------------------------------------------------------------------

function __ocx_main
    set -l no_modify_path 0
    if set -q OCX_NO_MODIFY_PATH; and __ocx_is_truthy $OCX_NO_MODIFY_PATH
        set no_modify_path 1
    end
    set -l ocxver $OCX_INSTALL_VERSION

    # Arg parsing (fish -s -- ...): --version=, --no-modify-path, -h/--help.
    argparse 'version=' no-modify-path h/help -- $argv
    or __ocx_err "invalid arguments (use --help for usage)" 2
    if set -q _flag_help
        __ocx_usage
        exit 0
    end
    set -q _flag_version; and set ocxver $_flag_version
    set -q _flag_no_modify_path; and set no_modify_path 1

    set -l ocx_home
    if set -q OCX_HOME; and test -n "$OCX_HOME"
        set ocx_home $OCX_HOME
    else
        set ocx_home "$HOME/.ocx"
    end
    __ocx_assert_safe_ocx_home $ocx_home
    set -l bin_dir "$ocx_home/$OCX_BIN_SUBPATH"

    set -l post
    if test "$no_modify_path" = 1
        set post --no-modify-path
    end

    # --- Internal test-mode hatch (UNDOCUMENTED) ---
    if set -q __OCX_TESTING_INSTALL_BINARY; and test -n "$__OCX_TESTING_INSTALL_BINARY"
        if not test -f "$__OCX_TESTING_INSTALL_BINARY"
            __ocx_err "__OCX_TESTING_INSTALL_BINARY does not point to a file: $__OCX_TESTING_INSTALL_BINARY" 2
        end
        __ocx_say "Test mode: installing local binary as the candidate (no download)."
        mkdir -p $bin_dir
        cp -f $__OCX_TESTING_INSTALL_BINARY "$bin_dir/ocx"
        chmod +x "$bin_dir/ocx"
        if __ocx_is_truthy $OCX_INSTALL_NO_SETUP
            __ocx_say "Skipping 'ocx self setup' (OCX_INSTALL_NO_SETUP)."
        else
            __ocx_run_self_setup "$bin_dir/ocx" --offline -- $post
        end
        __ocx_export_github_path $ocx_home
        if __ocx_is_truthy $OCX_INSTALL_PRINT_PATH
            echo $bin_dir
        end
        return 0
    end

    set -l target (__ocx_detect_target)
    __ocx_say "Detected platform: $target"

    # `string collect` keeps the multi-line manifest as ONE list element;
    # otherwise fish splits it on newlines and passing $dist to a function would
    # expand into many positional args and misalign --argument-names. A fetch
    # failure yields an empty capture, caught below.
    set -l dist (__ocx_download $OCX_INSTALL_DIST_URL | string collect)
    if test -z "$dist"
        __ocx_err "failed to determine the latest version from $OCX_INSTALL_DIST_URL
  (fetch failed or empty manifest). Check your connection, or pin OCX_INSTALL_VERSION." 3
    end

    if test -z "$ocxver"
        __ocx_say "Resolving latest version..."
        set ocxver (__ocx_dist_latest $dist)
    end

    if not string match -rq -- '^[0-9]+\.[0-9]+\.[0-9]' $ocxver; or string match -rq -- '[^0-9A-Za-z.+-]' $ocxver
        __ocx_err "invalid version format: $ocxver (expected semver like 1.2.3)" 2
    end

    # Idempotent fast-path.
    if test -x "$bin_dir/ocx"
        set -l old (eval "$bin_dir/ocx" version 2>/dev/null)
        if test -n "$old"; and test "$old" = "$ocxver"; and not __ocx_is_truthy $OCX_INSTALL_FORCE
            __ocx_say "ocx v$ocxver already installed at $bin_dir/ocx (set OCX_INSTALL_FORCE=1 to reinstall)"
            __ocx_export_github_path $ocx_home
            if __ocx_is_truthy $OCX_INSTALL_PRINT_PATH
                echo $bin_dir
            end
            return 0
        end
    end

    set -l row (__ocx_dist_row $dist $ocxver $target)
    if test -z "$row"
        __ocx_err "no published artifact for ocx v$ocxver on $target in the manifest at $OCX_INSTALL_DIST_URL" 3
    end
    set -l sha (__ocx_json_field $row sha256)
    set -l url (__ocx_json_field $row url)
    set -l filename (__ocx_json_field $row filename)
    set -l tag (__ocx_json_field $row tag)
    if test -z "$url"; or test -z "$filename"
        __ocx_err "manifest row for v$ocxver/$target is missing url/filename" 3
    end

    if test -n "$OCX_INSTALL_MIRROR_URL"
        set url (string trim --right --chars=/ $OCX_INSTALL_MIRROR_URL)"/$tag/$filename"
    end

    __ocx_say "Installing ocx v$ocxver..."
    set -l tmpdir (mktemp -d)
    set -l archive "$tmpdir/$filename"

    if not __ocx_download_file $url $archive
        rm -rf $tmpdir
        __ocx_err "failed to download $url
  Ensure v$ocxver is a valid release with a binary for $target.
  Available releases: https://github.com/$OCX_INSTALL_REPO/releases" 3
    end

    if test -n "$sha"
        __ocx_verify_checksum $archive $sha
    else
        __ocx_warn "no inline checksum for $filename in the manifest — skipping verification"
    end

    __ocx_safe_extract $archive $tmpdir

    set -l bin
    if test -f "$tmpdir/ocx-$target/ocx"
        set bin "$tmpdir/ocx-$target/ocx"
    else if test -f "$tmpdir/ocx"
        set bin "$tmpdir/ocx"
    else
        rm -rf $tmpdir
        __ocx_err "could not find ocx binary in archive" 5
    end
    chmod +x $bin

    if not __ocx_is_truthy $OCX_INSTALL_NO_SMOKETEST
        if not $bin version >/dev/null 2>&1
            __ocx_warn "binary failed to execute in temp directory — your /tmp may be mounted with noexec"
        end
    end

    if __ocx_is_truthy $OCX_INSTALL_NO_SETUP
        mkdir -p $bin_dir
        cp -f $bin "$bin_dir/ocx"
        chmod +x "$bin_dir/ocx"
        __ocx_say "Installed to $bin_dir/ocx"
    else
        __ocx_run_self_setup $bin -- $ocxver $post
    end

    rm -rf $tmpdir
    __ocx_export_github_path $ocx_home
    if __ocx_is_truthy $OCX_INSTALL_PRINT_PATH
        echo $bin_dir
    end
end

__ocx_main $argv
