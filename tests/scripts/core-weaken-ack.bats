#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
# Kind: TOOL (bats suite for scripts/core-weaken-ack.sh; bash 3.2-safe)
#
# A temp repo changes a Kind header on its branch. core-weaken reports it; the
# ack wrapper must fail until a commit carries a Weaken-Ok line with a reason
# for that exact path and kind.

load ../install/helpers/load
load ../install/helpers/server
bats_require_minimum_version 1.5.0

ACK="${BATS_TEST_DIRNAME}/../../scripts/core-weaken-ack.sh"

setup() {
    server_require_shell git
    REPO="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "$REPO"
    git -C "$REPO" init -q
    git -C "$REPO" config user.email t@example.invalid
    git -C "$REPO" config user.name t
    printf '#!/bin/sh\n# Kind: TOOL\necho ok\n' >"$REPO/a.sh"
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm base
    git -C "$REPO" tag base
    printf '#!/bin/sh\n# Kind: CI (POSIX sh)\necho ok\n' >"$REPO/a.sh"
    git -C "$REPO" add -A
}

commit() { git -C "$REPO" commit -qm "$1"; }
ack() { run bash -c 'cd "$1" && sh "$2" base' _ "$REPO" "$ACK"; }

@test "core-weaken-ack: an unacknowledged Kind header change fails and is printed" {
    commit "chore: retag"
    ack
    [ "$status" -eq 1 ]
    assert_output --partial 'a.sh: Kind header changed: +# Kind: CI'
}

@test "core-weaken-ack: a Weaken-Ok line with a reason acknowledges the finding" {
    commit "chore: retag

Weaken-Ok: a.sh: Kind header changed: the script runs in CI, not by hand"
    ack
    assert_success
}

@test "core-weaken-ack: a Weaken-Ok line with a blank reason acknowledges nothing" {
    commit "chore: retag

Weaken-Ok: a.sh: Kind header changed: "
    ack
    [ "$status" -eq 1 ]
}

@test "core-weaken-ack: an ack for another kind does not cover the finding" {
    printf '#!/bin/sh\n# Kind: CI (POSIX sh)\nfalse || true\n' >"$REPO/a.sh"
    git -C "$REPO" add -A
    commit "chore: retag

Weaken-Ok: a.sh: Kind header changed: the script runs in CI, not by hand"
    ack
    [ "$status" -eq 1 ]
    assert_output --partial 'a.sh: true-fallback with no reason'
    refute_output --partial 'Kind header changed'
}
