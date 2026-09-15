package TbQICPhase5;

import QLITypes::*;
import QICInterfaces::*;
import PLIOQICPhase1::*;
import PLIOQICPhase5::*;

function PlioIn busStim(Bool grant, Bool ack, Bool err);
    PlioIn x = plioInDefault();
    x.grant = grant;
    x.ack = ack;
    x.err = err;
    return x;
endfunction

function QliIn reqStim(BurstWords words);
    QliIn q = qliInDefault();
    q.dmaRequestValid = True;
    q.dmaRequest = DmaRequest { direction: DeviceToHost, address: 32'h3300_2000, words: words };
    return q;
endfunction

function QliIn wordStim(Bit#(32) data);
    QliIn q = qliInDefault();
    q.dmaWriteValid = True;
    q.dmaWrite = DmaWord { data: data };
    return q;
endfunction

function PlioIn piFor(Bit#(16) c);
    if (c == 0 || c == 14 || c == 25) begin
        PlioIn r = plioInDefault(); r.reset = True; return r;
    end
    if (c == 2 || c == 3 || c == 4 || (c >= 5 && c <= 11)) begin
        Bool a = c == 4 || c == 7 || c == 9;
        Bool e = c == 11;
        return busStim(True, a, e);
    end
    if (c == 16 || c == 17 || (c >= 18 && c <= 22)) begin
        Bool a = c == 17 || c == 19 || c == 21;
        return busStim(True, a, False);
    end
    if (c == 23 || c == 24) return busStim(False, False, False);
    if (c == 27 || c == 28 || (c >= 29 && c <= 285)) begin
        Bool a = c == 28;
        return busStim(True, a, False);
    end
    return plioInDefault();
endfunction

function QliIn qiFor(Bit#(16) c);
    if (c == 1 || c == 15) return reqStim(BurstFour);
    if (c == 26) return reqStim(BurstOne);
    case (c)
        5: return wordStim(32'h0000_0011);
        8: return wordStim(32'h0000_0022);
        10: return wordStim(32'h0000_0033);
        18: return wordStim(32'h0000_00aa);
        20: return wordStim(32'h0000_00bb);
        22: return wordStim(32'h0000_00cc);
        13, 24, 286: begin QliIn q = qliInDefault(); q.dmaCompletionReady = True; return q; end
        default: return qliInDefault();
    endcase
endfunction

function String evFor(Bit#(16) c);
    if (c == 0 || c == 14 || c == 25) return "reset";
    if (c == 1 || c == 2 || c == 15 || c == 16 || c == 26 || c == 27) return "manager_request";
    if (c == 3 || c == 4 || c == 17 || c == 28) return "manager_address";
    if (c == 11 || c == 23 || c == 285) return "fault";
    if (c == 12 || c == 13 || c == 24 || c == 286) return "dma_complete";
    return "dma_data";
endfunction

function Bit#(8) statusCode(DmaStatus s);
    return zeroExtend(pack(s));
endfunction

function Action emitTrace(Bit#(16) c, PlioIn pi, QliIn qi, PlioOut po, QliOut qo);
    Bit#(1) drqv = pack(qi.dmaRequestValid);
    Bit#(1) ddir = qi.dmaRequestValid ? pack(qi.dmaRequest.direction) : 0;
    Bit#(32) daddr = qi.dmaRequestValid ? qi.dmaRequest.address : 0;
    Bit#(2) dwords = qi.dmaRequestValid ? pack(qi.dmaRequest.words) : 0;
    Bit#(1) dwv = pack(qi.dmaWriteValid);
    Bit#(32) dwd = qi.dmaWriteValid ? qi.dmaWrite.data : 0;
    Bit#(1) compv = pack(qo.dmaCompletionValid);
    Bit#(8) comps = qo.dmaCompletionValid ? statusCode(qo.dmaCompletion.status) : 0;
    Bit#(5) compw = qo.dmaCompletionValid ? qo.dmaCompletion.wordsCompleted : 0;
    action
        $display("TRACE|v1|c=%08x|pi=%0d.%0d.%0d.%0d.%08x.%0d.%01x.%0d.%01x.%0d.%0d.%01x.%01x.%0d.%0d.%0d|qi=0.0.0.00000000.%0d.%0d.%08x.%0d.0.%0d.%08x.%0d.0.0|po=%0d.%0d.%08x.%0d.%01x.%0d.%01x.%0d.%0d.%01x.%01x.%0d.%0d.%0d|qo=%0d.0.00000000.0.0.00000000.0.0.%0d.0.00000000.%0d.%0d.%02x.%01x.0|ev=%s",
            zeroExtend(c),
            pack(pi.reset), pack(pi.selected), pack(pi.grant), pack(pi.adValid), pi.ad,
            pack(pi.parValid), pi.par, pack(pi.spaceValid), pack(pi.space),
            pack(pi.addressStrobe), pack(pi.read), pi.byteEnable, pack(pi.burst),
            pack(pi.dataStrobe), pack(pi.ack), pack(pi.err),
            drqv, ddir, daddr, dwords, dwv, dwd, pack(qi.dmaCompletionReady),
            pack(po.request), pack(po.adValid), po.ad, pack(po.parValid), po.par,
            pack(po.spaceValid), pack(po.space), pack(po.addressStrobe), pack(po.read),
            po.byteEnable, pack(po.burst), pack(po.dataStrobe), pack(po.ack), pack(po.err),
            pack(qo.reset), pack(qo.dmaRequestReady), pack(qo.dmaWriteReady), compv, comps, compw,
            evFor(c));
    endaction
endfunction

module mkTbQICPhase5(Empty);
    PLIOQICPhase5Ifc dut <- mkPLIOQICPhase5;
    Reg#(Bit#(16)) cycle <- mkReg(0);

    rule run;
        PlioIn pi = piFor(cycle);
        QliIn qi = qiFor(cycle);
        PlioOut po = dut.drivePlio(pi, qi);
        QliOut qo = dut.driveQli(pi, qi);

        if (cycle == 1 && !qo.dmaRequestReady) begin $display("FAIL D2H request not accepted"); $finish(1); end
        if (cycle == 3 && (!po.addressStrobe || po.read || po.space != PlioHostDma || po.byteEnable != 4'hf || po.burst != BurstFour)) begin
            $display("FAIL D2H address image"); $finish(1);
        end
        if (cycle == 5 && !qo.dmaWriteReady) begin $display("FAIL first local word not requested"); $finish(1); end
        if ((cycle == 6 || cycle == 7) && (!po.dataStrobe || !po.adValid || po.ad != 32'h11 || !po.parValid || po.par != oddParity32P1(32'h11))) begin
            $display("FAIL target wait did not hold first word stable"); $finish(1);
        end
        if (cycle == 11 && (!po.dataStrobe || po.ad != 32'h33)) begin $display("FAIL third word not driven on ERR cycle"); $finish(1); end
        if (cycle == 12 && (!qo.dmaCompletionValid || qo.dmaCompletion.status != DmaBusError || qo.dmaCompletion.wordsCompleted != 2)) begin
            $display("FAIL partial BusError completion"); $finish(1);
        end
        if (cycle == 23 && (po.dataStrobe || po.adValid)) begin $display("FAIL drove PLIO after BG loss"); $finish(1); end
        if (cycle == 24 && (!qo.dmaCompletionValid || qo.dmaCompletion.status != DmaProtocolError || qo.dmaCompletion.wordsCompleted != 2)) begin
            $display("FAIL BG-loss ProtocolError completion"); $finish(1);
        end
        if (cycle == 284 && qo.dmaWriteReady) begin $display("FAIL producer-ready remained asserted at timeout boundary"); $finish(1); end
        if (cycle == 285 && (!qo.dmaCompletionValid || qo.dmaCompletion.status != DmaTimeout || qo.dmaCompletion.wordsCompleted != 0)) begin
            $display("FAIL local producer timeout completion"); $finish(1);
        end

        emitTrace(cycle, pi, qi, po, qo);
        dut.advance(pi, qi);

        if (cycle == 286) begin
            $display("PASS QIC Phase5 D2H differential fixture");
            $finish(0);
        end
        cycle <= cycle + 1;
    endrule
endmodule

endpackage
