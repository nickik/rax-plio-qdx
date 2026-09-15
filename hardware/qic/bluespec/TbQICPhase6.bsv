package TbQICPhase6;

import QLITypes::*;
import QICInterfaces::*;
import PLIOQICPhase6::*;

function PlioIn busReset(); PlioIn x=plioInDefault(); x.reset=True; return x; endfunction
function PlioIn bg(); PlioIn x=plioInDefault(); x.grant=True; return x; endfunction
function PlioIn bgAck(); PlioIn x=bg(); x.ack=True; return x; endfunction
function PlioIn bgErr(); PlioIn x=bg(); x.err=True; return x; endfunction
function QliIn notif(Bit#(8) ch); QliIn q=qliInDefault(); q.notificationValid=True; q.notification=NotificationRequest{channel:ch}; return q; endfunction
function QliIn notifDma(Bit#(8) ch); QliIn q=notif(ch); q.dmaRequestValid=True; q.dmaRequest=DmaRequest{direction:HostToDevice,address:32'h4400_0000,words:BurstFour}; return q; endfunction
function QliIn dmaOnly(); QliIn q=qliInDefault(); q.dmaRequestValid=True; q.dmaRequest=DmaRequest{direction:HostToDevice,address:32'h4400_0000,words:BurstFour}; return q; endfunction

function PlioIn pi(Bit#(16) c);
    PlioIn result = plioInDefault();
    if (c==0 || c==10 || c==15 || c==21 || c==27 || c==288) begin
        result = busReset();
    end
    // Successful channel-2 transaction: grant, address waits/ACK, data wait/ACK.
    else if (c==3 || c==4 || c==5 || c==6 || c==7 || c==8) begin
        result = (c==6 || c==8) ? bgAck() : bg();
    end
    // Address error on channel 1.
    else if (c==12 || c==13) begin
        result = c==13 ? bgErr() : bg();
    end
    // Data error on channel 3.
    else if (c==17 || c==18 || c==19) begin
        if (c==18) result = bgAck();
        else if (c==19) result = bgErr();
        else result = bg();
    end
    // BG loss during channel-0 data: address succeeds at c24, grant absent at c25.
    else if (c==23 || c==24) begin
        result = c==24 ? bgAck() : bg();
    end
    // Channel-2 data timeout: address succeeds at c30, then 256 granted waits.
    else if (c==29 || c==30 || (c>=31 && c<=286)) begin
        result = c==30 ? bgAck() : bg();
    end
    // Wrong producer channel at the ACKed data beat.
    else if (c==290 || c==291 || c==292) begin
        result = (c==291 || c==292) ? bgAck() : bg();
    end
    return result;
endfunction

function QliIn qi(Bit#(16) c);
    QliIn result = qliInDefault();
    if (c>=1 && c<=8) result = notifDma(2);
    else if (c==9) result = dmaOnly();
    else if (c>=11 && c<=14) result = notif(1);
    else if (c>=16 && c<=20) result = notif(3);
    else if (c>=22 && c<=26) result = notif(0);
    else if (c>=28 && c<=287) result = notif(2);
    else if (c>=289 && c<=291) result = notif(1);
    else if (c==292) result = notif(2);
    return result;
endfunction

function String ev(Bit#(16) c);
    String result = "manager_request";
    if (c==0 || c==10 || c==15 || c==21 || c==27 || c==288)
        result = "reset";
    else if (c==13 || c==19 || c==25)
        result = "fault";
    else if (c==4 || c==5 || c==6 || c==13 || c==18 || c==24 || c==30 || c==291)
        result = "manager_address";
    else if (c==7 || c==8 || c==19 || c==25 || (c>=31 && c<=286) || c==292)
        result = "notification_data";
    else if (c==9)
        result = "idle";
    return result;
endfunction

function Bit#(8) notifChannel(QliIn q); return q.notificationValid ? q.notification.channel : 0; endfunction
function Bit#(1) notifValid(QliIn q); return pack(q.notificationValid); endfunction
function Bit#(1) dmaValid(QliIn q); return pack(q.dmaRequestValid); endfunction
function Bit#(1) dmaDir(QliIn q); return q.dmaRequestValid ? pack(q.dmaRequest.direction) : 0; endfunction
function Bit#(32) dmaAddr(QliIn q); return q.dmaRequestValid ? q.dmaRequest.address : 0; endfunction
function Bit#(2) dmaWords(QliIn q); return q.dmaRequestValid ? pack(q.dmaRequest.words) : 0; endfunction

function Action trace(Bit#(16) c,PlioIn i,QliIn q,PlioOut o,QliOut z);
 action
  Bit#(32) cycle32 = zeroExtend(c);
  Bit#(32) piAd = i.adValid ? i.ad : 0;
  Bit#(4) piParity = i.parValid ? i.parity : 0;
  Bit#(32) poAd = o.adValid ? o.ad : 0;
  Bit#(4) poParity = o.parValid ? o.parity : 0;
  $display("TRACE|v1|c=%08x|pi=%0d.%0d.%0d.%0d.%08x.%0d.%01x.%0d.%01x.%0d.%0d.%01x.%01x.%0d.%0d.%0d|qi=0.0.0.00000000.%0d.%0d.%08x.%0d.0.0.00000000.0.%0d.%02x|po=%0d.%0d.%08x.%0d.%01x.%0d.%01x.%0d.%0d.%01x.%01x.%0d.%0d.%0d|qo=%0d.0.00000000.0.0.00000000.0.0.%0d.0.00000000.0.0.00.0.%0d|ev=%s",
   cycle32, pack(i.reset),pack(i.selected),pack(i.grant),pack(i.adValid),piAd,pack(i.parValid),piParity,pack(i.spaceValid),pack(i.space),pack(i.addressStrobe),pack(i.read),i.byteEnable,pack(i.burst),pack(i.dataStrobe),pack(i.ack),pack(i.err),
   dmaValid(q),dmaDir(q),dmaAddr(q),dmaWords(q),notifValid(q),notifChannel(q),
   pack(o.request),pack(o.adValid),poAd,pack(o.parValid),poParity,pack(o.spaceValid),pack(o.space),pack(o.addressStrobe),pack(o.read),o.byteEnable,pack(o.burst),pack(o.dataStrobe),pack(o.ack),pack(o.err),
   pack(z.reset),pack(z.dmaRequestReady),pack(z.notificationReady),ev(c));
 endaction
endfunction

module mkTbQICPhase6(Empty);
 PLIOQICPhase6Ifc dut <- mkPLIOQICPhase6;
 Reg#(Bit#(16)) c <- mkReg(0);
 rule run;
  PlioIn i=pi(c); QliIn q=qi(c); PlioOut o=dut.drivePlio(i,q); QliOut z=dut.driveQli(i,q);

  if (c==1 && (z.dmaRequestReady || dut.debugState != QicIdle)) begin $display("FAIL priority"); $finish(1); end
  if (c==4 && (!o.addressStrobe || !o.spaceValid || o.space!=PlioController || o.ad!=32'h8 || o.read || o.byteEnable!=4'hf || o.burst!=BurstOne)) begin $display("FAIL address"); $finish(1); end
  if (c==7 && (!o.dataStrobe || !o.adValid || o.ad!=0 || !o.parValid || z.notificationReady)) begin $display("FAIL data wait"); $finish(1); end
  if (c==8 && !z.notificationReady) begin $display("FAIL completion ready"); $finish(1); end
  if ((c==13 || c==19 || c==25 || c==286) && z.notificationReady) begin $display("FAIL false ready"); $finish(1); end
  if (c==292 && z.notificationReady) begin $display("FAIL wrong-channel ready"); $finish(1); end
  if (o.addressStrobe && (!o.spaceValid || o.space!=PlioController || o.read || o.byteEnable!=4'hf || o.burst!=BurstOne)) begin $display("FAIL notification address invariant"); $finish(1); end
  if (o.dataStrobe && (!o.adValid || o.ad!=0 || !o.parValid)) begin $display("FAIL notification data invariant"); $finish(1); end

  trace(c,i,q,o,z);
  dut.advance(i,q);
  if (c==292) begin $display("PASS QIC Phase6 notification differential fixture"); $finish(0); end
  else c<=c+1;
 endrule
endmodule

endpackage
