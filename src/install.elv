#!/usr/bin/env elvish
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
#
# install.elv — OCX installer for the Elvish shell (Linux, macOS, Windows).
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
#   curl -fsSL https://setup.ocx.sh/elvish | elvish
#   E:OCX_INSTALL_VERSION=0.5.0 curl -fsSL https://setup.ocx.sh/elvish | elvish
#
# Pin a version with OCX_INSTALL_VERSION (env); the full OCX_INSTALL_* taxonomy
# applies, identical to install.sh.
#
# Stdout/stderr contract (load-bearing):
#   - All informational/warning/error messages go to STDERR.
#   - STDOUT is silent on success unless OCX_INSTALL_PRINT_PATH is truthy, in
#     which case the FINAL stdout line is the absolute path to the OCX bin dir.
#
# Exit codes: 0 ok · 1 generic · 2 arg/env · 3 network/download/manifest ·
#             4 checksum · 5 extract · 6 'ocx self setup' · 7 unsupported platform

use str
use platform
use os
use re

# --- Helpers ----------------------------------------------------------------

fn ocx-env {|name fallback|
    if (has-env $name) { put (get-env $name) } else { put $fallback }
}

fn ocx-truthy {|v|
    has-value [1 true yes TRUE YES True Yes] $v
}

fn ocx-quiet {
    ocx-truthy (ocx-env OCX_INSTALL_QUIET 0)
}

fn ocx-say {|msg|
    if (not (ocx-quiet)) { echo "ocx-install: "$msg >&2 }
}

fn ocx-warn {|msg|
    echo "ocx-install: warning: "$msg >&2
}

fn ocx-err {|msg code|
    echo "ocx-install: error: "$msg >&2
    exit $code
}

var bin-subpath = symlinks/ocx.sh/ocx/cli/current/content/bin

# --- Platform detection -----------------------------------------------------

fn ocx-detect-target {
    var os = $platform:os
    var raw = $platform:arch
    var arch = ''
    if (has-value [amd64 x86_64] $raw) {
        set arch = x86_64
    } elif (has-value [arm64 aarch64] $raw) {
        set arch = aarch64
    } else {
        ocx-err "unsupported architecture: "$raw" (expected x86_64 or aarch64)" 7
    }
    if (eq $os linux) {
        var libc = gnu
        if (os:exists /etc/alpine-release) {
            set libc = musl
        } elif ?(test -e (glob /lib/ld-musl-*.so.1)) {
            set libc = musl
        }
        put $arch"-unknown-linux-"$libc
    } elif (eq $os darwin) {
        put $arch"-apple-darwin"
    } elif (eq $os windows) {
        put $arch"-pc-windows-msvc"
    } else {
        ocx-err "unsupported operating system: "$os 7
    }
}

# --- Download utilities -----------------------------------------------------

