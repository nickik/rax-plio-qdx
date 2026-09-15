#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/qdx-a"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/qic/bluespec:$ROOT/qdx-a/bluespec"

rm -rf "$BUILD"
mkdir -p "$BUILD/sim" "$BUILD/rtl"

command -v cargo >/dev/null
command -v bsc >/dev/null

echo "== Rust QDX-A reference model =="
cargo test --manifest-path "$ROOT/Cargo.toml" -p qdx-a-model --all-targets
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p qdx-a-model --bin conformance \
    | tee "$BUILD/qdx-a-rust.log"
grep '^QDXATRACE|' "$BUILD/qdx-a-rust.log" > "$BUILD/qdx-a-rust.trace"
test "$(wc -l < "$BUILD/qdx-a-rust.trace")" -eq 9

echo "== Compile minimal QDX-A Bluesim testbench =="
bsc -u -sim -p "$SEARCH" \
    -bdir "$BUILD/sim" -simdir "$BUILD/sim" -info-dir "$BUILD/sim" \
    -g mkTbQDXA "$ROOT/qdx-a/bluespec/TbQDXA.bsv"

bsc -sim -p "$SEARCH" \
    -bdir "$BUILD/sim" -simdir "$BUILD/sim" \
    -e mkTbQDXA -o "$BUILD/tb-qdx-a"

"$BUILD/tb-qdx-a" | tee "$BUILD/qdx-a-bsv.log"
grep '^QDXATRACE|' "$BUILD/qdx-a-bsv.log" > "$BUILD/qdx-a-bsv.trace"
test "$(wc -l < "$BUILD/qdx-a-bsv.trace")" -eq 9
grep -q '^PASS minimal QDX-A chip queue path$' "$BUILD/qdx-a-bsv.log"

echo "== Exact Rust / Bluesim QDX-A lifecycle equivalence =="
diff -u "$BUILD/qdx-a-rust.trace" "$BUILD/qdx-a-bsv.trace"

echo "== Generate standalone QDX-A Verilog =="
bsc -u -verilog -p "$SEARCH" \
    -bdir "$BUILD/rtl" -vdir "$BUILD/rtl" -info-dir "$BUILD/rtl" \
    -g mkQDXA "$ROOT/qdx-a/bluespec/QDXA.bsv"

test -s "$BUILD/rtl/mkQDXA.v"

echo "PASS QDX-A Rust/Bluesim differential and RTL generation"
