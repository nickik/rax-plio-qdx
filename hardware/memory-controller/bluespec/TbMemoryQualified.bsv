package TbMemoryQualified;
import MemoryController::*;
(* synthesize *)
module mkTbMemoryQualified(Empty);
    MemoryControllerIfc mc <- mkMemoryController;
    Reg#(Bit#(4)) test <- mkReg(0);
    Reg#(Bit#(2)) phase <- mkReg(0);
    Reg#(Bit#(16)) watchdog <- mkReg(0);
    rule tick;
      watchdog<=watchdog+1;
      if(watchdog==1000) begin $display("FAIL qualifier watchdog");$finish(1);end
    endrule
    rule issue(phase==0);
      Bit#(2) kind=test==0 || test==1 || test==3 || test==7 ? 1 : test==2 || test==4 ? 2 : test==5 ? 3 : 0;
      Bit#(4) be=test==0 || test==7 ? 3 : test==1 ? 12 : test==3 ? 15 : test==4 ? 3 : 15;
      mc.hostReadQualified(kind,test==7 ? 32'h1001 : 32'h1000,be);phase<=1;
    endrule
    rule accept(phase==1 && mc.backendRequestValid);
      if(test>=3 || mc.backendValidate || mc.backendWrite || mc.backendAccessKind!=(test==2 ? 2 : 1) || mc.backendWriteData!=0) begin $display("FAIL qualified forwarding/rejection");$finish(1);end
      mc.backendRequestAccepted;phase<=2;
    endrule
    rule respond(phase==2 && mc.backendResponseReady);
      mc.backendRespond(False,True,32'h11223344);phase<=3;
    endrule
    rule retire((phase==1 || phase==3) && mc.hostResponseValid);
      if(mc.hostResponseFault!=(test>=3) || mc.hostReadDataValid!=(test<3) || (test<3 && mc.hostReadData!=32'h11223344)) begin $display("FAIL qualified response test=%0d",test);$finish(1);end
      mc.hostResponseConsumed;
      if(test==7) begin $display("PASS qualified instruction halves/page-table full-word; reserved/data kind, BE and alignment rejection");$finish(0);end
      test<=test+1;phase<=0;
    endrule
endmodule
endpackage
