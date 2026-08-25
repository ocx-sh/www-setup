#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
#
# install.nu — OCX installer for the Nushell shell (Linux, macOS, Windows).
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
#   curl -fsSL https://setup.ocx.sh/nu | nu
#   $env.OCX_INSTALL_VERSION = "0.5.0"; curl -fsSL https://setup.ocx.sh/nu | nu
#
# Nushell receives no positional args over `curl | nu`, so this installer is
# ENV-DRIVEN: pin a version with OCX_INSTALL_VERSION, skip profile changes with
# OCX_NO_MODIFY_PATH, etc. (the OCX_INSTALL_* taxonomy, identical to install.sh).
#
# Stdout/stderr contract (load-bearing):
#   - All informational/warning/error messages go to STDERR (print -e).
#   - STDOUT is silent on success unless OCX_INSTALL_PRINT_PATH is truthy, in
#     which case the FINAL stdout line is the absolute path to the OCX bin dir.
#
# Exit codes: 0 ok · 1 generic · 2 arg/env · 3 network/download/manifest ·
#             4 checksum · 5 extract · 6 'ocx self setup' · 7 unsupported platform

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

def __ocx-cfg-dist-url []: nothing -> string { '@OCX_INSTALL_DIST_URL@' }
def __ocx-cfg-mirror-url []: nothing -> string { '@OCX_INSTALL_MIRROR_URL@' }
def __ocx-cfg-ca-bundle []: nothing -> string { '@OCX_INSTALL_CA_BUNDLE@' }
def __ocx-cfg-managed-config []: nothing -> string { '@OCX_MANAGED_CONFIG@' }

# __ocx-cfg <embedded> <fallback> — the embedded value unless it is still an
# unreplaced placeholder. The guard carries no complete token, so no sed of a
# token above can ever rewrite it.
def __ocx-cfg [embedded: string, fallback: string]: nothing -> string {
    if ($embedded | str starts-with '@OCX_') and ($embedded | str ends-with '@') {
        $fallback
    } else {
        $embedded
    }
}

# --- Helpers ----------------------------------------------------------------

# Precedence: environment > embedded > built-in default.
def __ocx-env [name: string, fallback: string]: nothing -> string {
    $env | get -i $name | default $fallback
}

# CA bundle (PEM file) for every download — TLS-intercepting corporate proxies.
# Trust only; the inline sha256 from dist.json stays the integrity boundary.
def __ocx-ca-bundle []: nothing -> string {
    __ocx-env 'OCX_INSTALL_CA_BUNDLE' (__ocx-cfg (__ocx-cfg-ca-bundle) '')
}

def __ocx-truthy [v: string]: nothing -> bool {
    $v in ['1' 'true' 'yes' 'TRUE' 'YES' 'True' 'Yes']
}

def __ocx-quiet []: nothing -> bool {
    __ocx-truthy (__ocx-env 'OCX_INSTALL_QUIET' '0')
}

def __ocx-say [msg: string] {
    if not (__ocx-quiet) { print -e $"ocx-install: ($msg)" }
}

def __ocx-warn [msg: string] {
    print -e $"ocx-install: warning: ($msg)"
}

def __ocx-err [msg: string, code: int = 1] {
    print -e $"ocx-install: error: ($msg)"
    exit $code
}

def __ocx-bin-subpath []: nothing -> string {
    'symlinks/ocx.sh/ocx/cli/current/content/bin'
}

# --- Platform detection -----------------------------------------------------

def __ocx-detect-target []: nothing -> string {
    let os = $nu.os-info.name
    let raw_arch = $nu.os-info.arch
    let arch = if $raw_arch in ['x86_64' 'amd64'] {
        'x86_64'
    } else if $raw_arch in ['aarch64' 'arm64'] {
        'aarch64'
    } else {
        __ocx-err $"unsupported architecture: ($raw_arch) \(expected x86_64 or aarch64\)" 7
    }
    if $os == 'linux' {
        let libc = if ('/etc/alpine-release' | path exists) {
            'musl'
        } else if ((glob /lib/ld-musl-*.so.1 | length) > 0) {
            'musl'
        } else {
            'gnu'
        }
        $"($arch)-unknown-linux-($libc)"
    } else if $os == 'macos' {
        $"($arch)-apple-darwin"
    } else if $os == 'windows' {
        $"($arch)-pc-windows-msvc"
    } else {
        __ocx-err $"unsupported operating system: ($os)" 7
    }
}

