#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

# Kind: TOOL (POSIX sh: runs at image build on Alpine, Fedora and Ubuntu)
# Exit: 0 ok, 2 usage, 3 download, 7 arch, 69 a requested shell is missing,
# 129/130/143 HUP/INT/TERM

set -eu

# Temp state goes on every exit path; HUP/INT/TERM end the run with 128+N.
WORK=
cleanup() { [ -z "$WORK" ] || rm -rf "$WORK"; }
on_exit() {
    rc=$?
    trap - EXIT
    cleanup
    exit "$rc"
}
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
WORK=$(mktemp -d)

# --- Pinned tarball versions (GitHub releases) ---
# nu sits at the floor of install.nu's supported range (0.105.1).
NU_VERSION="0.105.1"
ELVISH_VERSION="0.21.0"
PWSH_VERSION="7.4.6"

ALL_SHELLS="bash dash zsh ksh fish nu elvish pwsh"

# --- Distro detection ---
DISTRO_ID=""
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091 # /etc/os-release exists only on the target distro
    DISTRO_ID=$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")
fi
case "$DISTRO_ID" in
    alpine | fedora | ubuntu | debian) ;;
    *)
        # Best-effort fallback by package manager presence.
        if command -v apk >/dev/null 2>&1; then
            DISTRO_ID="alpine"
        elif command -v dnf >/dev/null 2>&1; then
            DISTRO_ID="fedora"
        elif command -v apt-get >/dev/null 2>&1; then
            DISTRO_ID="ubuntu"
        else
            echo "install-shells.sh: cannot determine distro / package manager" >&2
            exit 2
        fi
        ;;
esac

# --- Architecture mapping for GitHub-release tarballs ---
RAW_ARCH=$(uname -m)
case "$RAW_ARCH" in
    x86_64 | amd64)
        ARCH_X="x86_64"
        ARCH_GO="amd64"
        ARCH_PWSH="x64"
        ;;
    aarch64 | arm64)
        ARCH_X="aarch64"
        ARCH_GO="arm64"
        ARCH_PWSH="arm64"
        ;;
    *)
        echo "install-shells.sh: unsupported architecture: $RAW_ARCH" >&2
        exit 7
        ;;
esac

# musl vs gnu for the cargo-dist-style nushell tarball naming.
LIBC="gnu"
if [ "$DISTRO_ID" = "alpine" ]; then
    LIBC="musl"
elif ls /lib/ld-musl-*.so.1 >/dev/null 2>&1; then
    LIBC="musl"
fi

# --- Package-manager refresh (quiet, once) ---
PM_REFRESHED=0
pm_refresh() {
    [ "$PM_REFRESHED" -eq 0 ] || return 0
    case "$DISTRO_ID" in
        alpine) apk update --quiet >/dev/null 2>&1 || apk update >/dev/null 2>&1 || : ;;
        fedora) dnf -q makecache >/dev/null 2>&1 || : ;;
        ubuntu | debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq >/dev/null 2>&1 || apt-get update >/dev/null 2>&1 || :
            ;;
    esac
    PM_REFRESHED=1
}

# pm_install <pkg...> -- install via the native manager, quietly.
pm_install() {
    pm_refresh
    case "$DISTRO_ID" in
        alpine) apk add --no-cache --quiet "$@" >/dev/null 2>&1 ;;
        fedora) dnf install -y -q --setopt=install_weak_deps=False "$@" >/dev/null 2>&1 ;;
        ubuntu | debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y -qq --no-install-recommends "$@" >/dev/null 2>&1
            ;;
        *) return 1 ;;
    esac
}

# pm_try <pkg...> -- best-effort install; never fails the script.
pm_try() {
    # shellcheck disable=SC2310 # pm_install is one package-manager call, its status is the answer
    pm_install "$@" || return 1
}

