#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
# Kind: TEST. Dialect: bash 3.2 under bats; runs src/install.sh as Git Bash, MSYS2 and Cygwin see it.
#
# install.sh runs natively in Git Bash, MSYS2 and Cygwin on Windows. These tests fake
# that host on any POSIX machine: `uname` answers MINGW64_NT-*, MSYS_NT-* or
# CYGWIN_NT-*, and a `cygpath` stand-in maps a drive letter onto a directory inside
# the test sandbox (server_fake_platform). Cygwin converts no argument for a native
# program, so the Cygwin cases also pin that a native tar.exe, curl.exe and ocx.exe
# are handed Windows-form paths. Reading a .zip needs bsdtar (Git's own tar is GNU tar and
# cannot), so the cases that extract one skip when it is absent and fail when
# OCX_TEST_REQUIRE_SHELLS is set. What only a real Windows host can prove (how
# System32/tar.exe lists a zip, what `uname -m` says on arm64, SYSTEMROOT's spelling)
# stays out of here.

bats_require_minimum_version 1.5.0

load helpers/server

INSTALL_SH="${BATS_TEST_DIRNAME}/../../src/install.sh"
BIN_SUBPATH="symlinks/ocx.sh/ocx/cli/current/content/bin"
GNULLVM="x86_64-pc-windows-gnullvm"
MSVC="x86_64-pc-windows-msvc"

setup_file() {
    export FIXTURE_DIR="${BATS_FILE_TMPDIR}/srv"
    server_build_zip_fixture "$FIXTURE_DIR" "$GNULLVM"
    printf '{"schema":1,"latest":{"version":"0.0.0","channel":"stable"},"releases":[]}\n' >"$FIXTURE_DIR/dist-norows.json"
    local _info
    _info=$(server_start "$FIXTURE_DIR" "${BATS_FILE_TMPDIR}/server.log")
    export FIXTURE_PID="${_info% *}"
    export FIXTURE_PORT="${_info#* }"
    export FIXTURE_URL="https://127.0.0.1:${FIXTURE_PORT}"
}

teardown_file() {
    server_stop "${FIXTURE_PID:-}"
}

setup() {
    export OCX_HOME="${BATS_TEST_TMPDIR}/.ocx"
    export OCX_NO_MODIFY_PATH=1
    export CURL_CA_BUNDLE
    CURL_CA_BUNDLE="$(server_ca_bundle)"
    export OCX_STUB_ARGV="${BATS_TEST_TMPDIR}/stub-argv.log"
    export OCX_INSTALL_DIST_URL="${FIXTURE_URL}/dist.json"
    export OCX_INSTALL_MIRROR_URL="${FIXTURE_URL}/releases/download"
    unset GITHUB_PATH OCX_INSTALL_NO_SETUP OCX_INSTALL_VERSION
    unset __OCX_TESTING_INSTALL_BINARY USERPROFILE SYSTEMROOT
    PLAT="${BATS_TEST_TMPDIR}/plat"
    ALT_PID=""
}

teardown() {
    server_stop "$ALT_PID"
}

# win_platform [UNAME_S]: fake a Windows host (default Git Bash on x64).
win_platform() {
    server_fake_platform "$PLAT" "${1:-MINGW64_NT-10.0-26100}" x86_64
}

# serve_zip TARGET [EXTRA_MEMBER]: a private fixture server for one variant.
serve_zip() {
    local _t="${BATS_TEST_TMPDIR}/srv" _info
    server_build_zip_fixture "$_t" "$@"
    _info=$(server_start "$_t" "${BATS_TEST_TMPDIR}/alt.log")
    ALT_PID="${_info% *}"
    export OCX_INSTALL_DIST_URL="https://127.0.0.1:${_info#* }/dist.json"
    export OCX_INSTALL_MIRROR_URL="https://127.0.0.1:${_info#* }/releases/download"
}

# stub_binary: a file for the test hatch to install as the candidate.
stub_binary() {
    server_stub_body >"${BATS_TEST_TMPDIR}/stub-bin"
    export __OCX_TESTING_INSTALL_BINARY="${BATS_TEST_TMPDIR}/stub-bin"
}

