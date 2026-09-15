#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/plio-host-m1"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/qic/bluespec:$ROOT/plio-rax-host/bluespec"

rm -rf "$BUILD"
mkdir -p "$BUILD/sim" "$BUILD/rtl"

command -v cargo >/dev/null
command -v bsc >/dev/null

echo "== Rust PLIO host worker model =="
cargo test --manifest-path "$ROOT/Cargo.toml" -p plio-host-model --all-targets
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p plio-host-model --bin conformance \
    | tee "$BUILD/rust.log"
grep '^PLIOHOSTTRACE|' "$BUILD/rust.log" > "$BUILD/rust.trace"
test "$(wc -l < "$BUILD/rust.trace")" -eq 9

echo "== Bluesim PLIO host worker model =="
bsc -u -sim -p "$SEARCH" \
    -bdir "$BUILD/sim" -simdir "$BUILD/sim" -info-dir "$BUILD/sim" \
    -g mkTbPLIOWorkerHost "$ROOT/plio-rax-host/bluespec/TbPLIOWorkerHost.bsv"

bsc -sim -p "$SEARCH" \
    -bdir "$BUILD/sim" -simdir "$BUILD/sim" \
    -e mkTbPLIOWorkerHost -o "$BUILD/tb-plio-host"

"$BUILD/tb-plio-host" | tee "$BUILD/bsv.log"
grep '^PLIOHOSTTRACE|' "$BUILD/bsv.log" > "$BUILD/bsv.trace"
test "$(wc -l < "$BUILD/bsv.trace")" -eq 9
grep -q '^PASS PLIO host M1 Rust/Bluespec worker MMIO semantics$' "$BUILD/bsv.log"

echo "== Exact Rust / Bluesim worker-host equivalence =="
diff -u "$BUILD/rust.trace" "$BUILD/bsv.trace"

echo "== Generate worker-host Verilog =="
bsc -u -verilog -p "$SEARCH" \
    -bdir "$BUILD/rtl" -vdir "$BUILD/rtl" -info-dir "$BUILD/rtl" \
    -g mkPLIOWorkerHost "$ROOT/plio-rax-host/bluespec/PLIOWorkerHost.bsv"

test -s "$BUILD/rtl/mkPLIOWorkerHost.v"
echo "PASS PLIO host M0/M1 Rust/Bluesim differential and RTL generation"
