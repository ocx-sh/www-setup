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

# --- Embedded configuration (sed-able) --------------------------------------
#
# Corporate mirrors host ONE patched copy of this installer, carrying the site
# defaults with it. Replace the placeholder values below with sed:
#
#   sed -i "s|<TOKEN>|https://artifactory.corp/ocx/dist.json|" install.*
#
# Each <TOKEN> is named for the environment variable it backs and is spelled
# identically in all five installers (install.sh ps1 nu fish elv), so ONE
# command patches every dialect. Values are single-quoted, which in every
# dialect means no interpolation and newlines allowed — an entire PEM block can
# be substituted for the CA bundle. Values must not contain a single quote.
#
# Precedence: environment > embedded > built-in default. A placeholder left
# unreplaced still matches @OCX_*@ and is ignored, so a pristine installer
# behaves exactly as it always has.

set -g __ocx_cfg_dist_url '@OCX_INSTALL_DIST_URL@'
set -g __ocx_cfg_mirror_url '@OCX_INSTALL_MIRROR_URL@'
set -g __ocx_cfg_ca_bundle '@OCX_INSTALL_CA_BUNDLE@'
set -g __ocx_cfg_managed_config '@OCX_MANAGED_CONFIG@'

# __ocx_cfg <embedded> <fallback> — echo the embedded value unless it is still
# an unreplaced placeholder. The guard carries no complete token, so no sed of a
# token above can ever rewrite it.
function __ocx_cfg --argument-names embedded fallback
    if string match -q -- '@OCX_*@' "$embedded"
        echo $fallback
    else
        echo $embedded
    end
end

# --- Configuration ----------------------------------------------------------

set -q OCX_INSTALL_REPO; or set -g OCX_INSTALL_REPO ocx-sh/ocx
set -q OCX_INSTALL_DIST_URL; or set -g OCX_INSTALL_DIST_URL (__ocx_cfg $__ocx_cfg_dist_url 'https://setup.ocx.sh/dist.json')
set -q OCX_INSTALL_MIRROR_URL; or set -g OCX_INSTALL_MIRROR_URL (__ocx_cfg $__ocx_cfg_mirror_url '')
set -q OCX_INSTALL_VERSION; or set -g OCX_INSTALL_VERSION ''
set -q OCX_INSTALL_NO_SETUP; or set -g OCX_INSTALL_NO_SETUP 0
set -q OCX_INSTALL_NO_SMOKETEST; or set -g OCX_INSTALL_NO_SMOKETEST 0
set -q OCX_INSTALL_PRINT_PATH; or set -g OCX_INSTALL_PRINT_PATH 0
set -q OCX_INSTALL_FORCE; or set -g OCX_INSTALL_FORCE 0
set -q OCX_INSTALL_QUIET; or set -g OCX_INSTALL_QUIET 0

# CA bundle for every download — TLS-intercepting corporate proxies. Trust only;
# the inline sha256 from dist.json stays the integrity boundary.
#
# NOT resolved through a command substitution: the value may be a whole PEM
# block, and `(...)` splits command output on newlines, which would turn one
# multi-line string into a list of lines. Assign the literal directly.
if not set -q OCX_INSTALL_CA_BUNDLE
    if string match -q -- '@OCX_*@' "$__ocx_cfg_ca_bundle"
        set -g OCX_INSTALL_CA_BUNDLE ''
    else
        set -g OCX_INSTALL_CA_BUNDLE $__ocx_cfg_ca_bundle
    end
end

# Corporate managed-config OCI ref, forwarded to `ocx self setup --managed-config`.
# ONLY from the embedded block: when OCX_MANAGED_CONFIG is exported, the flag is
# omitted so `ocx self setup` reads the env itself (its own documented order is
# flag > OCX_MANAGED_CONFIG > existing seed), which keeps env ahead of embedded.
set -g __ocx_managed_config ''
if not set -q OCX_MANAGED_CONFIG; or test -z "$OCX_MANAGED_CONFIG"
    set -g __ocx_managed_config (__ocx_cfg $__ocx_cfg_managed_config '')
end

# Canonical CLI bin dir relative to OCX_HOME (the real on-disk store layout).
set -g OCX_BIN_SUBPATH 'symlinks/ocx.sh/ocx/cli/current/content/bin'

# Attempts per network fetch (see __ocx_download_file). Deliberately not an
# OCX_INSTALL_* knob — three is right for a transient edge failure.
set -g __ocx_download_attempts 3

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
    OCX_HOME, OCX_NO_MODIFY_PATH, OCX_MANAGED_CONFIG, NO_COLOR
    OCX_INSTALL_VERSION, OCX_INSTALL_REPO, OCX_INSTALL_DIST_URL,
    OCX_INSTALL_MIRROR_URL, OCX_INSTALL_NO_SETUP, OCX_INSTALL_NO_SMOKETEST,
    OCX_INSTALL_FORCE, OCX_INSTALL_QUIET, OCX_INSTALL_PRINT_PATH,
    OCX_INSTALL_CA_BUNDLE" >&2
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

