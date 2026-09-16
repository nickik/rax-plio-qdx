#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${MEMORY_CONTROLLER_DEBUG_DIR:-$ROOT/build/memory-controller}"
BUILD="$BUILD_ROOT/fpga-bram"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/qic/bluespec:$ROOT/plio-rax-host/bluespec:$ROOT/memory-controller/bluespec"
BSC="${BSC:-bsc}"
BSC_STACK=(+RTS -K8M -RTS)

rm -rf "$BUILD"
mkdir -p "$BUILD/sim" "$BUILD/rtl-default" "$BUILD/rtl-128k"

command -v "$BSC" >/dev/null
command -v yosys >/dev/null

echo "== Default 1 MiB integrated BRAM backend Bluesim semantics =="
"$BSC" "${BSC_STACK[@]}" -u -sim -p "$SEARCH" \
    -bdir "$BUILD/sim" -simdir "$BUILD/sim" -info-dir "$BUILD/sim" \
    -g mkTbBlockRamBackend "$ROOT/memory-controller/bluespec/TbBlockRamBackend.bsv" \
    2>&1 | tee "$BUILD/bsc-sim-compile.log"
"$BSC" "${BSC_STACK[@]}" -sim -p "$SEARCH" \
    -bdir "$BUILD/sim" -simdir "$BUILD/sim" \
    -e mkTbBlockRamBackend -o "$BUILD/tb-block-ram-backend" \
    2>&1 | tee "$BUILD/bsc-sim-link.log"
"$BUILD/tb-block-ram-backend" 2>&1 | tee "$BUILD/sim.log"
grep '^MEMBRAMTRACE|' "$BUILD/sim.log" > "$BUILD/semantics.trace"
test "$(wc -l < "$BUILD/semantics.trace")" -eq 5
grep -q '^PASS FPGA block RAM backend semantics$' "$BUILD/sim.log"

echo "== Locate BSC BRAM1 synthesis primitive =="
BSC_REAL="$(readlink -f "$(command -v "$BSC")")"
BSC_PREFIX="$(cd "$(dirname "$BSC_REAL")/.." && pwd)"
BRAM1_V="$(find "$BSC_PREFIX" -type f -path '*/Verilog/BRAM1.v' -print -quit)"
test -n "$BRAM1_V"
test -s "$BRAM1_V"
printf 'BRAM1 primitive: %s\n' "$BRAM1_V"

generate_rtl() {
    local top="$1"
    local out="$2"
    "$BSC" "${BSC_STACK[@]}" -u -verilog -p "$SEARCH" \
        -bdir "$out" -vdir "$out" -info-dir "$out" \
        -g "$top" "$ROOT/memory-controller/bluespec/BlockRamBackend.bsv"
}

yosys_memory_stats() {
    local top="$1"
    local dir="$2"
    local log="$3"
    local rtl
    rtl="$(find "$dir" -maxdepth 1 -name '*.v' -print | sort | tr '\n' ' ')"
    test -n "$rtl"
    yosys -p "read_verilog -sv $rtl $BRAM1_V; hierarchy -check -top $top; flatten; proc; opt; stat" \
        2>&1 | tee "$log"
}

echo "== 1 MiB default integrated BRAM RTL =="
generate_rtl mkDefaultBlockRamBackend "$BUILD/rtl-default"
yosys_memory_stats mkDefaultBlockRamBackend "$BUILD/rtl-default" "$BUILD/yosys-default-memory.log"
grep -Eq 'Number of memories:[[:space:]]+1' "$BUILD/yosys-default-memory.log"
grep -Eq 'Number of memory bits:[[:space:]]+8388608' "$BUILD/yosys-default-memory.log"

echo "== 128 KiB alternative BRAM configuration RTL =="
generate_rtl mkBlockRamBackend128KiB "$BUILD/rtl-128k"
yosys_memory_stats mkBlockRamBackend128KiB "$BUILD/rtl-128k" "$BUILD/yosys-128k-memory.log"
grep -Eq 'Number of memories:[[:space:]]+1' "$BUILD/yosys-128k-memory.log"
grep -Eq 'Number of memory bits:[[:space:]]+1048576' "$BUILD/yosys-128k-memory.log"

echo "== Map default 1 MiB backend to native iCE40 block-RAM cells =="
RTL_DEFAULT="$(find "$BUILD/rtl-default" -maxdepth 1 -name '*.v' -print | sort | tr '\n' ' ')"
yosys -p "read_verilog -sv $RTL_DEFAULT $BRAM1_V; hierarchy -check -top mkDefaultBlockRamBackend; synth_ice40 -top mkDefaultBlockRamBackend; stat" \
    2>&1 | tee "$BUILD/yosys-ice40.log"
grep -Eq 'SB_RAM40_4K[[:space:]]+[1-9][0-9]*' "$BUILD/yosys-ice40.log"

echo "PASS 1 MiB integrated BRAM simulation, sizing, and native block-RAM synthesis"
