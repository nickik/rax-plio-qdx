#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/bluespec"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/naked-card/bluespec:$ROOT/qli16/bluespec:$ROOT/pti/bluespec:$ROOT/trace/bluespec:$ROOT/qic/bluespec"

rm -rf "$BUILD"
mkdir -p "$BUILD/qli" "$BUILD/naked" "$BUILD/naked-protocol" "$BUILD/qli16" "$BUILD/pti" "$BUILD/trace" "$BUILD/qic-phase1" "$BUILD/qic-phase2" "$BUILD/verilog" "$BUILD/ice40"

command -v bsc >/dev/null
command -v cargo >/dev/null

echo "== QLI type compile/simulation =="
bsc -u -sim -p "$SEARCH" -bdir "$BUILD/qli" -simdir "$BUILD/qli" -info-dir "$BUILD/qli" -g mkTbQLITypes "$ROOT/qli/bluespec/TbQLITypes.bsv"
bsc -sim -p "$SEARCH" -bdir "$BUILD/qli" -simdir "$BUILD/qli" -e mkTbQLITypes -o "$BUILD/tb-qli"
"$BUILD/tb-qli"

echo "== NakedDevice conformance compile/simulation =="
bsc -u -sim -p "$SEARCH" -bdir "$BUILD/naked" -simdir "$BUILD/naked" -info-dir "$BUILD/naked" -g mkTbNakedDevice "$ROOT/naked-card/bluespec/TbNakedDevice.bsv"
bsc -sim -p "$SEARCH" -bdir "$BUILD/naked" -simdir "$BUILD/naked" -e mkTbNakedDevice -o "$BUILD/tb-naked"
"$BUILD/tb-naked" | tee "$BUILD/naked-bsv.log"

echo "== NakedDevice handshake/reset/cancel simulation =="
bsc -u -sim -p "$SEARCH" -bdir "$BUILD/naked-protocol" -simdir "$BUILD/naked-protocol" -info-dir "$BUILD/naked-protocol" -g mkTbNakedDeviceProtocol "$ROOT/naked-card/bluespec/TbNakedDeviceProtocol.bsv"
bsc -sim -p "$SEARCH" -bdir "$BUILD/naked-protocol" -simdir "$BUILD/naked-protocol" -e mkTbNakedDeviceProtocol -o "$BUILD/tb-naked-protocol"
"$BUILD/tb-naked-protocol"

echo "== Rust / Bluespec NakedDevice conformance =="
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p naked-card --bin conformance | grep '^VECTOR ' | tr 'A-F' 'a-f' > "$BUILD/rust-vectors.txt"
grep '^VECTOR ' "$BUILD/naked-bsv.log" | tr 'A-F' 'a-f' > "$BUILD/bsv-vectors.txt"
diff -u "$BUILD/rust-vectors.txt" "$BUILD/bsv-vectors.txt"
echo "PASS Rust/Bluespec QLI NakedDevice conformance"

echo "== QLI-16 compile/simulation/conformance =="
bsc -u -sim -p "$SEARCH" -bdir "$BUILD/qli16" -simdir "$BUILD/qli16" -info-dir "$BUILD/qli16" -g mkTbQLI16 "$ROOT/qli16/bluespec/TbQLI16.bsv"
bsc -sim -p "$SEARCH" -bdir "$BUILD/qli16" -simdir "$BUILD/qli16" -e mkTbQLI16 -o "$BUILD/tb-qli16"
"$BUILD/tb-qli16" | tee "$BUILD/qli16-bsv.log"
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p qli16-model --bin conformance | grep '^VECTOR ' | tr 'A-F' 'a-f' > "$BUILD/qli16-rust.txt"
grep '^VECTOR ' "$BUILD/qli16-bsv.log" | tr 'A-F' 'a-f' > "$BUILD/qli16-bsv.txt"
diff -u "$BUILD/qli16-rust.txt" "$BUILD/qli16-bsv.txt"
echo "PASS Rust/Bluespec QLI-16 conformance"

echo "== PTI compile/simulation/conformance =="
bsc -u -sim -p "$SEARCH" -bdir "$BUILD/pti" -simdir "$BUILD/pti" -info-dir "$BUILD/pti" -g mkTbPTI "$ROOT/pti/bluespec/TbPTI.bsv"
bsc -sim -p "$SEARCH" -bdir "$BUILD/pti" -simdir "$BUILD/pti" -e mkTbPTI -o "$BUILD/tb-pti"
"$BUILD/tb-pti" | tee "$BUILD/pti-bsv.log"
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p pti-model --bin conformance | grep '^VECTOR ' | tr 'A-F' 'a-f' > "$BUILD/pti-rust.txt"
grep '^VECTOR ' "$BUILD/pti-bsv.log" | tr 'A-F' 'a-f' > "$BUILD/pti-bsv.txt"
diff -u "$BUILD/pti-rust.txt" "$BUILD/pti-bsv.txt"
echo "PASS Rust/Bluespec PTI conformance"

