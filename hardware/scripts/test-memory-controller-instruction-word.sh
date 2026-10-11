#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/lighting-instruction-word.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
SEARCH="+:$ROOT/qli/bluespec:$ROOT/qic/bluespec:$ROOT/plio-rax-host/bluespec:$ROOT/memory-controller/bluespec"
BSC="${BSC:-bsc}"
"$BSC" -promote-warnings G0021 -u -sim -p "$SEARCH" -bdir "$BUILD" -simdir "$BUILD" -g mkTbMemoryControllerInstructionWord "$ROOT/memory-controller/bluespec/TbMemoryControllerInstructionWord.bsv"
"$BSC" -sim -p "$SEARCH" -bdir "$BUILD" -simdir "$BUILD" -e mkTbMemoryControllerInstructionWord -o "$BUILD/test"
"$BUILD/test" | tee "$BUILD/result.log"
grep -q '^PASS qualified halfword/full-word fetch, malformed masks and word walker$' "$BUILD/result.log"
! grep -q '^FAIL' "$BUILD/result.log"
