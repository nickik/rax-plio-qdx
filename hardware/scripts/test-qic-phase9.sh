#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/qic-phase9"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/naked-card/bluespec:$ROOT/qli16/bluespec:$ROOT/pti/bluespec:$ROOT/trace/bluespec:$ROOT/qic/bluespec"

rm -rf "$BUILD"
mkdir -p "$BUILD/bdir" "$BUILD/vdir" "$BUILD/info"
command -v bsc >/dev/null
command -v yosys >/dev/null

echo '== QIC Phase9 generated-Verilog synthesis smoke =='
bsc -u -verilog -p "$SEARCH" -bdir "$BUILD/bdir" -vdir "$BUILD/vdir" -info-dir "$BUILD/info" \
    -g mkPLIOQIC "$ROOT/qic/bluespec/PLIOQIC.bsv"

VERILOG="$BUILD/vdir/mkPLIOQIC.v"
test -s "$VERILOG"
grep -q '^module mkPLIOQIC' "$VERILOG"

echo "Generated: $VERILOG"
echo "Yosys: $(yosys -V)"
# Yosys parses the -p argument itself; shell-style single quotes around the
# filename would become literal filename characters. Pass the path directly.
yosys -p "read_verilog -sv $VERILOG; hierarchy -check -top mkPLIOQIC; proc; opt; memory; opt; check; stat" \
    | tee "$BUILD/yosys.log"

grep -Eq 'Number of memories:[[:space:]]+0' "$BUILD/yosys.log"
grep -Eq 'Number of memory bits:[[:space:]]+0' "$BUILD/yosys.log"
! grep -Eiq '\$mem(rd|wr|init)|RAMB|SB_RAM' "$VERILOG"

echo "PASS QIC Phase9 generated Verilog and Yosys memory-free synthesis smoke"
