#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/qic-phase7"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/naked-card/bluespec:$ROOT/qli16/bluespec:$ROOT/pti/bluespec:$ROOT/trace/bluespec:$ROOT/qic/bluespec"

rm -rf "$BUILD"
mkdir -p "$BUILD"
command -v bsc >/dev/null

bsc -u -sim -p "$SEARCH" -bdir "$BUILD" -simdir "$BUILD" -info-dir "$BUILD" -g mkTbQICPhase7 "$ROOT/qic/bluespec/TbQICPhase7.bsv"
bsc -sim -p "$SEARCH" -bdir "$BUILD" -simdir "$BUILD" -e mkTbQICPhase7 -o "$BUILD/tb-qic-phase7"
"$BUILD/tb-qic-phase7"
