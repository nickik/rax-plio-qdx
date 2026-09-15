package TbQICPhase1;

import QLITypes::*;
import QICInterfaces::*;
import PLIOQICPhase1::*;

function PlioIn resetStim();
    return PlioIn {
        reset: True, selected: False, grant: False,
        adValid: False, ad: 0, parValid: False, parity: 0,
        spaceValid: False, space: PlioWorker,
        addressStrobe: False, read: False, byteEnable: 0,
        burst: BurstOne, dataStrobe: False, ack: False, err: False
    };
endfunction

function PlioIn workerStim(
    Bit#(32) address,
    Bool read,
    Bit#(4) be,
    Bool selected,
    PlioSpace space,
    BurstWords burst,
    Bool adValid,
    Bool parValid,
    Bit#(4) parity
);
    return PlioIn {
        reset: False, selected: selected, grant: False,
        adValid: adValid, ad: address,
        parValid: parValid, parity: parity,
        spaceValid: True, space: space,
        addressStrobe: True, read: read, byteEnable: be,
        burst: burst, dataStrobe: False, ack: False, err: False
    };
endfunction

function PlioIn stimulus(Bit#(8) cycle);
    case (cycle)
        0, 5, 7, 9: return resetStim();
        1: return plioInDefault();
        2: return workerStim(32'h0000_0100, True, 4'hf, False, PlioWorker, BurstOne, True, True, oddParity32P1(32'h0000_0100));
        3: return workerStim(32'h0000_0100, True, 4'hf, True, PlioHostDma, BurstOne, True, True, oddParity32P1(32'h0000_0100));
        4: return workerStim(32'h0000_0101, True, 4'h2, True, PlioWorker, BurstOne, True, True, oddParity32P1(32'h0000_0101));
        6: return workerStim(32'h0000_0102, False, 4'hc, True, PlioWorker, BurstOne, True, True, oddParity32P1(32'h0000_0102));
        8: return workerStim(32'h0000_0104, True, 4'hf, True, PlioWorker, BurstOne, True, True, oddParity32P1(32'h0000_0104));
        10: return workerStim(32'h0200_0000, True, 4'h1, True, PlioWorker, BurstOne, True, True, oddParity32P1(32'h0200_0000));
        11: return workerStim(32'h0000_0101, True, 4'h3, True, PlioWorker, BurstOne, True, True, oddParity32P1(32'h0000_0101));
        12: return workerStim(32'h0000_0100, True, 4'hf, True, PlioWorker, BurstFour, True, True, oddParity32P1(32'h0000_0100));
        13: return workerStim(32'h0000_0100, True, 4'hf, True, PlioWorker, BurstOne, True, False, 4'h0);
        14: return workerStim(32'h0000_0100, True, 4'hf, True, PlioWorker, BurstOne, True, True, oddParity32P1(32'h0000_0100) ^ 4'h1);
        15: return workerStim(32'h0000_0100, True, 4'hf, True, PlioWorker, BurstOne, False, True, oddParity32P1(32'h0000_0100));
        default: return plioInDefault();
    endcase
endfunction

function Bool expectedAck(Bit#(8) cycle);
    return cycle == 4 || cycle == 6 || cycle == 8;
endfunction

function Bool expectedErr(Bit#(8) cycle);
    return cycle >= 10 && cycle <= 15;
endfunction

function Action emitTrace(Bit#(8) cycle, PlioIn pi, PlioOut po, QliOut qo, String ev);
    action
        Bit#(32) cycle32 = zeroExtend(cycle);
        Bit#(8) completionStatus = zeroExtend(pack(qo.dmaCompletion.status));
        $display(
            "TRACE|v1|c=%08x|pi=%0d.%0d.%0d.%0d.%08x.%0d.%01x.%0d.%01x.%0d.%0d.%01x.%01x.%0d.%0d.%0d|qi=0.0.0.00000000.0.0.00000000.0.0.0.00000000.0.0.0|po=%0d.%0d.%08x.%0d.%01x.%0d.%01x.%0d.%0d.%01x.%01x.%0d.%0d.%0d|qo=%0d.%0d.%08x.%0d.%01x.%08x.%0d.%0d.%0d.%0d.%08x.%0d.%0d.%02x.%01x.%0d|ev=%s",
            cycle32,
            pack(pi.reset), pack(pi.selected), pack(pi.grant), pack(pi.adValid), pi.ad,
            pack(pi.parValid), pi.parity, pack(pi.spaceValid), pack(pi.space),
            pack(pi.addressStrobe), pack(pi.read), pi.byteEnable, pack(pi.burst),
            pack(pi.dataStrobe), pack(pi.ack), pack(pi.err),
            pack(po.request), pack(po.adValid), po.ad, pack(po.parValid), po.parity,
            pack(po.spaceValid), pack(po.space), pack(po.addressStrobe), pack(po.read),
            po.byteEnable, pack(po.burst), pack(po.dataStrobe), pack(po.ack), pack(po.err),
            pack(qo.reset), pack(qo.mmioRequestValid), qo.mmioRequest.address,
            pack(qo.mmioRequest.write), qo.mmioRequest.byteEnable, qo.mmioRequest.writeData,
            pack(qo.mmioResponseReady), pack(qo.mmioCancel), pack(qo.dmaRequestReady),
            pack(qo.dmaReadValid), qo.dmaRead.data, pack(qo.dmaWriteReady),
            pack(qo.dmaCompletionValid), completionStatus,
            qo.dmaCompletion.wordsCompleted, pack(qo.notificationReady), ev
        );
    endaction
endfunction

module mkTbQICPhase1(Empty);
    PLIOQICPhase1Ifc dut <- mkPLIOQICPhase1;
    Reg#(Bit#(8)) cycle <- mkReg(0);

    rule run;
        PlioIn pi = stimulus(cycle);
        QliIn qi = qliInDefault();
        PlioOut po = dut.drivePlio(pi, qi);
        QliOut qo = dut.driveQli(pi, qi);

        if (po.ack != expectedAck(cycle) || po.err != expectedErr(cycle)) begin
            $display("FAIL Phase1 ACK/ERR cycle=%0d ack=%0d err=%0d", cycle, pack(po.ack), pack(po.err));
            $finish(1);
        end

        if (po.ack && po.err) begin
            $display("FAIL ACK and ERR both asserted cycle=%0d", cycle);
            $finish(1);
        end

        if (po.request || po.adValid || po.parValid || po.spaceValid || po.addressStrobe || po.dataStrobe) begin
            $display("FAIL Phase1 unexpectedly drove manager-side PLIO cycle=%0d", cycle);
            $finish(1);
        end

        if (qo.mmioRequestValid || qo.mmioResponseReady || qo.mmioCancel
            || qo.dmaRequestReady || qo.dmaReadValid || qo.dmaWriteReady
            || qo.dmaCompletionValid || qo.notificationReady) begin
            $display("FAIL Phase1 emitted QLI work cycle=%0d", cycle);
            $finish(1);
        end

        if (qo.reset != pi.reset) begin
            $display("FAIL reset propagation cycle=%0d", cycle);
            $finish(1);
        end

        if (cycle == 1 && dut.debugState != QicIdle) begin
            $display("FAIL reset did not return QIC to Idle");
            $finish(1);
        end
        if (cycle == 5 && dut.debugState != QicWorkerReadData) begin
            $display("FAIL valid 8-bit read address did not enter read-data state");
            $finish(1);
        end
        if (cycle == 7 && dut.debugState != QicWorkerWriteData) begin
            $display("FAIL valid 16-bit write address did not enter write-data state");
            $finish(1);
        end
        if (cycle == 9 && dut.debugState != QicWorkerReadData) begin
            $display("FAIL valid 32-bit read address did not enter read-data state");
            $finish(1);
        end

        case (cycle)
            0, 5, 7, 9: emitTrace(cycle, pi, po, qo, "reset");
            1, 2, 3: emitTrace(cycle, pi, po, qo, "idle");
            4, 6, 8: emitTrace(cycle, pi, po, qo, "worker_address");
            default: emitTrace(cycle, pi, po, qo, "fault");
        endcase

        dut.advance(pi, qi);

        if (cycle == 15) begin
            $display("PASS QIC Phase1 worker-address differential fixture");
            $finish(0);
        end
        else begin
            cycle <= cycle + 1;
        end
    endrule
endmodule

endpackage
