package TbQLI16FaultHardening;

import QLITypes::*;
import QICInterfaces::*;
import QLI16Encoding::*;
import QLI16Codec::*;
import PTIEncoding::*;
import PLIOTx::*;

module mkTbQLI16FaultHardening(Empty);
    QLI16CodecIfc c <- mkQLI16Codec;
    PLIOTxIfc tx <- mkPLIOTx;
    Reg#(Bit#(4)) phase <- mkReg(0);
    Reg#(Qli16Token) held <- mkReg(q16Token(0,Q16Idle,0));

    rule loadBackpressure (phase==0);
        QliOut q=qliOutDefault();
        q.mmioRequestValid=True;
        q.mmioRequest=MmioRequest { address:32'h100, write:False, byteEnable:4'hf, writeData:0 };
        c.load(q,qliInDefault());
        phase<=1;
    endrule

    rule slot0 (phase==1);
        c.step;
        phase<=2;
    endrule

    rule observeHeld1 (phase==2);
        Qli16Slot s=c.currentSlot;
        if (!s.valid || s.ack) begin $display("FAIL expected held final QLI-16 token"); $finish(1); end
        held<=s.token;
        c.step;
        phase<=3;
    endrule

    rule reload (phase==3 && c.cycleComplete);
        QliOut q=qliOutDefault();
        q.mmioRequestValid=True;
        q.mmioRequest=MmioRequest { address:32'h100, write:False, byteEnable:4'hf, writeData:0 };
        c.load(q,qliInDefault());
        phase<=4;
    endrule

    rule observeHeld2 (phase==4);
        Qli16Slot s=c.currentSlot;
        if (!s.valid || s.ack || s.token!=held) begin
            $display("FAIL backpressured QLI-16 token was not stable"); $finish(1);
        end

        QicPtiDrive q=qicPtiDriveDefault();
        q.driveEnable=True; q.responseEnable=True; q.responseAck=True; q.busRequest=True;
        BackplaneDrive bp=tx.driveBackplane(True,q,backplaneSampleDefault());
        if (bp!=backplaneDriveDefault()) begin
            $display("FAIL PLIO-TX drove bus during reset"); $finish(1);
        end
        tx.advance(True,q,backplaneSampleDefault());

        $display("FAULTTRACE|v1|case=backpressure_reset|stable=1|tristate=1");
        c.resetCodec;
        phase<=5;
    endrule

    rule injectMalformed (phase==5);
        c.injectRaw(q16Token(1,Q16DmaCompletion,16'hff00));
        phase<=6;
    endrule

    rule checkMalformed (phase==6);
        if (!c.protocolFault) begin $display("FAIL malformed QLI-16 token not detected"); $finish(1); end
        c.resetCodec;
        phase<=7;
    endrule

    rule checkRecovery (phase==7);
        if (c.protocolFault) begin $display("FAIL QLI-16 fault did not clear on reset"); $finish(1); end
        $display("FAULTTRACE|v1|case=malformed_reset|fault=1|recovered=1");
        $display("PASS QLI-16 fault hardening");
        $finish(0);
    endrule
endmodule

endpackage
