#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

set -euo pipefail

DISTRO="${1:?distro required (alpine|fedora|ubuntu)}"
PLATFORM="${2:?platform required (linux/amd64|linux/arm64)}"
VERSION="${3:-latest}"
SHELL_AXIS="${4:-}"
# INSTALLER axis (smoke only): which of the five thin installers to run. The
# SHELL_AXIS (activation) path always uses the POSIX installer.
INSTALLER="${5:-sh}"

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

case "$INSTALLER" in
    sh | nu | nushell | fish | elvish | pwsh | powershell) ;;
    *)
        echo "run.sh: unknown installer '$INSTALLER' (want: sh, nu, fish, elvish, pwsh)" >&2
        exit 2
        ;;
esac

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DOCKERFILE="$REPO_ROOT/tests/docker/Dockerfile.$DISTRO"
ARCH_SLUG=${PLATFORM##*/}
TAG="setup-ocx-sh-test/${DISTRO}-${ARCH_SLUG}:latest"

echo "==> Building $TAG ($PLATFORM, $DOCKERFILE)"
# ponytail: retry the build to ride out transient Docker Hub registry flakes
# (e.g. 502 from auth.docker.io/token on the base-image pull). 3 tries, linear
# backoff. Bump attempts if the registry gets flakier.
build_attempts=3
for attempt in $(seq 1 "$build_attempts"); do
    if docker buildx build \
        --platform "$PLATFORM" \
        --file "$DOCKERFILE" \
        --tag "$TAG" \
        --load \
        "$REPO_ROOT"; then
        break
    fi
    if [ "$attempt" -eq "$build_attempts" ]; then
        echo "run.sh: build failed after $build_attempts attempts" >&2
        exit 1
    fi
    echo "==> Build attempt $attempt failed; retrying in $((attempt * 5))s" >&2
    sleep "$((attempt * 5))"
done

# --- Optional binary injection (network-free deterministic path) ---
# When OCX_TEST_BINARY points at a host file, bind-mount it read-only into the
# container at a fixed path and expose it through the installer's internal
# __OCX_TESTING_INSTALL_BINARY hatch. Collected as an array so the flags are
# omitted entirely (no empty args) when injection is not requested.
INJECT_ARGS=()
INJECT_DESC="real release flow (network)"
if [ -n "${OCX_TEST_BINARY:-}" ]; then
    if [ ! -f "$OCX_TEST_BINARY" ]; then
        echo "run.sh: OCX_TEST_BINARY='$OCX_TEST_BINARY' is not a file" >&2
        exit 2
    fi
    OCX_TEST_BINARY_ABS=$(cd "$(dirname "$OCX_TEST_BINARY")" && pwd)/$(basename "$OCX_TEST_BINARY")
    CONTAINER_BIN="/opt/ocx-test/ocx"
    INJECT_ARGS=(
        --volume "${OCX_TEST_BINARY_ABS}:${CONTAINER_BIN}:ro"
        --env "__OCX_TESTING_INSTALL_BINARY=${CONTAINER_BIN}"
    )
    INJECT_DESC="injected binary ${OCX_TEST_BINARY_ABS}"
fi

if [ -n "$SHELL_AXIS" ]; then
    # Activation test: run as the non-root 'tester' user (real writable HOME)
    # with profile modification ENABLED via the activate.sh entrypoint. A
    # per-user OCX_HOME keeps generated env files in /home/tester.
    echo "==> Running activation ($DISTRO, $PLATFORM, version=$VERSION, shell=$SHELL_AXIS) [${INJECT_DESC}]"
    docker run --rm \
        --platform "$PLATFORM" \
        --user tester \
        --env HOME=/home/tester \
        --env OCX_HOME=/home/tester/.ocx \
        ${INJECT_ARGS[@]+"${INJECT_ARGS[@]}"} \
        --entrypoint /work/activate.sh \
        "$TAG" "$SHELL_AXIS" "$VERSION"
else
    echo "==> Running smoke ($DISTRO, $PLATFORM, version=$VERSION, installer=$INSTALLER) [${INJECT_DESC}]"
    docker run --rm \
        --platform "$PLATFORM" \
        ${INJECT_ARGS[@]+"${INJECT_ARGS[@]}"} \
        "$TAG" "$VERSION" "$INSTALLER"
fi
