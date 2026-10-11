#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
# Kind: TOOL (bats suite for scripts/shell-gate.sh; bash 3.2-safe)
#
# The gate must lint what this repo authors and nothing grim installed. A temp
# git repo holds a clean authored script and a tracked vendored-style fixture
# under .claude/rules/ that has no shebang: linting every tracked *.sh (what
# `task shell:verify` did before the gate) fails on the fixture with SC2148.

load ../install/helpers/load
load ../install/helpers/server
bats_require_minimum_version 1.5.0

GATE="${BATS_TEST_DIRNAME}/../../scripts/shell-gate.sh"
ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    server_require_shell git
    server_require_shell shellcheck
    server_require_shell shfmt
    REPO="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "$REPO/.claude/rules/x/fixtures"
    cp "$ROOT/.shellcheckrc" "$ROOT/.editorconfig" "$REPO/"
    printf '#!/bin/sh\nset -eu\nprintf "%%s\\n" ok\n' >"$REPO/ok.sh"
    chmod +x "$REPO/ok.sh"
    printf '# doc: x\n' >"$REPO/.claude/rules/x/fixtures/noshebang.sh"
    git -C "$REPO" init -q
    git -C "$REPO" add -A
}

gate() { run bash -c 'cd "$1" && bash "$2"' _ "$REPO" "$GATE"; }

@test "the gate exits 0 on a clean script beside a tracked vendored fixture" {
    gate
    assert_success
}

# Negative control: without it the test above proves nothing, since a repo the
# gate never read would pass too.
@test "linting every tracked *.sh (the old behaviour) fails on the fixture with SC2148" {
    run bash -c 'cd "$1" && shellcheck $(git ls-files "*.sh")' _ "$REPO"
    [ "$status" -eq 1 ]
    assert_output --partial "SC2148"
    assert_output --partial "noshebang.sh"
}

@test "a bad authored script makes the gate exit 1" {
    local _body="echo \$1"
    printf '#!/bin/sh\n%s\n' "$_body" >"$REPO/bad.sh"
    chmod +x "$REPO/bad.sh"
    git -C "$REPO" add -A
    gate
    [ "$status" -eq 1 ]
    assert_output --partial "SC2086"
}

@test "an authored script without a shebang is still linted (the exclusion is by path)" {
    printf '# doc: x\n' >"$REPO/authored.sh"
    git -C "$REPO" add -A
    gate
    [ "$status" -eq 1 ]
    assert_output --partial "SC2148"
}
