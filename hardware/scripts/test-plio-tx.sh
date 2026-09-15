#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/plio-tx"
SEARCH="+:$ROOT/pti/bluespec:$ROOT/plio-tx/bluespec"

rm -rf "$BUILD"
mkdir -p "$BUILD/bsv"

command -v cargo >/dev/null
command -v bsc >/dev/null

echo "== PTI frozen encoding regression =="
cargo test --manifest-path "$ROOT/Cargo.toml" -p pti-model

echo "== Rust PLIO-TX logical model =="
cargo test --manifest-path "$ROOT/Cargo.toml" -p plio-tx-model --all-targets

echo "== Bluesim PLIO-TX logical model =="
bsc -u -sim -p "$SEARCH" \
    -bdir "$BUILD/bsv" -simdir "$BUILD/bsv" -info-dir "$BUILD/bsv" \
    -g mkTbPLIOTx "$ROOT/plio-tx/bluespec/TbPLIOTx.bsv"
bsc -sim -p "$SEARCH" \
    -bdir "$BUILD/bsv" -simdir "$BUILD/bsv" \
    -e mkTbPLIOTx -o "$BUILD/tb-plio-tx"
"$BUILD/tb-plio-tx" | tee "$BUILD/plio-tx-bsv.log"

echo "== Rust / Bluesim PLIO-TX exact trace =="
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p plio-tx-model --bin conformance \
    | grep '^TXTRACE|' > "$BUILD/plio-tx-rust.trace"
grep '^TXTRACE|' "$BUILD/plio-tx-bsv.log" > "$BUILD/plio-tx-bsv.trace"
diff -u "$BUILD/plio-tx-rust.trace" "$BUILD/plio-tx-bsv.trace"

echo "PASS Rust/Bluesim PLIO-TX logical equivalence"
