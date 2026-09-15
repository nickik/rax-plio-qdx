#!/usr/bin/env bash
set -euo pipefail
# Direct physical composition first; regressions run only after all three compositions pass.
# Completion observation is deliberately separated from host.advance cycles in the integration tops.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/m4.5-host-card"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/qli16/bluespec:$ROOT/qic/bluespec:$ROOT/pti/bluespec:$ROOT/plio-tx/bluespec:$ROOT/testbench/bluespec:$ROOT/naked-card/bluespec:$ROOT/qdx-a/bluespec:$ROOT/qdx-a-card/bluespec:$ROOT/qdx-b/bluespec:$ROOT/qdx-b-card/bluespec:$ROOT/plio-rax-host/bluespec:$ROOT/m4.5/bluespec"
STACK=(+RTS -K64m -RTS)
rm -rf "$BUILD"; mkdir -p "$BUILD"
run_tb(){ local top="$1" src="$2" tag="$3"; local dir="$BUILD/$tag"; mkdir -p "$dir"; bsc "${STACK[@]}" -u -sim -p "$SEARCH" -bdir "$dir" -simdir "$dir" -info-dir "$dir" -g "$top" "$src"; bsc "${STACK[@]}" -sim -p "$SEARCH" -bdir "$dir" -simdir "$dir" -e "$top" -o "$dir/tb"; timeout 180s "$dir/tb"|tee "$dir/run.log"; grep -q '^PASS M4.5 ' "$dir/run.log"; }
echo '== M4.5 NakedCard physical host/card compatibility ==';run_tb mkTbPLIOHostNakedIntegration "$ROOT/m4.5/bluespec/TbPLIOHostNakedIntegration.bsv" naked
echo '== M4.5 QDX-A physical host/card compatibility ==';run_tb mkTbPLIOHostQDXAIntegration "$ROOT/m4.5/bluespec/TbPLIOHostQDXAIntegration.bsv" qdxa
echo '== M4.5 QDX-B full host/card transaction ==';run_tb mkTbPLIOHostQDXBIntegration "$ROOT/m4.5/bluespec/TbPLIOHostQDXBIntegration.bsv" qdxb
grep -q 'event=end_to_end|sq_dma=1|cq_dma=1|notify=1|cq_exact=1' "$BUILD/qdxa/run.log";grep -q 'event=end_to_end|sq_dma=1|payload_dma=1|cq_dma=1|notify=1|durable=1|flush=1' "$BUILD/qdxb/run.log"
bash "$ROOT/scripts/test-plio-host-m4.sh";bash "$ROOT/scripts/test-qdx-a-card.sh";bash "$ROOT/scripts/test-qdx-b.sh"
echo 'PASS M4.5 PLIOHostCore physical NakedCard/QDX-A/QDX-B integration gate'
