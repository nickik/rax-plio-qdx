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
    if (c==0 || c==10 || c==15 || c==20 || c==25 || c==286) return busReset();
    if (c==3 || c==4 || c==5 || c==6 || c==7 || c==8 || c==12 || c==13 || c==17 || c==18 || c==22 || c==27 || c==28 || (c>=29 && c<=284) || c==288 || c==289) begin
        if (c==5 || c==8 || c==17 || c==22 || c==28 || c==288 || c==289) return bgAck();
        if (c==13 || c==18) return bgErr();
        return bg();
    end
    return plioInDefault();
endfunction

function QliIn qi(Bit#(16) c);
    if (c>=1 && c<=8) return notifDma(2);
    if (c==9) return dmaOnly();
    if (c>=11 && c<=14) return notif(1);
    if (c>=16 && c<=19) return notif(3);
    if (c>=21 && c<=24) return notif(0);
    if (c>=26 && c<=285) return notif(2);
    if (c>=287 && c<=288) return notif(1);
    if (c==289) return notif(2);
    return qliInDefault();
endfunction

function String ev(Bit#(16) c);
    if (c==0 || c==10 || c==15 || c==20 || c==25 || c==286) return "reset";
    if (c==13 || c==18 || c==23) return "fault";
    if (c==5 || c==17 || c==22 || c==28 || c==288) return "manager_address";
    if (c==6 || c==7 || c==8 || c==18 || c==23 || (c>=29 && c<=284) || c==289) return "notification_data";
    if (c==9) return "idle";
    return "manager_request";
endfunction

function Bit#(8) notifChannel(QliIn q); return q.notificationValid ? q.notification.channel : 0; endfunction
function Bit#(1) notifValid(QliIn q); return pack(q.notificationValid); endfunction
function Bit#(1) dmaValid(QliIn q); return pack(q.dmaRequestValid); endfunction
function Bit#(1) dmaDir(QliIn q); return q.dmaRequestValid ? pack(q.dmaRequest.direction) : 0; endfunction
function Bit#(32) dmaAddr(QliIn q); return q.dmaRequestValid ? q.dmaRequest.address : 0; endfunction
function Bit#(2) dmaWords(QliIn q); return q.dmaRequestValid ? pack(q.dmaRequest.words) : 0; endfunction

function Action trace(Bit#(16) c,PlioIn i,QliIn q,PlioOut o,QliOut z);
 action
  $display("TRACE|v1|c=%08x|pi=%0d.%0d.%0d.%0d.%08x.%0d.%01x.%0d.%01x.%0d.%0d.%01x.%01x.%0d.%0d.%0d|qi=0.0.0.00000000.%0d.%0d.%08x.%0d.0.0.00000000.0.%0d.%02x|po=%0d.%0d.%08x.%0d.%01x.%0d.%01x.%0d.%0d.%01x.%01x.%0d.%0d.%0d|qo=%0d.0.00000000.0.0.00000000.0.0.%0d.0.00000000.0.0.00.0.%0d|ev=%s",
   zeroExtend(c), pack(i.reset),pack(i.selected),pack(i.grant),pack(i.adValid),i.ad,pack(i.parValid),i.par,pack(i.spaceValid),pack(i.space),pack(i.addressStrobe),pack(i.read),i.byteEnable,pack(i.burst),pack(i.dataStrobe),pack(i.ack),pack(i.err),
   dmaValid(q),dmaDir(q),dmaAddr(q),dmaWords(q),notifValid(q),notifChannel(q),
   pack(o.request),pack(o.adValid),o.ad,pack(o.parValid),o.par,pack(o.spaceValid),pack(o.space),pack(o.addressStrobe),pack(o.read),o.byteEnable,pack(o.burst),pack(o.dataStrobe),pack(o.ack),pack(o.err),
   pack(z.reset),pack(z.dmaRequestReady),pack(z.notificationReady),ev(c));
 endaction
endfunction

module mkTbQICPhase6(Empty);
 PLIOQICPhase6Ifc dut <- mkPLIOQICPhase6;
 Reg#(Bit#(16)) c <- mkReg(0);
 rule run;
  PlioIn i=pi(c); QliIn q=qi(c); PlioOut o=dut.drivePlio(i,q); QliOut z=dut.driveQli(i,q);

  // Notification has priority at idle; simultaneous DMA is not accepted.
  if (c==1 && (z.dmaRequestReady || dut.debugState != QicIdle)) begin $display("FAIL priority"); $finish(1); end
  // Address image for channel 2.
  if (c==4 && (!o.addressStrobe || !o.spaceValid || o.space!=PlioController || o.ad!=32'h8 || o.read || o.byteEnable!=4'hf || o.burst!=BurstOne)) begin $display("FAIL address"); $finish(1); end
  // Data is zero advisory payload with valid parity, and ready occurs only on ACK.
  if (c==7 && (!o.dataStrobe || !o.adValid || o.ad!=0 || !o.parValid || z.notificationReady)) begin $display("FAIL data wait"); $finish(1); end
  if (c==8 && !z.notificationReady) begin $display("FAIL completion ready"); $finish(1); end
  if ((c==13 || c==18 || c==23 || c==284) && z.notificationReady) begin $display("FAIL false ready"); $finish(1); end
  // Wrong channel still held by producer: bus ACK completes but no local ready.
  if (c==289 && z.notificationReady) begin $display("FAIL wrong-channel ready"); $finish(1); end
  if (o.addressStrobe && (!o.spaceValid || o.space!=PlioController || o.read || o.byteEnable!=4'hf || o.burst!=BurstOne)) begin $display("FAIL notification address invariant"); $finish(1); end
  if (o.dataStrobe && (!o.adValid || o.ad!=0 || !o.parValid)) begin $display("FAIL notification data invariant"); $finish(1); end

  trace(c,i,q,o,z);
  dut.advance(i,q);
  if (c==289) begin $display("PASS QIC Phase6 notification differential fixture"); $finish(0); end
  else c<=c+1;
 endrule
endmodule

endpackage
