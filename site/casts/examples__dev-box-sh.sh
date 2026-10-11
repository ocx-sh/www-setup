#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
# cast: true
# doc: examples/dev-box-sh
# title: Install OCX in a POSIX shell
# description: Run the POSIX installer from setup.ocx.sh on a fresh Linux user.

# Environment: see site/scripts/run-cast-script.sh; the script runs in a fresh container as the user runner.
# The cast region is what the page shows; setup and verification run silently.
set -euo pipefail

# region cast
curl -fsSL https://setup.ocx.sh/sh | sh
# endregion cast

# Verification: the installer put ocx on the canonical bin dir.
test -x ~/.ocx/symlinks/ocx.sh/ocx/cli/current/content/bin/ocx