# --- Download utilities -----------------------------------------------------

def __ocx-assert-https [url: string] {
    if not ($url | str starts-with 'https://') {
        __ocx-err $"refusing insecure \(non-https\) URL: ($url)" 3
    }
}

# Fetch a URL as text (the manifest). Prefer `http get`, fall back to `^curl`.
# `http get` has no CA-bundle option, so a configured bundle skips it entirely
# rather than letting the run succeed against the wrong trust store.
#
# The `^curl` result goes through `| complete`, NOT a bare `try`. An external
# command left in tail position inside `try` hangs forever in nushell: `try`
# holds the stream nobody drains. `complete` collects stdout and the exit code
# up front, which also removes the need to catch a nonzero exit at all.
def __ocx-fetch-text [url: string]: nothing -> string {
    let ca = (__ocx-ca-bundle)
    if $ca == '' {
        let body = (try { http get --raw $url } catch { null })
        if $body != null { return $body }
    }
    let ca_args = if $ca == '' { [] } else { ['--cacert' $ca] }
    let res = (^curl --proto '=https' --tlsv1.2 ...$ca_args -fsSL $url | complete)
    if $res.exit_code != 0 {
        __ocx-err $"failed to fetch ($url)" 3
    }
    $res.stdout
}

# Download a URL to a file (the archive). Prefer `http get | save`, fall back to
# `^curl`. Returns true on success.
def __ocx-download-file [url: string, dest: string]: nothing -> bool {
    # `--raw` on the GET too: without it `http get` parses an application/json
    # body into a record and `save --raw` then writes nushell's repr of it, not
    # the served bytes — which the manifest-pin digest is taken over.
    let ca = (__ocx-ca-bundle)
    if $ca == '' {
        let ok = try {
            http get --raw $url | save --raw --force $dest
            true
        } catch {
            false
        }
        if $ok { return true }
    }
    let ca_args = if $ca == '' { [] } else { ['--cacert' $ca] }
    # `| complete` for the same reason as __ocx-fetch-text: never leave an
    # external in tail position inside `try`.
    let res = (^curl --proto '=https' --tlsv1.2 ...$ca_args -fsSL -o $dest $url | complete)
    $res.exit_code == 0
}

# --- Checksum verification --------------------------------------------------

def __ocx-verify-checksum [file: string, expected: string] {
    let actual = (open --raw $file | hash sha256)
    if ($expected | str downcase) != ($actual | str downcase) {
        __ocx-err $"checksum mismatch for ($file)\n  expected: ($expected)\n  got:      ($actual)" 4
    }
    __ocx-say 'Checksum verified.'
}

# Echo the sha256 a manifest URL pins itself to, or '' for a rolling URL.
#
# `ocx-mirror dist sync` keeps every manifest it has ever published at
# dist/<sha256>.json beside the rolling dist.json, and so does setup.ocx.sh.
# Pointing OCX_INSTALL_DIST_URL at one of those pins the WHOLE closure — every
# release row carries an inline sha256 — so checking the body against the digest
# in its own name makes the pin self-authenticating and leaves the mirror as
# pure transport. Unverified, a content-addressed URL is just a URL.
def __ocx-dist-pin-digest [url: string]: nothing -> string {
    let name = ($url | split row '?' | first | split row '#' | first | split row '/' | last)
    if ($name =~ '^[0-9a-f]{64}\.json$') { $name | str replace '.json' '' } else { '' }
}

# Fetch the manifest text, verifying it when the URL pins its own digest.
def __ocx-fetch-dist [url: string]: nothing -> string {
    let pin = (__ocx-dist-pin-digest $url)
    if $pin == '' { return (__ocx-fetch-text $url) }

    # Staged to a file: the digest covers the bytes as served, and `^curl`
    # output captured as a value would lose the manifest's trailing newline.
    let tmp = $"(mktemp -d)/dist.json"
    if not (__ocx-download-file $url $tmp) {
        __ocx-err $"failed to fetch ($url)" 3
    }
    __ocx-verify-checksum $tmp $pin
    open --raw $tmp
}

