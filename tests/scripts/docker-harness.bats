#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
# Kind: TOOL (bats suite for tests/docker: a cell must fail, never skip silently)
#
# The docker matrix is only worth its minutes when a missing interpreter or a
# failed shell download turns the cell red. PATH is a farm of symlinks to the
# few tools the scripts call, so the host's own shells are invisible. The
# install-shells cases need /etc/os-release to name a Debian, Ubuntu or Alpine
# host (the CI runner is ubuntu).

load ../install/helpers/load
bats_require_minimum_version 1.5.0

DOCKER_DIR="${BATS_TEST_DIRNAME}/../docker"

setup() {
    FARM="${BATS_TEST_TMPDIR}/farm"
    mkdir -p "$FARM"
    for t in uname mktemp rm ls mkdir cat; do
        ln -s "$(command -v "$t")" "${FARM}/${t}"
    done
    # A curl that always fails, and records that it was asked.
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/curl.calls"\nexit 22\n' "$BATS_TEST_TMPDIR" >"${FARM}/curl"
    chmod +x "${FARM}/curl"
    export TMPDIR="${BATS_TEST_TMPDIR}"
}

@test "smoke.sh exits 69 when the installer's interpreter is missing" {
    PATH="$FARM" run /bin/sh "${DOCKER_DIR}/smoke.sh" latest pwsh
    [ "$status" -eq 69 ]
    assert_output --partial "'pwsh' not installed"
}

@test "install-shells.sh exits 3 when the nu tarball cannot be downloaded" {
    PATH="$FARM" run /bin/sh "${DOCKER_DIR}/install-shells.sh" nu
    [ "$status" -eq 3 ]
    assert_output --partial "download failed"
    [ "$(wc -l <"${BATS_TEST_TMPDIR}/curl.calls" | tr -d ' ')" -eq 1 ]
}

@test "install-shells.sh exits 69 and names the shell it could not provision" {
    local _expect=69
    # ksh is best-effort on Debian, Ubuntu and Alpine; elsewhere the package
    # manager is not in the PATH farm, so the call fails with 127 earlier.
    case "$(. /etc/os-release && printf '%s' "${ID:-}")" in
        debian | ubuntu | alpine) ;;
        *) _expect=127 ;;
    esac
    PATH="$FARM" run "-${_expect}" /bin/sh "${DOCKER_DIR}/install-shells.sh" ksh
    if [ "$_expect" -eq 69 ]; then
        assert_output --partial "ksh=MISSING"
        assert_output --partial "not provisioned: ksh"
    fi
}

# These two run on a host. Inside a container smoke.sh is allowed to delete curl, so they are not meant for one.
@test "smoke.sh OCX_TEST_NO_CURL refuses an injected binary (exit 2) and leaves curl alone" {
    ln -s "$(command -v sh)" "${FARM}/sh"
    PATH="$FARM" __OCX_TESTING_INSTALL_BINARY=/nonexistent OCX_TEST_NO_CURL=1 \
        run /bin/sh "${DOCKER_DIR}/smoke.sh" latest sh
    [ "$status" -eq 2 ]
    assert_output --partial "needs a real download"
    [ -x "${FARM}/curl" ]
}

@test "smoke.sh OCX_TEST_NO_CURL refuses to delete curl outside a container (exit 2)" {
    ln -s "$(command -v sh)" "${FARM}/sh"
    PATH="$FARM" OCX_TEST_NO_CURL=1 run /bin/sh "${DOCKER_DIR}/smoke.sh" latest sh
    [ "$status" -eq 2 ]
    assert_output --partial "only runs inside a container"
    [ -x "${FARM}/curl" ]
}
