#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/qic-phase9"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/naked-card/bluespec:$ROOT/qli16/bluespec:$ROOT/pti/bluespec:$ROOT/trace/bluespec:$ROOT/qic/bluespec"

rm -rf "$BUILD"
mkdir -p "$BUILD/bdir" "$BUILD/vdir" "$BUILD/info"
command -v bsc >/dev/null
command -v yosys >/dev/null

bsc -u -verilog -p "$SEARCH" -bdir "$BUILD/bdir" -vdir "$BUILD/vdir" -info-dir "$BUILD/info" \
    -g mkPLIOQIC "$ROOT/qic/bluespec/PLIOQIC.bsv"

VERILOG="$BUILD/vdir/mkPLIOQIC.v"
test -s "$VERILOG"
grep -q '^module mkPLIOQIC' "$VERILOG"

# The unified abstract QIC is intentionally register/FSM logic only.  Yosys
# must be able to elaborate it without PTI/QLI-16 wrappers and must not infer
# RAMs or memories.
yosys -p "read_verilog '$VERILOG'; hierarchy -check -top mkPLIOQIC; proc; opt; memory; opt; check; stat" \
    | tee "$BUILD/yosys.log"

grep -Eq 'Number of memories:[[:space:]]+0' "$BUILD/yosys.log"
grep -Eq 'Number of memory bits:[[:space:]]+0' "$BUILD/yosys.log"
! grep -Eiq '\$mem(rd|wr|init)|RAMB|SB_RAM' "$VERILOG"

echo "PASS QIC Phase9 generated Verilog and Yosys memory-free synthesis smoke"
