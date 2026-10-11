#!/usr/bin/env elvish
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
# Kind: INST
# Exit: 0 ok, 1 generic, 2 arg/env, 3 network/manifest, 4 checksum, 5 extract, 6 self setup, 7 platform
# elvish-floor: 0.20.1 (os: module); newest tested 0.21.0. No 129/130/143: elvish has no trap.
#
# install.elv - OCX installer for the Elvish shell (Linux, macOS, Windows).
# https://ocx.sh
#
# This is a THIN BOOTSTRAP. It detects the platform, resolves the release from
# the self-hosted distribution manifest (dist.json), downloads + verifies the
# archive against the manifest's inline sha256, then hands off to the downloaded
# binary's `ocx self setup`. `ocx self setup` owns everything that touches the
# machine - the package-store self-install, the per-shell env shims under
# $OCX_HOME, and the managed shell-profile activation blocks.
#
# Usage: a bare `curl ... | elvish` installs nothing (elvish reads stdin as a
# line-by-line REPL, fails to parse the multi-line fns and still exits 0), so
# hand elvish the script text:
#
#   elvish -c "$(curl -fsSL https://setup.ocx.sh/elvish || echo 'exit 3')"   # from a POSIX shell
#   elvish -c (e:curl -fsSL https://setup.ocx.sh/elvish | slurp)   # from inside elvish
#
# A cut-off script fails to parse and runs nothing; the first form exits 3 when
# the download itself fails, the second exits 2 (elvish wraps the failure). Pin a
# version (or set any other OCX_* knob) in the environment of the receiving
# elvish: export OCX_INSTALL_VERSION as 0.5.0 before the first form, or run
# `set-env OCX_INSTALL_VERSION 0.5.0` before the second. The OCX_INSTALL_*
# taxonomy is identical to install.sh.
#
# Stdout/stderr contract (load-bearing):
#   - All informational/warning/error messages go to STDERR.
#   - STDOUT is silent on success unless OCX_INSTALL_PRINT_PATH is truthy, in
#     which case the FINAL stdout line is the absolute path to the OCX bin dir.

use str
use platform
use os
use re

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
# dialect means no interpolation and newlines allowed - an entire PEM block can
# be substituted for the CA bundle. Values must not contain a single quote.
#
# Precedence: environment > embedded > built-in default. A placeholder left
# unreplaced still matches @OCX_*@ and is ignored, so a pristine installer
# behaves exactly as it always has.

var cfg-dist-url = '@OCX_INSTALL_DIST_URL@'
var cfg-mirror-url = '@OCX_INSTALL_MIRROR_URL@'
var cfg-ca-bundle = '@OCX_INSTALL_CA_BUNDLE@'
var cfg-managed-config = '@OCX_MANAGED_CONFIG@'

# --- Helpers ----------------------------------------------------------------

# ocx-cfg <embedded> <fallback> - the embedded value unless it is still an
# unreplaced placeholder. The guard carries no complete token, so no sed of a
# token above can ever rewrite it.
fn ocx-cfg {|embedded fallback|
    if (and (str:has-prefix $embedded '@OCX_') (str:has-suffix $embedded '@')) {
        put $fallback
    } else {
        put $embedded
    }
}

# Precedence: environment > embedded > built-in default.
fn ocx-env {|name fallback|
    if (has-env $name) { put (get-env $name) } else { put $fallback }
}

