#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

# run-cast-script.sh DRIVER: run one generated cast driver in a throwaway world; the recorder calls it under asciinema.
# Kind: TOOL (bash). Exit: the driver's status, 2 usage, 69 docker is missing.
# env: CAST_TMP (required, scratch directory the driver logs into), CAST_RUNNER (container, default, or host),
# CAST_IMAGE (the image built from site/casts/Dockerfile), CAST_COLUMNS.
# container: a fresh container of that image, as its user `runner`, with an empty home. host: a clean environment on
# this machine, for the one cast that drives docker itself.
set -euo pipefail

[[ $# -eq 1 && -n ${CAST_TMP:-} ]] || {
    echo "run-cast-script: usage: CAST_TMP=<dir> run-cast-script.sh <driver.sh>" >&2
    exit 2
}
command -v docker >/dev/null || {
    echo "run-cast-script: docker is not on PATH" >&2
    exit 69
}
driver=$(realpath "$1")
chmod 0777 "$CAST_TMP" # the container user is not this user

case ${CAST_RUNNER:-container} in
    container)
        exec docker run --rm --tty --init \
            --volume "$driver:/cast/driver.sh:ro" --volume "$CAST_TMP:/cast/tmp" \
            --env CAST_TMP=/cast/tmp --env TERM=xterm-256color --env LANG=C.UTF-8 --env "COLUMNS=${CAST_COLUMNS:-100}" \
            "${CAST_IMAGE:-ocx-casts}" bash /cast/driver.sh
        ;;
    host)
        mkdir -p "$CAST_TMP/work" "$CAST_TMP/home"
        cd "$CAST_TMP/work"
        exec env -i PATH="$PATH" TERM=xterm-256color LANG=C.UTF-8 HOME="$CAST_TMP/home" \
            DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker}" ${DOCKER_HOST:+DOCKER_HOST="$DOCKER_HOST"} \
            CAST_TMP="$CAST_TMP" bash "$driver"
        ;;
    *)
        echo "run-cast-script: unknown CAST_RUNNER '$CAST_RUNNER'" >&2
        exit 2
        ;;
esac
