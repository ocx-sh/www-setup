#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
# cast: true
# doc: examples/ci-wrapper
# title: Capture the OCX bin directory in a CI job
# description: Capture the bin directory printed by the pinned POSIX installer, check the binary and put it on the path.

# Environment: see site/scripts/run-cast-script.sh; the script runs in a fresh container as the user runner, with the tree's installers behind setup.ocx.sh (site/casts/shim/curl).
# The cast region is what the page shows; setup and verification run silently.
set -euo pipefail

# region cast
BIN_DIR=$(curl -fsSL https://setup.ocx.sh/sh/0.3.0 | OCX_INSTALL_VERSION=0.6.5 OCX_INSTALL_PRINT_PATH=1 OCX_INSTALL_QUIET=1 sh | tail -n1)
test -x "$BIN_DIR/ocx" || {
    echo "ocx install failed" >&2
    exit 1
}
export PATH="$BIN_DIR:$PATH"
echo "$BIN_DIR"
# endregion cast

ocx version
