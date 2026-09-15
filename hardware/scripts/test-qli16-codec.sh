#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/qli16-codec"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/qic/bluespec:$ROOT/qli16/bluespec"

rm -rf "$BUILD"
mkdir -p "$BUILD/bsv"

command -v cargo >/dev/null
command -v bsc >/dev/null

echo "== Rust QLI-16 encoding + stateful codec =="
cargo test --manifest-path "$ROOT/Cargo.toml" -p qli16-model --all-targets

echo "== Bluesim QLI-16 stateful codec =="
bsc -u -sim -p "$SEARCH" \
    -bdir "$BUILD/bsv" -simdir "$BUILD/bsv" -info-dir "$BUILD/bsv" \
    -g mkTbQLI16Codec "$ROOT/qli16/bluespec/TbQLI16Codec.bsv"
bsc -sim -p "$SEARCH" \
    -bdir "$BUILD/bsv" -simdir "$BUILD/bsv" \
    -e mkTbQLI16Codec -o "$BUILD/tb-qli16-codec"
"$BUILD/tb-qli16-codec" | tee "$BUILD/qli16-bsv.log"

echo "== Rust / Bluesim exact QLI-16 physical trace =="
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p qli16-model --bin codec_conformance \
    | grep -E '^Q16(TRACE|RESULT)\|' > "$BUILD/qli16-rust.trace"
grep -E '^Q16(TRACE|RESULT)\|' "$BUILD/qli16-bsv.log" > "$BUILD/qli16-bsv.trace"
diff -u "$BUILD/qli16-rust.trace" "$BUILD/qli16-bsv.trace"

echo "PASS Rust/Bluesim QLI-16 stateful codec equivalence"