# --- Safe archive extraction ------------------------------------------------

# Member-name pre-scan (reject absolute paths and ".." components), then extract
# with ownership/permission hardening. The inline checksum is the primary guard.
def __ocx-safe-extract [archive: string, dest: string, target: string] {
    let bad = (try { ^tar --list -f $archive | lines } catch { [] }
        | where ($it =~ '(^|/)\.\.(/|$)|^/'))
    if ($bad | length) > 0 {
        __ocx-err $"archive contains unsafe path: ($bad | first)" 5
    }
    let ok = try {
        # Only flags accepted by BOTH GNU tar and macOS bsdtar (--no-overwrite-dir is GNU-only).
        ^tar xf $archive -C $dest --no-same-owner --no-same-permissions
        true
    } catch {
        false
    }
    if not $ok {
        __ocx-err $"failed to extract ($archive) — ensure tar is available" 5
    }
}

# --- Distribution manifest (dist.json) --------------------------------------

# Resolve the latest STABLE version from the parsed manifest.
def __ocx-dist-latest [dist: record]: nothing -> string {
    let stable = ($dist.releases | where channel == 'stable')
    if ($stable | length) == 0 {
        __ocx-err $"failed to determine the latest version: no stable release in the manifest" 3
    }
    ($stable | first | get version | str replace -r '^v' '')
}

# Find the (version,target) row, or null.
def __ocx-dist-row [dist: record, version: string, target: string]: nothing -> any {
    let rows = ($dist.releases | where version == $version and target == $target)
    if ($rows | length) == 0 { null } else { $rows | first }
}

# --- Hand off to `ocx self setup` -------------------------------------------

def __ocx-run-self-setup [bin: string, pre: list<string>, post: list<string>] {
    __ocx-say 'Running ocx self setup...'
    let ok = try {
        ^$bin ...$pre self setup ...$post
        true
    } catch {
        false
    }
    if not $ok {
        __ocx-err "'ocx self setup' failed — see the output above for details" 6
    }
}

def __ocx-export-github-path [ocx_home: string] {
    if 'GITHUB_PATH' in $env {
        let line = $"($ocx_home)/(__ocx-bin-subpath)\n"
        $line | save --append --raw $env.GITHUB_PATH
    }
}

# --- OCX_HOME validation ----------------------------------------------------

def __ocx-assert-safe-home [home: string] {
    let absolute = ($home | str starts-with '/') or ($home =~ '^[A-Za-z]:[\\/]')
    if not $absolute {
        __ocx-err $"OCX_HOME must be an absolute path \(got: ($home)\)" 2
    }
    if ($home =~ '(^|/)\.\.(/|$)') {
        __ocx-err $"OCX_HOME must not contain '..' \(got: ($home)\)" 2
    }
    if ($home =~ '["`$;&|<>()]') {
        __ocx-err $"OCX_HOME contains characters unsafe for shell embedding \(got: ($home)\)" 2
    }
}

# --- Main -------------------------------------------------------------------

