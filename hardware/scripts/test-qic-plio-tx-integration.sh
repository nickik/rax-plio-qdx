#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/qic-plio-tx-integration"
SEARCH="+:$ROOT/qic/bluespec:$ROOT/qli/bluespec:$ROOT/pti/bluespec:$ROOT/plio-tx/bluespec:$ROOT/testbench/bluespec"
rm -rf "$BUILD"; mkdir -p "$BUILD/bsv"
command -v cargo >/dev/null
command -v bsc >/dev/null

echo '== Rust complete QIC -> PTI -> PLIO-TX integration =='
cargo test --manifest-path "$ROOT/Cargo.toml" -p plio-testbench --test qic_plio_tx
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p plio-testbench --bin qic_tx_conformance | grep '^QTXTRACE|' > "$BUILD/rust.trace"

echo '== Bluespec unified QIC -> PTI -> PLIO-TX integration =='
bsc -u -sim -p "$SEARCH" -bdir "$BUILD/bsv" -simdir "$BUILD/bsv" -info-dir "$BUILD/bsv" -g mkTbQicTxIntegration "$ROOT/testbench/bluespec/TbQicTxIntegration.bsv"
bsc -sim -p "$SEARCH" -bdir "$BUILD/bsv" -simdir "$BUILD/bsv" -e mkTbQicTxIntegration -o "$BUILD/tb"
"$BUILD/tb" | tee "$BUILD/bsv.log"
grep '^QTXTRACE|' "$BUILD/bsv.log" > "$BUILD/bsv.trace"

echo '== Exact Rust / Bluesim externally-visible trace =='
diff -u "$BUILD/rust.trace" "$BUILD/bsv.trace"
echo 'PASS complete QIC + PTI + PLIO-TX Rust/Bluesim integration equivalence'
