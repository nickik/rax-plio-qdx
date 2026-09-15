#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/qic-phase5"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/qic/bluespec"

rm -rf "$BUILD"
mkdir -p "$BUILD/diff" "$BUILD/bursts"

command -v cargo >/dev/null
command -v bsc >/dev/null

echo "== Rust QIC manager/DMA regression =="
cargo test --manifest-path "$ROOT/Cargo.toml" -p plio-qic-model --test manager

echo "== QIC Phase 5 Bluesim / Rust differential trace =="
bsc -u -sim -p "$SEARCH" -bdir "$BUILD/diff" -simdir "$BUILD/diff" -info-dir "$BUILD/diff" \
    -g mkTbQICPhase5 "$ROOT/qic/bluespec/TbQICPhase5.bsv"
bsc -sim -p "$SEARCH" -bdir "$BUILD/diff" -simdir "$BUILD/diff" \
    -e mkTbQICPhase5 -o "$BUILD/tb-qic-phase5"
"$BUILD/tb-qic-phase5" | tee "$BUILD/qic-phase5-bsv.log"
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p plio-qic-model --bin phase5_conformance \
    | grep '^TRACE|' > "$BUILD/qic-phase5-rust.trace"
grep '^TRACE|' "$BUILD/qic-phase5-bsv.log" > "$BUILD/qic-phase5-bsv.trace"
diff -u "$BUILD/qic-phase5-rust.trace" "$BUILD/qic-phase5-bsv.trace"
echo "PASS Rust/Bluesim QIC Phase 5 differential trace"

echo "== QIC Phase 5 all burst sizes =="
bsc -u -sim -p "$SEARCH" -bdir "$BUILD/bursts" -simdir "$BUILD/bursts" -info-dir "$BUILD/bursts" \
    -g mkTbQICPhase5Bursts "$ROOT/qic/bluespec/TbQICPhase5Bursts.bsv"
bsc -sim -p "$SEARCH" -bdir "$BUILD/bursts" -simdir "$BUILD/bursts" \
    -e mkTbQICPhase5Bursts -o "$BUILD/tb-qic-phase5-bursts"
"$BUILD/tb-qic-phase5-bursts"
echo "PASS Bluesim QIC Phase 5 1/4/8/16 burst regression"
