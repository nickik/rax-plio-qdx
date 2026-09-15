#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/qdx-b"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/qic/bluespec:$ROOT/pti/bluespec:$ROOT/plio-tx/bluespec:$ROOT/qli16/bluespec:$ROOT/testbench/bluespec:$ROOT/qdx-a/bluespec:$ROOT/qdx-a-card/bluespec:$ROOT/qdx-b/bluespec:$ROOT/qdx-b-card/bluespec"

rm -rf "$BUILD"
mkdir -p "$BUILD/direct" "$BUILD/sg" "$BUILD/card"

command -v cargo >/dev/null
command -v bsc >/dev/null

echo "== Rust QDX-B mandatory profile tests =="
(
  cd "$ROOT"
  cargo test -p qdx-b-model
)

echo "== Rust QDX-B physical card =="
(
  cd "$ROOT"
  cargo run -q -p qdx-b-card-model --bin card_conformance
) | tee "$BUILD/rust-card.log"
grep '^QDXBCARDTRACE|v1|' "$BUILD/rust-card.log" > "$BUILD/rust-card.trace"
test "$(wc -l < "$BUILD/rust-card.trace")" -eq 4

echo "== Bluespec QDX-B direct profile =="
bsc -u -sim -p "$SEARCH" -bdir "$BUILD/direct" -simdir "$BUILD/direct" -info-dir "$BUILD/direct" \
    -g mkTbQDXBEndpoint "$ROOT/qdx-b/bluespec/TbQDXBEndpoint.bsv"
bsc -sim -p "$SEARCH" -bdir "$BUILD/direct" -simdir "$BUILD/direct" \
    -e mkTbQDXBEndpoint -o "$BUILD/tb-qdx-b-direct"
"$BUILD/tb-qdx-b-direct" | tee "$BUILD/direct.log"
grep -q '^QDXBTRACE|v1|case=direct|write=1|read=1|identify=1|durable=1|flush=1$' "$BUILD/direct.log"

echo "== Bluespec QDX-B scatter/gather profile =="
bsc -u -sim -p "$SEARCH" -bdir "$BUILD/sg" -simdir "$BUILD/sg" -info-dir "$BUILD/sg" \
    -g mkTbQDXBSg "$ROOT/qdx-b/bluespec/TbQDXBSg.bsv"
bsc -sim -p "$SEARCH" -bdir "$BUILD/sg" -simdir "$BUILD/sg" \
    -e mkTbQDXBSg -o "$BUILD/tb-qdx-b-sg"
"$BUILD/tb-qdx-b-sg" | tee "$BUILD/sg.log"
grep -q '^QDXBTRACE|v1|case=sg|entries=2|write_words=128|read_words=128|status=0$' "$BUILD/sg.log"

echo "== Bluespec QDX-B physical card =="
bsc -u -sim -p "$SEARCH" -bdir "$BUILD/card" -simdir "$BUILD/card" -info-dir "$BUILD/card" \
    -g mkTbQDXBCard "$ROOT/qdx-b-card/bluespec/TbQDXBCard.bsv"
bsc -sim -p "$SEARCH" -bdir "$BUILD/card" -simdir "$BUILD/card" \
    -e mkTbQDXBCard -o "$BUILD/tb-qdx-b-card"
"$BUILD/tb-qdx-b-card" | tee "$BUILD/bsv-card.log"
grep '^QDXBCARDTRACE|v1|' "$BUILD/bsv-card.log" > "$BUILD/bsv-card.trace"
test "$(wc -l < "$BUILD/bsv-card.trace")" -eq 4

echo "== Exact Rust <-> Bluespec physical-card trace =="
diff -u "$BUILD/rust-card.trace" "$BUILD/bsv-card.trace"

grep -q '^PASS QDX-B physical card WRITE_DURABLE through PLIO-TX/PTI/QIC/QLI-16/QDX-A$' "$BUILD/bsv-card.log"
grep -q '^PASS Rust QDX-B physical card WRITE_DURABLE through PLIO-TX/PTI/QIC/QLI-16/QDX-A$' "$BUILD/rust-card.log"

echo "PASS QDX-B mandatory base profile and physical-card differential"
