package TbQLI16Codec;

import QLITypes::*;
import QICInterfaces::*;
import QLI16Encoding::*;
import QLI16Codec::*;

function QliOut qicStimulus(Bit#(8) c);
    QliOut q = qliOutDefault();
    MmioRequest mmio = MmioRequest { address:32'h0000_0100, write:False, byteEnable:4'hf, writeData:0 };
    DmaRequest request = DmaRequest { direction:DeviceToHost, address:32'h1234_5000, words:BurstFour };
    DmaCompletion completion = DmaCompletion { status:DmaBusError, wordsCompleted:3 };
    case (c)
        1,2: begin q.mmioRequestValid=True; q.mmioRequest=mmio; end
        4: q.mmioResponseReady=True;
        5,6: q.dmaRequestReady=True;
        7: begin q.dmaCompletionValid=True; q.dmaCompletion=completion; end
        9: q.notificationReady=True;
        default: begin end
    endcase
    return q;
endfunction

function QliIn deviceStimulus(Bit#(8) c);
    QliIn d = qliInDefault();
    MmioResponse response = mmioReadOk(32'h89ab_cdef);
    DmaRequest request = DmaRequest { direction:DeviceToHost, address:32'h1234_5000, words:BurstFour };
    NotificationRequest n = NotificationRequest { channel:3 };
    case (c)
        2: d.mmioReady=True;
        3,4: begin d.mmioResponseValid=True; d.mmioResponse=response; end
        5,6: begin d.dmaRequestValid=True; d.dmaRequest=request; end
        7: d.dmaCompletionReady=True;
        8,9: begin d.notificationValid=True; d.notification=n; end
        default: begin end
    endcase
    return d;
endfunction

function Action showIdle(Bit#(8) c, Bit#(1) s);
    action
        $display("Q16TRACE|v1|c=%02x|s=%0d|v=0|a=0|d=0|t=0|ld=0000",c,s);
    endaction
endfunction

function Action showSlot(Bit#(8) c, Bit#(1) s, Qli16Slot x);
    action
        $display("Q16TRACE|v1|c=%02x|s=%0d|v=%0d|a=%0d|d=%0d|t=%0d|ld=%04x",
            c,s,pack(x.valid),pack(x.ack),x.token.direction,pack(x.token.kind),x.token.payload);
    endaction
endfunction

module mkTbQLI16Codec(Empty);
    QLI16CodecIfc dut <- mkQLI16Codec;
    Reg#(Bit#(8)) c <- mkReg(0);
    Reg#(Bit#(3)) phase <- mkReg(0);

    rule prepareReset (phase==0 && (c==0 || c==11));
        dut.resetCodec;
        phase<=5;
    endrule

    rule prepareInject (phase==0 && c==10);
        dut.injectRaw(q16Token(1,Q16Notification,16'h8000));
        phase<=4;
    endrule

    rule prepareLoad (phase==0 && c!=0 && c!=10 && c!=11);
        dut.load(qicStimulus(c),deviceStimulus(c));
        phase<=1;
    endrule

    rule afterReset (phase==5);
        phase<=1;
    endrule

    rule afterInject (phase==4);
        dut.load(qicStimulus(c),deviceStimulus(c));
        phase<=1;
    endrule

    rule slot0Idle (phase==1 && (c==0 || c==11));
        showIdle(c,0);
        phase<=2;
    endrule

    rule slot0Active (phase==1 && c!=0 && c!=11);
        Qli16Slot x=dut.currentSlot;
        showSlot(c,0,x);
        dut.step;
        phase<=2;
    endrule

    rule slot1Idle (phase==2 && (c==0 || c==11));
        showIdle(c,1);
        phase<=3;
    endrule

    rule slot1Active (phase==2 && c!=0 && c!=11);
        Qli16Slot x=dut.currentSlot;
        showSlot(c,1,x);
        dut.step;
        phase<=3;
    endrule

    rule result (phase==3);
        QliIn qi=dut.toQic;
        QliOut qo=dut.toDevice;
        $display("Q16RESULT|v1|c=%02x|mr=%0d|mrv=%0d|drq=%0d|drr=%0d|dw=%0d|dc=%0d|nv=%0d|nr=%0d|fault=%0d",
            c,pack(qi.mmioReady),pack(qi.mmioResponseValid),pack(qi.dmaRequestValid),pack(qi.dmaReadReady),
            pack(qi.dmaWriteValid),pack(qo.dmaCompletionValid),pack(qi.notificationValid),pack(qo.notificationReady),pack(dut.protocolFault));
        if (c==11) begin
            $display("PASS QLI-16 stateful codec differential fixture");
            $finish(0);
        end
        else begin c<=c+1; phase<=0; end
    endrule
endmodule

endpackage
