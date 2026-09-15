package TbQICPhase8;

import QLITypes::*;
import QICInterfaces::*;
import PLIOQIC::*;
import PLIOQICPhase1::*;
import PLIOQICPhase2::*;

function PlioIn resetPi(); PlioIn x=plioInDefault(); x.reset=True; return x; endfunction
function PlioIn grantPi(Bool ack, Bool err); PlioIn x=plioInDefault(); x.grant=True; x.ack=ack; x.err=err; return x; endfunction
function PlioIn workerAddr(Bit#(32) a, Bool rd, Bit#(4) be); PlioIn x=plioInDefault(); x.selected=True; x.adValid=True; x.ad=a; x.parValid=True; x.parity=oddParity32P2(a); x.spaceValid=True; x.space=PlioWorker; x.addressStrobe=True; x.read=rd; x.byteEnable=be; x.burst=BurstOne; return x; endfunction
function PlioIn workerData(Bit#(32) d); PlioIn x=plioInDefault(); x.dataStrobe=True; x.adValid=True; x.ad=d; x.parValid=True; x.parity=oddParity32P2(d); return x; endfunction
function QliIn dmaReq(DmaDirection dir, Bit#(32) addr, BurstWords words); QliIn q=qliInDefault(); q.dmaRequestValid=True; q.dmaRequest=DmaRequest{direction:dir,address:addr,words:words}; return q; endfunction
function QliIn notifReq(Bit#(8) ch); QliIn q=qliInDefault(); q.notificationValid=True; q.notification=NotificationRequest{channel:ch}; return q; endfunction

function PlioIn workerPi(Bit#(16) l, Bool write, Bit#(32) addr, Bit#(4) be, Bit#(32) data);
    PlioIn x=plioInDefault();
    if(l==0) x=resetPi();
    else if(l==1) x=workerAddr(addr,!write,be);
    else if(l==2) begin if(write) x=workerData(data); else x.dataStrobe=True; end
    else if(l==4) x.dataStrobe=True;
    return x;
endfunction
function QliIn workerQi(Bit#(16) l, Bool write, Bit#(32) responseData);
    QliIn q=qliInDefault();
    if(l==3) q.mmioReady=True;
    else if(l==4) begin q.mmioResponseValid=True; q.mmioResponse=write ? mmioWriteOk() : mmioReadOk(responseData); end
    return q;
endfunction
function PlioIn notificationPi(Bit#(16) l);
    PlioIn x=plioInDefault();
    if(l==0) x=resetPi();
    else if(l==2) x=grantPi(False,False);
    else if(l==3 || l==4) x=grantPi(True,False);
    return x;
endfunction
function QliIn notificationQi(Bit#(16) l, Bit#(8) ch);
    QliIn q=qliInDefault();
    if(l>=1 && l<=4) q=notifReq(ch);
    return q;
endfunction

function PlioIn h2dPi(Bit#(16) l, Bit#(16) n);
    PlioIn x=plioInDefault(); Bit#(16) twice=n<<1;
    if(l==0) x=resetPi();
    else if(l==2) x=grantPi(False,False);
    else if(l==3) x=grantPi(True,False);
    else if(l>=4 && l<4+twice) begin
        if(l[0]==0) begin Bit#(16) idx=(l-4)>>1; Bit#(32) d=32'h1100_0000+zeroExtend(idx); x=grantPi(True,False); x.adValid=True; x.ad=d; x.parValid=True; x.parity=oddParity32P1(d); end
        else if(l != 3+twice) x=grantPi(False,False);
    end
    return x;
endfunction
function QliIn h2dQi(Bit#(16) l, Bit#(16) n, Bit#(32) addr, BurstWords words);
    QliIn q=qliInDefault(); Bit#(16) twice=n<<1;
    if(l==1) q=dmaReq(HostToDevice,addr,words);
    else if(l>=5 && l<=3+twice && l[0]==1) q.dmaReadReady=True;
    else if(l==4+twice) q.dmaCompletionReady=True;
    return q;
endfunction
function PlioIn d2hPi(Bit#(16) l, Bit#(16) n);
    PlioIn x=plioInDefault(); Bit#(16) twice=n<<1;
    if(l==0) x=resetPi();
    else if(l==2) x=grantPi(False,False);
    else if(l==3) x=grantPi(True,False);
    else if(l>=4 && l<4+twice) x=grantPi(l[0]==1,False);
    return x;
endfunction
function QliIn d2hQi(Bit#(16) l, Bit#(16) n, Bit#(32) addr, BurstWords words);
    QliIn q=qliInDefault(); Bit#(16) twice=n<<1;
    if(l==1) q=dmaReq(DeviceToHost,addr,words);
    else if(l>=4 && l<4+twice && l[0]==0) begin Bit#(16) idx=(l-4)>>1; q.dmaWriteValid=True; q.dmaWrite=DmaWord{data:32'h2200_0000+zeroExtend(idx)}; end
    else if(l==4+twice) q.dmaCompletionReady=True;
    return q;
endfunction

function PlioIn piFor(Bit#(16) c);
    PlioIn x=plioInDefault();
    if(c<5) x=workerPi(c,False,32'h100,4'h1,0);
    else if(c<10) x=workerPi(c-5,False,32'h102,4'h3,0);
    else if(c<15) x=workerPi(c-10,False,32'h104,4'hf,0);
    else if(c<20) x=workerPi(c-15,True,32'h108,4'h1,32'h0000_005a);
    else if(c<25) x=workerPi(c-20,True,32'h10a,4'h3,32'h0000_a55a);
    else if(c<30) x=workerPi(c-25,True,32'h10c,4'hf,32'ha55a_5aa5);
    else if(c<36) x=notificationPi(c-30);
    else if(c<42) x=notificationPi(c-36);
    else if(c<48) x=notificationPi(c-42);
    else if(c<54) x=notificationPi(c-48);
    else if(c==54 || c==62 || c==219 || c==224 || c==229 || c==235 || c==496 || c==757 || c==1016) x=resetPi();
    else if(c==56 || c==59 || c==61 || c==221 || c==226 || c==231 || c==237 || c==1018 || c==1021 || c==1025) x=grantPi(False,False);
    else if(c==57 || c==58 || c==232 || c==1022 || c==1026 || c==1027) x=grantPi(True,False);
    else if(c==222 || c==1019 || c==1023) x=grantPi(False,True);
    else if(c==233) begin Bit#(32) d=32'hdead_beef; x=grantPi(True,False); x.adValid=True; x.ad=d; x.parValid=True; x.parity=oddParity32P1(d)^4'h1; end
    else if(c==238 || (c>=239 && c<=494)) x=grantPi(False,False);
    else if(c==497) x=workerAddr(32'h180,True,4'hf);
    else if(c==498 || (c>=500 && c<=755) || c==759) x.dataStrobe=True;
    else if(c==758) x=workerAddr(32'h184,True,4'hf);
    else if(c>=63 && c<70) x=h2dPi(c-63,1);
    else if(c>=70 && c<83) x=h2dPi(c-70,4);
    else if(c>=83 && c<104) x=h2dPi(c-83,8);
    else if(c>=104 && c<141) x=h2dPi(c-104,16);
    else if(c>=141 && c<148) x=d2hPi(c-141,1);
    else if(c>=148 && c<161) x=d2hPi(c-148,4);
    else if(c>=161 && c<182) x=d2hPi(c-161,8);
    else if(c>=182 && c<219) x=d2hPi(c-182,16);
    return x;
endfunction

function QliIn qiFor(Bit#(16) c);
    QliIn q=qliInDefault();
    if(c<5) q=workerQi(c,False,32'h0000_0011);
    else if(c<10) q=workerQi(c-5,False,32'h0000_2233);
    else if(c<15) q=workerQi(c-10,False,32'h4455_6677);
    else if(c<20) q=workerQi(c-15,True,0);
    else if(c<25) q=workerQi(c-20,True,0);
    else if(c<30) q=workerQi(c-25,True,0);
    else if(c<36) q=notificationQi(c-30,0);
    else if(c<42) q=notificationQi(c-36,1);
    else if(c<48) q=notificationQi(c-42,2);
    else if(c<54) q=notificationQi(c-48,3);
    else if(c>=55 && c<=58) begin q=notifReq(2); q.dmaRequestValid=True; q.dmaRequest=DmaRequest{direction:HostToDevice,address:32'h3300_0000,words:BurstOne}; end
    else if(c>=59 && c<=61) q=dmaReq(HostToDevice,32'h3300_0000,BurstOne);
    else if(c>=63 && c<70) q=h2dQi(c-63,1,32'h4000_1000,BurstOne);
    else if(c>=70 && c<83) q=h2dQi(c-70,4,32'h4000_2000,BurstFour);
    else if(c>=83 && c<104) q=h2dQi(c-83,8,32'h4000_3000,BurstEight);
    else if(c>=104 && c<141) q=h2dQi(c-104,16,32'h4000_4000,BurstSixteen);
    else if(c>=141 && c<148) q=d2hQi(c-141,1,32'h5000_1000,BurstOne);
    else if(c>=148 && c<161) q=d2hQi(c-148,4,32'h5000_2000,BurstFour);
    else if(c>=161 && c<182) q=d2hQi(c-161,8,32'h5000_3000,BurstEight);
    else if(c>=182 && c<219) q=d2hQi(c-182,16,32'h5000_4000,BurstSixteen);
    else if(c>=220 && c<=223) begin q=dmaReq(HostToDevice,32'h6000_1000,BurstOne); if(c==223) q.dmaCompletionReady=True; end
    else if(c>=225 && c<=228) begin q=dmaReq(HostToDevice,32'h6000_2000,BurstOne); if(c==228) q.dmaCompletionReady=True; end
    else if(c>=230 && c<=234) begin q=dmaReq(HostToDevice,32'h6000_3000,BurstOne); if(c==234) q.dmaCompletionReady=True; end
    else if(c>=236 && c<=495) begin q=dmaReq(DeviceToHost,32'h6000_4000,BurstOne); if(c==495) q.dmaCompletionReady=True; end
    else if(c==499) q.mmioReady=True;
    else if(c>=1017 && c<=1027) q=notifReq(3);
    return q;
endfunction

function Bit#(2) mmioKind(QliIn q);
    Bit#(2) k=0;
    if(q.mmioResponseValid) begin case(q.mmioResponse.status) MmioReadOk:k=1; MmioWriteOk:k=2; MmioError:k=3; endcase end
    return k;
endfunction
function Bit#(32) mmioData(QliIn q); return q.mmioResponseValid ? q.mmioResponse.data : 0; endfunction
function Bit#(2) dmaDir(DmaDirection d); return d==HostToDevice ? 0 : 1; endfunction
function Bit#(8) dmaStatus(DmaStatus s);
    Bit#(8) r=0; case(s) DmaOk:r=0; DmaBusError:r=1; DmaParityError:r=2; DmaTimeout:r=3; DmaProtocolError:r=4; endcase return r;
endfunction

function Action emitTrace(Bit#(16) c, PlioIn pi, QliIn qi, PlioOut po, QliOut qo);
 action
    Bit#(32) cc=zeroExtend(c); Bit#(32) pia=pi.adValid ? pi.ad : 0; Bit#(4) pip=pi.parValid ? pi.parity : 0; Bit#(32) poa=po.adValid ? po.ad : 0; Bit#(4) pop=po.parValid ? po.parity : 0;
    $display("TRACE|v2|c=%08x|pi=%0d.%0d.%0d.%0d.%08x.%0d.%01x.%0d.%01x.%0d.%0d.%01x.%01x.%0d.%0d.%0d|qi=%0d.%0d.%0d.%08x.%0d.%0d.%08x.%0d.%0d.%0d.%08x.%0d.%0d.%02x|po=%0d.%0d.%08x.%0d.%01x.%0d.%01x.%0d.%0d.%01x.%01x.%0d.%0d.%0d|qo=%0d.%0d.%08x.%0d.%01x.%08x.%0d.%0d.%0d.%0d.%08x.%0d.%0d.%02x.%01x.%0d|ev=phase8",
      cc,
      pack(pi.reset),pack(pi.selected),pack(pi.grant),pack(pi.adValid),pia,pack(pi.parValid),pip,pack(pi.spaceValid),pack(pi.space),pack(pi.addressStrobe),pack(pi.read),pi.byteEnable,pack(pi.burst),pack(pi.dataStrobe),pack(pi.ack),pack(pi.err),
      pack(qi.mmioReady),pack(qi.mmioResponseValid),mmioKind(qi),mmioData(qi),pack(qi.dmaRequestValid),dmaDir(qi.dmaRequest.direction),qi.dmaRequest.address,pack(qi.dmaRequest.words),pack(qi.dmaReadReady),pack(qi.dmaWriteValid),qi.dmaWrite.data,pack(qi.dmaCompletionReady),pack(qi.notificationValid),qi.notification.channel,
      pack(po.request),pack(po.adValid),poa,pack(po.parValid),pop,pack(po.spaceValid),pack(po.space),pack(po.addressStrobe),pack(po.read),po.byteEnable,pack(po.burst),pack(po.dataStrobe),pack(po.ack),pack(po.err),
      pack(qo.reset),pack(qo.mmioRequestValid),qo.mmioRequest.address,pack(qo.mmioRequest.write),qo.mmioRequest.byteEnable,qo.mmioRequest.writeData,pack(qo.mmioResponseReady),pack(qo.mmioCancel),pack(qo.dmaRequestReady),pack(qo.dmaReadValid),qo.dmaRead.data,pack(qo.dmaWriteReady),pack(qo.dmaCompletionValid),dmaStatus(qo.dmaCompletion.status),qo.dmaCompletion.wordsCompleted,pack(qo.notificationReady));
 endaction
endfunction

module mkTbQICPhase8(Empty);
    PLIOQICIfc dut <- mkPLIOQIC; Reg#(Bit#(16)) c <- mkReg(0);
    rule run;
        PlioIn pi=piFor(c); QliIn qi=qiFor(c); PlioOut po=dut.drivePlio(pi,qi); QliOut qo=dut.driveQli(pi,qi);
        emitTrace(c,pi,qi,po,qo); dut.advance(pi,qi);
        if(c==1027) begin $display("PASS QIC Phase8 unified conformance fixture"); $finish(0); end else c<=c+1;
    endrule
endmodule

endpackage
