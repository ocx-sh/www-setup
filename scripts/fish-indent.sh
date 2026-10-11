#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors

# fish-indent.sh [--check|--write] FILE...: fish_indent from the fish on PATH; the ocx fish package ships no fish_indent binary.
# Kind: TOOL. Exit: 0 clean, 1 a file differs, 2 usage, 69 fish missing.
# fish 4.x is one multicall binary: a link named fish_indent behaves as fish_indent.
set -u
mode=${1:-}
case $mode in
    --check | --write) shift ;;
    *)
        echo "usage: fish-indent.sh --check|--write FILE..." >&2
        exit 2
        ;;
esac
[ "$#" -gt 0 ] || {
    echo "usage: fish-indent.sh --check|--write FILE..." >&2
    exit 2
}
fish=$(command -v fish) || {
    echo "fish-indent: 'fish' not on PATH" >&2
    exit 69
}
tmp=$(mktemp -d) || exit 74
trap 'rm -rf "$tmp"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
ln -s "$fish" "$tmp/fish_indent" || exit 74
case $mode in
    --check) "$tmp/fish_indent" --check -- "$@" ;;
    --write) "$tmp/fish_indent" --write -- "$@" ;;
esac
