#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/bluespec"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/naked-card/bluespec:$ROOT/qli16/bluespec:$ROOT/pti/bluespec"

rm -rf "$BUILD"
mkdir -p "$BUILD/qli" "$BUILD/naked" "$BUILD/naked-protocol" "$BUILD/qli16" "$BUILD/pti"

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

echo "== NakedDevice conformance compile/simulation =="
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

echo "== NakedDevice handshake/reset simulation =="
bsc -u -sim \
  -p "$SEARCH" \
  -bdir "$BUILD/naked-protocol" \
  -simdir "$BUILD/naked-protocol" \
  -info-dir "$BUILD/naked-protocol" \
  -g mkTbNakedDeviceProtocol \
  "$ROOT/naked-card/bluespec/TbNakedDeviceProtocol.bsv"

bsc -sim \
  -p "$SEARCH" \
  -bdir "$BUILD/naked-protocol" \
  -simdir "$BUILD/naked-protocol" \
  -e mkTbNakedDeviceProtocol \
  -o "$BUILD/tb-naked-protocol"

"$BUILD/tb-naked-protocol"

echo "== Rust / Bluespec NakedDevice conformance =="
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p naked-card --bin conformance \
  | grep '^VECTOR ' | tr 'A-F' 'a-f' > "$BUILD/rust-vectors.txt"

grep '^VECTOR ' "$BUILD/naked-bsv.log" \
  | tr 'A-F' 'a-f' > "$BUILD/bsv-vectors.txt"

diff -u "$BUILD/rust-vectors.txt" "$BUILD/bsv-vectors.txt"

echo "PASS Rust/Bluespec QLI NakedDevice conformance"

echo "== QLI-16 compile/simulation/conformance =="
bsc -u -sim \
  -p "$SEARCH" \
  -bdir "$BUILD/qli16" \
  -simdir "$BUILD/qli16" \
  -info-dir "$BUILD/qli16" \
  -g mkTbQLI16 \
  "$ROOT/qli16/bluespec/TbQLI16.bsv"

bsc -sim \
  -p "$SEARCH" \
  -bdir "$BUILD/qli16" \
  -simdir "$BUILD/qli16" \
  -e mkTbQLI16 \
  -o "$BUILD/tb-qli16"

"$BUILD/tb-qli16" | tee "$BUILD/qli16-bsv.log"
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p qli16-model --bin conformance \
  | grep '^VECTOR ' | tr 'A-F' 'a-f' > "$BUILD/qli16-rust.txt"
grep '^VECTOR ' "$BUILD/qli16-bsv.log" \
  | tr 'A-F' 'a-f' > "$BUILD/qli16-bsv.txt"
diff -u "$BUILD/qli16-rust.txt" "$BUILD/qli16-bsv.txt"
echo "PASS Rust/Bluespec QLI-16 conformance"

echo "== PTI compile/simulation/conformance =="
bsc -u -sim \
  -p "$SEARCH" \
  -bdir "$BUILD/pti" \
  -simdir "$BUILD/pti" \
  -info-dir "$BUILD/pti" \
  -g mkTbPTI \
  "$ROOT/pti/bluespec/TbPTI.bsv"

bsc -sim \
  -p "$SEARCH" \
  -bdir "$BUILD/pti" \
  -simdir "$BUILD/pti" \
  -e mkTbPTI \
  -o "$BUILD/tb-pti"

"$BUILD/tb-pti" | tee "$BUILD/pti-bsv.log"
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p pti-model --bin conformance \
  | grep '^VECTOR ' | tr 'A-F' 'a-f' > "$BUILD/pti-rust.txt"
grep '^VECTOR ' "$BUILD/pti-bsv.log" \
  | tr 'A-F' 'a-f' > "$BUILD/pti-bsv.txt"
diff -u "$BUILD/pti-rust.txt" "$BUILD/pti-bsv.txt"
echo "PASS Rust/Bluespec PTI conformance"
