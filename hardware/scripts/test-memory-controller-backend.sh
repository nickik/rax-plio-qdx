#!/usr/bin/env bash
set -Eeuo pipefail
PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
set -x

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${MEMORY_CONTROLLER_DEBUG_DIR:-$ROOT/build/memory-controller}"
BUILD="$BUILD_ROOT/backend-sequences"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/qic/bluespec:$ROOT/plio-rax-host/bluespec:$ROOT/memory-controller/bluespec"
BSC="${BSC:-bsc}"
BSC_STACK=(+RTS -K8M -RTS)

rm -rf "$BUILD"
mkdir -p "$BUILD/bsv"
BUILD="$(cd "$BUILD" && pwd)"

command -v "$BSC" >/dev/null
command -v cargo >/dev/null

echo "== Rust backend sequence semantics =="
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p memory-controller-model --bin backend_conformance \
    2>&1 | tee "$BUILD/rust.log"
grep '^MEMBACKENDTRACE|' "$BUILD/rust.log" > "$BUILD/rust.trace"
test "$(wc -l < "$BUILD/rust.trace")" -eq 3
grep -q '^PASS memory controller backend sequence semantics$' "$BUILD/rust.log"

echo "== Bluesim backend sequence semantics =="
"$BSC" "${BSC_STACK[@]}" -u -sim -p "$SEARCH" \
    -bdir "$BUILD/bsv" -simdir "$BUILD/bsv" -info-dir "$BUILD/bsv" \
    -g mkTbMemoryControllerBackend "$ROOT/memory-controller/bluespec/TbMemoryControllerBackend.bsv" \
    2>&1 | tee "$BUILD/bsc-compile.log"
"$BSC" "${BSC_STACK[@]}" -sim -p "$SEARCH" \
    -bdir "$BUILD/bsv" -simdir "$BUILD/bsv" \
    -e mkTbMemoryControllerBackend -o "$BUILD/tb-memory-controller-backend" \
    2>&1 | tee "$BUILD/bsc-link.log"
"$BUILD/tb-memory-controller-backend" 2>&1 | tee "$BUILD/bsv.log"
grep '^MEMBACKENDTRACE|' "$BUILD/bsv.log" > "$BUILD/bsv.trace"
test "$(wc -l < "$BUILD/bsv.trace")" -eq 3
grep -q '^PASS memory controller backend sequence semantics$' "$BUILD/bsv.log"

echo "== Exact Rust / Bluesim backend sequence trace =="
diff -u "$BUILD/rust.trace" "$BUILD/bsv.trace" 2>&1 | tee "$BUILD/diff.log"

echo "PASS memory controller backend sequence differential"
