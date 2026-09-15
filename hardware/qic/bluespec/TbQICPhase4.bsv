package TbQICPhase4;

import QLITypes::*;
import QICInterfaces::*;
import PLIOQICPhase1::*;
import PLIOQICPhase4::*;

function PlioIn b(Bool grant);
    PlioIn x = plioInDefault();
    x.grant = grant;
    return x;
endfunction

function PlioIn rst();
    PlioIn x = b(False);
    x.reset = True;
    return x;
endfunction

function PlioIn addrAck();
    PlioIn x = b(True);
    x.ack = True;
    return x;
endfunction

function PlioIn dataBeat(Bit#(32) value, Bool badParity);
    PlioIn x = b(True);
    x.ack = True;
    x.adValid = True;
    x.ad = value;
    x.parValid = True;
    x.parity = oddParity32P1(value) ^ (badParity ? 4'h1 : 4'h0);
    return x;
endfunction

function PlioIn dataErr();
    PlioIn x = b(True);
    x.err = True;
    return x;
endfunction

function QliIn qDefault();
    return qliInDefault();
endfunction

function QliIn request(BurstWords words);
    QliIn q = qliInDefault();
    q.dmaRequestValid = True;
    q.dmaRequest = DmaRequest {
        direction: HostToDevice,
        address: 32'h2100_1000,
        words: words
    };
    return q;
endfunction

function QliIn readReady();
    QliIn q = qliInDefault();
    q.dmaReadReady = True;
    return q;
endfunction

function QliIn completionReady();
    QliIn q = qliInDefault();
    q.dmaCompletionReady = True;
    return q;
endfunction

function PlioIn piFor(Bit#(8) c);
    case (c)
        0, 17, 24: return rst();
        2, 4, 6, 7, 9, 11, 19, 22, 23, 26, 29: return b(True);
        3, 20, 27: return addrAck();
        5: return dataBeat(32'h1111_1111, False);
        8: return dataBeat(32'h2222_2222, False);
        10: return dataBeat(32'h3333_3333, False);
        12: return dataBeat(32'h4444_4444, False);
        21: return dataErr();
        28: return dataBeat(32'hfeed_beef, True);
        default: return b(False);
    endcase
endfunction

function QliIn qiFor(Bit#(8) c);
    case (c)
        1: return request(BurstFour);
        7, 9, 11, 14: return readReady();
        16, 23: return completionReady();
        18, 25: return request(BurstOne);
        default: return qDefault();
    endcase
endfunction

function String eventFor(Bit#(8) c);
    String result = "dma_data";
    if (c == 0 || c == 17 || c == 24)
        result = "reset";
    else if (c == 1 || c == 2 || c == 18 || c == 19 || c == 25 || c == 26)
        result = "manager_request";
    else if (c == 3 || c == 20 || c == 27)
        result = "manager_address";
    else if (c == 15 || c == 16 || c == 22 || c == 23 || c == 29)
        result = "dma_complete";
    else if (c == 21 || c == 28)
        result = "fault";
    return result;
endfunction

function Bit#(2) dmaDirCode(DmaDirection d);
    return d == HostToDevice ? 0 : 1;
endfunction

function Bit#(3) dmaStatusCode(DmaStatus s);
    Bit#(3) result = 0;
    case (s)
        DmaOk: result = 0;
        DmaBusError: result = 1;
        DmaParityError: result = 2;
        DmaTimeout: result = 3;
        DmaProtocolError: result = 4;
    endcase
    return result;
endfunction

function Action emitTrace(Bit#(8) cycle, PlioIn pi, QliIn qi, PlioOut po, QliOut qo);
    action
        Bit#(32) cycle32 = zeroExtend(cycle);
        Bit#(32) piAd = pi.adValid ? pi.ad : 0;
        Bit#(4) piParity = pi.parValid ? pi.parity : 0;
        Bit#(32) poAd = po.adValid ? po.ad : 0;
        Bit#(4) poParity = po.parValid ? po.parity : 0;
        $display(
            "TRACE|v1|c=%08x|pi=%0d.%0d.%0d.%0d.%08x.%0d.%01x.%0d.%01x.%0d.%0d.%01x.%01x.%0d.%0d.%0d|qi=0.0.0.00000000.%0d.%0d.%08x.%0d.%0d.0.00000000.%0d.0.0|po=%0d.%0d.%08x.%0d.%01x.%0d.%01x.%0d.%0d.%01x.%01x.%0d.%0d.%0d|qo=%0d.0.00000000.0.0.00000000.0.0.%0d.%0d.%08x.%0d.%0d.%02x.%01x.0|ev=%s",
            cycle32,
            pack(pi.reset), pack(pi.selected), pack(pi.grant), pack(pi.adValid), piAd,
            pack(pi.parValid), piParity, pack(pi.spaceValid), pack(pi.space),
            pack(pi.addressStrobe), pack(pi.read), pi.byteEnable, pack(pi.burst),
            pack(pi.dataStrobe), pack(pi.ack), pack(pi.err),
            pack(qi.dmaRequestValid), dmaDirCode(qi.dmaRequest.direction), qi.dmaRequest.address,
            pack(qi.dmaRequest.words), pack(qi.dmaReadReady), pack(qi.dmaCompletionReady),
            pack(po.request), pack(po.adValid), poAd, pack(po.parValid), poParity,
            pack(po.spaceValid), pack(po.space), pack(po.addressStrobe), pack(po.read),
            po.byteEnable, pack(po.burst), pack(po.dataStrobe), pack(po.ack), pack(po.err),
            pack(qo.reset), pack(qo.dmaRequestReady), pack(qo.dmaReadValid), qo.dmaRead.data,
            pack(qo.dmaWriteReady), pack(qo.dmaCompletionValid), dmaStatusCode(qo.dmaCompletion.status),
            qo.dmaCompletion.wordsCompleted,
            eventFor(cycle)
        );
    endaction
endfunction

module mkTbQICPhase4(Empty);
    PLIOQICPhase4Ifc dut <- mkPLIOQICPhase4;
    Reg#(Bit#(8)) cycle <- mkReg(0);

    rule run;
        PlioIn pi = piFor(cycle);
        QliIn qi = qiFor(cycle);
        PlioOut po = dut.drivePlio(pi, qi);
        QliOut qo = dut.driveQli(pi, qi);

        if (po.ack || po.err) begin
            $display("FAIL manager QIC must not source target ACK/ERR cycle=%0d", cycle);
            $finish(1);
        end
        if (po.adValid && po.dataStrobe) begin
            $display("FAIL host-to-device DMA drove AD during read data beat cycle=%0d", cycle);
            $finish(1);
        end
        if (qo.dmaWriteReady) begin
            $display("FAIL Phase4 exposed device-to-host data path cycle=%0d", cycle);
            $finish(1);
        end

        // BR before BG, but no bus ownership signals.
        if (cycle == 2 && (!po.request || po.addressStrobe || po.adValid || po.dataStrobe)) begin
            $display("FAIL BR-before-BG behavior");
            $finish(1);
        end
        if (cycle == 3 && (!po.request || !po.addressStrobe || !po.adValid || !po.parValid
            || !po.spaceValid || po.space != PlioHostDma || !po.read
            || po.byteEnable != 4'hf || po.burst != BurstFour)) begin
            $display("FAIL DMA address image");
            $finish(1);
        end
        if (cycle == 4 && !po.dataStrobe) begin
            $display("FAIL DMA read data strobe");
            $finish(1);
        end
        if (cycle == 6 && (!qo.dmaReadValid || qo.dmaRead.data != 32'h1111_1111 || !po.request)) begin
            $display("FAIL local backpressure buffer");
            $finish(1);
        end
        // Final ACKed word is local-only work: BR drops and BG may disappear.
        if (cycle == 13 && (!qo.dmaReadValid || qo.dmaRead.data != 32'h4444_4444 || po.request)) begin
            $display("FAIL final buffered word did not release PLIO ownership");
            $finish(1);
        end
        if (cycle == 14 && (!qo.dmaReadValid || qo.dmaRead.data != 32'h4444_4444 || po.request)) begin
            $display("FAIL final buffered word could not drain without BG");
            $finish(1);
        end
        if (cycle == 15 && (!qo.dmaCompletionValid || qo.dmaCompletion.status != DmaOk
            || qo.dmaCompletion.wordsCompleted != 4)) begin
            $display("FAIL successful completion accounting");
            $finish(1);
        end
        if (cycle == 22 && (!qo.dmaCompletionValid || qo.dmaCompletion.status != DmaBusError
            || qo.dmaCompletion.wordsCompleted != 0)) begin
            $display("FAIL bus-error completion accounting");
            $finish(1);
        end
        if (cycle == 29 && (!qo.dmaCompletionValid || qo.dmaCompletion.status != DmaParityError
            || qo.dmaCompletion.wordsCompleted != 0 || qo.dmaReadValid)) begin
            $display("FAIL parity error reached local device");
            $finish(1);
        end

        emitTrace(cycle, pi, qi, po, qo);
        dut.advance(pi, qi);

        if (cycle == 29) begin
            $display("PASS QIC Phase4 host-to-device DMA differential fixture");
            $finish(0);
        end
        else cycle <= cycle + 1;
    endrule
endmodule

endpackage
