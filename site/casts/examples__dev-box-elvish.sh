#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
# cast: true
# doc: examples/dev-box-elvish
# title: Install OCX in Elvish
# description: Run the Elvish installer from setup.ocx.sh from a POSIX shell.

# Environment: see site/scripts/run-cast-script.sh; the script runs in a fresh container as the user runner.
# The cast region is what the page shows; setup and verification run silently.
set -euo pipefail

# region cast
elvish -c "$(curl -fsSL https://setup.ocx.sh/elvish || echo 'exit 3')"
# endregion cast

test -x ~/.ocx/symlinks/ocx.sh/ocx/cli/current/content/bin/ocx