@test "windows: the gnullvm row is resolved on Git Bash" {
    server_require_shell bsdtar
    win_platform
    PATH="$PLAT:$PATH" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [[ "$output" == *"Detected platform: ${GNULLVM}"* ]] || false
    [[ "$output" == *"Downloading ocx-${GNULLVM}.zip"* ]] || false
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "windows: the same row is resolved on MSYS2" {
    server_require_shell bsdtar
    win_platform MSYS_NT-10.0-26100
    PATH="$PLAT:$PATH" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [[ "$output" == *"Detected platform: ${GNULLVM}"* ]] || false
}

@test "windows: a manifest with only the msvc row still resolves" {
    server_require_shell bsdtar
    win_platform
    serve_zip "$MSVC"
    PATH="$PLAT:$PATH" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [[ "$output" == *"Detected platform: ${GNULLVM}"* ]] || false
    [[ "$output" == *"Downloading ocx-${MSVC}.zip"* ]] || false
}

@test "windows: a missing row names the gnullvm target and exits 3" {
    server_require_shell bsdtar
    win_platform
    PATH="$PLAT:$PATH" OCX_INSTALL_DIST_URL="${FIXTURE_URL}/dist-norows.json" \
        run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 3 ]
    [[ "$output" == *"Detected platform: ${GNULLVM}"* ]] || false
    [[ "$output" == *"no published artifact for ocx v0.0.0 on ${GNULLVM}"* ]] || false
}

@test "windows: a .zip is extracted and ocx.exe is what lands in the bin dir" {
    server_require_shell bsdtar
    win_platform
    OCX_INSTALL_NO_SETUP=1 PATH="$PLAT:$PATH" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [ -x "${OCX_HOME}/${BIN_SUBPATH}/ocx.exe" ]
    [ ! -e "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
}

@test "windows: a second run sees the installed ocx.exe and stops early" {
    server_require_shell bsdtar
    win_platform
    OCX_INSTALL_NO_SETUP=1 PATH="$PLAT:$PATH" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    OCX_INSTALL_NO_SETUP=1 PATH="$PLAT:$PATH" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]] || false
}

@test "windows: a zip member that climbs out of the archive exits 5" {
    server_require_shell bsdtar
    win_platform
    serve_zip "$GNULLVM" "../evil"
    PATH="$PLAT:$PATH" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 5 ]
    [[ "$output" == *"unsafe path"* ]] || false
    [ ! -e "${OCX_HOME}/${BIN_SUBPATH}/ocx.exe" ]
}

@test "windows: without bsdtar, Windows' own System32 tar.exe reads the zip" {
    server_require_shell bsdtar
    win_platform
    mkdir -p "$PLAT/drive/c/Windows/System32"
    ln -s "$(command -v bsdtar)" "$PLAT/drive/c/Windows/System32/tar.exe"
    SYSTEMROOT='C:\Windows' PATH="$PLAT:$(server_path_without bsdtar)" \
        run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "windows: no bsdtar and no System32 tar.exe exits 2 naming the tool" {
    win_platform
    SYSTEMROOT='C:\Windows' PATH="$PLAT:$(server_path_without bsdtar)" \
        run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 2 ]
    [[ "$output" == *"bsdtar"* ]] || false
}

@test "windows: a missing zip tar fails before any network work" {
    win_platform
    OCX_INSTALL_DIST_URL="https://127.0.0.1:1/dist.json" SYSTEMROOT='C:\Windows' \
        PATH="$PLAT:$(server_path_without bsdtar)" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 2 ]
    [[ "$output" == *"bsdtar"* ]] || false
}

# fake_tar_listing TEXT: a bsdtar on PATH whose member listing is TEXT (printf %b),
# so the scan can be fed the spellings a native Windows tar.exe prints.
fake_tar_listing() {
    cat >"$PLAT/bsdtar" <<'EOF'
#!/bin/sh
case "$1" in
    --list) printf '%b' "$FAKE_TAR_LIST" ;;
    -tvf) exit 0 ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$PLAT/bsdtar"
    export FAKE_TAR_LIST="$1"
}

@test "windows: a listed member with a backslash climb exits 5" {
    win_platform
    fake_tar_listing 'ocx.exe\n..\\evil\n'
    PATH="$PLAT:$PATH" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 5 ]
    [[ "$output" == *"unsafe path"* ]] || false
}

@test "windows: a listed member with a backslash climb inside a path exits 5" {
    win_platform
    fake_tar_listing 'a/..\\evil\n'
    PATH="$PLAT:$PATH" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 5 ]
    [[ "$output" == *"unsafe path"* ]] || false
}

