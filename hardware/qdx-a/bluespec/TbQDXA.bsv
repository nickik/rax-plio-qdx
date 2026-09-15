package TbQDXA;

import Vector::*;
import QLITypes::*;
import QICInterfaces::*;
import QDXAQicPort::*;
import QDXAEndpointIfc::*;
import QDXA::*;

function QliOut mmioWrite(Bit#(32) address, Bit#(4) be, Bit#(32) data);
    QliOut q = qliOutDefault();
    q.mmioRequestValid = True;
    q.mmioRequest = MmioRequest {
        address: address,
        write: True,
        byteEnable: be,
        writeData: data
    };
    return q;
endfunction

function QliOut acceptMmioResponse();
    QliOut q = qliOutDefault();
    q.mmioResponseReady = True;
    return q;
endfunction

function Bool isWriteOk(QliIn d);
    return d.mmioResponseValid && d.mmioResponse.status == MmioWriteOk;
endfunction

function QdxACompletion testCompletion();
    QdxACompletion c = replicate(0);
    c[0] = 32'hc001_0000;
    c[1] = 32'hc001_0001;
    c[2] = 32'hc001_0002;
    c[3] = 32'hc001_0003;
    return c;
endfunction

module mkTbQDXA(Empty);
    QDXAIfc dut <- mkQDXA;
    Reg#(Bit#(8)) phase <- mkReg(0);
    Reg#(Bit#(4)) dmaWord <- mkReg(0);

    rule r0 (phase == 0);
        QliOut q = qliOutDefault();
        q.reset = True;
        dut.advance(q, qdxAEndpointInDefault());
        phase <= 1;
    endrule

    rule r1 (phase == 1);
        QliOut q = mmioWrite(REG_SQ_BASE, 4'hf, 32'h1200_1000);
        QliIn d = dut.qicPort(q);
        if (!d.mmioReady) begin $display("FAIL SQ_BASE not ready"); $finish(1); end
        dut.advance(q, qdxAEndpointInDefault());
        phase <= 2;
    endrule

    rule r2 (phase == 2);
        QliOut q = acceptMmioResponse();
        QliIn d = dut.qicPort(q);
        if (!isWriteOk(d)) begin $display("FAIL SQ_BASE WriteOk"); $finish(1); end
        dut.advance(q, qdxAEndpointInDefault());
        phase <= 3;
    endrule

    rule r3 (phase == 3);
        QliOut q = mmioWrite(REG_SQ_SIZE, 4'h3, 4);
        dut.advance(q, qdxAEndpointInDefault());
        phase <= 4;
    endrule

    rule r4 (phase == 4);
        QliOut q = acceptMmioResponse();
        QliIn d = dut.qicPort(q);
        if (!isWriteOk(d)) begin $display("FAIL SQ_SIZE WriteOk"); $finish(1); end
        dut.advance(q, qdxAEndpointInDefault());
        phase <= 5;
    endrule

    rule r5 (phase == 5);
        QliOut q = mmioWrite(REG_CQ_BASE, 4'hf, 32'h2300_2000);
        dut.advance(q, qdxAEndpointInDefault());
        phase <= 6;
    endrule

    rule r6 (phase == 6);
        QliOut q = acceptMmioResponse();
        QliIn d = dut.qicPort(q);
        if (!isWriteOk(d)) begin $display("FAIL CQ_BASE WriteOk"); $finish(1); end
        dut.advance(q, qdxAEndpointInDefault());
        phase <= 7;
    endrule

    rule r7 (phase == 7);
        QliOut q = mmioWrite(REG_CQ_SIZE, 4'h3, 4);
        dut.advance(q, qdxAEndpointInDefault());
        phase <= 8;
    endrule

    rule r8 (phase == 8);
        QliOut q = acceptMmioResponse();
        QliIn d = dut.qicPort(q);
        if (!isWriteOk(d)) begin $display("FAIL CQ_SIZE WriteOk"); $finish(1); end
        dut.advance(q, qdxAEndpointInDefault());
        phase <= 9;
    endrule

    rule r9 (phase == 9);
        // ENABLE | NOTIFY_EN
        QliOut q = mmioWrite(REG_QDX_CONTROL, 4'hf, 32'h0000_0005);
        dut.advance(q, qdxAEndpointInDefault());
        phase <= 10;
    endrule

    rule r10 (phase == 10);
        QliOut q = acceptMmioResponse();
        QliIn d = dut.qicPort(q);
        if (!isWriteOk(d)) begin $display("FAIL QDX_CONTROL WriteOk"); $finish(1); end
        dut.advance(q, qdxAEndpointInDefault());
        phase <= 11;
    endrule

    rule r11 (phase == 11);
        QliOut q = mmioWrite(REG_SQ_TAIL, 4'h3, 1);
        dut.advance(q, qdxAEndpointInDefault());
        phase <= 12;
    endrule

    rule r12 (phase == 12);
        QliOut q = acceptMmioResponse();
        QliIn d = dut.qicPort(q);
        if (!isWriteOk(d)) begin $display("FAIL SQ_TAIL WriteOk"); $finish(1); end
        dut.advance(q, qdxAEndpointInDefault());
        phase <= 13;
    endrule

    rule r13 (phase == 13);
        QliOut q = qliOutDefault();
        QliIn d = dut.qicPort(q);
        if (!d.dmaRequestValid || d.dmaRequest.direction != HostToDevice
            || d.dmaRequest.address != 32'h1200_1000 || d.dmaRequest.words != BurstEight) begin
            $display("FAIL SQ DMA request"); $finish(1);
        end
        q.dmaRequestReady = True;
        dut.advance(q, qdxAEndpointInDefault());
        dmaWord <= 0;
        phase <= 14;
    endrule

    rule receiveSq (phase == 14 && dmaWord < 8);
        QliOut q = qliOutDefault();
        QliIn d = dut.qicPort(q);
        if (!d.dmaReadReady) begin $display("FAIL SQ DMA read not ready"); $finish(1); end
        q.dmaReadValid = True;
        q.dmaRead = DmaWord { data: 32'ha000_0000 + zeroExtend(dmaWord) };
        dut.advance(q, qdxAEndpointInDefault());
        if (dmaWord == 7) begin
            dmaWord <= 0;
            phase <= 15;
        end
        else dmaWord <= dmaWord + 1;
    endrule

    rule r15 (phase == 15);
        QliOut q = qliOutDefault();
        QliIn d = dut.qicPort(q);
        if (!d.dmaCompletionReady) begin $display("FAIL SQ completion not ready"); $finish(1); end
        q.dmaCompletionValid = True;
        q.dmaCompletion = DmaCompletion { status: DmaOk, wordsCompleted: 8 };
        dut.advance(q, qdxAEndpointInDefault());
        phase <= 16;
    endrule

    rule r16 (phase == 16);
        QliOut q = qliOutDefault();
        QdxAEndpointOut e = dut.endpointPort(q);
        if (!e.commandValid) begin $display("FAIL command not offered"); $finish(1); end
        for (Integer i=0; i<8; i=i+1)
            if (e.command[i] != 32'ha000_0000 + fromInteger(i)) begin
                $display("FAIL command word %0d",i); $finish(1);
            end
        QdxAEndpointIn ep = qdxAEndpointInDefault();
        ep.commandReady = True;
        dut.advance(q,ep);
        phase <= 17;
    endrule

    rule r17 (phase == 17);
        QliOut q = qliOutDefault();
        QdxAEndpointOut e = dut.endpointPort(q);
        if (!e.completionReady) begin $display("FAIL completion path not ready"); $finish(1); end
        QdxAEndpointIn ep = qdxAEndpointInDefault();
        ep.completionValid = True;
        ep.completion = testCompletion();
        dut.advance(q,ep);
        phase <= 18;
    endrule

    rule r18 (phase == 18);
        QliOut q = qliOutDefault();
        QliIn d = dut.qicPort(q);
        if (!d.dmaRequestValid || d.dmaRequest.direction != DeviceToHost
            || d.dmaRequest.address != 32'h2300_2000 || d.dmaRequest.words != BurstFour) begin
            $display("FAIL CQ DMA request"); $finish(1);
        end
        q.dmaRequestReady = True;
        dut.advance(q,qdxAEndpointInDefault());
        dmaWord <= 0;
        phase <= 19;
    endrule

    rule sendCq (phase == 19 && dmaWord < 4);
        QliOut q = qliOutDefault();
        QliIn d = dut.qicPort(q);
        QdxACompletion c = testCompletion();
        Bit#(2) i = dmaWord[1:0];
        if (!d.dmaWriteValid || d.dmaWrite.data != c[i]) begin
            $display("FAIL CQ DMA word %0d",dmaWord); $finish(1);
        end
        q.dmaWriteReady = True;
        dut.advance(q,qdxAEndpointInDefault());
        if (dmaWord == 3) begin
            dmaWord <= 0;
            phase <= 20;
        end
        else dmaWord <= dmaWord + 1;
    endrule

    rule r20 (phase == 20);
        QliOut q = qliOutDefault();
        QliIn d = dut.qicPort(q);
        if (!d.dmaCompletionReady) begin $display("FAIL CQ completion not ready"); $finish(1); end
        q.dmaCompletionValid = True;
        q.dmaCompletion = DmaCompletion { status: DmaOk, wordsCompleted: 4 };
        dut.advance(q,qdxAEndpointInDefault());
        phase <= 21;
    endrule

    rule r21 (phase == 21);
        QliOut q = qliOutDefault();
        QliIn d = dut.qicPort(q);
        if (!d.notificationValid || d.notification.channel != 0) begin
            $display("FAIL Notification channel 0"); $finish(1);
        end
        q.notificationReady = True;
        dut.advance(q,qdxAEndpointInDefault());
        phase <= 22;
    endrule

    rule finish (phase == 22);
        if (dut.debugSqHead != 1 || dut.debugSqTail != 1
            || dut.debugCqHead != 0 || dut.debugCqTail != 1
            || dut.debugState != AReadyIdle) begin
            $display("FAIL final QDX-A positions/state"); $finish(1);
        end
        $display("QDXATRACE|v1|case=one_command|sqh=1|sqt=1|cqh=0|cqt=1|notify=1|error=0");
        $display("PASS minimal QDX-A chip queue path");
        $finish(0);
    endrule
endmodule

endpackage