fn ocx-assert-https {|url|
    if (not (str:has-prefix $url https://)) {
        ocx-err "refusing insecure (non-https) URL: "$url 3
    }
}

# Fetch a URL as text (the manifest) -> stdout. Uses external curl.
fn ocx-fetch-text {|url|
    var out = ''
    if ?(set out = (e:curl --proto '=https' --tlsv1.2 -fsSL $url 2>/dev/null | slurp)) {
        put $out
    } else {
        ocx-err "failed to fetch "$url 3
    }
}

# Download a URL to a file (the archive). Returns via exit status of curl.
fn ocx-download-file {|url dest|
    put ?(e:curl --proto '=https' --tlsv1.2 -fsSL -o $dest $url 2>/dev/null)
}

# --- Checksum verification --------------------------------------------------

fn ocx-verify-checksum {|file expected|
    var actual = ''
    if (eq $platform:os windows) {
        # certutil prints a hash line between two status lines.
        set actual = (e:certutil -hashfile $file SHA256 | re:find '[0-9a-fA-F]{64}' (all) | take 1)
    } else {
        if (has-external sha256sum) {
            set actual = (str:split ' ' (e:sha256sum $file) | take 1)
        } elif (has-external shasum) {
            set actual = (str:split ' ' (e:shasum -a 256 $file) | take 1)
        } else {
            ocx-warn "neither sha256sum nor shasum found — SKIPPING CHECKSUM VERIFICATION"
            return
        }
    }
    if (not-eq (str:to-lower $expected) (str:to-lower $actual)) {
        ocx-err "checksum mismatch for "$file": expected "$expected" got "$actual 4
    }
    ocx-say "Checksum verified."
}

# --- Safe archive extraction ------------------------------------------------

# Member-name pre-scan (reject absolute paths and ".." components), then extract
# with ownership/permission hardening. The inline checksum is the primary guard.
fn ocx-safe-extract {|archive dest|
    var bad = ''
    try {
        for line (e:tar --list -f $archive | from-lines) {
            if (re:match '(^|/)\.\.(/|$)|^/' $line) {
                set bad = $line
                break
            }
        }
    } catch _ { }
    if (not-eq $bad '') {
        ocx-err "archive contains unsafe path: "$bad 5
    }
    # Only flags accepted by BOTH GNU tar and macOS bsdtar (--no-overwrite-dir is GNU-only).
    if (not ?(e:tar xf $archive -C $dest --no-same-owner --no-same-permissions 2>/dev/null)) {
        ocx-err "failed to extract "$archive" — ensure tar is available" 5
    }
}

# --- Distribution manifest (dist.json) --------------------------------------

fn ocx-dist-latest {|dist|
    var found = ''
    for r $dist[releases] {
        if (and (eq $found '') (eq $r[channel] stable)) {
            var v = $r[version]
            if (str:has-prefix $v v) { set v = $v[1..] }
            set found = $v
        }
    }
    if (eq $found '') {
        ocx-err "failed to determine the latest version: no stable release in the manifest" 3
    }
    put $found
}

fn ocx-dist-row {|dist version target|
    for r $dist[releases] {
        if (and (eq $r[version] $version) (eq $r[target] $target)) {
            put $r
            return
        }
    }
    put $false
}

fn ocx-field {|row key|
    if (has-key $row $key) { put $row[$key] } else { put '' }
}

# --- Hand off to `ocx self setup` -------------------------------------------

fn ocx-run-self-setup {|bin pre post|
    ocx-say "Running ocx self setup..."
    if (not ?((external $bin) $@pre self setup $@post)) {
        ocx-err "'ocx self setup' failed — see the output above for details" 6
    }
}

fn ocx-export-github-path {|ocx_home|
    if (has-env GITHUB_PATH) {
        echo $ocx_home"/"$bin-subpath >> (get-env GITHUB_PATH)
    }
}

# --- OCX_HOME validation ----------------------------------------------------

fn ocx-assert-safe-home {|home|
    var absolute = (or (str:has-prefix $home /) (re:match '^[A-Za-z]:[\\/]' $home))
    if (not $absolute) {
        ocx-err "OCX_HOME must be an absolute path (got: "$home")" 2
    }
    if (re:match '(^|/)\.\.(/|$)' $home) {
        ocx-err "OCX_HOME must not contain '..' (got: "$home")" 2
    }
    if (re:match '["`$;&|<>()]' $home) {
        ocx-err "OCX_HOME contains characters unsafe for shell embedding (got: "$home")" 2
    }
}

# --- Main -------------------------------------------------------------------

fn ocx-main {|@args|
    var dist_url = (ocx-env OCX_INSTALL_DIST_URL https://setup.ocx.sh/dist.json)
    var mirror_url = (ocx-env OCX_INSTALL_MIRROR_URL '')
    var repo = (ocx-env OCX_INSTALL_REPO ocx-sh/ocx)
    var no_setup = (ocx-truthy (ocx-env OCX_INSTALL_NO_SETUP 0))
    var no_smoketest = (ocx-truthy (ocx-env OCX_INSTALL_NO_SMOKETEST 0))
    var force = (ocx-truthy (ocx-env OCX_INSTALL_FORCE 0))
    var print_path = (ocx-truthy (ocx-env OCX_INSTALL_PRINT_PATH 0))
    var no_modify_path = (ocx-truthy (ocx-env OCX_NO_MODIFY_PATH 0))
    var req = (ocx-env OCX_INSTALL_VERSION '')

    # Minimal arg scan (when run as a file): --version <v>, --no-modify-path.
    var i = 0
    var n = (count $args)
    while (< $i $n) {
        var a = $args[$i]
        if (eq $a --no-modify-path) {
            set no_modify_path = $true
        } elif (eq $a --version) {
            set i = (+ $i 1)
            if (< $i $n) { set req = $args[$i] }
        } elif (str:has-prefix $a --version=) {
            set req = (str:trim-prefix $a --version=)
        }
        set i = (+ $i 1)
    }

    var home_base = (ocx-env HOME (ocx-env USERPROFILE ''))
    var ocx_home = (ocx-env OCX_HOME $home_base"/.ocx")
    ocx-assert-safe-home $ocx_home
    var bin_dir = $ocx_home"/"$bin-subpath

    var post = []
    if $no_modify_path { set post = [--no-modify-path] }

    # --- Internal test-mode hatch (UNDOCUMENTED) ---
    var test_bin = (ocx-env __OCX_TESTING_INSTALL_BINARY '')
    if (not-eq $test_bin '') {
        if (not (os:exists $test_bin)) {
            ocx-err "__OCX_TESTING_INSTALL_BINARY does not point to a file: "$test_bin 2
        }
        var exe = (if (eq $platform:os windows) { put ocx.exe } else { put ocx })
        ocx-say "Test mode: installing local binary as the candidate (no download)."
        os:mkdir-all $bin_dir
        e:cp -f $test_bin $bin_dir"/"$exe
        if (not-eq $platform:os windows) { e:chmod +x $bin_dir"/"$exe }
        if $no_setup {
            ocx-say "Skipping 'ocx self setup' (OCX_INSTALL_NO_SETUP)."
        } else {
            ocx-run-self-setup $bin_dir"/"$exe [--offline] $post
        }
        ocx-export-github-path $ocx_home
        if $print_path { echo $bin_dir }
        return
    }

    var target = (ocx-detect-target)
    ocx-say "Detected platform: "$target
    var exe = (if (re:match windows $target) { put ocx.exe } else { put ocx })

    var dist_text = (ocx-fetch-text $dist_url)
    if (eq (str:trim-space $dist_text) '') {
        ocx-err "failed to determine the latest version: empty manifest at "$dist_url 3
    }
    var dist = ''
    try {
        set dist = (echo $dist_text | from-json)
    } catch _ {
        ocx-err "failed to parse the latest version from the manifest at "$dist_url 3
    }

    var version = $req
    if (eq $version '') {
        ocx-say "Resolving latest version..."
        set version = (ocx-dist-latest $dist)
    }
    if (or (not (re:match '^[0-9]+\.[0-9]+\.[0-9]' $version)) (re:match '[^0-9A-Za-z.+-]' $version)) {
        ocx-err "invalid version format: "$version" (expected semver like 1.2.3)" 2
    }

    # Idempotent fast-path.
    var existing = $bin_dir"/"$exe
    if (os:exists $existing) {
        var old = ''
        try { set old = (str:trim-space ((external $existing) version)) } catch _ { }
        if (and (eq $old $version) (not $force)) {
            ocx-say "ocx v"$version" already installed at "$existing" (set OCX_INSTALL_FORCE=1 to reinstall)"
            ocx-export-github-path $ocx_home
            if $print_path { echo $bin_dir }
            return
        }
    }

    var row = (ocx-dist-row $dist $version $target)
    if (eq $row $false) {
        ocx-err "no published artifact for ocx v"$version" on "$target" in the manifest at "$dist_url 3
    }
    var sha = (ocx-field $row sha256)
    var filename = (ocx-field $row filename)
    var tag = (ocx-field $row tag)
    var url = (ocx-field $row url)
    if (or (eq $url '') (eq $filename '')) {
        ocx-err "manifest row for v"$version"/"$target" is missing url/filename" 3
    }
    if (not-eq $mirror_url '') {
        set url = (str:trim-right $mirror_url /)"/"$tag"/"$filename
    }

    ocx-say "Installing ocx v"$version"..."
    var tmpdir = (str:trim-space (e:mktemp -d))
    var archive = $tmpdir"/"$filename
    if (not (ocx-download-file $url $archive)) {
        e:rm -rf $tmpdir
        ocx-err "failed to download "$url" — ensure v"$version" is a valid release for "$target 3
    }

    if (not-eq $sha '') {
        ocx-verify-checksum $archive $sha
    } else {
        ocx-warn "no inline checksum for "$filename" in the manifest — skipping verification"
    }

    ocx-safe-extract $archive $tmpdir

    var nested = $tmpdir"/ocx-"$target"/"$exe
    var flat = $tmpdir"/"$exe
    var bin = ''
    if (os:exists $nested) {
        set bin = $nested
    } elif (os:exists $flat) {
        set bin = $flat
    } else {
        e:rm -rf $tmpdir
        ocx-err "could not find ocx binary in archive" 5
    }
    if (not-eq $platform:os windows) { e:chmod +x $bin }

    if (not $no_smoketest) {
        if (not ?((external $bin) version >/dev/null 2>&1)) {
            ocx-warn "binary failed to execute in temp directory — your /tmp may be mounted with noexec"
        }
    }

    if $no_setup {
        os:mkdir-all $bin_dir
        e:cp -f $bin $bin_dir"/"$exe
        if (not-eq $platform:os windows) { e:chmod +x $bin_dir"/"$exe }
        ocx-say "Installed to "$bin_dir"/"$exe
    } else {
        ocx-run-self-setup $bin [] [$version $@post]
    }

    e:rm -rf $tmpdir
    ocx-export-github-path $ocx_home
    if $print_path { echo $bin_dir }
}

ocx-main $@args