@test "windows: a listed member with a leading backslash exits 5" {
    win_platform
    fake_tar_listing '\\abs\n'
    PATH="$PLAT:$PATH" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 5 ]
    [[ "$output" == *"unsafe path"* ]] || false
}

@test "windows: a listed member with a drive prefix exits 5" {
    win_platform
    fake_tar_listing 'C:\\x\n'
    PATH="$PLAT:$PATH" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 5 ]
    [[ "$output" == *"unsafe path"* ]] || false
}

@test "windows: a CRLF listing does not hide a trailing .. member" {
    win_platform
    fake_tar_listing 'a/..\r\n'
    PATH="$PLAT:$PATH" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 5 ]
    [[ "$output" == *"unsafe path"* ]] || false
}

@test "windows: a zip member with a drive path exits 5" {
    server_require_shell bsdtar
    win_platform
    serve_zip "$GNULLVM" 'C:\x'
    PATH="$PLAT:$PATH" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 5 ]
    [[ "$output" == *"unsafe path"* ]] || false
}

@test "windows: a zip symlink member that escapes exits 5" {
    server_require_shell bsdtar
    win_platform
    FIXTURE_ZIP_LINK="../../outside" serve_zip "$GNULLVM"
    PATH="$PLAT:$PATH" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 5 ]
    [[ "$output" == *"escaping link target"* ]] || false
}

@test "windows: an msvc-only manifest with a nested zip layout installs" {
    server_require_shell bsdtar
    win_platform
    FIXTURE_ZIP_NESTED=1 serve_zip "$MSVC"
    OCX_INSTALL_NO_SETUP=1 PATH="$PLAT:$PATH" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [ -x "${OCX_HOME}/${BIN_SUBPATH}/ocx.exe" ]
}

@test "windows: aarch64 resolves the aarch64 gnullvm row" {
    server_require_shell bsdtar
    server_fake_platform "$PLAT" MINGW64_NT-10.0-26100 aarch64
    serve_zip aarch64-pc-windows-gnullvm
    PATH="$PLAT:$PATH" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [[ "$output" == *"Detected platform: aarch64-pc-windows-gnullvm"* ]] || false
}

@test "windows: arm64 is read as aarch64" {
    server_require_shell bsdtar
    server_fake_platform "$PLAT" MINGW64_NT-10.0-26100 arm64
    serve_zip aarch64-pc-windows-gnullvm
    PATH="$PLAT:$PATH" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [[ "$output" == *"Detected platform: aarch64-pc-windows-gnullvm"* ]] || false
}

