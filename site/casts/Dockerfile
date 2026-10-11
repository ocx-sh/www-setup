# The world the install casts run in: a fresh Ubuntu user with every installer's shell and no ocx.
# Build context is the repository root (task site:casts); the shells come from the docker matrix's installer.
ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates coreutils curl findutils gzip passwd tar xz-utils \
    && rm -rf /var/lib/apt/lists/*

COPY tests/docker/install-shells.sh /tmp/install-shells.sh
RUN sh /tmp/install-shells.sh && rm /tmp/install-shells.sh

# runner is the user GitHub-hosted runners use, so a CI cast shows a familiar home. /opt/ocx is the
# OCX_HOME the air-gapped example names.
RUN useradd --create-home --shell /bin/bash runner \
    && mkdir /opt/ocx && chown runner /opt/ocx
USER runner
WORKDIR /home/runner
