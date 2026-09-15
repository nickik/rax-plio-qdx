#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/qdx-a-card"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/qic/bluespec:$ROOT/pti/bluespec:$ROOT/plio-tx/bluespec:$ROOT/qli16/bluespec:$ROOT/testbench/bluespec:$ROOT/qdx-a/bluespec:$ROOT/qdx-a-card/bluespec"

rm -rf "$BUILD"
mkdir -p "$BUILD/sim"

command -v cargo >/dev/null
command -v bsc >/dev/null

echo "== Rust QDX-A physical card reference =="
(
    cd "$ROOT"
    cargo test -q -p qdx-a-card-model
    cargo run -q -p qdx-a-card-model --bin card_conformance
) | tee "$BUILD/rust-card.log"
grep '^QDXACARDTRACE|v1|' "$BUILD/rust-card.log" > "$BUILD/rust.trace"
test "$(wc -l < "$BUILD/rust.trace")" -eq 7
grep -q '^PASS Rust QDX-A physical card PLIO-TX -> PTI -> QIC -> QLI-16 -> QDX-A$' "$BUILD/rust-card.log"

echo "== Bluespec QDX-A physical card =="
bsc -u -sim -p "$SEARCH" \
    -bdir "$BUILD/sim" -simdir "$BUILD/sim" -info-dir "$BUILD/sim" \
    -g mkTbQDXACard "$ROOT/qdx-a-card/bluespec/TbQDXACard.bsv"

bsc -sim -p "$SEARCH" \
    -bdir "$BUILD/sim" -simdir "$BUILD/sim" \
    -e mkTbQDXACard -o "$BUILD/tb-qdx-a-card"

"$BUILD/tb-qdx-a-card" | tee "$BUILD/bluespec-card.log"
grep '^QDXACARDTRACE|v1|' "$BUILD/bluespec-card.log" > "$BUILD/bluespec.trace"
test "$(wc -l < "$BUILD/bluespec.trace")" -eq 7
grep -q '^PASS QDX-A physical card PLIO-TX -> PTI -> QIC -> QLI-16 -> QDX-A$' "$BUILD/bluespec-card.log"

echo "== Exact ordered Rust <-> Bluespec physical-card trace diff =="
diff -u "$BUILD/rust.trace" "$BUILD/bluespec.trace"

echo "PASS QDX-A physical card Rust/Bluespec differential"
