#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/bluespec"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/naked-card/bluespec"

rm -rf "$BUILD"
mkdir -p "$BUILD/qli" "$BUILD/naked"

command -v bsc >/dev/null
command -v cargo >/dev/null

echo "== QLI type compile/simulation =="
bsc -u -sim \
  -p "$SEARCH" \
  -bdir "$BUILD/qli" \
  -simdir "$BUILD/qli" \
  -info-dir "$BUILD/qli" \
  -g mkTbQLITypes \
  "$ROOT/qli/bluespec/TbQLITypes.bsv"

bsc -sim \
  -p "$SEARCH" \
  -bdir "$BUILD/qli" \
  -simdir "$BUILD/qli" \
  -e mkTbQLITypes \
  -o "$BUILD/tb-qli"

"$BUILD/tb-qli"

echo "== NakedDevice compile/simulation =="
bsc -u -sim \
  -p "$SEARCH" \
  -bdir "$BUILD/naked" \
  -simdir "$BUILD/naked" \
  -info-dir "$BUILD/naked" \
  -g mkTbNakedDevice \
  "$ROOT/naked-card/bluespec/TbNakedDevice.bsv"

bsc -sim \
  -p "$SEARCH" \
  -bdir "$BUILD/naked" \
  -simdir "$BUILD/naked" \
  -e mkTbNakedDevice \
  -o "$BUILD/tb-naked"

"$BUILD/tb-naked" | tee "$BUILD/naked-bsv.log"

echo "== Rust / Bluespec NakedDevice conformance =="
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p naked-card --bin conformance \
  | grep '^VECTOR ' | tr 'A-F' 'a-f' > "$BUILD/rust-vectors.txt"

grep '^VECTOR ' "$BUILD/naked-bsv.log" \
  | tr 'A-F' 'a-f' > "$BUILD/bsv-vectors.txt"

diff -u "$BUILD/rust-vectors.txt" "$BUILD/bsv-vectors.txt"

echo "PASS Rust/Bluespec QLI NakedDevice conformance"
