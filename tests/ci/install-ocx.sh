#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

# Bootstrap the OCX package manager itself inside a clean distro container, so
# downstream steps can provision the project toolchain (nu/fish/elvish/pwsh, …)
# straight from ocx.toml via `ocx run` / `ocx pull`.
#
# This is the container analogue of the `ocx-sh/setup-ocx` GitHub Action: the
# action is a node24 JS action and does not run cleanly inside musl (Alpine)
# containers, so the distro matrix installs ocx with this pure-POSIX-sh script
# instead. Deterministic: a pinned OCX version fetched from the ocx-sh/ocx
# GitHub release, verified against the published per-file sha256.
#
# Usage: install-ocx.sh [DEST_BIN_DIR]   (default /usr/local/bin)
# Honors OCX_VERSION (default below). Prints the installed binary path on stdout.

set -eu

OCX_VERSION="${OCX_VERSION:-0.3.8}"
DEST="${1:-/usr/local/bin}"
REPO="ocx-sh/ocx"

log() { echo ">>> [install-ocx] $*" >&2; }
die() {
    echo "!!! [install-ocx] $1" >&2
    exit "${2:-1}"
}

# --- Target triple (arch + libc) ---
RAW_ARCH=$(uname -m)
case "$RAW_ARCH" in
    x86_64 | amd64) ARCH="x86_64" ;;
    aarch64 | arm64) ARCH="aarch64" ;;
    *) die "unsupported architecture: $RAW_ARCH" 7 ;;
esac

LIBC="gnu"
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    _id=$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")
    [ "$_id" = "alpine" ] && LIBC="musl"
fi
# Fallback probe for musl independent of /etc/os-release.
if [ "$LIBC" = "gnu" ] && [ -n "$(find /lib -maxdepth 1 -name 'ld-musl-*.so.1' 2>/dev/null)" ]; then
    LIBC="musl"
fi

TARGET="${ARCH}-unknown-linux-${LIBC}"
BASE="https://github.com/${REPO}/releases/download/v${OCX_VERSION}"

# --- Fetch helper (curl or wget; HTTPS-only) ---
fetch() {
    # fetch <url> <dest>
    if command -v curl >/dev/null 2>&1; then
        curl --proto '=https' --tlsv1.2 -fsSL -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"
    else
        die "neither curl nor wget available to fetch $1" 3
    fi
}

TMP=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$TMP'" EXIT INT TERM

log "fetching ocx ${OCX_VERSION} (${TARGET})"
# Archive format: 0.4.3+ ship .tar.gz; <= 0.4.2 shipped .tar.xz. Try gz, fall back to xz.
EXT=""
for _ext in tar.gz tar.xz; do
    _name="ocx-${TARGET}.${_ext}"
    if fetch "${BASE}/${_name}" "${TMP}/${_name}"; then
        NAME="$_name"
        EXT="$_ext"
        break
    fi
done
[ -n "$EXT" ] || die "download failed: ${BASE}/ocx-${TARGET}.tar.{gz,xz}" 3
fetch "${BASE}/${NAME}.sha256" "${TMP}/${NAME}.sha256" || die "checksum download failed" 3

# --- Verify against the published per-file sha256 ---
EXPECTED=$(awk '{print $1; exit}' "${TMP}/${NAME}.sha256")
[ -n "$EXPECTED" ] || die "empty expected checksum" 4
if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL=$(sha256sum "${TMP}/${NAME}" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
    ACTUAL=$(shasum -a 256 "${TMP}/${NAME}" | awk '{print $1}')
else
    die "no sha256 tool (sha256sum/shasum) to verify download" 3
fi
[ "$ACTUAL" = "$EXPECTED" ] || die "checksum mismatch: expected $EXPECTED got $ACTUAL" 4

# --- Extract + install ---
case "$EXT" in
    tar.gz) tar -xzf "${TMP}/${NAME}" -C "${TMP}" || die "extraction failed" 5 ;;
    tar.xz) tar -xJf "${TMP}/${NAME}" -C "${TMP}" || die "extraction failed" 5 ;;
esac
BIN=$(find "${TMP}" -type f -name ocx | head -n1)
[ -n "$BIN" ] || die "ocx binary not found in archive" 5

mkdir -p "$DEST"
install -m 0755 "$BIN" "${DEST}/ocx"
log "installed ocx -> ${DEST}/ocx"
"${DEST}/ocx" version >&2 || die "installed ocx failed to run" 1

printf '%s\n' "${DEST}/ocx"
