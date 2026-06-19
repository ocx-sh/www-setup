#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

# Install the base toolchain a clean distro container needs before the OCX
# project toolchain takes over: VCS (git, for checkout submodules + `git
# ls-files`), the download/extract chain (curl, ca-certificates, tar, xz), and
# the Bats fixture harness deps (python3 for the HTTPS server, coreutils for
# sha256sum, findutils, grep, bash). The target SHELLS themselves (nu/fish/
# elvish/pwsh) are NOT installed here — they come from ocx.toml via `ocx run`.
#
# Usage: setup-distro.sh [alpine|fedora|ubuntu|debian]
# Distro auto-detected from /etc/os-release when omitted.

set -eu

DISTRO="${1:-}"
if [ -z "$DISTRO" ] && [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    DISTRO=$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")
fi

case "$DISTRO" in
    alpine)
        apk add --no-cache \
            git curl ca-certificates tar xz gzip \
            coreutils findutils grep bash python3
        ;;
    fedora)
        dnf install -y --setopt=install_weak_deps=False \
            git curl ca-certificates tar xz gzip \
            coreutils findutils grep bash python3
        dnf clean all || true
        ;;
    ubuntu | debian)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends \
            git curl ca-certificates tar xz-utils gzip \
            coreutils findutils grep bash python3
        rm -rf /var/lib/apt/lists/*
        ;;
    *)
        echo "setup-distro.sh: unknown distro '$DISTRO' (want: alpine, fedora, ubuntu, debian)" >&2
        exit 2
        ;;
esac

echo "setup-distro: base deps installed for ${DISTRO}" >&2