# need_base -- tools the tarball installers depend on.
ensure_base_tools() {
    # shellcheck disable=SC2310 # optional package: a miss surfaces in the final provisioning check
    command -v curl >/dev/null 2>&1 || pm_try curl ca-certificates || :
    # shellcheck disable=SC2310 # optional package: a miss surfaces in the final provisioning check
    command -v tar >/dev/null 2>&1 || pm_try tar || :
}

fetch() {
    # fetch <url> <dest> -- fatal: a cell without its shell must not stay green.
    if command -v curl >/dev/null 2>&1; then
        curl --proto '=https' --tlsv1.2 -fsSL -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"
    else
        echo "install-shells.sh: neither curl nor wget available for $1" >&2
        return 3
    fi
}

die() {
    echo "install-shells.sh: $1" >&2
    exit "${2:-1}"
}

# download <url> <dest> -- fetch or exit 3, so a missing tarball fails the build.
download() {
    # shellcheck disable=SC2310 # fetch is a single curl or wget, its status is the test
    fetch "$1" "$2" || die "download failed: $1" 3
}

# Shells this run may legitimately leave absent (the one upstream gap, pwsh on Alpine/arm64).
SKIPPED=""

# --- Per-shell installers ---

install_bash() {
    command -v bash >/dev/null 2>&1 && return 0
    pm_install bash
}

install_zsh() {
    command -v zsh >/dev/null 2>&1 && return 0
    pm_install zsh
}

install_fish() {
    command -v fish >/dev/null 2>&1 && return 0
    pm_install fish
}

install_dash() {
    command -v dash >/dev/null 2>&1 && return 0
    case "$DISTRO_ID" in
        ubuntu | debian)
            pm_install dash
            ;;
        alpine)
            # Alpine packages a REAL dash (main repo: dash-0.5.x). Prefer it.
            # The busybox-ash symlink fallback does NOT work: busybox dispatches
            # on argv[0] basename and has no `dash` applet, so invoking the
            # symlink prints "dash: applet not found" (exit 127) and never sources
            # ~/.profile. Only fall back to the symlink if the package is
            # genuinely unavailable (then activation for dash is unsupported and
            # the probe will report it).
            # shellcheck disable=SC2310 # pm_try is one package-manager call, its status is the test
            if pm_try dash && command -v dash >/dev/null 2>&1; then
                :
            elif [ -x /bin/ash ]; then
                ln -sf /bin/ash /usr/local/bin/dash
            elif command -v busybox >/dev/null 2>&1; then
                ln -sf "$(command -v busybox)" /usr/local/bin/dash
            fi
            ;;
        fedora)
            # dash is not packaged on Fedora; busybox provides ash. Install
            # busybox and expose its ash as dash (documented fallback).
            # shellcheck disable=SC2310 # pm_try is one package-manager call, its status is the test
            pm_try dash && return 0
            # shellcheck disable=SC2310 # optional package: a miss surfaces in the final provisioning check
            pm_try busybox || :
            if command -v busybox >/dev/null 2>&1; then
                ln -sf "$(command -v busybox)" /usr/local/bin/dash 2>/dev/null || :
            elif [ -x /bin/sh ]; then
                # Last resort: /bin/sh is a POSIX sh on Fedora (bash in sh-mode).
                ln -sf /bin/sh /usr/local/bin/dash
            fi
            ;;
    esac
}