# CA bundle (PEM file) for every download - TLS-intercepting corporate proxies.
# Trust only; the inline sha256 from dist.json stays the integrity boundary.
fn ocx-ca-bundle {
    ocx-env OCX_INSTALL_CA_BUNDLE (ocx-cfg $cfg-ca-bundle '')
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

# Temp paths created by this run. Elvish has no trap and `exit` skips `finally`,
# so ocx-err removes them itself: a failing install must not leave the archive.
var tmp-paths = []

fn ocx-track {|path|
    set tmp-paths = [$@tmp-paths $path]
}

fn ocx-cleanup {
    for p $tmp-paths { e:rm -rf $p }
    set tmp-paths = []
}

fn ocx-err {|msg code|
    echo "ocx-install: error: "$msg >&2
    ocx-cleanup
    exit $code
}

# os:mkdir-all is newer than the 0.20.1 floor and `resolve` cannot probe a module
# member, so fall back at run time rather than die on the older build.
fn ocx-mkdir-p {|dir|
    try { os:mkdir-all $dir } catch _ {
        if (not ?(e:mkdir -p $dir)) { ocx-err "cannot create directory: "$dir 2 }
    }
}

var bin-subpath = symlinks/ocx.sh/ocx/cli/current/content/bin

# Attempts per network fetch. Deliberately not an OCX_INSTALL_* knob - three is
# right for a transient edge failure.
var download-attempts = 3

# --- Platform detection -----------------------------------------------------

# True when DIR holds a musl dynamic loader. `[nomatch-ok]` makes an empty glob
# an empty list; without it a no-musl host would throw on every gnu install.
fn ocx-has-musl-loader {|dir|
    > (count [$dir/ld-musl-*[nomatch-ok].so.1]) 0
}

# True when ROOT holds a glibc dynamic loader in any of the usual places.
fn ocx-has-gnu-loader {|root|
    > (count [$root/lib64/ld-linux*[nomatch-ok] $root/lib/ld-linux*[nomatch-ok] $root/lib/*/ld-linux*[nomatch-ok] $root/usr/lib/ld-linux*[nomatch-ok] $root/usr/lib64/ld-linux*[nomatch-ok]]) 0
}

# `ldd --version` text, stdout and stderr together (musl prints it on stderr and
# exits 1), or '' when there is no ldd. Collected line by line because a failing
# pipeline discards a `(...)` capture.
fn ocx-ldd-output {
    var out = ''
    try {
        e:ldd --version 2>&1 | from-lines | each {|l| set out = $out$l"\n" }
    } catch _ { }
    put $out
}

# gnu or musl from evidence under ROOT ('' on a real host), in install.sh's
# order: ldd output, then a musl loader or alpine-release, then a glibc loader.
# Exit 7 when nothing decides: guessing glibc hands a static or musl-only host a
# binary it cannot load.
fn ocx-detect-libc {|root|
    var ldd = (ocx-ldd-output)
    if (str:contains $ldd musl) {
        put musl
    } elif (or (str:contains $ldd GLIBC) (str:contains $ldd 'GNU libc') (str:contains $ldd 'GNU C Library')) {
        put gnu
    } elif (or (ocx-has-musl-loader $root/lib) (os:exists $root/etc/alpine-release)) {
        put musl
    } elif (ocx-has-gnu-loader $root) {
        put gnu
    } else {
        ocx-err "cannot tell glibc from musl on this host (no ldd output, loader file or alpine-release)" 7
    }
}

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
        put $arch"-unknown-linux-"(ocx-detect-libc '')
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

# The CA bundle is passed as its own argv element, so a path containing spaces
# still works.
fn ocx-ca-args {
    var ca = (ocx-ca-bundle)
    if (eq $ca '') { put [] } else { put [--cacert $ca] }
}

# curl before 7.34 rejects --tlsv1.2, so the flag is sent only when `curl --help all` lists it.
fn ocx-tls-args {
    var help = ''
    if ?(set help = (e:curl --help all 2>&1 | slurp)) {
        if (str:contains $help --tlsv1.2) {
            put [--tlsv1.2]
            return
        }
    }
    put []
}

# Bounded retry around every network hop. A single transient failure must not
# abort an install: an edge PoP can serve a 5xx while every other one is
# healthy, and both fetches (manifest, archive) are idempotent GETs.
#
# ponytail: retries on ANY failure instead of inspecting the status code -
# doing that would mean parsing curl errors in five dialects. The ceiling is
# that a genuine 404 costs two extra requests before it still exits 3.
# Fetch a URL as text (the manifest) -> stdout. Uses external curl.
fn ocx-fetch-text {|url|
    ocx-assert-https $url
    var ca = (ocx-ca-args)
    var tls = (ocx-tls-args)
    var out = ''
    var attempt = 1
    var delay = 1
    while $true {
        if ?(set out = (e:curl --proto '=https' $@tls $@ca -fsSL $url 2>/dev/null | slurp)) {
            put $out
            return
        }
        if (>= $attempt $download-attempts) {
            ocx-err "failed to fetch "$url 3
        }
        ocx-say "download failed (attempt "$attempt"/"$download-attempts"), retrying in "$delay"s"
        e:sleep $delay
        set attempt = (+ $attempt 1)
        set delay = (* $delay 2)
    }
}

# Download a URL to a file (the archive). Returns via exit status of curl.
fn ocx-download-file {|url dest|
    ocx-assert-https $url
    var ca = (ocx-ca-args)
    var tls = (ocx-tls-args)
    var attempt = 1
    var delay = 1
    while $true {
        if ?(e:curl --proto '=https' $@tls $@ca -fsSL -o $dest $url 2>/dev/null) {
            put $true
            return
        }
        if (>= $attempt $download-attempts) {
            put $false
            return
        }
        ocx-say "download failed (attempt "$attempt"/"$download-attempts"), retrying in "$delay"s"
        e:sleep $delay
        set attempt = (+ $attempt 1)
        set delay = (* $delay 2)
    }
}

# --- Checksum verification --------------------------------------------------

# certutil prints the digest on its own line between two status lines, with CRLF
# endings and (older builds) spaces between byte pairs. Match per line: one
# re:find over the whole stream yields a match map, which str:to-lower rejects.
fn ocx-certutil-digest {|file|
    e:certutil -hashfile $file SHA256 | from-lines | each {|ln|
        var c = (str:replace ' ' '' (str:trim-space $ln))
        if (re:match '^[0-9a-fA-F]{64}$' $c) { put $c }
    } | take 1
}

# Fails closed: with no hash tool the download is NOT trusted. The digest is the
# only thing authenticating the archive and the pinned manifest.
fn ocx-verify-checksum {|file expected|
    var actual = ''
    if (eq $platform:os windows) {
        if (not (has-external certutil)) {
            ocx-err "certutil not found - cannot verify the download" 2
        }
        set actual = (ocx-certutil-digest $file)
    } elif (has-external sha256sum) {
        set actual = (str:split ' ' (e:sha256sum $file) | take 1)
    } elif (has-external shasum) {
        set actual = (str:split ' ' (e:shasum -a 256 $file) | take 1)
    } elif (has-external openssl) {
        # "SHA2-256(path)= HEX" (openssl 3) or "SHA256(path)= HEX" (1.x)
        set actual = (re:replace '^.*= ' '' (e:openssl dgst -sha256 $file))
    } else {
        ocx-err "no SHA-256 tool found (sha256sum, shasum or openssl) - cannot verify the download" 2
    }
    if (not-eq (str:to-lower $expected) (str:to-lower $actual)) {
        ocx-err "checksum mismatch for "$file": expected "$expected" got "$actual 4
    }
    ocx-say "Checksum verified."
}

# --- Distribution manifest fetch --------------------------------------------

# Put the sha256 a manifest URL pins itself to, or '' for a rolling URL.
#
# `ocx-mirror dist sync` keeps every manifest it has ever published at
# dist/<sha256>.json beside the rolling dist.json, and so does setup.ocx.sh.
# Pointing OCX_INSTALL_DIST_URL at one of those pins the WHOLE closure - every
# release row carries an inline sha256 - so checking the body against the digest
# in its own name makes the pin self-authenticating and leaves the mirror as
# pure transport. Unverified, a content-addressed URL is just a URL.
fn ocx-dist-pin-digest {|url|
    var name = (re:replace '^.*/' '' (re:replace '[?#].*$' '' $url))
    if (re:match '^[0-9a-f]{64}\.json$' $name) {
        put (re:replace '\.json$' '' $name)
    } else {
        put ''
    }
}

# Fetch the manifest as text, verifying it when the URL pins its own digest.
fn ocx-fetch-dist {|url|
    var pin = (ocx-dist-pin-digest $url)
    if (eq $pin '') {
        ocx-fetch-text $url
        return
    }

    # Staged to a file: the digest covers the bytes as served, and `slurp` of a
    # curl pipeline would not survive the trailing newline intact everywhere.
    var tmp = (str:trim-space (e:mktemp))
    ocx-track $tmp
    if (not (ocx-download-file $url $tmp)) {
        ocx-err "failed to fetch "$url 3
    }
    ocx-verify-checksum $tmp $pin
    var body = (slurp < $tmp)
    e:rm -f $tmp
    put $body
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
        ocx-err "failed to extract "$archive" - ensure tar is available" 5
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
        ocx-err "'ocx self setup' failed - see the output above for details" 6
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
    var dist_url = (ocx-env OCX_INSTALL_DIST_URL (ocx-cfg $cfg-dist-url https://setup.ocx.sh/dist.json))
    var mirror_url = (ocx-env OCX_INSTALL_MIRROR_URL (ocx-cfg $cfg-mirror-url ''))
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

    # The CA bundle is either a path or the PEM text itself. The embedded
    # placeholder is single-quoted in every dialect and single quotes span
    # newlines, so a whole PEM block can be substituted straight into the
    # script - no second file to ship alongside the mirrored installer. Inline
    # PEM is materialized to a temp file, which is what curl needs; it is a
    # public certificate, removed with the other temp paths when the run ends.
    var ca_bundle = (ocx-ca-bundle)
    # A real bundle may open with comment lines or a certificate label
    # (Fedora/RHEL ship exactly that), so detect PEM by CONTENT, not by a
    # leading marker: a filesystem path can never contain "-----BEGIN".
    if (str:contains $ca_bundle '-----BEGIN') {
        var ca_tmp = (str:trim-space (e:mktemp | slurp))
        ocx-track $ca_tmp
        print $ca_bundle"\n" > $ca_tmp
        set-env OCX_INSTALL_CA_BUNDLE $ca_tmp
    } elif (and (not-eq $ca_bundle '') (not (os:exists $ca_bundle))) {
        ocx-err "OCX_INSTALL_CA_BUNDLE is neither a readable file nor an inline PEM block: "$ca_bundle 2
    }
    # `ocx self setup` does its own HTTPS work (it pulls the package store from
    # the registry), so the same bundle is handed down - that is what makes ONE
    # corporate CA cover BOTH hops. Two variables, because two ocx generations:
    #   * OCX_EXTRA_CA_CERTS - the value AS SUPPLIED (path or PEM text; ocx does
    #     the same content sniff). `ocx self setup` persists the certificate
    #     text into $OCX_HOME/config.toml, so every later ocx invocation trusts
    #     the CA, on every OS. An older ocx ignores the unknown variable.
    #   * SSL_CERT_FILE - the materialized PATH, which is how an older ocx
    #     discovers a host trust store (Linux only; a no-op elsewhere).
    # A value already in the environment wins, as everywhere.
    if (and (not-eq (ocx-ca-bundle) '') (eq (ocx-env SSL_CERT_FILE '') '')) {
        set-env SSL_CERT_FILE (ocx-ca-bundle)
    }
    if (and (not-eq $ca_bundle '') (eq (ocx-env OCX_EXTRA_CA_CERTS '') '')) {
        set-env OCX_EXTRA_CA_CERTS $ca_bundle
    }

    # Corporate managed-config OCI ref, forwarded to `ocx self setup
    # --managed-config`. ONLY from the embedded block: when OCX_MANAGED_CONFIG is
    # exported, the flag is omitted so `ocx self setup` reads the env itself (its
    # own documented order is flag > OCX_MANAGED_CONFIG > existing seed), which
    # keeps env ahead of embedded.
    var managed_config = ''
    if (eq (ocx-env OCX_MANAGED_CONFIG '') '') {
        set managed_config = (ocx-cfg $cfg-managed-config '')
    }

    var home_base = (ocx-env HOME (ocx-env USERPROFILE ''))
    var ocx_home = (ocx-env OCX_HOME $home_base"/.ocx")
    ocx-assert-safe-home $ocx_home
    var bin_dir = $ocx_home"/"$bin-subpath

    var post = []
    if $no_modify_path { set post = [--no-modify-path] }
    # Adopt the corporate managed-config tier. Not forwarded on the --offline
    # test hatch below, where the OCI fetch could not succeed anyway.
    var managed_post = $post
    if (not-eq $managed_config '') {
        set managed_post = [$@post --managed-config $managed_config]
    }

    # --- Internal test-mode hatch (UNDOCUMENTED) ---
    var test_bin = (ocx-env __OCX_TESTING_INSTALL_BINARY '')
    if (not-eq $test_bin '') {
        if (not (os:exists $test_bin)) {
            ocx-err "__OCX_TESTING_INSTALL_BINARY does not point to a file: "$test_bin 2
        }
        var exe = (if (eq $platform:os windows) { put ocx.exe } else { put ocx })
        ocx-say "Test mode: installing local binary as the candidate (no download)."
        ocx-mkdir-p $bin_dir
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

    # A content-addressed URL (dist/<sha256>.json) is verified against the
    # digest in its own name before anything is parsed out of it.
    var dist_text = (ocx-fetch-dist $dist_url)
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
            ocx-say "ocx v"$version" already installed at "$existing" (set OCX_INSTALL_FORCE to 1 to reinstall)"
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
    if (not (re:match '^[0-9a-fA-F]{64}$' $sha)) {
        ocx-err "manifest row for v"$version"/"$target" has no valid sha256" 3
    }
    if (not-eq $mirror_url '') {
        set url = (str:trim-right $mirror_url /)"/"$tag"/"$filename
    }

    ocx-say "Installing ocx v"$version"..."
    var tmpdir = (str:trim-space (e:mktemp -d))
    ocx-track $tmpdir
    var archive = $tmpdir"/"$filename
    if (not (ocx-download-file $url $archive)) {
        ocx-err "failed to download "$url" - ensure v"$version" is a valid release for "$target 3
    }

    ocx-verify-checksum $archive $sha

    ocx-safe-extract $archive $tmpdir

    var nested = $tmpdir"/ocx-"$target"/"$exe
    var flat = $tmpdir"/"$exe
    var bin = ''
    if (os:exists $nested) {
        set bin = $nested
    } elif (os:exists $flat) {
        set bin = $flat
    } else {
        ocx-err "could not find ocx binary in archive" 5
    }
    if (not-eq $platform:os windows) { e:chmod +x $bin }

    if (not $no_smoketest) {
        if (not ?((external $bin) version >/dev/null 2>&1)) {
            ocx-warn "binary failed to execute in temp directory - your /tmp may be mounted with noexec"
        }
    }

    if $no_setup {
        ocx-mkdir-p $bin_dir
        e:cp -f $bin $bin_dir"/"$exe
        if (not-eq $platform:os windows) { e:chmod +x $bin_dir"/"$exe }
        ocx-say "Installed to "$bin_dir"/"$exe
    } else {
        ocx-run-self-setup $bin [] [$version $@managed_post]
    }

    ocx-export-github-path $ocx_home
    if $print_path { echo $bin_dir }
}

# finally covers an uncaught exception (a failed external); ocx-err covers exit.
try { ocx-main $@args } finally { ocx-cleanup }
