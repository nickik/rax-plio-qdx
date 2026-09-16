package TbMainboardM6Reset;

import Vector::*;
import QLITypes::*;
import QICInterfaces::*;
import PLIOTx::*;
import PLIOWorkerHost::*;
import PLIOHostDmaM3::*;
import MemoryController::*;
import LightingMemoryBusCompat::*;
import MainboardFPGA::*;
function Vector#(8,BackplaneDrive) idleCards();return replicate(backplaneDriveDefault());endfunction
function HostWorkerRequest noWorkerRequest();return HostWorkerRequest{slot:0,address:0,width:HostW32,write:False,value:0};endfunction
function Bit#(4) parity32(Bit#(32)w);return{~(^w[31:24]),~(^w[23:16]),~(^w[15:8]),~(^w[7:0])};endfunction
function BackplaneDrive requestOnly();BackplaneDrive d=backplaneDriveDefault();d.request=True;return d;endfunction
function BackplaneDrive dmaAddress(Bit#(32)h);BackplaneDrive d=requestOnly();BackplaneControl c=backplaneControlDefault();c.space=pack(PlioHostDma);c.addressStrobe=True;c.read=True;c.byteEnable=4'hf;c.burstLen=pack(BurstOne);d.controlValid=True;d.control=c;d.adParValid=True;d.ad=h;d.parity=parity32(h);return d;endfunction
function BackplaneDrive dmaReadBeat();BackplaneDrive d=requestOnly();BackplaneControl c=backplaneControlDefault();c.dataStrobe=True;d.controlValid=True;d.control=c;return d;endfunction
function Vector#(8,BackplaneDrive) pc();Vector#(8,BackplaneDrive)c=idleCards();c[1]=dmaReadBeat();return c;endfunction
function LightingBusMasterDrive cpuBR();LightingBusMasterDrive d=lightingBusMasterDriveDefault();d.busRequest=True;return d;endfunction
function LightingBusMasterDrive cpuRead(Bit#(32)a);LightingBusMasterDrive d=cpuBR();d.request=True;d.payload.addr=a;d.payload.write=False;d.payload.byteEnable=4'hf;return d;endfunction

(* synthesize *)
module mkTbMainboardM6ResetCpuOwner(Empty);
 MainboardFPGAIfc b<-mkMainboardFPGA;Reg#(Bit#(6))s<-mkReg(0);Reg#(Bit#(16))wd<-mkReg(0);Bit#(32)ca=32'h2000,pa=32'h2400,pd=32'h63c0ffee;
 rule watchdog;wd<=wd+1;if(wd==14000)begin$display("FAIL|m6.3|cpu-owner-watchdog|stage=%0d|owner=%0d",s,pack(b.debugMemoryOwner));$finish(1);end endrule
 rule r0(s==0&&b.debugAdvanceReady);b.advance(idleCards(),lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,True);s<=1;endrule
 rule r1(s==1);b.bindDma(1,3,pa,25'h100,True,True);s<=2;endrule
 rule r2(s==2&&b.debugAdvanceReady);Vector#(8,BackplaneDrive)c=idleCards();c[1]=requestOnly();b.advance(c,lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,False);s<=3;endrule
 rule r3(s==3&&b.debugAdvanceReady);Vector#(8,BackplaneDrive)c=idleCards();c[1]=dmaAddress(32'h30000000);b.advance(c,lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,False);s<=4;endrule
 rule r4(s==4&&b.debugAdvanceReady);Vector#(8,BackplaneDrive)c=idleCards();Vector#(8,PlioIn)i=b.plioSlots(c,False);c[1]=dmaAddress(32'h30000000);i=b.plioSlots(c,False);if(!i[1].ack||i[1].err)begin$display("FAIL|m6.3|cpu-owner-address");$finish(1);end b.advance(c,lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,False);s<=5;endrule
 rule r5(s==5&&b.debugAdvanceReady&&b.debugPlioMemoryRequestValid);LightingBusInputs x=b.lightingMemory(pc(),cpuBR(),False);if(!x.busGrant)begin$display("FAIL|m6.3|cpu-owner-grant");$finish(1);end b.advance(pc(),cpuBR(),False,noWorkerRequest(),False,False,False,False,0,False);s<=6;endrule
 rule r6(s==6&&b.debugAdvanceReady);b.advance(pc(),cpuRead(ca),False,noWorkerRequest(),False,False,False,False,0,False);s<=7;endrule
 rule accept(s==7&&b.debugAdvanceReady&&b.memoryBackendRequestValid);if(b.debugMemoryOwner!=MainMemCpu||!b.debugPlioMemoryRequestValid)begin$display("FAIL|m6.3|cpu-owner-pre-reset");$finish(1);end b.advance(pc(),cpuRead(ca),False,noWorkerRequest(),True,False,False,False,0,False);s<=8;endrule
 rule reset(s==8&&b.debugAdvanceReady&&b.memoryBackendResponseReady);b.advance(pc(),cpuRead(ca),False,noWorkerRequest(),False,False,False,False,0,True);s<=9;endrule
 rule cleared(s==9&&b.debugAdvanceReady&&b.debugMemoryOwner==MainMemNone&&!b.memoryBackendRequestValid&&!b.memoryBackendResponseReady&&!b.debugCpuResponsePending&&!b.debugPlioMemoryRequestValid);LightingBusInputs x=b.lightingMemory(idleCards(),lightingBusMasterDriveDefault(),False);Vector#(8,PlioIn)i=b.plioSlots(idleCards(),False);if(x.ready||x.error||i[1].ack||i[1].err)begin$display("FAIL|m6.3|cpu-owner-reset-output");$finish(1);end b.advance(idleCards(),lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,True,False,True,32'hdeadbeef,False);s<=10;endrule
 rule stale(s==10&&b.debugAdvanceReady);LightingBusInputs x=b.lightingMemory(idleCards(),lightingBusMasterDriveDefault(),False);Vector#(8,PlioIn)i=b.plioSlots(idleCards(),False);if(b.debugMemoryOwner!=MainMemNone||b.debugCpuResponsePending||b.debugPlioMemoryRequestValid||x.ready||x.error||i[1].ack||i[1].err)begin$display("FAIL|m6.3|cpu-owner-stale");$finish(1);end $display("M6RESET|owner=cpu|waiting=plio|cleared=1|stale_suppressed=1|status=ok");s<=11;endrule
 rule rb(s==11);b.bindDma(1,3,pa,25'h100,True,True);s<=12;endrule
 rule q(s==12&&b.debugAdvanceReady);Vector#(8,BackplaneDrive)c=idleCards();c[1]=requestOnly();b.advance(c,lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,False);s<=13;endrule
 rule a0(s==13&&b.debugAdvanceReady);Vector#(8,BackplaneDrive)c=idleCards();c[1]=dmaAddress(32'h30000000);b.advance(c,lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,False);s<=14;endrule
 rule a1(s==14&&b.debugAdvanceReady);Vector#(8,BackplaneDrive)c=idleCards();Vector#(8,PlioIn)i=b.plioSlots(c,False);c[1]=dmaAddress(32'h30000000);i=b.plioSlots(c,False);if(!i[1].ack||i[1].err)begin$display("FAIL|m6.3|cpu-owner-recovery-address");$finish(1);end b.advance(c,lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,False);s<=15;endrule
 rule pa1(s==15&&b.debugAdvanceReady&&b.memoryBackendRequestValid);if(b.debugMemoryOwner!=MainMemPlio)begin$display("FAIL|m6.3|cpu-owner-recovery-owner");$finish(1);end b.advance(pc(),lightingBusMasterDriveDefault(),False,noWorkerRequest(),True,False,False,False,0,False);s<=16;endrule
 rule pr(s==16&&b.debugAdvanceReady&&b.memoryBackendResponseReady);b.advance(pc(),lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,True,False,True,pd,False);s<=17;endrule
 rule po(s==17&&b.debugAdvanceReady);Vector#(8,PlioIn)i=b.plioSlots(pc(),False);if(i[1].err)begin$display("FAIL|m6.3|cpu-owner-recovery-error");$finish(1);end if(i[1].ack)begin if(!i[1].adValid||i[1].ad!=pd)begin$display("FAIL|m6.3|cpu-owner-recovery-data");$finish(1);end $display("PASS|m6.3-cpu-owner|reset clears CPU owner and waiting PLIO, suppresses stale completion, fresh PLIO recovers");$finish(0);end b.advance(pc(),lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,False);endrule
endmodule

(* synthesize *)
module mkTbMainboardM6ResetPlioOwner(Empty);
 MainboardFPGAIfc b<-mkMainboardFPGA;Reg#(Bit#(6))s<-mkReg(0);Reg#(Bit#(16))wd<-mkReg(0);Bit#(32)pa=32'h2800,ca=32'h2c00,cd=32'h6300cafe;
 rule watchdog;wd<=wd+1;if(wd==14000)begin$display("FAIL|m6.3|plio-owner-watchdog|stage=%0d|owner=%0d",s,pack(b.debugMemoryOwner));$finish(1);end endrule
 rule r0(s==0&&b.debugAdvanceReady);b.advance(idleCards(),lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,True);s<=1;endrule
 rule r1(s==1);b.bindDma(1,3,pa,25'h100,True,True);s<=2;endrule
 rule r2(s==2&&b.debugAdvanceReady);Vector#(8,BackplaneDrive)c=idleCards();c[1]=requestOnly();b.advance(c,lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,False);s<=3;endrule
 rule r3(s==3&&b.debugAdvanceReady);Vector#(8,BackplaneDrive)c=idleCards();c[1]=dmaAddress(32'h30000000);b.advance(c,lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,False);s<=4;endrule
 rule r4(s==4&&b.debugAdvanceReady);Vector#(8,BackplaneDrive)c=idleCards();Vector#(8,PlioIn)i=b.plioSlots(c,False);c[1]=dmaAddress(32'h30000000);i=b.plioSlots(c,False);if(!i[1].ack||i[1].err)begin$display("FAIL|m6.3|plio-owner-address");$finish(1);end b.advance(c,lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,False,False,False,0,False);s<=5;endrule
 rule own(s==5&&b.debugAdvanceReady&&b.memoryBackendRequestValid);if(b.debugMemoryOwner!=MainMemPlio)begin$display("FAIL|m6.3|plio-owner-pre");$finish(1);end LightingBusInputs x=b.lightingMemory(pc(),cpuBR(),False);if(x.busGrant)begin$display("FAIL|m6.3|plio-owner-cpu-grant");$finish(1);end b.advance(pc(),cpuBR(),False,noWorkerRequest(),True,False,False,False,0,False);s<=6;endrule
 rule reset(s==6&&b.debugAdvanceReady&&b.memoryBackendResponseReady);b.advance(pc(),cpuBR(),False,noWorkerRequest(),False,False,False,False,0,True);s<=7;endrule
 rule cleared(s==7&&b.debugAdvanceReady&&b.debugMemoryOwner==MainMemNone&&!b.memoryBackendRequestValid&&!b.memoryBackendResponseReady&&!b.debugCpuGrantHeld&&!b.debugCpuResponsePending&&!b.debugPlioMemoryRequestValid);b.advance(idleCards(),lightingBusMasterDriveDefault(),False,noWorkerRequest(),False,True,False,True,32'hdeadbeef,False);s<=8;endrule
 rule stale(s==8&&b.debugAdvanceReady);LightingBusInputs x=b.lightingMemory(idleCards(),lightingBusMasterDriveDefault(),False);Vector#(8,PlioIn)i=b.plioSlots(idleCards(),False);if(b.debugMemoryOwner!=MainMemNone||b.debugCpuResponsePending||b.debugPlioMemoryRequestValid||x.ready||x.error||i[1].ack||i[1].err)begin$display("FAIL|m6.3|plio-owner-stale");$finish(1);end $display("M6RESET|owner=plio|waiting=cpu|cleared=1|stale_suppressed=1|status=ok");s<=9;endrule
 rule cb(s==9&&b.debugAdvanceReady);LightingBusInputs x=b.lightingMemory(idleCards(),cpuBR(),False);if(!x.busGrant)begin$display("FAIL|m6.3|plio-owner-recovery-grant");$finish(1);end b.advance(idleCards(),cpuBR(),False,noWorkerRequest(),False,False,False,False,0,False);s<=10;endrule
 rule cr(s==10&&b.debugAdvanceReady);b.advance(idleCards(),cpuRead(ca),False,noWorkerRequest(),False,False,False,False,0,False);s<=11;endrule
 rule ca1(s==11&&b.debugAdvanceReady&&b.memoryBackendRequestValid);if(b.debugMemoryOwner!=MainMemCpu||b.memoryBackendAddress!=ca)begin$display("FAIL|m6.3|plio-owner-recovery-owner");$finish(1);end b.advance(idleCards(),cpuRead(ca),False,noWorkerRequest(),True,False,False,False,0,False);s<=12;endrule
 rule rr(s==12&&b.debugAdvanceReady&&b.memoryBackendResponseReady);b.advance(idleCards(),cpuRead(ca),False,noWorkerRequest(),False,True,False,True,cd,False);s<=13;endrule
 rule ro(s==13&&b.debugAdvanceReady&&b.debugCpuResponsePending);LightingBusInputs x=b.lightingMemory(idleCards(),cpuRead(ca),False);if(!x.ready||x.error||x.readData!=cd)begin$display("FAIL|m6.3|plio-owner-recovery-data");$finish(1);end $display("PASS|m6.3-plio-owner|reset clears PLIO owner and waiting CPU, suppresses stale completion, fresh CPU recovers");$finish(0);endrule
endmodule
endpackage
