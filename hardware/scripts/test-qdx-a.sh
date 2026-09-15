#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/qdx-a"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/qic/bluespec:$ROOT/qdx-a/bluespec"

rm -rf "$BUILD"
mkdir -p "$BUILD/sim" "$BUILD/rtl"

command -v bsc >/dev/null

echo "== Compile minimal QDX-A chip testbench =="
bsc -u -sim -p "$SEARCH" \
    -bdir "$BUILD/sim" -simdir "$BUILD/sim" -info-dir "$BUILD/sim" \
    -g mkTbQDXA "$ROOT/qdx-a/bluespec/TbQDXA.bsv"

bsc -sim -p "$SEARCH" \
    -bdir "$BUILD/sim" -simdir "$BUILD/sim" \
    -e mkTbQDXA -o "$BUILD/tb-qdx-a"

"$BUILD/tb-qdx-a" | tee "$BUILD/qdx-a.log"
grep -q '^QDXATRACE|v1|case=one_command|sqh=1|sqt=1|cqh=0|cqt=1|notify=1|error=0$' "$BUILD/qdx-a.log"
grep -q '^PASS minimal QDX-A chip queue path$' "$BUILD/qdx-a.log"

echo "== Generate standalone QDX-A Verilog =="
bsc -u -verilog -p "$SEARCH" \
    -bdir "$BUILD/rtl" -vdir "$BUILD/rtl" -info-dir "$BUILD/rtl" \
    -g mkQDXA "$ROOT/qdx-a/bluespec/QDXA.bsv"

test -s "$BUILD/rtl/mkQDXA.v"

echo "PASS QDX-A chip Bluesim and RTL generation"
