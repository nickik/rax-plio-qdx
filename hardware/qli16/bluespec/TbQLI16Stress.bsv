package TbQLI16Stress;

import QLITypes::*;
import QICInterfaces::*;
import QLI16Encoding::*;
import QLI16Codec::*;

typedef Bit#(3) SrcSel;

function Bit#(16) lfsrStep(Bit#(16) x0);
    Bit#(16) x=x0;
    x = x ^ (x << 7);
    x = x ^ (x >> 9);
    x = x ^ (x << 8);
    return x;
endfunction

function Bit#(32) slotWord(Qli16Slot s, Bool high);
    Bit#(32) v=zeroExtend(s.token.payload);
    v = v ^ (zeroExtend(pack(s.token.kind)) << 17);
    v = v ^ (zeroExtend(s.token.direction) << 21);
    v = v ^ (zeroExtend(pack(s.valid)) << 22);
    v = v ^ (zeroExtend(pack(s.ack)) << 23);
    if (high) v={v[20:0],v[31:21]};
    return v;
endfunction

function Bit#(32) mixChecksum(Bit#(32) checksum, Bit#(32) cycle, Qli16Slot s0, Qli16Slot s1, QliIn qi, QliOut qo, Bool fault);
    Bit#(32) word=slotWord(s0,False)^slotWord(s1,True);
    word = word ^ (zeroExtend(pack(qi.mmioReady)) << 1);
    word = word ^ (zeroExtend(pack(qi.mmioResponseValid)) << 2);
    word = word ^ (zeroExtend(pack(qi.dmaRequestValid)) << 3);
    word = word ^ (zeroExtend(pack(qi.dmaReadReady)) << 4);
    word = word ^ (zeroExtend(pack(qi.dmaWriteValid)) << 5);
    word = word ^ (zeroExtend(pack(qi.dmaCompletionReady)) << 6);
    word = word ^ (zeroExtend(pack(qi.notificationValid)) << 7);
    word = word ^ (zeroExtend(pack(qo.mmioRequestValid)) << 8);
    word = word ^ (zeroExtend(pack(qo.mmioResponseReady)) << 9);
    word = word ^ (zeroExtend(pack(qo.dmaRequestReady)) << 10);
    word = word ^ (zeroExtend(pack(qo.dmaReadValid)) << 11);
    word = word ^ (zeroExtend(pack(qo.dmaWriteReady)) << 12);
    word = word ^ (zeroExtend(pack(qo.dmaCompletionValid)) << 13);
    word = word ^ (zeroExtend(pack(qo.notificationReady)) << 14);
    word = word ^ (zeroExtend(pack(fault)) << 15);
    Bit#(32) rot={checksum[26:0],checksum[31:27]};
    return rot ^ word ^ cycle;
endfunction

