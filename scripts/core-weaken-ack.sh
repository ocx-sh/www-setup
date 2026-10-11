#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

# core-weaken-ack: runs core-weaken.sh and fails only on the findings no commit in BASE..HEAD gives a reason for (SH-CORE-01: each printed line needs a one-line reason in the commit, or is removed).
# Usage: from the repo root, sh scripts/core-weaken-ack.sh BASE. A commit body line acknowledges every finding with the same path and kind: Weaken-Ok: <path>: <kind>: <reason>, where "<path>: <kind>" is the prefix core-weaken prints (src/install.sh: Kind header changed). A blank reason acknowledges nothing.
# Exit: 0 nothing unacknowledged; 1 an unacknowledged finding (printed); 64 no BASE argument; 74 git log failed; any other core-weaken.sh status passes through.
# Kind: CI (POSIX sh: runs on dash and busybox ash)
set -u
[ "$#" -ge 1 ] || {
    echo "core-weaken-ack: usage: core-weaken-ack.sh BASE" >&2
    exit 64
}
found=$(sh "$(dirname "$0")/core-weaken.sh" "$1")
rc=$?
[ "$rc" -eq 1 ] || exit "$rc"
OCX_WEAKEN_ACKS=$(git log --format=%B "$1..HEAD") || exit 74
export OCX_WEAKEN_ACKS
printf '%s\n' "$found" | awk '
    # "<path>: <kind>" of "<path>: <kind>: <rest>", and the offset of <rest>.
    function key(s,   i, j) {
        i = index(s, ": "); if (!i) return ""
        j = index(substr(s, i + 2), ": "); if (!j) return ""
        rest = i + j + 2
        return substr(s, 1, i + j)
    }
    BEGIN {
        n = split(ENVIRON["OCX_WEAKEN_ACKS"], a, "\n")
        for (k = 1; k <= n; k++) {
            if (a[k] !~ /^Weaken-Ok:[ \t]*/) continue
            l = a[k]; sub(/^Weaken-Ok:[ \t]*/, "", l)
            ak = key(l)
            if (ak != "" && substr(l, rest) ~ /[^ \t]/) ok[ak] = 1
        }
    }
    { if (!(key($0) in ok)) { print; bad = 1 } else acked++ }
    END {
        if (acked) printf "core-weaken-ack: %d finding(s) acknowledged by a Weaken-Ok line\n", acked > "/dev/stderr"
        exit bad
    }'
