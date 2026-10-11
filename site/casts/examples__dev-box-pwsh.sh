#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
# cast: true
# doc: examples/dev-box-pwsh
# title: Install OCX in PowerShell
# description: Run the PowerShell installer from setup.ocx.sh on a fresh Linux user.
# eval: pwsh -NoProfile -Command "function irm(\$u) { if (\$u -ne 'https://setup.ocx.sh/pwsh') { throw \"unmapped \$u\" }; Get-Content -Raw /cast/tree/src/install.ps1 }; $b"

# Environment: see site/scripts/run-cast-script.sh; the script runs in a fresh container as the user runner, with the tree's installers behind setup.ocx.sh (site/casts/shim/curl).
# The cast region is what the page shows; setup and verification run silently.
set -euo pipefail

# region cast
irm https://setup.ocx.sh/pwsh | iex
# endregion cast

test -x ~/.ocx/symlinks/ocx.sh/ocx/cli/current/content/bin/ocx
