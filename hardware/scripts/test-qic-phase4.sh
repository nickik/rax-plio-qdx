#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/qic-phase4"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/qic/bluespec"

rm -rf "$BUILD"
mkdir -p "$BUILD/diff" "$BUILD/bursts"

command -v cargo >/dev/null
command -v bsc >/dev/null

echo "== Rust QIC manager/DMA regression =="
cargo test --manifest-path "$ROOT/Cargo.toml" -p plio-qic-model --test manager

echo "== QIC Phase 4 Bluesim / Rust differential trace =="
bsc -u -sim -p "$SEARCH" -bdir "$BUILD/diff" -simdir "$BUILD/diff" -info-dir "$BUILD/diff" \
    -g mkTbQICPhase4 "$ROOT/qic/bluespec/TbQICPhase4.bsv"
bsc -sim -p "$SEARCH" -bdir "$BUILD/diff" -simdir "$BUILD/diff" \
    -e mkTbQICPhase4 -o "$BUILD/tb-qic-phase4"
"$BUILD/tb-qic-phase4" | tee "$BUILD/qic-phase4-bsv.log"
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p plio-qic-model --bin phase4_conformance \
    | grep '^TRACE|' > "$BUILD/qic-phase4-rust.trace"
grep '^TRACE|' "$BUILD/qic-phase4-bsv.log" > "$BUILD/qic-phase4-bsv.trace"
diff -u "$BUILD/qic-phase4-rust.trace" "$BUILD/qic-phase4-bsv.trace"
echo "PASS Rust/Bluesim QIC Phase 4 differential trace"

echo "== QIC Phase 4 all burst sizes =="
bsc -u -sim -p "$SEARCH" -bdir "$BUILD/bursts" -simdir "$BUILD/bursts" -info-dir "$BUILD/bursts" \
    -g mkTbQICPhase4Bursts "$ROOT/qic/bluespec/TbQICPhase4Bursts.bsv"
bsc -sim -p "$SEARCH" -bdir "$BUILD/bursts" -simdir "$BUILD/bursts" \
    -e mkTbQICPhase4Bursts -o "$BUILD/tb-qic-phase4-bursts"
"$BUILD/tb-qic-phase4-bursts"
echo "PASS Bluesim QIC Phase 4 1/4/8/16 burst regression"
