#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
#
# Build a single (distro, platform) image and run a test inside it.
#
# Two modes:
#   1. SMOKE (3 args): runs the existing print-path smoke test as root.
#   2. ACTIVATION (4 args): runs the SHELL-axis activation test as user
#      'tester' with profile modification ENABLED, asserting the given shell
#      auto-activates ocx on PATH.
#
# Usage:
#   tests/docker/run.sh <distro> <platform> [version]            # smoke
#   tests/docker/run.sh <distro> <platform> [version] <shell>    # activation
#
# Examples:
#   tests/docker/run.sh alpine linux/amd64
#   tests/docker/run.sh fedora linux/arm64
#   tests/docker/run.sh ubuntu linux/amd64 0.5.0
#   tests/docker/run.sh alpine linux/amd64 latest fish
#   tests/docker/run.sh ubuntu linux/amd64 0.3.1 nu

set -euo pipefail

DISTRO="${1:?distro required (alpine|fedora|ubuntu)}"
PLATFORM="${2:?platform required (linux/amd64|linux/arm64)}"
VERSION="${3:-latest}"
SHELL_AXIS="${4:-}"

case "$DISTRO" in
    alpine | fedora | ubuntu) ;;
    *)
        echo "run.sh: unknown distro '$DISTRO' (want: alpine, fedora, ubuntu)" >&2
        exit 2
        ;;
esac

case "$PLATFORM" in
    linux/amd64 | linux/arm64) ;;
    *)
        echo "run.sh: unknown platform '$PLATFORM' (want: linux/amd64, linux/arm64)" >&2
        exit 2
        ;;
esac

if [ -n "$SHELL_AXIS" ]; then
    case "$SHELL_AXIS" in
        bash | dash | zsh | ksh | fish | nu | nushell | elvish | pwsh | powershell) ;;
        *)
            echo "run.sh: unknown shell '$SHELL_AXIS' (want: bash, dash, zsh, ksh, fish, nu, elvish, pwsh)" >&2
            exit 2
            ;;
    esac
fi

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DOCKERFILE="$REPO_ROOT/tests/docker/Dockerfile.$DISTRO"
ARCH_SLUG=${PLATFORM##*/}
TAG="setup-ocx-sh-test/${DISTRO}-${ARCH_SLUG}:latest"

echo "==> Building $TAG ($PLATFORM, $DOCKERFILE)"
docker buildx build \
    --platform "$PLATFORM" \
    --file "$DOCKERFILE" \
    --tag "$TAG" \
    --load \
    "$REPO_ROOT"

if [ -n "$SHELL_AXIS" ]; then
    # Activation test: run as the non-root 'tester' user (real writable HOME)
    # with profile modification ENABLED via the activate.sh entrypoint. A
    # per-user OCX_HOME keeps generated env files in /home/tester.
    echo "==> Running activation ($DISTRO, $PLATFORM, version=$VERSION, shell=$SHELL_AXIS)"
    docker run --rm \
        --platform "$PLATFORM" \
        --user tester \
        --env HOME=/home/tester \
        --env OCX_HOME=/home/tester/.ocx \
        --env GITHUB_TOKEN \
        --entrypoint /work/activate.sh \
        "$TAG" "$SHELL_AXIS" "$VERSION"
else
    echo "==> Running smoke ($DISTRO, $PLATFORM, version=$VERSION)"
    docker run --rm \
        --platform "$PLATFORM" \
        --env GITHUB_TOKEN \
        "$TAG" "$VERSION"
fi
