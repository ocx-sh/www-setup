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

# --- Helpers ----------------------------------------------------------------

def __ocx-env [name: string, fallback: string]: nothing -> string {
    $env | get -i $name | default $fallback
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
def __ocx-fetch-text [url: string]: nothing -> string {
    try {
        http get --raw $url
    } catch {
        try {
            ^curl --proto '=https' --tlsv1.2 -fsSL $url
        } catch {
            __ocx-err $"failed to fetch ($url)" 3
        }
    }
}

# Download a URL to a file (the archive). Prefer `http get | save`, fall back to
# `^curl`. Returns true on success.
def __ocx-download-file [url: string, dest: string]: nothing -> bool {
    let ok = try {
        http get $url | save --raw --force $dest
        true
    } catch {
        false
    }
    if $ok { return true }
    try {
        ^curl --proto '=https' --tlsv1.2 -fsSL -o $dest $url
        true
    } catch {
        false
    }
}

# --- Checksum verification --------------------------------------------------

def __ocx-verify-checksum [file: string, expected: string] {
    let actual = (open --raw $file | hash sha256)
    if ($expected | str downcase) != ($actual | str downcase) {
        __ocx-err $"checksum mismatch for ($file)\n  expected: ($expected)\n  got:      ($actual)" 4
    }
    __ocx-say 'Checksum verified.'
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
    let dist_url = (__ocx-env 'OCX_INSTALL_DIST_URL' 'https://setup.ocx.sh/dist.json')
    let mirror_url = (__ocx-env 'OCX_INSTALL_MIRROR_URL' '')
    let repo = (__ocx-env 'OCX_INSTALL_REPO' 'ocx-sh/ocx')
    let no_setup = (__ocx-truthy (__ocx-env 'OCX_INSTALL_NO_SETUP' '0'))
    let no_smoketest = (__ocx-truthy (__ocx-env 'OCX_INSTALL_NO_SMOKETEST' '0'))
    let force = (__ocx-truthy (__ocx-env 'OCX_INSTALL_FORCE' '0'))
    let print_path = (__ocx-truthy (__ocx-env 'OCX_INSTALL_PRINT_PATH' '0'))
    let no_modify_path = (__ocx-truthy (__ocx-env 'OCX_NO_MODIFY_PATH' '0'))

    let home_base = (__ocx-env 'HOME' (__ocx-env 'USERPROFILE' ''))
    let ocx_home = (__ocx-env 'OCX_HOME' $"($home_base)/.ocx")
    __ocx-assert-safe-home $ocx_home
    let bin_dir = $"($ocx_home)/(__ocx-bin-subpath)"

    let post = if $no_modify_path { ['--no-modify-path'] } else { [] }

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

    let dist_text = (__ocx-fetch-text $dist_url)
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
        __ocx-run-self-setup $bin [] ([$version] | append $post)
    }

    rm -rf $tmpdir
    __ocx-export-github-path $ocx_home
    if $print_path { print $bin_dir }
}

__ocx-main