install_ksh() {
    command -v ksh >/dev/null 2>&1 && return 0
    command -v mksh >/dev/null 2>&1 && {
        ln -sf "$(command -v mksh)" /usr/local/bin/ksh 2>/dev/null || :
        return 0
    }
    case "$DISTRO_ID" in
        alpine)
            # ksh proper is not in Alpine; loksh/mksh are the substitutes.
            # NOTE: Alpine's loksh package installs its binary as /bin/ksh (there
            # is NO `loksh` command), so a `command -v loksh` guard always fails
            # (exit 127) -- under `set -eu` that 127 aborts the whole script and
            # breaks the image build. After loksh installs, ksh is already on
            # PATH at /bin/ksh, so the early `command -v ksh` guard at the top of
            # install_ksh catches it on the next invocation. Terminate the branch
            # with `:` so a failed optional symlink never propagates 127.
            # shellcheck disable=SC2310 # pm_try is one package-manager call, its status is the test
            if pm_try loksh; then
                if command -v loksh >/dev/null 2>&1; then
                    ln -sf "$(command -v loksh)" /usr/local/bin/ksh
                fi
                # loksh already provides /bin/ksh; nothing more required.
                :
            else
                # shellcheck disable=SC2310 # pm_try is one package-manager call, its status is the test
                if pm_try mksh; then
                    if command -v mksh >/dev/null 2>&1; then
                        ln -sf "$(command -v mksh)" /usr/local/bin/ksh
                    fi
                fi
            fi
            ;;
        fedora)
            pm_install ksh
            ;;
        ubuntu | debian)
            # 'ksh' (ksh93) is in universe; fall back to mksh.
            # shellcheck disable=SC2310 # pm_try is one package-manager call, its status is the test
            if pm_try ksh; then
                :
            else
                # shellcheck disable=SC2310 # pm_try is one package-manager call, its status is the test
                if pm_try mksh; then
                    command -v mksh >/dev/null 2>&1 && ln -sf "$(command -v mksh)" /usr/local/bin/ksh
                fi
            fi
            ;;
    esac
}

install_elvish() {
    command -v elvish >/dev/null 2>&1 && return 0
    # Always install the pinned release tarball -- NOT the distro package. Distro
    # elvish (e.g. Ubuntu 24.04 universe ships 0.19) predates the os: module
    # functions the installer relies on (`os:mkdir-all`, added in 0.21), so a
    # distro build fails the smoke with "variable $os:mkdir-all~ not found". The
    # pin matches the OCX-provisioned elvish (0.21) used locally and in CI.
    ensure_base_tools
    _url="https://dl.elv.sh/linux-${ARCH_GO}/elvish-v${ELVISH_VERSION}.tar.gz"
    _tmp="$WORK/elvish"
    # Extract into a clean subdir and name the download so it does NOT match the
    # 'elvish*' glob below -- otherwise `find` can pick the downloaded archive
    # itself and install the gzip as the binary ("Exec format error").
    mkdir -p "$_tmp/ex"
    download "$_url" "$_tmp/dl.tgz"
    tar -xzf "$_tmp/dl.tgz" -C "$_tmp/ex"
    # Archive contains the 'elvish-v<ver>' binary; normalize the name.
    _bin=$(find "$_tmp/ex" -maxdepth 1 -type f -name 'elvish*' | head -n1)
    [ -n "$_bin" ] || die "no elvish binary in $_url" 3
    install -m 0755 "$_bin" /usr/local/bin/elvish
}

install_nu() {
    command -v nu >/dev/null 2>&1 && return 0
    # nushell is in NO official distro repo -- pinned GitHub release tarball.
    ensure_base_tools
    _target="${ARCH_X}-unknown-linux-${LIBC}"
    _name="nu-${NU_VERSION}-${_target}"
    _url="https://github.com/nushell/nushell/releases/download/${NU_VERSION}/${_name}.tar.gz"
    _tmp="$WORK/nu"
    mkdir -p "$_tmp"
    download "$_url" "$_tmp/nu.tar.gz"
    tar -xzf "$_tmp/nu.tar.gz" -C "$_tmp"
    _bin=$(find "$_tmp" -type f -name 'nu' | head -n1)
    [ -n "$_bin" ] || die "no nu binary in $_url" 3
    install -m 0755 "$_bin" /usr/local/bin/nu
    # nushell ships plugins alongside; copy any nu_plugin_* too.
    find "$_tmp" -type f -name 'nu_plugin_*' -exec \
        install -m 0755 {} /usr/local/bin/ \;
}

