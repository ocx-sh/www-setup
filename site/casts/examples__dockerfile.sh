#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
# cast: true
# doc: examples/dockerfile
# title: Build an image with OCX installed
# description: Build the Dockerfile the page shows and ask the installed ocx for its version.
# runner: host

# Environment: see site/scripts/run-cast-script.sh; this one runs on the recording machine, which needs docker.
# The Dockerfile is the one on the examples page (site/scripts/session-casts.test.mjs keeps them equal).
# The cast region is what the page shows; setup and verification run silently.
set -euo pipefail

# region setup
cat >Dockerfile <<'DOCKERFILE'
FROM debian:12-slim
RUN apt-get update \
 && apt-get install --yes --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
ENV OCX_HOME=/opt/ocx
RUN curl -fsSL https://setup.ocx.sh/sh/0.2.2 | OCX_INSTALL_VERSION=0.6.5 OCX_NO_MODIFY_PATH=1 sh
ENV PATH="${OCX_HOME}/symlinks/ocx.sh/ocx/cli/current/content/bin:${PATH}"
DOCKERFILE
docker pull --quiet debian:12-slim
# endregion setup

# region cast
docker build --quiet --tag ocx-box . >/dev/null
docker run --rm ocx-box ocx version
# endregion cast

docker rmi ocx-box
