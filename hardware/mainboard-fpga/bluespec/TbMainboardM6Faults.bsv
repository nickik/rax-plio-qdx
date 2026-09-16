package TbMainboardM6Faults;

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
function BackplaneDrive dmaAddress(Bit#(32) h, Bool rd); BackplaneDrive d=requestOnly(); BackplaneControl c=backplaneControlDefault(); c.space=pack(PlioHostDma); c.addressStrobe=True; c.read=rd; c.byteEnable=4'hf; c.burstLen=pack(BurstOne); d.controlValid=True; d.control=c; d.adParValid=True; d.ad=h; d.parity=parity32(h); return d; endfunction
function BackplaneDrive dmaReadBeat(); BackplaneDrive d=requestOnly(); BackplaneControl c=backplaneControlDefault(); c.dataStrobe=True; d.controlValid=True; d.control=c; return d; endfunction
function BackplaneDrive dmaWriteBeat(Bit#(32) v); BackplaneDrive d=dmaReadBeat(); d.adParValid=True; d.ad=v; d.parity=parity32(v); return d; endfunction
function LightingBusMasterDrive cpuBR(); LightingBusMasterDrive d=lightingBusMasterDriveDefault(); d.busRequest=True; return d; endfunction
function LightingBusMasterDrive cpuReq(Bit#(32) a, Bool wr); LightingBusMasterDrive d=cpuBR(); d.request=True; d.payload.addr=a; d.payload.write=wr; d.payload.byteEnable=4'hf; d.payload.writeData=32'hfeed6002; return d; endfunction

(* synthesize *)
module mkTbMainboardM6CpuFaultIsolation(Empty);
    MainboardFPGAIfc b <- mkMainboardFPGA;
    Bit#(32) ca=32'h1000, pa=32'h1400, pd=32'h6002cafe;
    Reg#(Bit#(6)) s<-mkReg(0); Reg#(Bit#(16)) wd<-mkReg(0); Reg#(Bit#(4)) faults<-mkReg(0);
    function Vector#(8,BackplaneDrive) pc(); Vector#(8,BackplaneDrive)c=idleCards(); c[1]=dmaReadBeat(); return c; endfunction
    rule watchdog; wd<=wd+1; if(wd==12000) begin $display("FAIL|m6.2|cpu-isolation-watchdog|stage=%0d",s);$finish(1);end endrule
    rule r0(s==0&&b.debugAdvanceReady); b.advance(idleCards(),lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,True);s<=1;endrule
    rule r1(s==1); b.bindDma(1,3,pa,25'h100,True,True);s<=2;endrule
    rule r2(s==2&&b.debugAdvanceReady); Vector#(8,BackplaneDrive)c=idleCards();c[1]=requestOnly();b.advance(c,lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,False);s<=3;endrule
    rule r3(s==3&&b.debugAdvanceReady); Vector#(8,BackplaneDrive)c=idleCards();c[1]=dmaAddress(32'h30000000,True);b.advance(c,lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,False);s<=4;endrule
    rule r4(s==4&&b.debugAdvanceReady); Vector#(8,BackplaneDrive)c=idleCards(); Vector#(8,PlioIn)i=b.plioSlots(c,False); c[1]=dmaAddress(32'h30000000,True); i=b.plioSlots(c,False);if(!i[1].ack||i[1].err)begin$display("FAIL|m6.2|cpu-isolation-address");$finish(1);end b.advance(c,lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,False);s<=5;endrule
    rule r5(s==5&&b.debugAdvanceReady&&b.debugPlioMemoryRequestValid); LightingBusInputs x=b.lightingMemory(pc(),cpuBR(),False);if(!x.busGrant)begin$display("FAIL|m6.2|cpu-isolation-grant");$finish(1);end b.advance(pc(),cpuBR(),False,noWorkerRequest(),False,False,False,False,0,False);s<=6;endrule
    rule r6(s==6&&b.debugAdvanceReady); b.advance(pc(),cpuReq(ca,False),False,noWorkerRequest(),False,False,False,False,0,False);s<=7;endrule
    rule acceptCpu(s==7&&b.debugAdvanceReady&&b.memoryBackendRequestValid); if(b.debugMemoryOwner!=MainMemCpu||!b.debugPlioMemoryRequestValid)begin$display("FAIL|m6.2|cpu-owner");$finish(1);end b.advance(pc(),cpuReq(ca,False),False,noWorkerRequest(),True,False,False,False,0,False);s<=8;endrule
    rule faultCpu(s==8&&b.debugAdvanceReady&&b.memoryBackendResponseReady); b.advance(pc(),cpuReq(ca,False),False,noWorkerRequest(),False,True,True,False,0,False);faults<=faults+1;s<=9;endrule
    rule observeCpu(s==9&&b.debugAdvanceReady&&b.debugCpuResponsePending); LightingBusInputs x=b.lightingMemory(pc(),cpuReq(ca,False),False); Vector#(8,PlioIn)i=b.plioSlots(pc(),False); if(!x.ready||!x.error||i[1].ack||i[1].err||faults!=1)begin$display("FAIL|m6.2|cpu-fault-routing|ready=%0d|err=%0d|pack=%0d|perr=%0d|faults=%0d",pack(x.ready),pack(x.error),pack(i[1].ack),pack(i[1].err),faults);$finish(1);end $display("M6FAULT|owner=cpu|op=read|cpu_fault=1|plio_spurious=0|status=ok"); b.advance(pc(),cpuReq(ca,False),False,noWorkerRequest(),False,False,False,False,0,False);s<=10;endrule
    rule retire(s==10&&b.debugAdvanceReady); b.advance(pc(),lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,False);s<=11;endrule
    rule acceptPlio(s==11&&b.debugAdvanceReady&&b.memoryBackendRequestValid&&b.debugMemoryOwner==MainMemPlio); if(b.memoryBackendAddress!=pa)begin$display("FAIL|m6.2|pending-plio-address");$finish(1);end b.advance(pc(),lightingBusMasterDriveDefault(),False,noWorkerRequest(),True,False,False,False,0,False);s<=12;endrule
    rule respondPlio(s==12&&b.debugAdvanceReady&&b.memoryBackendResponseReady); b.advance(pc(),lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,True,False,True,pd,False);s<=13;endrule
    rule observePlio(s==13&&b.debugAdvanceReady); Vector#(8,PlioIn)i=b.plioSlots(pc(),False); if(i[1].err)begin$display("FAIL|m6.2|pending-plio-error");$finish(1);end if(i[1].ack)begin if(!i[1].adValid||i[1].ad!=pd)begin$display("FAIL|m6.2|pending-plio-data");$finish(1);end $display("PASS|m6.2-cpu-isolation|CPU fault routed once, PLIO isolated and preserved through owner fault");$finish(0);end b.advance(pc(),lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,False);endrule
endmodule

(* synthesize *)
module mkTbMainboardM6CpuWriteFault(Empty);
    MainboardFPGAIfc b<-mkMainboardFPGA; Reg#(Bit#(4))s<-mkReg(0);Reg#(Bit#(8))wd<-mkReg(0);
    rule watchdog;wd<=wd+1;if(wd==100)begin$display("FAIL|m6.2|cpu-write-watchdog");$finish(1);end endrule
    rule r0(s==0&&b.debugAdvanceReady);b.advance(idleCards(),lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,True);s<=1;endrule
    rule r1(s==1&&b.debugAdvanceReady);LightingBusInputs x=b.lightingMemory(idleCards(),cpuBR(),False);if(!x.busGrant)begin$display("FAIL|m6.2|cpu-write-grant");$finish(1);end b.advance(idleCards(),cpuBR(),False,noWorkerRequest(),False,False,False,False,0,False);s<=2;endrule
    rule r2(s==2&&b.debugAdvanceReady);b.advance(idleCards(),cpuReq(32'h1800,True),False,noWorkerRequest(),False,False,False,False,0,False);s<=3;endrule
    rule r3(s==3&&b.debugAdvanceReady&&b.memoryBackendRequestValid);if(!b.memoryBackendWrite||b.debugMemoryOwner!=MainMemCpu)begin$display("FAIL|m6.2|cpu-write-owner");$finish(1);end b.advance(idleCards(),cpuReq(32'h1800,True),False,noWorkerRequest(),True,False,False,False,0,False);s<=4;endrule
    rule r4(s==4&&b.debugAdvanceReady&&b.memoryBackendResponseReady);b.advance(idleCards(),cpuReq(32'h1800,True),False,noWorkerRequest(),False,True,True,False,0,False);s<=5;endrule
    rule r5(s==5&&b.debugAdvanceReady&&b.debugCpuResponsePending);LightingBusInputs x=b.lightingMemory(idleCards(),cpuReq(32'h1800,True),False);Vector#(8,PlioIn)i=b.plioSlots(idleCards(),False);if(!x.ready||!x.error||i[1].ack||i[1].err)begin$display("FAIL|m6.2|cpu-write-routing");$finish(1);end $display("M6FAULT|owner=cpu|op=write|cpu_fault=1|plio_spurious=0|status=ok");$display("PASS|m6.2-cpu-write|CPU write fault routed exactly to CPU");$finish(0);endrule
endmodule

module mkPlioFault#(Bool isRead)(Empty);
    MainboardFPGAIfc b<-mkMainboardFPGA; Reg#(Bit#(5))s<-mkReg(0);Reg#(Bit#(16))wd<-mkReg(0); Bit#(32) pa=32'h1c00;
    function Vector#(8,BackplaneDrive) beat(); Vector#(8,BackplaneDrive)c=idleCards();c[1]=isRead?dmaReadBeat():dmaWriteBeat(32'h12345678);return c;endfunction
    rule watchdog;wd<=wd+1;if(wd==8000)begin$display("FAIL|m6.2|plio-watchdog|read=%0d|stage=%0d",pack(isRead),s);$finish(1);end endrule
    rule r0(s==0&&b.debugAdvanceReady);b.advance(idleCards(),lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,True);s<=1;endrule
    rule r1(s==1);b.bindDma(1,3,pa,25'h100,True,True);s<=2;endrule
    rule r2(s==2&&b.debugAdvanceReady);Vector#(8,BackplaneDrive)c=idleCards();c[1]=requestOnly();b.advance(c,lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,False);s<=3;endrule
    rule r3(s==3&&b.debugAdvanceReady);Vector#(8,BackplaneDrive)c=idleCards();c[1]=dmaAddress(32'h30000000,isRead);b.advance(c,lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,False);s<=4;endrule
    rule r4(s==4&&b.debugAdvanceReady);Vector#(8,BackplaneDrive)c=idleCards();Vector#(8,PlioIn)i=b.plioSlots(c,False);c[1]=dmaAddress(32'h30000000,isRead);i=b.plioSlots(c,False);if(!i[1].ack||i[1].err)begin$display("FAIL|m6.2|plio-address|read=%0d",pack(isRead));$finish(1);end b.advance(c,lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,False);s<=5;endrule
    rule accept(s==5&&b.debugAdvanceReady&&b.memoryBackendRequestValid);if(b.debugMemoryOwner!=MainMemPlio||b.memoryBackendAddress!=pa||b.memoryBackendWrite==isRead)begin$display("FAIL|m6.2|plio-owner|read=%0d|write=%0d",pack(isRead),pack(b.memoryBackendWrite));$finish(1);end b.advance(beat(),cpuBR(),False,noWorkerRequest(),True,False,False,False,0,False);s<=6;endrule
    rule fault(s==6&&b.debugAdvanceReady&&b.memoryBackendResponseReady);b.advance(beat(),cpuBR(),False,noWorkerRequest(),False,True,True,False,0,False);s<=7;endrule
    rule observe(s==7&&b.debugAdvanceReady);Vector#(8,PlioIn)i=b.plioSlots(beat(),False);LightingBusInputs x=b.lightingMemory(beat(),cpuBR(),False);if(x.ready||x.error)begin$display("FAIL|m6.2|plio-fault-leaked-to-cpu|read=%0d",pack(isRead));$finish(1);end if(i[1].ack)begin$display("FAIL|m6.2|plio-fault-acked|read=%0d",pack(isRead));$finish(1);end if(i[1].err)begin$display("M6FAULT|owner=plio|op_read=%0d|plio_fault=1|cpu_spurious=0|status=ok",pack(isRead));$display("PASS|m6.2-plio|PLIO DMA fault routed exactly to PLIO|read=%0d",pack(isRead));$finish(0);end b.advance(beat(),cpuBR(),False,noWorkerRequest(),False,False,False,False,0,False);endrule
endmodule
(* synthesize *) module mkTbMainboardM6PlioReadFault(Empty); Empty x<-mkPlioFault(True); endmodule
(* synthesize *) module mkTbMainboardM6PlioWriteFault(Empty); Empty x<-mkPlioFault(False); endmodule
endpackage
