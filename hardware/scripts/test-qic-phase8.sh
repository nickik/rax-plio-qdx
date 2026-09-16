#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/qic-phase8"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/naked-card/bluespec:$ROOT/qli16/bluespec:$ROOT/pti/bluespec:$ROOT/trace/bluespec:$ROOT/qic/bluespec"

rm -rf "$BUILD"
mkdir -p "$BUILD"
command -v bsc >/dev/null
command -v cargo >/dev/null

bsc -u -sim -p "$SEARCH" -bdir "$BUILD" -simdir "$BUILD" -info-dir "$BUILD" -g mkTbQICPhase8 "$ROOT/qic/bluespec/TbQICPhase8.bsv"
bsc -sim -p "$SEARCH" -bdir "$BUILD" -simdir "$BUILD" -e mkTbQICPhase8 -o "$BUILD/tb-qic-phase8"
"$BUILD/tb-qic-phase8" | tee "$BUILD/phase8-bsv.log"
if grep -q '^FAIL ' "$BUILD/phase8-bsv.log"; then
    echo "QIC Phase8 Bluesim fixture reported a failure" >&2
    exit 1
fi
grep '^TRACE|' "$BUILD/phase8-bsv.log" > "$BUILD/phase8-bsv.trace"

cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p plio-qic-model --bin phase8_conformance \
    | tee "$BUILD/phase8-rust.log" >/dev/null
grep '^TRACE|' "$BUILD/phase8-rust.log" > "$BUILD/phase8-rust.trace"

if ! diff -u "$BUILD/phase8-rust.trace" "$BUILD/phase8-bsv.trace" > "$BUILD/phase8.diff"; then
    first_line="$(paste "$BUILD/phase8-rust.trace" "$BUILD/phase8-bsv.trace" | awk -F '\t' '$1 != $2 { print NR; exit }')"
    if [[ -n "$first_line" ]]; then
        cycle=$((first_line - 1))
        printf -v cycle_hex '%08x' "$cycle"
        echo "FAIL QIC Phase8 first interface divergence at trace line $first_line, cycle 0x$cycle_hex" >&2
        echo "Rust cycle debug:" >&2
        grep "^QICDBG|model=rust|c=${cycle_hex}|" "$BUILD/phase8-rust.log" >&2 || true
        echo "Bluespec cycle debug:" >&2
        grep "^QICDBG|model=bsv|c=${cycle_hex}|" "$BUILD/phase8-bsv.log" >&2 || true
    fi
    echo "First Phase8 trace diff hunk:" >&2
    sed -n '1,120p' "$BUILD/phase8.diff" >&2
    exit 1
fi

test "$(wc -l < "$BUILD/phase8-rust.trace")" -eq 1028
echo "PASS QIC Phase8 unified Rust/Bluesim differential trace (1028 cycles)"
