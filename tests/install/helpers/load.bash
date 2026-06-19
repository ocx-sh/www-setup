#!/usr/bin/env bash
# Load bats-support + bats-assert from the vendored submodules so suites can use
# assert_success / assert_failure / assert_output / refute_output, etc.
# Existing suites that use raw `[ "$status" -eq N ]` keep working; new suites
# `load helpers/load` to opt into the assertion library.
#
# BATS_TEST_DIRNAME is the dir of the running .bats file (tests/install/...),
# so the repo root is three levels up: tests/install/<suite> -> repo root is
# tests/install/.. -> ../.. ; load.bash lives in tests/install/helpers so the
# repo root is "$BATS_TEST_DIRNAME/../..".
_OCX_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
load "${_OCX_REPO_ROOT}/external/bats-support/load.bash"
load "${_OCX_REPO_ROOT}/external/bats-assert/load.bash"