# A downloader is a PRECONDITION, asserted once in statement position.
#
# __ocx_download_file is called from `if not …` / `; or …` conjunctions, and fish
# demotes an `exit` inside a conditional's command to a plain stop with status
# ZERO — so raising this from in there ended the run reporting success while
# installing nothing. Check it up front instead, where `exit` means exit.
function __ocx_require_downloader
    if not command -q curl; and not command -q wget
        __ocx_err "either curl or wget is required to download OCX" 2
    end
end

# __ocx_download_once <url> <dest>
#
# The CA bundle is passed as its own argv element rather than spliced into an
# unquoted flag string, so a path containing spaces still works.
function __ocx_download_once --argument-names url dest
    if command -q curl
        if test -n "$OCX_INSTALL_CA_BUNDLE"
            curl --proto '=https' --tlsv1.2 --cacert "$OCX_INSTALL_CA_BUNDLE" -fsSL -o $dest $url
        else
            curl --proto '=https' --tlsv1.2 -fsSL -o $dest $url
        end
    else if command -q wget
        __ocx_assert_https $url
        if test -n "$OCX_INSTALL_CA_BUNDLE"
            wget --secure-protocol=TLSv1_2 --https-only --ca-certificate="$OCX_INSTALL_CA_BUNDLE" -q -O $dest $url
        else
            wget --secure-protocol=TLSv1_2 --https-only -q -O $dest $url
        end
    else
        __ocx_err "either curl or wget is required to download OCX" 2
    end
end

# __ocx_download_file <url> <dest>
#
# Bounded retry around every network hop. A single transient failure must not
# abort an install: an edge PoP can serve a 5xx while every other one is
# healthy, and both fetches (manifest, archive) are idempotent GETs.
#
# ponytail: retries on ANY failure instead of inspecting the status code —
# doing that would mean parsing curl/wget errors in five dialects. The ceiling
# is that a genuine 404 costs two extra requests before it still exits 3.
function __ocx_download_file --argument-names url dest
    set -l attempt 1
    set -l delay 1
    while true
        if __ocx_download_once $url $dest
            return 0
        end
        if test $attempt -ge $__ocx_download_attempts
            return 1
        end
        __ocx_say "download failed (attempt $attempt/$__ocx_download_attempts), retrying in {$delay}s"
        sleep $delay
        set attempt (math "$attempt + 1")
        set delay (math "$delay * 2")
    end
end

# --- Checksum verification --------------------------------------------------

# __ocx_verify_checksum <file> <expected_sha256> [required]
#
# A non-empty `required` makes a missing sha256 tool FATAL instead of a warning.
# On the content-addressed manifest path the digest is the only thing
# authenticating the pin, so degrading to "unverified" there would hand back
# whatever the mirror served while the URL still claimed to be a pin.
function __ocx_verify_checksum --argument-names file expected required
    set -l actual ''
    if command -q sha256sum
        set actual (sha256sum $file | string split ' ')[1]
    else if command -q shasum
        set actual (shasum -a 256 $file | string split ' ')[1]
    else if test -n "$required"
        __ocx_err "neither sha256sum nor shasum found — cannot verify the pinned manifest at $OCX_INSTALL_DIST_URL
  Install coreutils, or point OCX_INSTALL_DIST_URL at the rolling manifest." 2
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

# --- Distribution manifest fetch --------------------------------------------

# Echo the sha256 a manifest URL pins itself to, or nothing for a rolling URL.
#
# `ocx-mirror dist sync` keeps every manifest it has ever published at
# dist/<sha256>.json beside the rolling dist.json, and so does setup.ocx.sh.
# Pointing OCX_INSTALL_DIST_URL at one of those pins the WHOLE closure — every
# release row carries an inline sha256 — so checking the body against the digest
# in its own name makes the pin self-authenticating and leaves the mirror as
# pure transport. Unverified, a content-addressed URL is just a URL.
function __ocx_dist_pin_digest --argument-names url
    set -l base (string replace -r '[?#].*$' '' -- $url)
    set -l m (string match -r '^([0-9a-f]{64})\.json$' -- (basename $base))
    test (count $m) -ge 2; and echo $m[2]
end

