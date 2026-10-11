#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

# ci-verify.sh: run the workflow and Taskfile checks of the shell-quality set. Output is the violation.
# Kind: GATE, so `set -u` and no `-e`: each check carries its own status into `fail`.
# bash-floor: 3.2
# Exit: 0 clean; 1 a finding; 69 python3 or a venv with PyYAML is unavailable; 78 not a repository root.
# The YAML checks run `python3 -I`, which sees only the interpreter's own site, so PyYAML comes from a throwaway venv.
set -u

cd "$(dirname "$0")/.." || exit 78
[ -f taskfile.yml ] || {
    echo "ci-verify: not at the repository root" >&2
    exit 78
}
command -v python3 >/dev/null 2>&1 || {
    echo "ci-verify: 'python3' not on PATH" >&2
    exit 69
}
tmp=$(mktemp -d) || exit 74
trap 'rm -rf "$tmp"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if ! python3 -I -c 'import importlib.util, sys; sys.exit(importlib.util.find_spec("yaml") is None)'; then
    if ! { python3 -m venv "$tmp/venv" && "$tmp/venv/bin/pip" install --quiet --disable-pip-version-check 'pyyaml==6.0.3'; }; then
        echo "ci-verify: could not provision PyYAML" >&2
        exit 69
    fi
    PATH="$tmp/venv/bin:$PATH"
fi

fail=0
check() { # NAME CMD...: the check prints its violations; any non-zero status marks the gate red
    local name=$1
    shift
    "$@" || {
        echo "ci-verify: $name reported findings (status $?)" >&2
        fail=1
    }
}

for mode in pipe noshell composite ps51; do
    check "ci-steps $mode" sh scripts/ci-steps.sh "$mode"
done
for mode in inputs envctx outputs matrix; do
    check "ci-taint $mode" sh scripts/ci-taint.sh "$mode"
done
check ci-orand sh scripts/ci-orand.sh
for mode in pipeline shopt; do
    check "ci-task-pipefail $mode" sh scripts/ci-task-pipefail.sh "$mode"
done
check "ci-extract-lint taskfile" sh scripts/ci-extract-lint.sh taskfile
check ci-job-shell-lint python3 -I scripts/ci-job-shell-lint.py
check ci-pwsh-run-lint python3 -I scripts/ci-pwsh-run-lint.py
exit "$fail"
