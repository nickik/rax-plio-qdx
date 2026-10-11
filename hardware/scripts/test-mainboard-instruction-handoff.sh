#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
SEARCH="+"
for dir in "$ROOT"/*/bluespec; do SEARCH="$SEARCH:$dir"; done
# Reuse the reset scenario with an active four-word instruction extent. The
# original scalar reset cases remain gates too; generated source is temporary.
sed -e 's/TbMainboardM6Reset/TbMainboardStreamReset/g' \
    -e 's/d.payload.addr=a;/d.payload.streamWords=3;d.payload.accessKind=1;d.payload.addr=a;/' \
    -e 's/PASS|m6.3-cpu-owner|/PASS|m6.3-stream-cpu-owner|/' \
    "$ROOT/mainboard-fpga/bluespec/TbMainboardM6Reset.bsv" > "$BUILD/TbMainboardStreamReset.bsv"
for TOP in mkTbMainboardInstructionArbitration mkTbMainboardM6ResetCpuOwner mkTbMainboardM6ResetPlioOwner mkTbMainboardStreamResetCpuOwner; do
  SOURCE=TbMainboardM6Reset
  if [[ "$TOP" == mkTbMainboardInstructionArbitration ]]; then SOURCE=TbMainboardInstructionArbitration; fi
  SOURCE_PATH="$ROOT/mainboard-fpga/bluespec/$SOURCE.bsv"
  if [[ "$TOP" == mkTbMainboardStreamResetCpuOwner ]]; then SOURCE_PATH="$BUILD/TbMainboardStreamReset.bsv"; fi
  timeout 180s bsc +RTS -K8M -RTS -u -sim -p "$SEARCH" -bdir "$BUILD" -simdir "$BUILD" -info-dir "$BUILD" -g "$TOP" "$SOURCE_PATH" > "$BUILD/compile.log" 2>&1 || { cat "$BUILD/compile.log"; exit 1; }
  if grep -q '(G0023)' "$BUILD/compile.log"; then cat "$BUILD/compile.log"; exit 1; fi
  timeout 180s bsc -sim -p "$SEARCH" -bdir "$BUILD" -simdir "$BUILD" -e "$TOP" -o "$BUILD/tb" > "$BUILD/link.log" 2>&1 || { cat "$BUILD/link.log"; exit 1; }
  timeout 30s "$BUILD/tb" | tee "$BUILD/run.log"
  if grep -q 'FAIL' "$BUILD/run.log"; then exit 1; fi
  grep -q 'PASS' "$BUILD/run.log"
done