# __ocx_fetch_dist <url> <dest> — download the manifest, verifying it when the
# URL pins its own digest. Non-zero on a download failure; a digest mismatch is
# fatal (exit 4) via __ocx_verify_checksum.
#
# Staged to a file rather than echoed: the digest covers the bytes as served, and
# a command substitution would strip the manifest's trailing newline. It also
# keeps __ocx_verify_checksum out of a command substitution, where its `exit`
# would end only the capture and the caller would report the wrong code.
function __ocx_fetch_dist --argument-names url dest
    set -l pin (__ocx_dist_pin_digest $url)
    __ocx_download_file $url $dest; or return 1
    if test -n "$pin"
        __ocx_verify_checksum $dest $pin required
    end
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
        __ocx_err "failed to extract $archive — ensure tar is installed" 5
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
    # The CA bundle is either a path or the PEM text itself. The embedded
    # placeholder is single-quoted in every dialect and single quotes span
    # newlines, so a whole PEM block can be substituted straight into the
    # script — no second file to ship alongside the mirrored installer. Inline
    # PEM is materialized to a temp file (mktemp creates it 0600), which is what
    # curl/wget need; it is a public certificate, so it is left for TMPDIR to
    # reap rather than threaded through every error path.
    # A real bundle may open with comment lines or a certificate label
    # (Fedora/RHEL ship exactly that), so detect PEM by CONTENT, not by a
    # leading marker: a filesystem path can never contain "-----BEGIN".
    set -l ca_raw "$OCX_INSTALL_CA_BUNDLE"
    if string match -q -- '*-----BEGIN*' "$OCX_INSTALL_CA_BUNDLE"
        set -l ca_tmp (mktemp)
        printf '%s\n' "$OCX_INSTALL_CA_BUNDLE" >$ca_tmp
        set -g OCX_INSTALL_CA_BUNDLE $ca_tmp
    else if test -n "$OCX_INSTALL_CA_BUNDLE"; and not test -r "$OCX_INSTALL_CA_BUNDLE"
        __ocx_err "OCX_INSTALL_CA_BUNDLE is neither a readable file nor an inline PEM block: $OCX_INSTALL_CA_BUNDLE" 2
    end
    # `ocx self setup` does its own HTTPS work (it pulls the package store from
    # the registry), so the same bundle is handed down — that is what makes ONE
    # corporate CA cover BOTH hops. Two variables, because two ocx generations:
    #   * OCX_EXTRA_CA_CERTS — the value AS SUPPLIED (path or PEM text; ocx does
    #     the same content sniff). `ocx self setup` persists the certificate
    #     text into $OCX_HOME/config.toml, so every later ocx invocation trusts
    #     the CA, on every OS. An older ocx ignores the unknown variable.
    #   * SSL_CERT_FILE — the materialized PATH, which is how an older ocx
    #     discovers a host trust store (Linux only; a no-op elsewhere).
    # A value already in the environment wins, as everywhere.
    if test -n "$OCX_INSTALL_CA_BUNDLE"; and test -z "$SSL_CERT_FILE"
        set -gx SSL_CERT_FILE $OCX_INSTALL_CA_BUNDLE
    end
    if test -n "$ca_raw"; and test -z "$OCX_EXTRA_CA_CERTS"
        set -gx OCX_EXTRA_CA_CERTS $ca_raw
    end

    __ocx_assert_safe_ocx_home $ocx_home
    set -l bin_dir "$ocx_home/$OCX_BIN_SUBPATH"

    set -l post
    if test "$no_modify_path" = 1
        set post --no-modify-path
    end
    # Adopt the corporate managed-config tier. Not forwarded on the --offline
    # test hatch below, where the OCI fetch could not succeed anyway.
    set -l managed_post $post
    if test -n "$__ocx_managed_config"
        set managed_post $post --managed-config $__ocx_managed_config
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

    # A content-addressed URL (dist/<sha256>.json) is verified against the
    # digest in its own name before anything is parsed out of it.
    __ocx_require_downloader

    # Called in STATEMENT position, not as an `if` condition: fish turns an
    # `exit` inside a conditional's command into a plain stop with status 0, so a
    # digest mismatch would be reported and then exit SUCCESSFULLY.
    set -l dist_tmp (mktemp)
    __ocx_fetch_dist $OCX_INSTALL_DIST_URL $dist_tmp
    set -l fetch_status $status
    if test $fetch_status -ne 0
        rm -f $dist_tmp
        __ocx_err "failed to determine the latest version from $OCX_INSTALL_DIST_URL
  (fetch failed or empty manifest). Check your connection, or pin OCX_INSTALL_VERSION." 3
    end
    # `string collect` keeps the multi-line manifest as ONE list element;
    # otherwise fish splits it on newlines and passing $dist to a function would
    # expand into many positional args and misalign --argument-names.
    set -l dist (cat $dist_tmp | string collect)
    rm -f $dist_tmp
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
        __ocx_run_self_setup $bin -- $ocxver $managed_post
    end

    rm -rf $tmpdir
    __ocx_export_github_path $ocx_home
    if __ocx_is_truthy $OCX_INSTALL_PRINT_PATH
        echo $bin_dir
    end
end

__ocx_main $argv