install_pwsh() {
    command -v pwsh >/dev/null 2>&1 && return 0
    # PowerShell is NOT in default Linux repos -- pinned GitHub release tarball.
    ensure_base_tools
    # Pick the right build per distro/arch. Alpine (musl) needs PowerShell's
    # dedicated linux-musl-* build -- the GLIBC tarball under a `gcompat` shim
    # cannot even initialise a runspace (NullReferenceException in AstSearcher).
    # Upstream ships linux-musl-x64 but NOT linux-musl-arm64, so pwsh on Alpine is
    # amd64-only; on Alpine/arm64 we skip provisioning (the smoke + activation
    # paths then `command -v pwsh`-skip cleanly).
    _build=""
    case "$DISTRO_ID" in
        alpine)
            if [ "$ARCH_PWSH" != "x64" ]; then
                echo "install-shells.sh: PowerShell has no linux-musl-${ARCH_PWSH} build; skipping pwsh on Alpine/${ARCH_PWSH}" >&2
                SKIPPED=" pwsh "
                return 0
            fi
            _build="linux-musl-x64"
            # Runtime deps for the musl build (no gcompat -- it is a native musl binary).
            # shellcheck disable=SC2310 # optional package: a miss surfaces in the final provisioning check
            pm_try icu-libs libgcc libstdc++ || :
            ;;
        fedora)
            _build="linux-${ARCH_PWSH}"
            # shellcheck disable=SC2310 # optional package: a miss surfaces in the final provisioning check
            pm_try libicu || :
            ;;
        ubuntu | debian)
            _build="linux-${ARCH_PWSH}"
            # shellcheck disable=SC2310 # optional package: a miss surfaces in the final provisioning check
            pm_try libicu74 || pm_try libicu72 || pm_try libicu70 || :
            ;;
    esac
    _name="powershell-${PWSH_VERSION}-${_build}.tar.gz"
    _url="https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/${_name}"
    _dest="/opt/microsoft/powershell/7"
    _tmp="$WORK/pwsh"
    mkdir -p "$_tmp" "$_dest"
    download "$_url" "$_tmp/pwsh.tar.gz"
    tar -xzf "$_tmp/pwsh.tar.gz" -C "$_dest"
    chmod +x "$_dest/pwsh"
    ln -sf "$_dest/pwsh" /usr/local/bin/pwsh
}

# --- Driver ---

REQUESTED="${*:-$ALL_SHELLS}"

for _shell in $REQUESTED; do
    case "$_shell" in
        bash) install_bash ;;
        dash) install_dash ;;
        zsh) install_zsh ;;
        ksh) install_ksh ;;
        fish) install_fish ;;
        nu | nushell) install_nu ;;
        elvish) install_elvish ;;
        pwsh | powershell) install_pwsh ;;
        *)
            echo "install-shells.sh: unknown shell '$_shell'" >&2
            exit 2
            ;;
    esac
done

# --- Summary: one line per resolved shell + a header line ---
resolve() {
    # resolve <name> -> prints path or 'MISSING'
    _p=$(command -v "$1") || _p=""
    if [ -n "$_p" ]; then printf '%s' "$_p"; else printf 'MISSING'; fi
}

_summary=""
_missing=""
for _shell in $REQUESTED; do
    case "$_shell" in
        nu | nushell) _name="nu" ;;
        pwsh | powershell) _name="pwsh" ;;
        *) _name="$_shell" ;;
    esac
    _path=$(resolve "$_name")
    _summary="${_summary} ${_name}=${_path}"
    if [ "$_path" = "MISSING" ]; then
        case "$SKIPPED" in
            *" $_name "*) ;;
            *) _missing="${_missing} ${_name}" ;;
        esac
    fi
done

echo "install-shells: distro=${DISTRO_ID} arch=${RAW_ARCH} libc=${LIBC} installed:${_summary}"
# A requested shell that is absent would leave its matrix cell green and untested.
[ -z "$_missing" ] || die "requested shells not provisioned:${_missing}" 69