module mkTbQLI16Stress(Empty);
    QLI16CodecIfc dut <- mkQLI16Codec;
    Reg#(Bit#(13)) cycle <- mkReg(0);
    Reg#(Bit#(3)) phase <- mkReg(0);
    Reg#(Bit#(16)) lfsr <- mkReg(16'hace1);
    Reg#(Bit#(32)) checksum <- mkReg(32'h514c_4931);
    Reg#(SrcSel) qsrc <- mkReg(0);
    Reg#(SrcSel) dsrc <- mkReg(0);
    Reg#(Bit#(9)) resetCountdown <- mkReg(0);
    Reg#(Bit#(5)) resetCount <- mkReg(0);
    Reg#(Qli16Slot) slot0Reg <- mkReg(idleSlot());
    Reg#(Qli16Slot) slot1Reg <- mkReg(idleSlot());
    Reg#(Bool) resetCycle <- mkReg(False);

    rule prepare (phase==0 && cycle<4096);
        if (resetCountdown==0) begin
            dut.resetCodec;
            qsrc<=0; dsrc<=0;
            slot0Reg<=idleSlot(); slot1Reg<=idleSlot();
            resetCycle<=True;
            phase<=3;
        end
        else begin
            SrcSel qs=qsrc;
            SrcSel ds=dsrc;
            if (qs==0) begin
                case (lfsr[1:0])
                    0: qs=1;
                    1: qs=2;
                    2: qs=3;
                    default: qs=0;
                endcase
            end
            if (ds==0) begin
                case (lfsr[4:2])
                    0: ds=1;
                    1: ds=2;
                    2: ds=3;
                    3: ds=4;
                    default: ds=0;
                endcase
            end

            QliOut q=qliOutDefault();
            case (qs)
                1: begin
                    q.mmioRequestValid=True;
                    q.mmioRequest=MmioRequest { address:32'h100, write:False, byteEnable:4'hf, writeData:0 };
                end
                2: begin q.dmaReadValid=True; q.dmaRead=DmaWord { data:32'h1122_3344 }; end
                3: begin q.dmaCompletionValid=True; q.dmaCompletion=DmaCompletion { status:DmaBusError, wordsCompleted:2 }; end
                default: begin end
            endcase
            q.mmioResponseReady=lfsr[8]==1;
            q.dmaRequestReady=lfsr[9]==1;
            q.dmaWriteReady=lfsr[10]==1;
            q.notificationReady=lfsr[11]==1;

            QliIn d=qliInDefault();
            d.mmioReady=lfsr[4]==1;
            d.dmaReadReady=lfsr[5]==1;
            d.dmaCompletionReady=lfsr[6]==1;
            case (ds)
                1: begin d.mmioResponseValid=True; d.mmioResponse=mmioReadOk(32'h3344_5566); end
                2: begin
                    d.dmaRequestValid=True;
                    d.dmaRequest=DmaRequest { direction:DeviceToHost, address:32'h1234_5000, words:BurstFour };
                end
                3: begin d.dmaWriteValid=True; d.dmaWrite=DmaWord { data:32'h5566_7788 }; end
                4: begin d.notificationValid=True; d.notification=NotificationRequest { channel:2 }; end
                default: begin end
            endcase

            qsrc<=qs; dsrc<=ds;
            dut.load(q,d);
            resetCycle<=False;
            phase<=1;
        end
    endrule

    rule slot0 (phase==1);
        Qli16Slot s=dut.currentSlot;
        slot0Reg<=s;
        dut.step;
        phase<=2;
    endrule

    rule slot1 (phase==2);
        Qli16Slot s=dut.currentSlot;
        slot1Reg<=s;
        dut.step;
        phase<=3;
    endrule

    rule collect (phase==3 && cycle<4096);
        QliIn qi=qliInDefault();
        QliOut qo=qliOutDefault();
        Bool fault=False;
        if (!resetCycle) begin
            qi=dut.toQic;
            qo=dut.toDevice;
            fault=dut.protocolFault;
            if (fault) begin $display("FAIL legal QLI-16 stress stimulus faulted at cycle %0d",cycle); $finish(1); end

            case (qsrc)
                1: if (qi.mmioReady) qsrc<=0;
                2: if (qi.dmaReadReady) qsrc<=0;
                3: if (qi.dmaCompletionReady) qsrc<=0;
                default: begin end
            endcase
            case (dsrc)
                1: if (qo.mmioResponseReady) dsrc<=0;
                2: if (qo.dmaRequestReady) dsrc<=0;
                3: if (qo.dmaWriteReady) dsrc<=0;
                4: if (qo.notificationReady) dsrc<=0;
                default: begin end
            endcase
            resetCountdown<=resetCountdown-1;
        end
        else begin
            resetCountdown<=256;
            resetCount<=resetCount+1;
        end

        checksum<=mixChecksum(checksum,zeroExtend(cycle),slot0Reg,slot1Reg,qi,qo,fault);
        lfsr<=lfsrStep(lfsr);
        cycle<=cycle+1;
        phase<=0;
    endrule

    rule finish (phase==0 && cycle==4096);
        $display("STRESSTRACE|v1|cycles=4096|resets=%0d|checksum=%08x|lfsr=%04x",resetCount,checksum,lfsr);
        $display("PASS 4096-cycle deterministic QLI-16 stress conformance");
        $finish(0);
    endrule
endmodule

endpackage
