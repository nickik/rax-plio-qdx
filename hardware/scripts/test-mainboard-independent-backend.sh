#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
python3 - "$ROOT" "$BUILD" <<'PYGEN'
from pathlib import Path
import sys
r=Path(sys.argv[1])/'mainboard-fpga/bluespec'
build=Path(sys.argv[2])
for name in ['TbMainboardInstructionArbitration','TbMainboardM6Reset']:
 s=(r/(name+'.bsv')).read_text().replace('package '+name+';','package '+name+'Independent;').replace('import Vector::*;','import Vector::*;\nimport FIFOF::*;')
 s=s.replace('b<-mkMainboardFPGA;', 'b <- mkMainboardFPGA;').replace('b <- mkMainboardFPGA;','b <- mkMainboardFPGAWithIndependentBackend(True);')
 s=s.replace('b.advance(', 'advanceSample(').replace('b.debugAdvanceReady', '(!b.debugCyclePending)')
 s=s.replace('if(wd==12000)', 'if(wd==2000)')
 s=s.replace('stage=%0d|owner=%0d|plio=%0d",s,pack(b.debugMemoryOwner),pack(b.debugPlioMemoryRequestValid)', 'stage=%0d|owner=%0d|plio=%0d|state=%0d|accepts=%0d|responses=%0d|stalls=%0d|samples=%0d|cycle=%0d",s,pack(b.debugMemoryOwner),pack(b.debugPlioMemoryRequestValid),pack(b.debugMemoryControllerState),accepts,responses,stalls,pack(backendSamples.notEmpty),pack(b.debugCyclePending)')
 # Each fixture may contain several modules, each with a board instance.
 needle='MainboardFPGAIfc b <- mkMainboardFPGAWithIndependentBackend(True);'
 insert='''
    FIFOF#(Tuple6#(Bool,Bool,Bool,Bool,Bit#(32),Bool)) backendSamples <- mkFIFOF;
    function Action advanceSample(Vector#(8,BackplaneDrive) cards,
        LightingBusMasterDrive cpu, Bool workerValid, HostWorkerRequest worker,
        Bool reqReady, Bool respValid, Bool fault, Bool readValid, Bit#(32) data, Bool reset);
        action
            b.advance(cards,cpu,workerValid,worker,False,False,False,False,0,reset);
            backendSamples.enq(tuple6(reqReady,respValid,fault,readValid,data,reset));
        endaction
    endfunction
    rule sampleBackendRequest (!b.debugCyclePending && tpl_1(backendSamples.first) && !tpl_6(backendSamples.first));
        b.acceptMemoryBackendRequest;
        backendSamples.deq;
    endrule
    rule sampleBackendResponse (!b.debugCyclePending && tpl_2(backendSamples.first) && !tpl_6(backendSamples.first)
        && b.memoryBackendResponseReady);
        let x=backendSamples.first;
        b.acceptMemoryBackendResponse(tpl_3(x),tpl_4(x),tpl_5(x));
        backendSamples.deq;
    endrule
    rule sampleBackendIdle (tpl_6(backendSamples.first)
        || (!tpl_1(backendSamples.first) && !tpl_2(backendSamples.first))
        || (tpl_2(backendSamples.first) && !b.memoryBackendResponseReady));
        backendSamples.deq;
    endrule
'''
 assert needle in s
 s=s.replace(needle,needle+insert)
 s=s.replace('mk'+name,'mk'+name+'Independent')
 (build/(name+'Independent.bsv')).write_text(s)

base=build/'TbMainboardM6ResetIndependent.bsv'
s=base.read_text().replace('TbMainboardM6ResetIndependent','TbMainboardM6StreamResetIndependent')
s=s.replace('d.payload.addr=a;', 'd.payload.streamWords=3;d.payload.accessKind=1;d.payload.addr=a;')
(build/'TbMainboardM6StreamResetIndependent.bsv').write_text(s)

s=(build/'TbMainboardInstructionArbitrationIndependent.bsv').read_text().replace('TbMainboardInstructionArbitrationIndependent','TbMainboardInstructionFaultIndependent')
s=s.replace('False,True,False,True,cd+zeroExtend(responses),False','False,True,responses==1,responses!=1,cd+zeroExtend(responses),False')
s=s.replace('s<=accepts==4 ? 9:7','s<=accepts==2 ? 9:7')
s=s.replace('!x.ready||x.error||x.readData!=cd+3','!x.ready||!x.error||x.readData!=0')
s=s.replace('accepts!=4','accepts!=2').replace('accepts<=5','accepts<=3').replace('responses<=5','responses<=3').replace('accepts!=5','accepts!=3').replace('responses!=5','responses!=3')
s=s.replace('four-word instruction stream then DMA','instruction error terminates extent after two words then DMA')
(build/'TbMainboardInstructionFaultIndependent.bsv').write_text(s)
PYGEN
SEARCH=+
for dir in "$ROOT"/*/bluespec; do SEARCH="$SEARCH:$dir"; done
for TOP in mkTbMainboardInstructionArbitrationIndependent mkTbMainboardM6ResetIndependentCpuOwner mkTbMainboardM6ResetIndependentPlioOwner mkTbMainboardM6StreamResetIndependentCpuOwner mkTbMainboardInstructionFaultIndependent; do
 SOURCE=TbMainboardM6ResetIndependent
 if [[ "$TOP" == mkTbMainboardInstructionArbitrationIndependent ]]; then SOURCE=TbMainboardInstructionArbitrationIndependent; fi
 if [[ "$TOP" == mkTbMainboardM6StreamResetIndependentCpuOwner ]]; then SOURCE=TbMainboardM6StreamResetIndependent; fi
 if [[ "$TOP" == mkTbMainboardInstructionFaultIndependent ]]; then SOURCE=TbMainboardInstructionFaultIndependent; fi
 timeout 180s bsc +RTS -K8M -RTS -u -sim -p "$SEARCH" -bdir "$BUILD" -simdir "$BUILD" -info-dir "$BUILD" -g "$TOP" "$BUILD/$SOURCE.bsv" > "$BUILD/$TOP.compile.log" 2>&1 || { cat "$BUILD/$TOP.compile.log"; exit 1; }
 if grep -q '(G0023)' "$BUILD/$TOP.compile.log"; then cat "$BUILD/$TOP.compile.log"; exit 1; fi
 timeout 180s bsc -sim -p "$SEARCH" -bdir "$BUILD" -simdir "$BUILD" -e "$TOP" -o "$BUILD/$TOP" > "$BUILD/$TOP.link.log" 2>&1 || { cat "$BUILD/$TOP.link.log"; exit 1; }
 timeout 30s "$BUILD/$TOP" | tee "$BUILD/$TOP.run.log"
 if grep -q FAIL "$BUILD/$TOP.run.log"; then exit 1; fi
 grep -q PASS "$BUILD/$TOP.run.log"
done
