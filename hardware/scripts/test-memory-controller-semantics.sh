#!/usr/bin/env bash
set -Eeuo pipefail
PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
set -x

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${MEMORY_CONTROLLER_DEBUG_DIR:-$ROOT/build/memory-controller}"
BUILD="$BUILD_ROOT/semantics"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/qic/bluespec:$ROOT/plio-rax-host/bluespec:$ROOT/memory-controller/bluespec"
BSC="${BSC:-bsc}"
BSC_STACK=(+RTS -K8M -RTS)

rm -rf "$BUILD"
mkdir -p "$BUILD/bsv"
BUILD="$(cd "$BUILD" && pwd)"
command -v "$BSC" >/dev/null
command -v cargo >/dev/null

echo "== Rust exhaustive MemoryController semantics =="
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p memory-controller-model --bin semantics_conformance \
    2>&1 | tee "$BUILD/rust.log"
grep '^MEMSEMTRACE|' "$BUILD/rust.log" > "$BUILD/rust.trace"
test "$(wc -l < "$BUILD/rust.trace")" -eq 18
grep -q '^PASS exhaustive memory controller byte-enable semantics$' "$BUILD/rust.log"

echo "== Bluesim exhaustive MemoryController semantics =="
"$BSC" "${BSC_STACK[@]}" -u -sim -p "$SEARCH" \
    -bdir "$BUILD/bsv" -simdir "$BUILD/bsv" -info-dir "$BUILD/bsv" \
    -g mkTbMemoryControllerSemantics "$ROOT/memory-controller/bluespec/TbMemoryControllerSemantics.bsv" \
    2>&1 | tee "$BUILD/bsc-compile.log"
"$BSC" "${BSC_STACK[@]}" -sim -p "$SEARCH" \
    -bdir "$BUILD/bsv" -simdir "$BUILD/bsv" \
    -e mkTbMemoryControllerSemantics -o "$BUILD/tb-memory-controller-semantics" \
    2>&1 | tee "$BUILD/bsc-link.log"
"$BUILD/tb-memory-controller-semantics" 2>&1 | tee "$BUILD/bsv.log"
grep '^MEMSEMTRACE|' "$BUILD/bsv.log" > "$BUILD/bsv.trace"
test "$(wc -l < "$BUILD/bsv.trace")" -eq 18
grep -q '^PASS exhaustive memory controller byte-enable semantics$' "$BUILD/bsv.log"

echo "== Exact Rust / Bluesim exhaustive semantics trace =="
diff -u "$BUILD/rust.trace" "$BUILD/bsv.trace" 2>&1 | tee "$BUILD/diff.log"

echo "PASS exhaustive MemoryController Rust/Bluesim differential"