def __ocx-main [] {
    let dist_url = (__ocx-env 'OCX_INSTALL_DIST_URL' (__ocx-cfg (__ocx-cfg-dist-url) 'https://setup.ocx.sh/dist.json'))
    let mirror_url = (__ocx-env 'OCX_INSTALL_MIRROR_URL' (__ocx-cfg (__ocx-cfg-mirror-url) ''))
    let repo = (__ocx-env 'OCX_INSTALL_REPO' 'ocx-sh/ocx')
    let no_setup = (__ocx-truthy (__ocx-env 'OCX_INSTALL_NO_SETUP' '0'))
    let no_smoketest = (__ocx-truthy (__ocx-env 'OCX_INSTALL_NO_SMOKETEST' '0'))
    let force = (__ocx-truthy (__ocx-env 'OCX_INSTALL_FORCE' '0'))
    let print_path = (__ocx-truthy (__ocx-env 'OCX_INSTALL_PRINT_PATH' '0'))
    let no_modify_path = (__ocx-truthy (__ocx-env 'OCX_NO_MODIFY_PATH' '0'))

    # The CA bundle is either a path or the PEM text itself. The embedded
    # placeholder is single-quoted in every dialect and single quotes span
    # newlines, so a whole PEM block can be substituted straight into the
    # script — no second file to ship alongside the mirrored installer. Inline
    # PEM is materialized to a temp file, which is what curl needs; it is a
    # public certificate, so it is left for TMPDIR to reap rather than threaded
    # through every error path.
    let raw_ca = (__ocx-ca-bundle)
    # A real bundle may open with comment lines or a certificate label
    # (Fedora/RHEL ship exactly that), so detect PEM by CONTENT, not by a
    # leading marker: a filesystem path can never contain "-----BEGIN".
    if ($raw_ca | str contains '-----BEGIN') {
        let ca_tmp = (mktemp -t)
        $"($raw_ca)\n" | save --raw --force $ca_tmp
        $env.OCX_INSTALL_CA_BUNDLE = $ca_tmp
    } else if $raw_ca != '' and not ($raw_ca | path exists) {
        __ocx-err $"OCX_INSTALL_CA_BUNDLE is neither a readable file nor an inline PEM block: ($raw_ca)" 2
    }
    # `ocx self setup` does its own HTTPS work (it pulls the package store from
    # the registry). It merges the host trust store into its compiled-in Mozilla
    # roots and discovers that store via SSL_CERT_FILE / SSL_CERT_DIR (PEM only)
    # — so handing the same bundle down is what makes ONE corporate CA cover
    # BOTH hops. An SSL_CERT_FILE already in the environment wins, as everywhere.
    if (__ocx-ca-bundle) != '' and (__ocx-env 'SSL_CERT_FILE' '') == '' {
        $env.SSL_CERT_FILE = (__ocx-ca-bundle)
    }

    # Corporate managed-config OCI ref, forwarded to `ocx self setup
    # --managed-config`. ONLY from the embedded block: when OCX_MANAGED_CONFIG is
    # exported, the flag is omitted so `ocx self setup` reads the env itself (its
    # own documented order is flag > OCX_MANAGED_CONFIG > existing seed), which
    # keeps env ahead of embedded.
    let managed_config = if (__ocx-env 'OCX_MANAGED_CONFIG' '') == '' {
        __ocx-cfg (__ocx-cfg-managed-config) ''
    } else {
        ''
    }

    let home_base = (__ocx-env 'HOME' (__ocx-env 'USERPROFILE' ''))
    let ocx_home = (__ocx-env 'OCX_HOME' $"($home_base)/.ocx")
    __ocx-assert-safe-home $ocx_home
    let bin_dir = $"($ocx_home)/(__ocx-bin-subpath)"

    let post = if $no_modify_path { ['--no-modify-path'] } else { [] }
    # Adopt the corporate managed-config tier. Not forwarded on the --offline
    # test hatch below, where the OCI fetch could not succeed anyway.
    let managed_post = if $managed_config == '' {
        $post
    } else {
        $post | append ['--managed-config' $managed_config]
    }

    # --- Internal test-mode hatch (UNDOCUMENTED) ---
    let test_bin = (__ocx-env '__OCX_TESTING_INSTALL_BINARY' '')
    if $test_bin != '' {
        if not ($test_bin | path exists) {
            __ocx-err $"__OCX_TESTING_INSTALL_BINARY does not point to a file: ($test_bin)" 2
        }
        let exe = if (($nu.os-info.name) == 'windows') { 'ocx.exe' } else { 'ocx' }
        __ocx-say 'Test mode: installing local binary as the candidate (no download).'
        mkdir $bin_dir
        cp --force $test_bin $"($bin_dir)/($exe)"
        if (($nu.os-info.name) != 'windows') { ^chmod +x $"($bin_dir)/($exe)" }
        if $no_setup {
            __ocx-say "Skipping 'ocx self setup' (OCX_INSTALL_NO_SETUP)."
        } else {
            __ocx-run-self-setup $"($bin_dir)/($exe)" ['--offline'] $post
        }
        __ocx-export-github-path $ocx_home
        if $print_path { print $bin_dir }
        return
    }

    let target = (__ocx-detect-target)
    __ocx-say $"Detected platform: ($target)"
    let exe = if ($target =~ 'windows') { 'ocx.exe' } else { 'ocx' }

    # A content-addressed URL (dist/<sha256>.json) is verified against the
    # digest in its own name before anything is parsed out of it.
    let dist_text = (__ocx-fetch-dist $dist_url)
    if ($dist_text | str trim | is-empty) {
        __ocx-err $"failed to determine the latest version: empty manifest at ($dist_url)" 3
    }
    let dist = (try { $dist_text | from json } catch {
        __ocx-err $"failed to parse the latest version from the manifest at ($dist_url)" 3
    })

    let req = (__ocx-env 'OCX_INSTALL_VERSION' '')
    let version = if $req == '' {
        __ocx-say 'Resolving latest version...'
        __ocx-dist-latest $dist
    } else {
        $req
    }
    if not ($version =~ '^[0-9]+\.[0-9]+\.[0-9]') or ($version =~ '[^0-9A-Za-z.+-]') {
        __ocx-err $"invalid version format: ($version) \(expected semver like 1.2.3\)" 2
    }

    # Idempotent fast-path.
    let existing = $"($bin_dir)/($exe)"
    if ($existing | path exists) {
        let old = (try { (^$existing version | str trim) } catch { '' })
        if $old == $version and (not $force) {
            __ocx-say $"ocx v($version) already installed at ($existing) \(set OCX_INSTALL_FORCE=1 to reinstall\)"
            __ocx-export-github-path $ocx_home
            if $print_path { print $bin_dir }
            return
        }
    }

    let row = (__ocx-dist-row $dist $version $target)
    if ($row == null) {
        __ocx-err $"no published artifact for ocx v($version) on ($target) in the manifest at ($dist_url)" 3
    }
    let sha = ($row | get -i sha256 | default '')
    let filename = ($row | get -i filename | default '')
    let tag = ($row | get -i tag | default '')
    mut url = ($row | get -i url | default '')
    if $url == '' or $filename == '' {
        __ocx-err $"manifest row for v($version)/($target) is missing url/filename" 3
    }
    if $mirror_url != '' {
        $url = $"($mirror_url | str trim --right --char '/')/($tag)/($filename)"
    }

    __ocx-say $"Installing ocx v($version)..."
    let tmpdir = (mktemp -d)
    let archive = $"($tmpdir)/($filename)"
    if not (__ocx-download-file $url $archive) {
        rm -rf $tmpdir
        __ocx-err $"failed to download ($url)\n  Ensure v($version) is a valid release with a binary for ($target).\n  Available releases: https://github.com/($repo)/releases" 3
    }

    if $sha != '' {
        __ocx-verify-checksum $archive $sha
    } else {
        __ocx-warn $"no inline checksum for ($filename) in the manifest — skipping verification"
    }

    __ocx-safe-extract $archive $tmpdir $target

    let nested = $"($tmpdir)/ocx-($target)/($exe)"
    let flat = $"($tmpdir)/($exe)"
    let bin = if ($nested | path exists) {
        $nested
    } else if ($flat | path exists) {
        $flat
    } else {
        rm -rf $tmpdir
        __ocx-err 'could not find ocx binary in archive' 5
    }
    if ($target !~ 'windows') { ^chmod +x $bin }

    if not $no_smoketest {
        let ok = (try { ^$bin version | ignore; true } catch { false })
        if not $ok {
            __ocx-warn 'binary failed to execute in temp directory — your /tmp may be mounted with noexec'
        }
    }

    if $no_setup {
        mkdir $bin_dir
        cp --force $bin $"($bin_dir)/($exe)"
        if ($target !~ 'windows') { ^chmod +x $"($bin_dir)/($exe)" }
        __ocx-say $"Installed to ($bin_dir)/($exe)"
    } else {
        __ocx-run-self-setup $bin [] ([$version] | append $managed_post)
    }

    rm -rf $tmpdir
    __ocx-export-github-path $ocx_home
    if $print_path { print $bin_dir }
}

__ocx-main