echo "== Differential trace formatter conformance =="
bsc -u -sim -p "$SEARCH" -bdir "$BUILD/trace" -simdir "$BUILD/trace" -info-dir "$BUILD/trace" -g mkTbTraceFormat "$ROOT/trace/bluespec/TbTraceFormat.bsv"
bsc -sim -p "$SEARCH" -bdir "$BUILD/trace" -simdir "$BUILD/trace" -e mkTbTraceFormat -o "$BUILD/tb-trace"
"$BUILD/tb-trace" | grep '^TRACE|' > "$BUILD/trace-bsv.txt"
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p plio-trace --bin conformance | grep '^TRACE|' > "$BUILD/trace-rust.txt"
diff -u "$BUILD/trace-rust.txt" "$BUILD/trace-bsv.txt"
echo "PASS Rust/Bluespec trace-format conformance"

echo "== QIC Phase 1 Bluesim / Rust differential trace =="
bsc -u -sim -p "$SEARCH" -bdir "$BUILD/qic-phase1" -simdir "$BUILD/qic-phase1" -info-dir "$BUILD/qic-phase1" -g mkTbQICPhase1 "$ROOT/qic/bluespec/TbQICPhase1.bsv"
bsc -sim -p "$SEARCH" -bdir "$BUILD/qic-phase1" -simdir "$BUILD/qic-phase1" -e mkTbQICPhase1 -o "$BUILD/tb-qic-phase1"
"$BUILD/tb-qic-phase1" | tee "$BUILD/qic-phase1-bsv.log"
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p plio-qic-model --bin phase1_conformance | grep '^TRACE|' > "$BUILD/qic-phase1-rust.trace"
grep '^TRACE|' "$BUILD/qic-phase1-bsv.log" > "$BUILD/qic-phase1-bsv.trace"
diff -u "$BUILD/qic-phase1-rust.trace" "$BUILD/qic-phase1-bsv.trace"
echo "PASS Rust/Bluesim QIC Phase 1 differential trace"

echo "== QIC Phase 2 Bluesim / Rust differential trace =="
bsc -u -sim -p "$SEARCH" -bdir "$BUILD/qic-phase2" -simdir "$BUILD/qic-phase2" -info-dir "$BUILD/qic-phase2" -g mkTbQICPhase2 "$ROOT/qic/bluespec/TbQICPhase2.bsv"
bsc -sim -p "$SEARCH" -bdir "$BUILD/qic-phase2" -simdir "$BUILD/qic-phase2" -e mkTbQICPhase2 -o "$BUILD/tb-qic-phase2"
"$BUILD/tb-qic-phase2" | tee "$BUILD/qic-phase2-bsv.log"
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p plio-qic-model --bin phase2_conformance | grep '^TRACE|' > "$BUILD/qic-phase2-rust.trace"
grep '^TRACE|' "$BUILD/qic-phase2-bsv.log" > "$BUILD/qic-phase2-bsv.trace"
diff -u "$BUILD/qic-phase2-rust.trace" "$BUILD/qic-phase2-bsv.trace"
echo "PASS Rust/Bluesim QIC Phase 2 differential trace"

if command -v iverilog >/dev/null; then
    echo "== Generated-Verilog QLI-16 simulation =="
    mkdir -p "$BUILD/verilog/obj"
    bsc -u -verilog -p "$SEARCH" -bdir "$BUILD/verilog/obj" -vdir "$BUILD/verilog" -info-dir "$BUILD/verilog/obj" -g mkTbQLI16 "$ROOT/qli16/bluespec/TbQLI16.bsv"
    bsc -verilog -vsim iverilog -p "$SEARCH" -bdir "$BUILD/verilog/obj" -vdir "$BUILD/verilog" -e mkTbQLI16 -o "$BUILD/tb-qli16-verilog"
    "$BUILD/tb-qli16-verilog" | grep '^VECTOR ' | tr 'A-F' 'a-f' > "$BUILD/qli16-verilog.txt"
    diff -u "$BUILD/qli16-rust.txt" "$BUILD/qli16-verilog.txt"
    echo "PASS Rust/generated-Verilog QLI-16 conformance"
fi

if command -v yosys >/dev/null; then
    echo "== iCE40 synthesis smoke =="
    mkdir -p "$BUILD/ice40/obj"
    bsc -u -verilog -p "$SEARCH" -bdir "$BUILD/ice40/obj" -vdir "$BUILD/ice40" -info-dir "$BUILD/ice40/obj" -g mkQLI16CancelProbe "$ROOT/qli16/bluespec/QLI16CancelProbe.bsv"
    BSC_PREFIX="$(cd "$(dirname "$(command -v bsc)")/.." && pwd)"
    REGN_V="$BSC_PREFIX/lib/Verilog/RegN.v"
    test -f "$REGN_V"
    yosys -q -p "read_verilog $REGN_V $BUILD/ice40/mkQLI16CancelProbe.v; synth_ice40 -top mkQLI16CancelProbe -json $BUILD/ice40/cancel.json"
    if command -v nextpnr-ice40 >/dev/null; then
        nextpnr-ice40 --hx8k --package ct256 --json "$BUILD/ice40/cancel.json" --asc "$BUILD/ice40/cancel.asc" --freq 5 --pcf-allow-unconstrained >/dev/null
    fi
    echo "PASS generated-Verilog/iCE40 synthesis smoke"
fi
