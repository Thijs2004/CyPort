#!/bin/bash
# Builds and runs the on-screen controller layout check (tools/test_pad_layout.c) on the Mac. Exit 1 on any failure.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; T="$(mktemp -d)"
clang -O1 -Wall -o "$T/test_pad_layout" "$HERE/tools/test_pad_layout.c" "$HERE/shim/PadLayout.c" -lm
"$T/test_pad_layout" "$@"
