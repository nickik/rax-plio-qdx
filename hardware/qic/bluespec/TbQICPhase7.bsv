package TbQICPhase7;

import QLITypes::*;
import QICInterfaces::*;
import PLIOQIC::*;
import PLIOQICPhase1::*;
import PLIOQICPhase2::*;

function PlioIn rst(); PlioIn x=plioInDefault(); x.reset=True; return x; endfunction
function PlioIn bg(); PlioIn x=plioInDefault(); x.grant=True; return x; endfunction
function PlioIn bgAck(); PlioIn x=bg(); x.ack=True; return x; endfunction
function PlioIn workerAddr(Bit#(32) a,Bool rd,Bit#(4) be); PlioIn x=plioInDefault(); x.selected=True; x.adValid=True; x.ad=a; x.parValid=True; x.parity=oddParity32P2(a); x.spaceValid=True; x.space=PlioWorker; x.addressStrobe=True; x.read=rd; x.byteEnable=be; x.burst=BurstOne; return x; endfunction
function PlioIn dataNoPayload(); PlioIn x=plioInDefault(); x.dataStrobe=True; return x; endfunction
function PlioIn dataWord(Bit#(32) d,Bool good); PlioIn x=bgAck(); x.dataStrobe=True; x.adValid=True; x.ad=d; x.parValid=True; x.parity=good ? oddParity32P1(d) : (oddParity32P1(d)^4'h1); return x; endfunction
function QliIn notif(Bit#(8) ch); QliIn q=qliInDefault(); q.notificationValid=True; q.notification=NotificationRequest{channel:ch}; return q; endfunction
function QliIn dmaH2D(BurstWords w); QliIn q=qliInDefault(); q.dmaRequestValid=True; q.dmaRequest=DmaRequest{direction:HostToDevice,address:32'h4400_0000,words:w}; return q; endfunction
function QliIn dmaD2H(BurstWords w); QliIn q=qliInDefault(); q.dmaRequestValid=True; q.dmaRequest=DmaRequest{direction:DeviceToHost,address:32'h5500_0000,words:w}; return q; endfunction
function QliIn notifDma(Bit#(8) ch); QliIn q=dmaH2D(BurstOne); q.notificationValid=True; q.notification=NotificationRequest{channel:ch}; return q; endfunction

function Bool workerState(UnifiedQicState s);
 return s==UWorkerReadData || s==UWorkerWriteData || s==UWorkerOffer || s==UWorkerResponse;
endfunction
function Bool dmaState(UnifiedQicState s);
 return s==URequestDma || s==UDmaAddress || s==UDmaData || s==UDmaComplete;
endfunction
function Bool notificationState(UnifiedQicState s);
 return s==URequestNotification || s==UNotificationAddress || s==UNotificationData;
endfunction

function PlioIn pi(Bit#(16) c);
 PlioIn x=plioInDefault();
 if(c==0 || c==5 || c==8 || c==20 || c==26 || c==289 || c==292) x=rst();
 else if(c==1) x=workerAddr(32'h0000_0100,True,4'hf);
 else if(c==2 || c==4) x=dataNoPayload();
 else if(c==6) x=workerAddr(32'h0000_0104,False,4'hf);
 else if(c==7) begin x=dataNoPayload(); x.adValid=True; x.ad=32'ha5a5_5a5a; x.parValid=True; x.parity=oddParity32P2(32'ha5a5_5a5a)^4'h1; end
 else if(c==10 || c==11 || c==12 || c==13) begin x=bg(); if(c==11 || c==12) x.ack=True; end
 else if(c==15 || c==16 || c==17) begin x=bg(); if(c==16) x.ack=True; if(c==17) begin x.ack=True; x.adValid=True; x.ad=32'h1122_3344; x.parValid=True; x.parity=oddParity32P1(32'h1122_3344); end end
 else if(c==22 || c==23 || c==24) begin x=bg(); if(c==23) x.ack=True; if(c==24) begin x.ack=True; x.adValid=True; x.ad=32'hfeed_face; x.parValid=True; x.parity=oddParity32P1(32'hfeed_face)^4'h1; end end
 else if(c==28 || c==29 || (c>=30 && c<=285)) begin x=bg(); if(c==29) x.ack=True; end
 else if(c==287) x=bg();
 else if(c==291) x=workerAddr(32'h0000_0108,True,4'hf);
 return x;
endfunction

function QliIn qi(Bit#(16) c);
 QliIn q=qliInDefault();
 if(c==3) q.mmioReady=True;
 else if(c==4) begin q.mmioResponseValid=True; q.mmioResponse=mmioReadOk(32'hdead_beef); end
 else if(c>=9 && c<=12) q=notifDma(2);
 else if(c==13 || c==14 || c==15 || c==16) q=dmaH2D(BurstOne);
 else if(c==17) begin q=notif(1); q.dmaReadReady=False; end
 else if(c==18) begin q=notif(1); q.dmaReadReady=True; end
 else if(c==19) begin q=notif(1); q.dmaCompletionReady=True; end
 else if(c>=21 && c<=25) begin q=dmaH2D(BurstFour); if(c==25) q.dmaCompletionReady=True; end
 else if(c>=27 && c<=286) begin q=dmaD2H(BurstOne); if(c==286) q.dmaCompletionReady=True; end
 else if(c==287 || c==288) q=notif(0);
 return q;
endfunction

module mkTbQICPhase7(Empty);
 PLIOQICIfc dut <- mkPLIOQIC;
 Reg#(Bit#(16)) c <- mkReg(0);
 Reg#(Bool) managerAddressSeen <- mkReg(False);
 rule run;
  PlioIn i=pi(c); QliIn q=qi(c); PlioOut o=dut.drivePlio(i,q); QliOut z=dut.driveQli(i,q); UnifiedQicState s=dut.debugState;

  if(o.ack && o.err) begin $display("FAIL invariant ack_and_err c=%0d",c); $finish(1); end
  if(o.addressStrobe && o.dataStrobe) begin $display("FAIL invariant as_and_ds c=%0d",c); $finish(1); end
  if((s==UDmaAddress || s==UDmaData || s==UNotificationAddress || s==UNotificationData)
     && (o.addressStrobe || o.dataStrobe || o.adValid || o.parValid || o.spaceValid) && !i.grant) begin
    $display("FAIL invariant manager_drive_without_bg c=%0d state=%0d",c,pack(s)); $finish(1);
  end
  if((s==UDmaAddress || s==UNotificationAddress) && o.spaceValid && o.space==PlioWorker) begin
    $display("FAIL invariant manager_space_worker c=%0d",c); $finish(1);
  end
  if(s==UDmaAddress && o.addressStrobe && (!o.spaceValid || o.space!=PlioHostDma || o.byteEnable!=4'hf)) begin
    $display("FAIL invariant dma_address_control c=%0d",c); $finish(1);
  end
  if(s==UNotificationAddress && o.addressStrobe && (!o.spaceValid || o.space!=PlioController || o.byteEnable!=4'hf || o.burst!=BurstOne)) begin
    $display("FAIL invariant notification_shape c=%0d",c); $finish(1);
  end
  if(i.reset && (o.request || o.addressStrobe || o.dataStrobe || o.adValid || o.parValid || o.ack || o.err || !z.reset)) begin
    $display("FAIL invariant reset_not_quiescent c=%0d",c); $finish(1);
  end
  if((o.ack || o.err) && !(workerState(s) || (s==UIdle && i.selected && i.spaceValid && i.space==PlioWorker && i.addressStrobe))) begin
    $display("FAIL invariant worker_response_context c=%0d state=%0d",c,pack(s)); $finish(1);
  end
  if(dmaState(s) && q.notificationValid && notificationState(s)) begin
    $display("FAIL invariant dma_preempted c=%0d",c); $finish(1);
  end

  if(!i.grant) managerAddressSeen <= False;
  else if(o.addressStrobe) begin
    if(managerAddressSeen) begin $display("FAIL invariant second_transaction_same_grant c=%0d",c); $finish(1); end
    managerAddressSeen <= True;
  end

  // A completed Notification must not let a waiting DMA consume the same continuously-held grant.
  if(c==13 && z.dmaRequestReady) begin $display("FAIL invariant fresh_grant_ready c=13"); $finish(1); end
  // Once BG drops, the DMA may become eligible immediately.
  if(c==14 && !z.dmaRequestReady) begin $display("FAIL invariant fresh_grant_release c=14"); $finish(1); end
  // Notification injected while DMA is active must not preempt the transfer.
  if((c==17 || c==18) && notificationState(s)) begin $display("FAIL invariant notification_preempted_dma c=%0d",c); $finish(1); end
  // Bad H2D parity must produce a parity-error completion with zero acknowledged words.
  if(c==25 && (!z.dmaCompletionValid || z.dmaCompletion.status!=DmaParityError || z.dmaCompletion.wordsCompleted!=0)) begin
    $display("FAIL fault_sweep parity_completion state=%0d valid=%0d status=%0d words=%0d",pack(s),pack(z.dmaCompletionValid),pack(z.dmaCompletion.status),z.dmaCompletion.wordsCompleted); $finish(1);
  end
  // A stalled D2H producer must timeout instead of retaining BG forever.
  if(c==286 && (!z.dmaCompletionValid || z.dmaCompletion.status!=DmaTimeout || z.dmaCompletion.wordsCompleted!=0)) begin
    $display("FAIL fault_sweep producer_timeout state=%0d valid=%0d status=%0d words=%0d",pack(s),pack(z.dmaCompletionValid),pack(z.dmaCompletion.status),z.dmaCompletion.wordsCompleted); $finish(1);
  end
  // Inject reset while a manager request and worker transaction are active.
  if(c==289 && s!=URequestNotification) begin $display("FAIL fault_sweep manager_reset_not_active state=%0d",pack(s)); $finish(1); end
  if(c==290 && s!=UIdle) begin $display("FAIL fault_sweep manager_reset_priority state=%0d",pack(s)); $finish(1); end
  if(c==292 && s!=UWorkerReadData) begin $display("FAIL fault_sweep worker_reset_not_active state=%0d",pack(s)); $finish(1); end
  if(c==293 && s!=UIdle) begin $display("FAIL fault_sweep worker_reset_priority state=%0d",pack(s)); $finish(1); end

  dut.advance(i,q);
  if(c==293) begin $display("PASS QIC Phase7 global safety and fault sweep"); $finish(0); end
  else c<=c+1;
 endrule
endmodule

endpackage
