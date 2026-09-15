#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/plio-host-m1"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/qic/bluespec:$ROOT/plio-rax-host/bluespec"

rm -rf "$BUILD"
mkdir -p "$BUILD/m1-sim" "$BUILD/m1-rtl" "$BUILD/m2-sim" "$BUILD/m2-rtl"

command -v cargo >/dev/null
command -v bsc >/dev/null

echo "== M1 Rust PLIO host worker model =="
cargo test --manifest-path "$ROOT/Cargo.toml" -p plio-host-model --all-targets
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p plio-host-model --bin conformance \
    | tee "$BUILD/m1-rust.log"
grep '^PLIOHOSTTRACE|' "$BUILD/m1-rust.log" > "$BUILD/m1-rust.trace"
test "$(wc -l < "$BUILD/m1-rust.trace")" -eq 9

echo "== M1 Bluesim PLIO host worker model =="
bsc -u -sim -p "$SEARCH" \
    -bdir "$BUILD/m1-sim" -simdir "$BUILD/m1-sim" -info-dir "$BUILD/m1-sim" \
    -g mkTbPLIOWorkerHost "$ROOT/plio-rax-host/bluespec/TbPLIOWorkerHost.bsv"

bsc -sim -p "$SEARCH" \
    -bdir "$BUILD/m1-sim" -simdir "$BUILD/m1-sim" \
    -e mkTbPLIOWorkerHost -o "$BUILD/tb-plio-host-m1"

"$BUILD/tb-plio-host-m1" | tee "$BUILD/m1-bsv.log"
grep '^PLIOHOSTTRACE|' "$BUILD/m1-bsv.log" > "$BUILD/m1-bsv.trace"
test "$(wc -l < "$BUILD/m1-bsv.trace")" -eq 9
grep -q '^PASS PLIO host M1 Rust/Bluespec worker MMIO semantics$' "$BUILD/m1-bsv.log"

echo "== Exact M1 Rust / Bluesim equivalence =="
diff -u "$BUILD/m1-rust.trace" "$BUILD/m1-bsv.trace"

echo "== M2 Rust manager model =="
cargo test --manifest-path "$ROOT/Cargo.toml" -p plio-host-manager-model --all-targets
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p plio-host-manager-model --bin conformance \
    | tee "$BUILD/m2-rust.log"
grep '^PLIOHOSTM2TRACE|' "$BUILD/m2-rust.log" > "$BUILD/m2-rust.trace"
test "$(wc -l < "$BUILD/m2-rust.trace")" -eq 8

echo "== M2 Bluesim manager model =="
bsc +RTS -K64m -RTS -u -sim -p "$SEARCH" \
    -bdir "$BUILD/m2-sim" -simdir "$BUILD/m2-sim" -info-dir "$BUILD/m2-sim" \
    -g mkTbPLIOHostManagerM2 "$ROOT/plio-rax-host/bluespec/TbPLIOHostManagerM2.bsv"

bsc +RTS -K64m -RTS -sim -p "$SEARCH" \
    -bdir "$BUILD/m2-sim" -simdir "$BUILD/m2-sim" \
    -e mkTbPLIOHostManagerM2 -o "$BUILD/tb-plio-host-m2"

"$BUILD/tb-plio-host-m2" | tee "$BUILD/m2-bsv.log"
grep '^PLIOHOSTM2TRACE|' "$BUILD/m2-bsv.log" > "$BUILD/m2-bsv.trace"
test "$(wc -l < "$BUILD/m2-bsv.trace")" -eq 8
grep -q '^PASS PLIO host M2 arbitration/notification semantics$' "$BUILD/m2-bsv.log"

echo "== Exact M2 Rust / Bluesim equivalence =="
diff -u "$BUILD/m2-rust.trace" "$BUILD/m2-bsv.trace"

echo "== Generate M1/M2 Verilog =="
bsc -u -verilog -p "$SEARCH" \
    -bdir "$BUILD/m1-rtl" -vdir "$BUILD/m1-rtl" -info-dir "$BUILD/m1-rtl" \
    -g mkPLIOWorkerHost "$ROOT/plio-rax-host/bluespec/PLIOWorkerHost.bsv"

bsc +RTS -K64m -RTS -u -verilog -p "$SEARCH" \
    -bdir "$BUILD/m2-rtl" -vdir "$BUILD/m2-rtl" -info-dir "$BUILD/m2-rtl" \
    -g mkPLIOHostManagerM2 "$ROOT/plio-rax-host/bluespec/PLIOHostManagerM2.bsv"

test -s "$BUILD/m1-rtl/mkPLIOWorkerHost.v"
test -s "$BUILD/m2-rtl/mkPLIOHostManagerM2.v"
echo "PASS PLIO host M0/M1/M2 Rust/Bluesim differential and RTL generation"
