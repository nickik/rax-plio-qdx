package TbMainboardM6ArbitrationV2;

import Vector::*;
import QLITypes::*;
import QICInterfaces::*;
import PLIOTx::*;
import PLIOWorkerHost::*;
import PLIOHostDmaM3::*;
import MemoryController::*;
import LightingMemoryBusCompat::*;
import MainboardFPGA::*;

function Vector#(8, BackplaneDrive) idleCards(); return replicate(backplaneDriveDefault()); endfunction
function HostWorkerRequest noWorkerRequest(); return HostWorkerRequest { slot: 0, address: 0, width: HostW32, write: False, value: 0 }; endfunction
function Bit#(4) parity32(Bit#(32) w); return {~(^w[31:24]),~(^w[23:16]),~(^w[15:8]),~(^w[7:0])}; endfunction
function BackplaneDrive requestOnly(); BackplaneDrive d=backplaneDriveDefault(); d.request=True; return d; endfunction
function BackplaneDrive dmaAddress(Bit#(32) h); BackplaneDrive d=requestOnly(); BackplaneControl c=backplaneControlDefault(); c.space=pack(PlioHostDma); c.addressStrobe=True; c.read=True; c.byteEnable=4'hf; c.burstLen=pack(BurstOne); d.controlValid=True; d.control=c; d.adParValid=True; d.ad=h; d.parity=parity32(h); return d; endfunction
function BackplaneDrive dmaReadBeat(); BackplaneDrive d=requestOnly(); BackplaneControl c=backplaneControlDefault(); c.dataStrobe=True; d.controlValid=True; d.control=c; return d; endfunction
function Vector#(8, BackplaneDrive) plioCards(); Vector#(8, BackplaneDrive) c=idleCards(); c[1]=dmaReadBeat(); return c; endfunction
function LightingBusMasterDrive cpuBR(); LightingBusMasterDrive d=lightingBusMasterDriveDefault(); d.busRequest=True; return d; endfunction
function LightingBusMasterDrive cpuRead(Bit#(32) a); LightingBusMasterDrive d=cpuBR(); d.request=True; d.payload.addr=a; d.payload.write=False; d.payload.byteEnable=4'hf; d.payload.writeData=0; return d; endfunction

(* synthesize *)
module mkTbMainboardM6ArbitrationV2(Empty);
    MainboardFPGAIfc b <- mkMainboardFPGA;
    Bit#(32) ca=32'h800, pa=32'hc00, cd=32'hc0de6001, pd=32'hc0de6002;
    Reg#(Bit#(6)) s <- mkReg(0); Reg#(Bit#(4)) stalls <- mkReg(0);
    Reg#(Bit#(4)) accepts <- mkReg(0); Reg#(Bit#(4)) responses <- mkReg(0);
    Reg#(Bit#(16)) wd <- mkReg(0);

    rule watchdog; wd<=wd+1; if(wd==12000) begin $display("FAIL|m6.1|watchdog|stage=%0d|owner=%0d|plio=%0d",s,pack(b.debugMemoryOwner),pack(b.debugPlioMemoryRequestValid)); $finish(1); end endrule
    rule r0(s==0 && b.debugAdvanceReady); b.advance(idleCards(),lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,True); s<=1; endrule
    rule r1(s==1); b.bindDma(1,3,pa,25'h100,True,True); s<=2; endrule
    rule r2(s==2 && b.debugAdvanceReady); Vector#(8,BackplaneDrive)c=idleCards(); c[1]=requestOnly(); b.advance(c,lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,False); s<=3; endrule
    rule r3(s==3 && b.debugAdvanceReady); Vector#(8,BackplaneDrive)c=idleCards(); c[1]=dmaAddress(32'h30000000); b.advance(c,lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,False); s<=4; endrule
    rule r4(s==4 && b.debugAdvanceReady); Vector#(8,BackplaneDrive)c=idleCards(); c[1]=dmaAddress(32'h30000000); Vector#(8,PlioIn)i=b.plioSlots(c,False); if(!i[1].ack||i[1].err) begin $display("FAIL|m6.1|dma-address");$finish(1);end b.advance(c,lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,False); s<=5; endrule

    // Wait for the registered PLIO request before presenting the simultaneous CPU contender.
    rule cpuWins(s==5 && b.debugAdvanceReady && b.debugPlioMemoryRequestValid);
        LightingBusInputs x=b.lightingMemory(plioCards(),cpuBR(),False);
        if(!x.busGrant || !b.debugPreferCpu || b.debugMemoryOwner!=MainMemNone) begin $display("FAIL|m6.1|cpu-policy");$finish(1);end
        b.advance(plioCards(),cpuBR(),False,noWorkerRequest(),False,False,False,False,0,False); s<=6;
    endrule
    rule cpuActive(s==6 && b.debugAdvanceReady);
        if(!b.debugCpuGrantHeld || !b.debugPlioMemoryRequestValid) begin $display("FAIL|m6.1|cpu-grant-held");$finish(1);end
        b.advance(plioCards(),cpuRead(ca),False,noWorkerRequest(),False,False,False,False,0,False); s<=7;
    endrule
    rule cpuStall(s==7 && b.debugAdvanceReady && b.memoryBackendRequestValid && stalls<4);
        if(b.debugMemoryOwner!=MainMemCpu || !b.debugPlioMemoryRequestValid || b.memoryBackendAddress!=ca || b.memoryBackendWrite || b.memoryBackendByteEnable!=4'hf) begin $display("FAIL|m6.1|cpu-stall|n=%0d|owner=%0d|plio=%0d|addr=%08x",stalls,pack(b.debugMemoryOwner),pack(b.debugPlioMemoryRequestValid),b.memoryBackendAddress);$finish(1);end
        b.advance(plioCards(),cpuRead(ca),False,noWorkerRequest(),False,False,False,False,0,False); stalls<=stalls+1;
    endrule
    rule cpuAccept(s==7 && b.debugAdvanceReady && b.memoryBackendRequestValid && stalls==4);
        if(accepts!=0 || b.debugMemoryOwner!=MainMemCpu || !b.debugPlioMemoryRequestValid) begin $display("FAIL|m6.1|cpu-accept");$finish(1);end
        b.advance(plioCards(),cpuRead(ca),False,noWorkerRequest(),True,False,False,False,0,False); accepts<=1; s<=8;
    endrule
    rule cpuRespond(s==8 && b.debugAdvanceReady && b.memoryBackendResponseReady);
        if(b.debugMemoryOwner!=MainMemCpu) begin $display("FAIL|m6.1|cpu-response-owner");$finish(1);end
        b.advance(plioCards(),cpuRead(ca),False,noWorkerRequest(),False,True,False,True,cd,False); responses<=1; s<=9;
    endrule
    rule cpuComplete(s==9 && b.debugAdvanceReady && b.debugCpuResponsePending);
        LightingBusInputs x=b.lightingMemory(plioCards(),cpuRead(ca),False);
        if(!x.ready||x.error||x.readData!=cd||b.debugMemoryOwner!=MainMemNone) begin $display("FAIL|m6.1|cpu-complete");$finish(1);end
        $display("M6ARBITRATION|winner=cpu|loser=plio|stall_cycles=4|owner_stable=1|pending_preserved=1|status=ok");
        b.advance(plioCards(),cpuRead(ca),False,noWorkerRequest(),False,False,False,False,0,False); s<=10;
    endrule
    rule cpuRetire(s==10 && b.debugAdvanceReady); b.advance(plioCards(),lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,False); s<=11; endrule

    // The queued retire cycle must be consumed before observing host state. Wait rather than
    // assuming a zero-latency debug transition. The original M6.1 bench exposed this distinction.
    rule plioWins(s==11 && b.debugAdvanceReady && !b.debugCpuResponsePending && b.debugPlioMemoryRequestValid);
        if(b.debugPreferCpu) begin $display("FAIL|m6.1|plio-policy");$finish(1);end
        LightingBusInputs x=b.lightingMemory(plioCards(),cpuBR(),False);
        if(x.busGrant) begin $display("FAIL|m6.1|cpu-granted-while-plio-preferred");$finish(1);end
        b.advance(plioCards(),cpuBR(),False,noWorkerRequest(),False,False,False,False,0,False); stalls<=0; s<=12;
    endrule
    rule plioStall(s==12 && b.debugAdvanceReady && b.memoryBackendRequestValid && stalls<4);
        LightingBusInputs x=b.lightingMemory(plioCards(),cpuBR(),False);
        if(b.debugMemoryOwner!=MainMemPlio || b.memoryBackendAddress!=pa || b.memoryBackendWrite || b.memoryBackendByteEnable!=4'hf || x.busGrant) begin $display("FAIL|m6.1|plio-stall|n=%0d|owner=%0d|addr=%08x|cpu_grant=%0d",stalls,pack(b.debugMemoryOwner),b.memoryBackendAddress,pack(x.busGrant));$finish(1);end
        b.advance(plioCards(),cpuBR(),False,noWorkerRequest(),False,False,False,False,0,False); stalls<=stalls+1;
    endrule
    rule plioAccept(s==12 && b.debugAdvanceReady && b.memoryBackendRequestValid && stalls==4);
        if(accepts!=1 || b.debugMemoryOwner!=MainMemPlio) begin $display("FAIL|m6.1|plio-accept|accepts=%0d|owner=%0d",accepts,pack(b.debugMemoryOwner));$finish(1);end
        b.advance(plioCards(),cpuBR(),False,noWorkerRequest(),True,False,False,False,0,False); accepts<=2; s<=13;
    endrule
    rule plioRespond(s==13 && b.debugAdvanceReady && b.memoryBackendResponseReady);
        if(b.debugMemoryOwner!=MainMemPlio) begin $display("FAIL|m6.1|plio-response-owner");$finish(1);end
        b.advance(plioCards(),cpuBR(),False,noWorkerRequest(),False,True,False,True,pd,False); responses<=2; s<=14;
    endrule
    rule plioObserve(s==14 && b.debugAdvanceReady);
        Vector#(8,PlioIn)i=b.plioSlots(plioCards(),False);
        if(i[1].err) begin $display("FAIL|m6.1|plio-error");$finish(1);end
        if(i[1].ack) begin
            if(!i[1].adValid||i[1].ad!=pd||accepts!=2||responses!=2) begin $display("FAIL|m6.1|plio-data|data=%08x|a=%0d|r=%0d",i[1].ad,accepts,responses);$finish(1);end
            $display("M6ARBITRATION|winner=plio|loser=cpu|stall_cycles=4|owner_stable=1|no_duplicate=1|status=ok"); s<=15;
        end
        b.advance(plioCards(),cpuBR(),False,noWorkerRequest(),False,False,False,False,0,False);
    endrule
    rule done(s==15); if(accepts!=2||responses!=2) begin $display("FAIL|m6.1|counts");$finish(1);end $display("PASS|m6.1|deterministic CPU/PLIO arbitration, stable ownership, preserved loser, backpressure, no loss or duplication"); $finish(0); endrule
endmodule
endpackage
