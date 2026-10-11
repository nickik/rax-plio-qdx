package TbMemoryControllerInstructionWord;
import MemoryController::*;
module mkTbMemoryControllerInstructionWord(Empty);
 MemoryControllerIfc mc <- mkMemoryController;
 Reg#(Bit#(3)) item <- mkReg(0);
 Reg#(Bit#(2)) phase <- mkReg(0);
 Reg#(Bit#(16)) cycles <- mkReg(0);
 function Bit#(4) lanes();
  case(item)
   0:return 3; 1:return 12; 2:return 15; 3:return 1;
   4:return 5; 5:return 0; default:return 15;
  endcase
 endfunction
 function Bool permitted();return item<3 || item==6;endfunction
 rule tick;cycles<=cycles+1;if(cycles==200)begin $display("FAIL instruction word controller watchdog");$finish(1);end endrule
 rule issue(phase==0 && mc.hostRequestReady);mc.hostReadQualified(item==6 ? 2:1,'h100,lanes());phase<=1;endrule
 rule backend(phase==1 && mc.backendRequestValid);
  if(!permitted() || mc.backendAccessKind!=(item==6 ? 2:1) || mc.backendByteEnable!=lanes() || mc.backendAddress!='h100 || mc.backendWrite)begin $display("FAIL classified request shape item=%0d",item);$finish(1);end
  mc.backendRequestAccepted;phase<=2;
 endrule
 rule reply(phase==2 && mc.backendResponseReady);mc.backendRespond(False,True,'h11223344);phase<=3;endrule
 rule rejected(phase==1 && mc.hostResponseValid);
  if(permitted() || !mc.hostResponseFault || mc.hostReadDataValid)begin $display("FAIL malformed fetch accepted item=%0d",item);$finish(1);end
  mc.hostResponseConsumed;item<=item+1;phase<=0;
 endrule
 rule accepted(phase==3 && mc.hostResponseValid);
  if(mc.hostResponseFault || !mc.hostReadDataValid || mc.hostReadData!='h11223344)begin $display("FAIL instruction word response item=%0d",item);$finish(1);end
  mc.hostResponseConsumed;item<=item+1;phase<=0;
  if(item==6)begin $display("PASS qualified halfword/full-word fetch, malformed masks and word walker");$finish(0);end
 endrule
endmodule
endpackage
