#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
# cast: true
# doc: examples/dev-box-fish
# title: Install OCX in fish
# description: Run the fish installer from setup.ocx.sh by piping it to fish.

# Environment: see site/scripts/run-cast-script.sh; the script runs in a fresh container as the user runner, with the tree's installers behind setup.ocx.sh (site/casts/shim/curl).
# The cast region is what the page shows; setup and verification run silently.
set -euo pipefail

# region cast
curl -fsSL https://setup.ocx.sh/fish | fish
# endregion cast

test -x ~/.ocx/symlinks/ocx.sh/ocx/cli/current/content/bin/ocx
