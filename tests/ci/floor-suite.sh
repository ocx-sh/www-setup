#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

# Kind: CI (POSIX sh: runs on dash and busybox ash inside a distro container)
# Exit: 0 suite green, 1 the distro's interpreter is not the floor, 2 usage, else setup-distro.sh's or the census's status

# floor-suite.sh SHELL: install the distro's own SHELL package and run its bats suite through the
# census. The floors are the oldest interpreters the installers declare:
#   fish   3.6.0  Debian 12 (debian:12)
#   elvish 0.20.1 Alpine 3.20 (alpine:3.20)
# The interpreter version is asserted, so a base image that moves on turns this red instead of
# silently testing a newer shell. Run from the repo root with the repo as the container's cwd.

set -eu

shell=${1:-}
case "$shell" in
    fish)
        floor=3.6.0
        suite=tests/install/fish
        ;;
    elvish)
        floor=0.20.1
        suite=tests/install/elvish
        ;;
    *)
        echo "usage: floor-suite.sh fish|elvish" >&2
        exit 2
        ;;
esac

sh tests/ci/setup-distro.sh
distro=$(. /etc/os-release && printf '%s' "${ID:-}")
case "$distro" in
    alpine) apk add --no-cache openssl "$shell" ;;
    debian | ubuntu)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends openssl "$shell"
        ;;
    *)
        echo "floor-suite.sh: no package recipe for '$distro'" >&2
        exit 2
        ;;
esac

got=$("$shell" --version 2>&1)
case "$got" in
    *"$floor"*) ;;
    *)
        echo "floor-suite.sh: $shell reports '$got', want $floor" >&2
        exit 1
        ;;
esac
echo "floor-suite: $got" >&2

git config --global --add safe.directory "$(pwd)"
# None of these images carries GNU wget, and Alpine has no GNU timeout either.
TESTS_DIR=$suite CENSUS_SKIP_OK='GNU wget not installed|timeout[(]1[)] not available' \
    bash scripts/bats-ci.sh "$suite"
