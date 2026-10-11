#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

# shell-format.sh: rewrite the shell files shell-gate.sh checks, with the style from .editorconfig.
# Kind: TOOL. Exit: 0 formatted, 69 a tool is missing, 74 listing or shfmt failed, 78 not a work tree.
# bash-floor: 3.2
set -euo pipefail

for tool in git xargs shfmt; do # vd-ok: xargs here is a tool name, not an invocation
    command -v "$tool" >/dev/null 2>&1 || {
        echo "shell-format: '$tool' not on PATH" >&2
        exit 69
    }
done
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "shell-format: not a usable git work tree" >&2
    exit 78
}
EXCLUDE=(':(exclude).agents' ':(exclude).claude' ':(exclude).opencode' ':(exclude)external')
# shellcheck disable=SC2016 # single quotes are deliberate: the $f is for the inner sh, not this shell
git ls-files -z --cached --others --exclude-standard -- . "${EXCLUDE[@]}" |
    xargs -0 -r sh -c 'for f; do if [ -f "$f" ]; then printf "%s\0" "$f"; fi; done' _ |
    xargs -0 -r shfmt -f -- |
    tr '\n' '\0' |
    xargs -0 -r shfmt -w --apply-ignore --