@test "windows: the test hatch writes ocx.exe, not ocx" {
    win_platform
    stub_binary
    OCX_INSTALL_NO_SETUP=1 PATH="$PLAT:$PATH" run sh "$INSTALL_SH"
    [ "$status" -eq 0 ]
    [ -x "${OCX_HOME}/${BIN_SUBPATH}/ocx.exe" ]
    [ ! -e "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
}

@test "windows: OCX_HOME in Windows form is normalised" {
    win_platform
    stub_binary
    OCX_HOME='C:\x\.ocx' OCX_INSTALL_NO_SETUP=1 PATH="$PLAT:$PATH" run sh "$INSTALL_SH"
    [ "$status" -eq 0 ]
    [ -x "$PLAT/drive/c/x/.ocx/${BIN_SUBPATH}/ocx.exe" ]
}

@test "windows: the default OCX_HOME comes from USERPROFILE, not HOME" {
    win_platform
    stub_binary
    unset OCX_HOME
    HOME="${BATS_TEST_TMPDIR}/not-this-home" USERPROFILE='C:\Users\tester' \
        OCX_INSTALL_NO_SETUP=1 PATH="$PLAT:$PATH" run sh "$INSTALL_SH"
    [ "$status" -eq 0 ]
    [ -x "$PLAT/drive/c/Users/tester/.ocx/${BIN_SUBPATH}/ocx.exe" ]
    [ ! -e "${BATS_TEST_TMPDIR}/not-this-home" ]
}

@test "windows: OCX_HOME in Windows form may contain a space" {
    win_platform
    stub_binary
    OCX_HOME='C:\Users\John Smith\.ocx' OCX_INSTALL_NO_SETUP=1 PATH="$PLAT:$PATH" run sh "$INSTALL_SH"
    [ "$status" -eq 0 ]
    [ -x "$PLAT/drive/c/Users/John Smith/.ocx/${BIN_SUBPATH}/ocx.exe" ]
}

@test "windows: OCX_HOME with a .. component exits 2" {
    win_platform
    stub_binary
    OCX_HOME='C:\a\..\b' OCX_INSTALL_NO_SETUP=1 PATH="$PLAT:$PATH" run sh "$INSTALL_SH"
    [ "$status" -eq 2 ]
    [[ "$output" == *"must not contain '..'"* ]] || false
}

@test "windows: OCX_HOME in Windows form without cygpath exits 2 naming cygpath" {
    win_platform
    rm -f "$PLAT/cygpath"
    stub_binary
    OCX_HOME='C:\x\.ocx' OCX_INSTALL_NO_SETUP=1 PATH="$PLAT:$PATH" run sh "$INSTALL_SH"
    [ "$status" -eq 2 ]
    [[ "$output" == *"cygpath"* ]] || false
}

@test "windows: a UNC USERPROFILE is converted, not refused as relative" {
    win_platform
    stub_binary
    unset OCX_HOME
    USERPROFILE='\\srv\home\u' OCX_INSTALL_NO_SETUP=1 PATH="$PLAT:$PATH" run sh "$INSTALL_SH"
    [ "$status" -eq 0 ]
    [ -x "$PLAT/drive/unc/srv/home/u/.ocx/${BIN_SUBPATH}/ocx.exe" ]
}

@test "windows: an unsafe USERPROFILE names USERPROFILE and the way out" {
    win_platform
    stub_binary
    unset OCX_HOME
    USERPROFILE='C:\Users\Jane (Contoso)' OCX_INSTALL_NO_SETUP=1 PATH="$PLAT:$PATH" run sh "$INSTALL_SH"
    [ "$status" -eq 2 ]
    [[ "$output" == *"USERPROFILE contains characters unsafe"* ]] || false
    [[ "$output" == *"'('"* ]] || false
    [[ "$output" == *"set OCX_HOME"* ]] || false
}

@test "windows: GITHUB_PATH gets the bin dir in Windows form" {
    win_platform
    stub_binary
    local _gp="${BATS_TEST_TMPDIR}/github_path"
    OCX_HOME='C:\x\.ocx' GITHUB_PATH="$_gp" OCX_INSTALL_NO_SETUP=1 PATH="$PLAT:$PATH" \
        run sh "$INSTALL_SH"
    [ "$status" -eq 0 ]
    grep -qxF -- 'C:\x\.ocx\symlinks\ocx.sh\ocx\cli\current\content\bin' "$_gp"
}

# --- Cygwin ------------------------------------------------------------------
# Cygwin differs from MSYS2 in that it never converts an argument or a variable
# (bar PATH, HOME and the temp ones) for a native program, and spells a drive
# /cygdrive/c. The cygpath stand-in uses neither /c nor /cygdrive/c as its root, so
# a script that hard-codes a drive spelling writes outside the sandbox and fails.

CYGWIN="CYGWIN_NT-10.0-26100"

@test "cygwin: the gnullvm row is resolved" {
    server_require_shell bsdtar
    win_platform "$CYGWIN"
    PATH="$PLAT:$PATH" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [[ "$output" == *"Detected platform: ${GNULLVM}"* ]] || false
    [[ "$output" == *"Downloading ocx-${GNULLVM}.zip"* ]] || false
    grep -qxF -- "self setup 0.0.0 --no-modify-path" "$OCX_STUB_ARGV"
}

@test "cygwin: a .zip is extracted and ocx.exe is what lands in the bin dir" {
    server_require_shell bsdtar
    win_platform "$CYGWIN"
    OCX_INSTALL_NO_SETUP=1 PATH="$PLAT:$PATH" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    [ -x "${OCX_HOME}/${BIN_SUBPATH}/ocx.exe" ]
    [ ! -e "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
}

@test "cygwin: the test hatch writes ocx.exe, not ocx" {
    win_platform "$CYGWIN"
    stub_binary
    OCX_INSTALL_NO_SETUP=1 PATH="$PLAT:$PATH" run sh "$INSTALL_SH"
    [ "$status" -eq 0 ]
    [ -x "${OCX_HOME}/${BIN_SUBPATH}/ocx.exe" ]
    [ ! -e "${OCX_HOME}/${BIN_SUBPATH}/ocx" ]
}

@test "cygwin: the default OCX_HOME comes from USERPROFILE, spelled by cygpath" {
    win_platform "$CYGWIN"
    stub_binary
    unset OCX_HOME
    HOME="${BATS_TEST_TMPDIR}/not-this-home" USERPROFILE='C:\Users\tester' \
        OCX_INSTALL_NO_SETUP=1 PATH="$PLAT:$PATH" run sh "$INSTALL_SH"
    [ "$status" -eq 0 ]
    [ -x "$PLAT/drive/c/Users/tester/.ocx/${BIN_SUBPATH}/ocx.exe" ]
    [ ! -e "${BATS_TEST_TMPDIR}/not-this-home" ]
}

@test "windows: OCX_HOME reaches the binary in Windows form on every Windows shell" {
    local _os _log
    for _os in MINGW64_NT-10.0-26100 MSYS_NT-10.0-26100 "$CYGWIN"; do
        win_platform "$_os"
        stub_binary
        _log="${BATS_TEST_TMPDIR}/stub-env-${_os}.log"
        # The POSIX spelling a Cygwin user has: Cygwin hands it over unconverted.
        OCX_STUB_ENV="$_log" OCX_HOME="$PLAT/drive/c/x/.ocx" PATH="$PLAT:$PATH" run sh "$INSTALL_SH"
        [ "$status" -eq 0 ]
        grep -qxF -- 'OCX_HOME=C:/x/.ocx' "$_log"
    done
}

@test "windows: a Windows-form OCX_HOME is handed over as C:/ form" {
    win_platform "$CYGWIN"
    stub_binary
    OCX_STUB_ENV="${BATS_TEST_TMPDIR}/stub-env.log" OCX_HOME='C:\x\.ocx' PATH="$PLAT:$PATH" \
        run sh "$INSTALL_SH"
    [ "$status" -eq 0 ]
    grep -qxF -- 'OCX_HOME=C:/x/.ocx' "${BATS_TEST_TMPDIR}/stub-env.log"
    [ -x "$PLAT/drive/c/x/.ocx/${BIN_SUBPATH}/ocx.exe" ]
}

# native_tar_exe: a System32 tar.exe that records its argv, then resolves C:/ the
# way Windows would and runs bsdtar. Without bsdtar on PATH, the installer falls
# back to it.
native_tar_exe() {
    mkdir -p "$PLAT/drive/c/Windows/System32"
    cat >"$PLAT/drive/c/Windows/System32/tar.exe" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/tar-argv.log"
n=\$#
while [ "\$n" -gt 0 ]; do
    a=\$1
    shift
    case "\$a" in
        [A-Z]:/*) a=\$("$PLAT/cygpath" -u "\$a") ;;
    esac
    set -- "\$@" "\$a"
    n=\$((n - 1))
done
exec "$(command -v bsdtar)" "\$@"
EOF
    chmod +x "$PLAT/drive/c/Windows/System32/tar.exe"
}

@test "cygwin: System32 tar.exe gets Windows-form archive and directory arguments" {
    server_require_shell bsdtar
    win_platform "$CYGWIN"
    native_tar_exe
    native_curl
    server_fake_mktemp "$PLAT" "$PLAT/drive/c/tmp"
    SYSTEMROOT='C:\Windows' PATH="$PLAT:$(server_path_without bsdtar)" \
        run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qE -- '^xf C:/tmp/tmp\.[^/]+/ocx-.*\.zip -C C:/tmp/tmp\.[^/]+ ' "$BATS_TEST_TMPDIR/tar-argv.log"
    grep -qE -- '^--list -f C:/tmp/tmp\.[^/]+/ocx-.*\.zip$' "$BATS_TEST_TMPDIR/tar-argv.log"
    # No argument is a POSIX path into the sandbox.
    run ! grep -qF -- "$PLAT" "$BATS_TEST_TMPDIR/tar-argv.log"
}

@test "cygwin: a bsdtar from the runtime keeps POSIX paths" {
    server_require_shell bsdtar
    win_platform "$CYGWIN"
    native_curl
    server_fake_mktemp "$PLAT" "$PLAT/drive/c/tmp"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\nexec "%s" "$@"\n' \
        "$BATS_TEST_TMPDIR/bsdtar-argv.log" "$(command -v bsdtar)" >"$PLAT/bsdtar"
    chmod +x "$PLAT/bsdtar"
    PATH="$PLAT:$PATH" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qF -- "xf $PLAT/drive/c/tmp/" "$BATS_TEST_TMPDIR/bsdtar-argv.log"
    grep -qF -- " -C $PLAT/drive/c/tmp/" "$BATS_TEST_TMPDIR/bsdtar-argv.log"
}

@test "cygwin: an OCX_INSTALL_CA_BUNDLE path reaches the binary as OCX_EXTRA_CA_CERTS in Windows form" {
    win_platform "$CYGWIN"
    stub_binary
    mkdir -p "$PLAT/drive/c"
    cp -f "$(server_ca_bundle)" "$PLAT/drive/c/ca.pem"
    OCX_STUB_ENV="${BATS_TEST_TMPDIR}/stub-env.log" OCX_INSTALL_CA_BUNDLE="$PLAT/drive/c/ca.pem" \
        PATH="$PLAT:$PATH" run sh "$INSTALL_SH"
    [ "$status" -eq 0 ]
    grep -qxF -- 'OCX_EXTRA_CA_CERTS=C:/ca.pem' "${BATS_TEST_TMPDIR}/stub-env.log"
}

@test "cygwin: an inline PEM CA bundle reaches the binary untouched" {
    win_platform "$CYGWIN"
    stub_binary
    local _pem
    _pem=$(cat "$(server_ca_bundle)")
    OCX_STUB_ENV="${BATS_TEST_TMPDIR}/stub-env.log" OCX_INSTALL_CA_BUNDLE="$_pem" PATH="$PLAT:$PATH" \
        run sh "$INSTALL_SH"
    [ "$status" -eq 0 ]
    grep -qxF -- 'OCX_EXTRA_CA_CERTS=-----BEGIN CERTIFICATE-----' "${BATS_TEST_TMPDIR}/stub-env.log"
    run ! grep -qF -- 'OCX_EXTRA_CA_CERTS=C:' "${BATS_TEST_TMPDIR}/stub-env.log"
}

# native_curl: a curl on PATH that records its argv, then resolves C:/ arguments
# the way Windows would and runs the real curl, as curl.exe does under Cygwin.
native_curl() {
    local _real
    _real=$(command -v curl)
    cat >"$PLAT/curl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$BATS_TEST_TMPDIR/curl-argv.log"
n=\$#
while [ "\$n" -gt 0 ]; do
    a=\$1
    shift
    case "\$a" in
        [A-Z]:/*) a=\$("$PLAT/cygpath" -u "\$a") ;;
    esac
    set -- "\$@" "\$a"
    n=\$((n - 1))
done
exec "$_real" "\$@"
EOF
    chmod +x "$PLAT/curl"
}

@test "cygwin: a native curl is not given a POSIX output path" {
    server_require_shell bsdtar
    win_platform "$CYGWIN"
    native_curl
    server_fake_mktemp "$PLAT" "$PLAT/drive/c/tmp"
    PATH="$PLAT:$PATH" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qF -- "$FIXTURE_URL/dist.json" "$BATS_TEST_TMPDIR/curl-argv.log"
    grep -qE -- ' -o C:/[^ ]+ ' "$BATS_TEST_TMPDIR/curl-argv.log"
    run ! grep -qE -- ' -o /' "$BATS_TEST_TMPDIR/curl-argv.log"
}

@test "cygwin: a native curl gets the CA bundle in Windows form" {
    server_require_shell bsdtar
    win_platform "$CYGWIN"
    native_curl
    mkdir -p "$PLAT/drive/c"
    cp -f "$(server_ca_bundle)" "$PLAT/drive/c/ca.pem"
    OCX_INSTALL_CA_BUNDLE="$PLAT/drive/c/ca.pem" PATH="$PLAT:$PATH" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 0 ]
    grep -qF -- "--cacert C:/ca.pem" "$BATS_TEST_TMPDIR/curl-argv.log"
}

@test "cygwin: without cygpath the installer exits 2 naming cygpath" {
    win_platform "$CYGWIN"
    rm -f "$PLAT/cygpath"
    stub_binary
    OCX_INSTALL_NO_SETUP=1 PATH="$PLAT:$PATH" run sh "$INSTALL_SH"
    [ "$status" -eq 2 ]
    [[ "$output" == *"cygpath"* ]] || false
}

@test "windows: an unknown system still exits 7 and names the three Windows shells" {
    win_platform SunOS
    PATH="$PLAT:$PATH" run sh "$INSTALL_SH" --version 0.0.0
    [ "$status" -eq 7 ]
    [[ "$output" == *"unsupported operating system: SunOS"* ]] || false
    [[ "$output" == *"Git Bash, MSYS2 or Cygwin"* ]] || false
}
