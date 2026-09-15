#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/naked-card-physical"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/qic/bluespec:$ROOT/pti/bluespec:$ROOT/plio-tx/bluespec:$ROOT/qli16/bluespec:$ROOT/naked-card/bluespec:$ROOT/testbench/bluespec"

rm -rf "$BUILD"
mkdir -p "$BUILD/bsv-worker" "$BUILD/bsv-probe"

command -v cargo >/dev/null
command -v bsc >/dev/null

echo "== Rust QIC regression oracle =="
cargo test --manifest-path "$ROOT/Cargo.toml" -p plio-qic-model

echo "== Exact Rust / Bluesim QLI-16 codec equivalence =="
bash "$ROOT/scripts/test-qli16-codec.sh"

echo "== Rust complete NakedCard physical stack =="
cargo test --manifest-path "$ROOT/Cargo.toml" -p naked-card --test physical_stack -- --nocapture

echo "== Bluesim full worker NakedCard =="
bsc -u -sim -p "$SEARCH" \
    -bdir "$BUILD/bsv-worker" -simdir "$BUILD/bsv-worker" -info-dir "$BUILD/bsv-worker" \
    -g mkTbNakedCardPhysical "$ROOT/naked-card/bluespec/TbNakedCardPhysical.bsv"
bsc -sim -p "$SEARCH" \
    -bdir "$BUILD/bsv-worker" -simdir "$BUILD/bsv-worker" \
    -e mkTbNakedCardPhysical -o "$BUILD/tb-naked-worker"
"$BUILD/tb-naked-worker" | tee "$BUILD/naked-worker.log"
grep -q '^NAKEDTRACE|v1|case=worker_read|ad=504c494f|ack=1|err=0$' "$BUILD/naked-worker.log"
grep -q '^NAKEDTRACE|v1|case=worker_write|ack=1|err=0$' "$BUILD/naked-worker.log"
grep -q '^NAKEDTRACE|v1|case=unsupported|ack=0|err=1$' "$BUILD/naked-worker.log"

echo "== Bluesim physical DMA / Notification protocol probe =="
bsc -u -sim -p "$SEARCH" \
    -bdir "$BUILD/bsv-probe" -simdir "$BUILD/bsv-probe" -info-dir "$BUILD/bsv-probe" \
    -g mkTbNakedCardProtocolPhysical "$ROOT/naked-card/bluespec/TbNakedCardProtocolPhysical.bsv"
bsc -sim -p "$SEARCH" \
    -bdir "$BUILD/bsv-probe" -simdir "$BUILD/bsv-probe" \
    -e mkTbNakedCardProtocolPhysical -o "$BUILD/tb-naked-probe"
"$BUILD/tb-naked-probe" | tee "$BUILD/naked-probe.log"

for words in 1 4 8 16; do
    grep -q "^NAKEDTRACE|v1|case=d2h|words=${words}|status=0$" "$BUILD/naked-probe.log"
    grep -q "^NAKEDTRACE|v1|case=h2d|words=${words}|status=0$" "$BUILD/naked-probe.log"
done
grep -q '^NAKEDTRACE|v1|case=notification|channel=2|ready=1$' "$BUILD/naked-probe.log"

echo "PASS complete NakedCard physical validation ladder"
