#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/qic-phase6"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/qic/bluespec"

rm -rf "$BUILD"
mkdir -p "$BUILD/diff"

command -v cargo >/dev/null
command -v bsc >/dev/null

echo "== Rust QIC manager/notification regression =="
cargo test --manifest-path "$ROOT/Cargo.toml" -p plio-qic-model --test manager

echo "== QIC Phase 6 Bluesim / Rust differential trace =="
bsc -u -sim -p "$SEARCH" -bdir "$BUILD/diff" -simdir "$BUILD/diff" -info-dir "$BUILD/diff" \
    -g mkTbQICPhase6 "$ROOT/qic/bluespec/TbQICPhase6.bsv"
bsc -sim -p "$SEARCH" -bdir "$BUILD/diff" -simdir "$BUILD/diff" \
    -e mkTbQICPhase6 -o "$BUILD/tb-qic-phase6"
"$BUILD/tb-qic-phase6" | tee "$BUILD/qic-phase6-bsv.log"
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p plio-qic-model --bin phase6_conformance \
    | grep '^TRACE|' > "$BUILD/qic-phase6-rust.trace"
grep '^TRACE|' "$BUILD/qic-phase6-bsv.log" > "$BUILD/qic-phase6-bsv.trace"
diff -u "$BUILD/qic-phase6-rust.trace" "$BUILD/qic-phase6-bsv.trace"
echo "PASS Rust/Bluesim QIC Phase 6 differential trace"
