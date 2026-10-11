#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
# cast: true
# doc: examples/air-gapped
# title: Install OCX without ocx self setup
# description: Place the ocx binary with OCX_INSTALL_NO_SETUP and print its directory; the installer comes from the archive, as it would be copied to a host.

# Environment: see site/scripts/run-cast-script.sh; the script runs in a fresh container as the user runner.
# The cast region is what the page shows; setup and verification run silently.
set -euo pipefail

# region setup
export OCX_HOME=/opt/ocx
export OCX_INSTALL_VERSION=0.6.5
curl -fsSL https://setup.ocx.sh/archive/0.2.2/install.sh -o install.sh
# endregion setup

# region cast
OCX_INSTALL_NO_SETUP=1 OCX_INSTALL_PRINT_PATH=1 OCX_INSTALL_QUIET=1 sh install.sh
# endregion cast

# Verification: the binary sits in the printed directory and nothing ran ocx self setup.
test -x /opt/ocx/symlinks/ocx.sh/ocx/cli/current/content/bin/ocx
test ! -e ~/.ocx
