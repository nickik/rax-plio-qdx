#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/memory-controller"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/qic/bluespec:$ROOT/plio-rax-host/bluespec:$ROOT/memory-controller/bluespec"
BSC_STACK=(+RTS -K8M -RTS)

rm -rf "$BUILD"
mkdir -p "$BUILD/controller-sim" "$BUILD/host-sim" "$BUILD/rtl"
command -v bsc >/dev/null
command -v cargo >/dev/null
command -v yosys >/dev/null

echo "== Memory controller Rust reference =="
cargo test --manifest-path "$ROOT/Cargo.toml" -p memory-controller-model --all-targets
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p memory-controller-model --bin conformance | tee "$BUILD/rust.log"
grep '^MEMCTRLTRACE|' "$BUILD/rust.log" > "$BUILD/rust-controller.trace"
grep '^MEMHOSTTRACE|' "$BUILD/rust.log" > "$BUILD/rust-host.trace"
test "$(wc -l < "$BUILD/rust-controller.trace")" -eq 12
test "$(wc -l < "$BUILD/rust-host.trace")" -eq 3
grep -q '^PASS memory controller Rust reference + PLIO host integration$' "$BUILD/rust.log"

echo "== Memory controller Bluesim reference =="
bsc "${BSC_STACK[@]}" -u -sim -p "$SEARCH" \
    -bdir "$BUILD/controller-sim" -simdir "$BUILD/controller-sim" -info-dir "$BUILD/controller-sim" \
    -g mkTbMemoryController "$ROOT/memory-controller/bluespec/TbMemoryController.bsv"
bsc "${BSC_STACK[@]}" -sim -p "$SEARCH" \
    -bdir "$BUILD/controller-sim" -simdir "$BUILD/controller-sim" \
    -e mkTbMemoryController -o "$BUILD/tb-memory-controller"
"$BUILD/tb-memory-controller" | tee "$BUILD/controller-bsv.log"
grep '^MEMCTRLTRACE|' "$BUILD/controller-bsv.log" > "$BUILD/bsv-controller.trace"
test "$(wc -l < "$BUILD/bsv-controller.trace")" -eq 12
grep -q '^PASS memory controller Bluespec deterministic semantics$' "$BUILD/controller-bsv.log"

echo "== Exact Rust / Bluesim memory-controller trace =="
diff -u "$BUILD/rust-controller.trace" "$BUILD/bsv-controller.trace"

echo "== PLIOHostCore -> MemoryController -> fake RAM Bluesim integration =="
bsc "${BSC_STACK[@]}" -u -sim -p "$SEARCH" \
    -bdir "$BUILD/host-sim" -simdir "$BUILD/host-sim" -info-dir "$BUILD/host-sim" \
    -g mkTbPLIOHostMemory "$ROOT/memory-controller/bluespec/TbPLIOHostMemory.bsv"
bsc "${BSC_STACK[@]}" -sim -p "$SEARCH" \
    -bdir "$BUILD/host-sim" -simdir "$BUILD/host-sim" \
    -e mkTbPLIOHostMemory -o "$BUILD/tb-plio-host-memory"
"$BUILD/tb-plio-host-memory" | tee "$BUILD/host-bsv.log"
grep '^MEMHOSTTRACE|' "$BUILD/host-bsv.log" > "$BUILD/bsv-host.trace"
test "$(wc -l < "$BUILD/bsv-host.trace")" -eq 3
grep -q '^PASS memory controller Bluespec + PLIO host integration$' "$BUILD/host-bsv.log"

echo "== Exact Rust / Bluesim PLIO-host memory integration =="
diff -u "$BUILD/rust-host.trace" "$BUILD/bsv-host.trace"

echo "== Generate and synthesize memory-free controller RTL =="
bsc "${BSC_STACK[@]}" -u -verilog -p "$SEARCH" \
    -bdir "$BUILD/rtl" -vdir "$BUILD/rtl" -info-dir "$BUILD/rtl" \
    -g mkMemoryController "$ROOT/memory-controller/bluespec/MemoryController.bsv"
VERILOG="$BUILD/rtl/mkMemoryController.v"
test -s "$VERILOG"
grep -q '^module mkMemoryController' "$VERILOG"
yosys -p "read_verilog -sv $VERILOG; hierarchy -check -top mkMemoryController; proc; opt; memory; opt; check; stat" \
    | tee "$BUILD/yosys.log"
grep -Eq 'Number of memories:[[:space:]]+0' "$BUILD/yosys.log"
grep -Eq 'Number of memory bits:[[:space:]]+0' "$BUILD/yosys.log"
! grep -Eiq '\$mem(rd|wr|init)|RAMB|SB_RAM' "$VERILOG"

echo "PASS memory controller Rust/Bluespec/PLIO integration and synthesis gate"
