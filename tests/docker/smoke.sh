#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

set -eu

VERSION="${1:-latest}"
# INSTALLER axis: which of the five thin installers to exercise. Default sh.
INSTALLER="${2:-${OCX_TEST_INSTALLER:-sh}}"

# Canonical real-CLI bin dir relative to OCX_HOME (audit ground truth). MUST
# match OCX_BIN_SUBPATH in src/install.sh.
OCX_BIN_SUBPATH="symlinks/ocx.sh/ocx/cli/current/content/bin"

# Map the INSTALLER axis to (interpreter, script). All five are copied into /work
# by the Dockerfile. The exotic shells must be provisioned in the image
# (install-shells.sh); a missing interpreter is a skip, not a failure.
case "$INSTALLER" in
    sh)
        OCX_RUN="sh"
        OCX_SCRIPT="/work/install.sh"
        ;;
    nu | nushell)
        OCX_RUN="nu"
        OCX_SCRIPT="/work/install.nu"
        ;;
    fish)
        OCX_RUN="fish"
        OCX_SCRIPT="/work/install.fish"
        ;;
    elvish)
        OCX_RUN="elvish"
        OCX_SCRIPT="/work/install.elv"
        ;;
    pwsh | powershell)
        OCX_RUN="pwsh"
        OCX_SCRIPT="/work/install.ps1"
        ;;
    *)
        echo "!!! [smoke] unknown installer '$INSTALLER' (want: sh, nu, fish, elvish, pwsh)" >&2
        exit 2
        ;;
esac
if ! command -v "$OCX_RUN" >/dev/null 2>&1; then
    echo ">>> [smoke] interpreter '$OCX_RUN' not installed — skipping $INSTALLER installer" >&2
    exit 0
fi

distro_desc() {
    if [ -r /etc/os-release ]; then
        # shellcheck source=/dev/null
        (. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}") || uname -a
    else
        uname -a
    fi
}

echo ">>> [smoke] distro: $(distro_desc)"
echo ">>> [smoke] arch:   $(uname -m)"
echo ">>> [smoke] target version: $VERSION"

# --- Resolve the install source ---
# When __OCX_TESTING_INSTALL_BINARY is set, the installer takes the injection
# path: no network, no version flag. Otherwise fall back to the real release.
echo ">>> [smoke] installer: $INSTALLER ($OCX_RUN $OCX_SCRIPT)"
if [ -n "${__OCX_TESTING_INSTALL_BINARY:-}" ]; then
    echo ">>> [smoke] injection: __OCX_TESTING_INSTALL_BINARY=${__OCX_TESTING_INSTALL_BINARY}"
    if [ ! -f "${__OCX_TESTING_INSTALL_BINARY}" ]; then
        echo "!!! [smoke] __OCX_TESTING_INSTALL_BINARY does not point to a file" >&2
        exit 2
    fi
    BIN_DIR=$(OCX_INSTALL_PRINT_PATH=1 OCX_INSTALL_QUIET=1 "$OCX_RUN" "$OCX_SCRIPT" | tail -n1)
elif [ "$VERSION" = "latest" ]; then
    BIN_DIR=$(OCX_INSTALL_PRINT_PATH=1 OCX_INSTALL_QUIET=1 "$OCX_RUN" "$OCX_SCRIPT" | tail -n1)
else
    BIN_DIR=$(OCX_INSTALL_PRINT_PATH=1 OCX_INSTALL_QUIET=1 OCX_INSTALL_VERSION="$VERSION" "$OCX_RUN" "$OCX_SCRIPT" | tail -n1)
fi

echo ">>> [smoke] bin dir: $BIN_DIR"

# --- Assert: print-path emitted the canonical bin dir ---
case "$BIN_DIR" in
    */"$OCX_BIN_SUBPATH")
        : # ok — print-path ends with the canonical subpath
        ;;
    *)
        echo "!!! [smoke] print-path '$BIN_DIR' does not end with canonical subpath '$OCX_BIN_SUBPATH'" >&2
        exit 1
        ;;
esac

# --- Assert: the binary is present + executable at the canonical bin dir ---
if [ ! -x "$BIN_DIR/ocx" ]; then
    echo "!!! [smoke] $BIN_DIR/ocx is missing or not executable" >&2
    ls -la "$BIN_DIR" >&2 || :
    exit 1
fi

# --- Assert: it runs ---
"$BIN_DIR/ocx" version

echo ">>> [smoke] OK"
