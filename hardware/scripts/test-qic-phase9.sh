#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/qic-phase9"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/naked-card/bluespec:$ROOT/qli16/bluespec:$ROOT/pti/bluespec:$ROOT/trace/bluespec:$ROOT/qic/bluespec"

rm -rf "$BUILD"
mkdir -p "$BUILD/bdir" "$BUILD/vdir" "$BUILD/info"
command -v bsc >/dev/null
command -v yosys >/dev/null

echo '== Phase9 diagnostic environment =='
echo "PWD=$PWD"
echo "ROOT=$ROOT"
printf 'bsc='; command -v bsc
printf 'yosys='; command -v yosys
bsc -version || true
yosys -V || true
if command -v iverilog >/dev/null; then
    iverilog -V 2>&1 | head -4 || true
fi

BSC_BIN="$(readlink -f "$(command -v bsc)")"
BSC_ROOT="$(cd "$(dirname "$BSC_BIN")/.." && pwd)"
echo "BSC_BIN=$BSC_BIN"
echo "BSC_ROOT=$BSC_ROOT"
echo 'BSC RegN candidates:'
find "$BSC_ROOT" -type f -name 'RegN.v' -print 2>/dev/null | sort || true
REGN="$(find "$BSC_ROOT" -type f -name 'RegN.v' -print -quit 2>/dev/null || true)"
if [[ -n "$REGN" ]]; then
    echo "REGN=$REGN"
    echo '--- installed RegN.v ---'
    nl -ba "$REGN" | sed -n '1,140p'
    echo '--- installed BSV reset macro references near Verilog primitives ---'
    grep -R -n -m 40 -E 'define BSV_RESET_(VALUE|EDGE)|module RegN' "$(dirname "$REGN")" || true
fi

echo '== BSC Verilog generation =='
set -x
bsc -u -verilog -p "$SEARCH" -bdir "$BUILD/bdir" -vdir "$BUILD/vdir" -info-dir "$BUILD/info" \
    -g mkPLIOQIC "$ROOT/qic/bluespec/PLIOQIC.bsv"
set +x

VERILOG="$BUILD/vdir/mkPLIOQIC.v"
test -s "$VERILOG"
grep -q '^module mkPLIOQIC' "$VERILOG"

echo 'Generated Verilog files:'
find "$BUILD/vdir" -maxdepth 1 -type f -printf '%f\n' | sort
echo 'Generated module declarations:'
grep -R -n '^module ' "$BUILD/vdir" || true
echo 'Generated RegN/reset/fire references with context:'
grep -n -B 8 -A 12 -E 'RegN|BSV_RESET_VALUE|WILL_FIRE_EN' "$VERILOG" || true
echo 'Generated Verilog first 180 lines:'
nl -ba "$VERILOG" | sed -n '1,180p'
echo 'Generated Verilog lines containing suspicious adjacent named connections:'
grep -n -E '^\s*\.[A-Za-z_][A-Za-z0-9_]*\([^;]*\)$' "$VERILOG" | head -80 || true

echo '== Parser probes =='
IVERILOG_RC=127
if command -v iverilog >/dev/null; then
    set +e
    if [[ -n "$REGN" ]]; then
        iverilog -g2012 -tnull -I "$(dirname "$REGN")" "$REGN" "$VERILOG" 2>&1 | tee "$BUILD/iverilog.log"
    else
        iverilog -g2012 -tnull "$VERILOG" 2>&1 | tee "$BUILD/iverilog.log"
    fi
    IVERILOG_RC=${PIPESTATUS[0]}
    set -e
    echo "IVERILOG_RC=$IVERILOG_RC"
fi

set +e
if [[ -n "$REGN" ]]; then
    yosys -p "read_verilog -sv -I$(dirname "$REGN") '$REGN' '$VERILOG'; hierarchy -check -top mkPLIOQIC; proc; opt; memory; opt; check; stat" \
        2>&1 | tee "$BUILD/yosys.log"
else
    yosys -p "read_verilog -sv '$VERILOG'; hierarchy -check -top mkPLIOQIC; proc; opt; memory; opt; check; stat" \
        2>&1 | tee "$BUILD/yosys.log"
fi
YOSYS_RC=${PIPESTATUS[0]}
set -e
echo "YOSYS_RC=$YOSYS_RC"

if [[ $YOSYS_RC -ne 0 ]]; then
    echo 'FAIL Phase9 Yosys synthesis probe'
    exit "$YOSYS_RC"
fi

grep -Eq 'Number of memories:[[:space:]]+0' "$BUILD/yosys.log"
grep -Eq 'Number of memory bits:[[:space:]]+0' "$BUILD/yosys.log"
! grep -Eiq '\$mem(rd|wr|init)|RAMB|SB_RAM' "$VERILOG"

echo "PASS QIC Phase9 generated Verilog and Yosys memory-free synthesis smoke"
