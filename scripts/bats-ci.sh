#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

# bats-ci.sh [BATS_ARGS...]: run the vendored bats through the census; the one wrapper every bats leg calls.
# Kind: CI. Exit: bats's own status or the census's, 69 bash or bats missing, 78 wrong bats version.
# bash-floor: 3.2
# env: BATS (pinned executable), TESTS_DIR (census scope), CENSUS_SKIP_OK, CENSUS_EXCLUDE (see bats-census.sh).
# With no BATS_ARGS the whole TESTS_DIR runs with -r.
set -euo pipefail

BATS=${BATS:-external/bats-core/bin/bats}
TESTS_DIR=${TESTS_DIR:-tests/install}
PIN='Bats 1.14.0'

die() {
    echo "bats-ci: $2" >&2
    exit "$1"
}

[ -f "$BATS" ] || die 69 "bats not found at $BATS (run: git submodule update --init --recursive)"
got=$(bash "$BATS" --version) || die 69 "$BATS --version failed"
[ "$got" = "$PIN" ] || die 78 "wrong bats version: '$got', want '$PIN'"

tmp=$(mktemp -d) || die 74 "mktemp failed"
trap 'rm -rf "$tmp"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Canary: a planted failing suite must go red through the same runner, or this leg cannot go red at all.
printf '@test "canary: always fails" {\n    false\n}\n' >"$tmp/failing.bats"
if bash "$BATS" "$tmp/failing.bats" >/dev/null 2>&1; then
    die 1 "canary: the planted failing suite exited 0"
fi

if [ "$#" -eq 0 ]; then
    set -- -r "$TESTS_DIR"
fi
rc=0
bash "$BATS" --tap "$@" >"$tmp/tap.txt" 2>"$tmp/bats.err" || rc=$?
cat "$tmp/tap.txt"
cat "$tmp/bats.err" >&2
BATS=$BATS sh scripts/bats-census.sh "$TESTS_DIR" "$tmp/tap.txt" "$tmp/bats.err" || rc=1
exit "$rc"
