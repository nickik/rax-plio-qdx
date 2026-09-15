#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/qic-phase4-6"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/naked-card/bluespec:$ROOT/qli16/bluespec:$ROOT/pti/bluespec:$ROOT/trace/bluespec:$ROOT/qic/bluespec"

rm -rf "$BUILD"
mkdir -p "$BUILD"

command -v bsc >/dev/null
command -v cargo >/dev/null

run_phase() {
    local phase="$1"
    local dir="$BUILD/qic-phase${phase}"
    local top="mkTbQICPhase${phase}"
    local tb="$ROOT/qic/bluespec/TbQICPhase${phase}.bsv"
    local exe="$dir/tb-qic-phase${phase}"
    local bsv_log="$dir/qic-phase${phase}-bsv.log"
    local rust_trace="$dir/qic-phase${phase}-rust.trace"
    local bsv_trace="$dir/qic-phase${phase}-bsv.trace"

    mkdir -p "$dir"
    echo "== QIC Phase ${phase} Bluesim / Rust differential trace =="
    bsc -u -sim -p "$SEARCH" -bdir "$dir" -simdir "$dir" -info-dir "$dir" -g "$top" "$tb"
    bsc -sim -p "$SEARCH" -bdir "$dir" -simdir "$dir" -e "$top" -o "$exe"
    "$exe" | tee "$bsv_log"
    cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p plio-qic-model --bin "phase${phase}_conformance" \
        | grep '^TRACE|' > "$rust_trace"
    grep '^TRACE|' "$bsv_log" > "$bsv_trace"
    diff -u "$rust_trace" "$bsv_trace"
    echo "PASS Rust/Bluesim QIC Phase ${phase} differential trace"
}

run_phase 4
run_phase 5
run_phase 6
