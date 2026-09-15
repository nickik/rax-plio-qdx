#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE_BUILD="$ROOT/build/plio-host-m1"
BUILD="$ROOT/build/plio-host-m4"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/qic/bluespec:$ROOT/plio-rax-host/bluespec"
BSC_STACK=(+RTS -K8M -RTS)

# M4 must not regress the independently proven M1/M2/M3 components.
bash "$ROOT/scripts/test-plio-host-m1.sh"

rm -rf "$BUILD"
mkdir -p "$BUILD/sim" "$BUILD/rtl"

echo "== M4 Rust integrated PLIOHostCore =="
cargo test --manifest-path "$ROOT/Cargo.toml" -p plio-host-core-model --all-targets
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p plio-host-core-model --bin conformance | tee "$BUILD/rust.log"
grep '^PLIOHOSTCORETRACE|' "$BUILD/rust.log" > "$BUILD/rust.trace"
test "$(wc -l < "$BUILD/rust.trace")" -eq 20
grep -q '^PASS PLIO host M4a-M4d integrated deterministic semantics$' "$BUILD/rust.log"

echo "== M4 Bluesim integrated PLIOHostCore =="
bsc "${BSC_STACK[@]}" -u -sim -p "$SEARCH" -bdir "$BUILD/sim" -simdir "$BUILD/sim" -info-dir "$BUILD/sim" -g mkTbPLIOHostCore "$ROOT/plio-rax-host/bluespec/TbPLIOHostCore.bsv"
bsc "${BSC_STACK[@]}" -sim -p "$SEARCH" -bdir "$BUILD/sim" -simdir "$BUILD/sim" -e mkTbPLIOHostCore -o "$BUILD/tb-plio-host-m4"
"$BUILD/tb-plio-host-m4" | tee "$BUILD/bsv.log"
grep '^PLIOHOSTCORETRACE|' "$BUILD/bsv.log" > "$BUILD/bsv.trace"
test "$(wc -l < "$BUILD/bsv.trace")" -eq 20
grep -q '^PASS PLIO host M4a-M4d integrated deterministic semantics$' "$BUILD/bsv.log"

echo "== Exact M4 deterministic Rust / Bluesim equivalence =="
diff -u "$BUILD/rust.trace" "$BUILD/bsv.trace"

echo "== Generate integrated mkPLIOHostCore Verilog =="
bsc "${BSC_STACK[@]}" -u -verilog -p "$SEARCH" -bdir "$BUILD/rtl" -vdir "$BUILD/rtl" -info-dir "$BUILD/rtl" -g mkPLIOHostCore "$ROOT/plio-rax-host/bluespec/PLIOHostCore.bsv" 2>&1 | tee "$BUILD/rtl.log"
test -s "$BUILD/rtl/mkPLIOHostCore.v"
# M4 owns the bus structurally; scheduling warnings that mention mkPLIOHostCore are treated as failures.
if grep -E 'Warning:.*PLIOHostCore|Rule .*shadow|will appear to fire before' "$BUILD/rtl.log"; then
    echo "FAIL: unresolved M4 scheduling/ownership warning" >&2
    exit 1
fi

echo "PASS PLIO host M4a-M4d Rust/Bluesim deterministic differential and RTL generation"
