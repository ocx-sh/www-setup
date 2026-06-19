#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
#
# make-stub.sh — emit a minimal POSIX `ocx` stub to $1 (default ./ocx-stub).
#
# The stub answers `version` (-> 0.0.0) and the `ocx self setup` hand-off
# (records nothing, exits 0), so the thin installers' test hatch
# (__OCX_TESTING_INSTALL_BINARY) can place it and run a network-free smoke in the
# docker matrix without a real release. It is NOT a real ocx — it does not write
# shell shims, so it cannot drive the activation matrix (that needs a real ocx).

set -eu

DEST="${1:-./ocx-stub}"

cat >"$DEST" <<'STUB'
#!/bin/sh
case "$1" in
    version) echo "0.0.0" ;;
    about) echo "ocx 0.0.0 (docker smoke stub)" ;;
    --offline)
        shift
        [ "$1" = "self" ] && [ "$2" = "setup" ] && exit 0
        echo "stub ocx" ;;
    self)
        [ "$2" = "setup" ] && exit 0
        echo "stub ocx" ;;
    *) echo "stub ocx" ;;
esac
STUB

chmod +x "$DEST"
printf '%s\n' "$DEST"
