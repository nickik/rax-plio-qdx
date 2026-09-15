package TbQICPhase2;

import QLITypes::*;
import QICInterfaces::*;
import PLIOQICPhase2::*;

function PlioIn resetStim();
    PlioIn x = plioInDefault();
    x.reset = True;
    return x;
endfunction

function PlioIn workerAddr(Bit#(32) address, Bool read, Bit#(4) be);
    PlioIn x = plioInDefault();
    x.selected = True;
    x.adValid = True;
    x.ad = address;
    x.parValid = True;
    x.parity = oddParity32P2(address);
    x.spaceValid = True;
    x.space = PlioWorker;
    x.addressStrobe = True;
    x.read = read;
    x.byteEnable = be;
    x.burst = BurstOne;
    return x;
endfunction

function PlioIn dataNoPayload();
    PlioIn x = plioInDefault();
    x.dataStrobe = True;
    return x;
endfunction

function PlioIn dataWord(Bit#(32) data, Bit#(4) parity);
    PlioIn x = plioInDefault();
    x.dataStrobe = True;
    x.adValid = True;
    x.ad = data;
    x.parValid = True;
    x.parity = parity;
    return x;
endfunction

function PlioIn stimulus(Bit#(16) c);
    case (c)
        0, 14, 274: return resetStim();
        1: return workerAddr(32'h0000_0100, True, 4'hf);
        3, 7, 11, 16: return dataNoPayload();
        8: return workerAddr(32'h0000_0102, False, 4'hc);
        9: return dataWord(32'h1234_5678, oddParity32P2(32'h1234_5678));
        12: return workerAddr(32'h0000_0100, False, 4'hf);
        13: return dataWord(32'ha5a5_5a5a, oddParity32P2(32'ha5a5_5a5a) ^ 4'h1);
        15: return workerAddr(32'h0000_0104, True, 4'hf);
        default: return plioInDefault();
    endcase
endfunction

function QliIn qliStimulus(Bit#(16) c);
    QliIn q = qliInDefault();
    case (c)
        5, 10, 17: q.mmioReady = True;
        6, 7: begin
            q.mmioResponseValid = True;
            q.mmioResponse = mmioReadOk(32'hdead_beef);
        end
        11: begin
            q.mmioResponseValid = True;
            q.mmioResponse = mmioWriteOk();
        end
    endcase
    return q;
endfunction

function Bit#(2) traceMmioKind(QliIn q);
    Bit#(2) result = 0;
    if (q.mmioResponseValid) begin
        case (q.mmioResponse.status)
            MmioReadOk: result = 1;
            MmioWriteOk: result = 2;
            MmioError: result = 3;
        endcase
    end
    return result;
endfunction

function Bit#(32) traceMmioData(QliIn q);
    return q.mmioResponseValid && q.mmioResponse.status == MmioReadOk
        ? q.mmioResponse.data : 0;
endfunction

function String eventName(Bit#(16) c);
    String result = "worker_data";
    if (c == 0 || c == 14 || c == 274) result = "reset";
    else if (c == 1 || c == 8 || c == 12 || c == 15) result = "worker_address";
    else if (c == 13 || c == 273) result = "fault";
    return result;
endfunction

function Action emitTrace(Bit#(16) cycle, PlioIn pi, QliIn qi, PlioOut po, QliOut qo);
    action
        $display(
            "TRACE|v1|c=%08x|pi=%0d.%0d.%0d.%0d.%08x.%0d.%01x.%0d.%01x.%0d.%0d.%01x.%01x.%0d.%0d.%0d|qi=%0d.%0d.%0d.%08x.0.0.00000000.0.0.0.00000000.0.0.0|po=%0d.%0d.%08x.%0d.%01x.%0d.%01x.%0d.%0d.%01x.%01x.%0d.%0d.%0d|qo=%0d.%0d.%08x.%0d.%01x.%08x.%0d.%0d.0.0.00000000.0.0.00.0.%0d|ev=%s",
            zeroExtend(cycle),
            pack(pi.reset), pack(pi.selected), pack(pi.grant), pack(pi.adValid), pi.ad,
            pack(pi.parValid), pi.parity, pack(pi.spaceValid), pack(pi.space),
            pack(pi.addressStrobe), pack(pi.read), pi.byteEnable, pack(pi.burst),
            pack(pi.dataStrobe), pack(pi.ack), pack(pi.err),
            pack(qi.mmioReady), pack(qi.mmioResponseValid), traceMmioKind(qi), traceMmioData(qi),
            pack(po.request), pack(po.adValid), po.ad, pack(po.parValid), po.parity,
            pack(po.spaceValid), pack(po.space), pack(po.addressStrobe), pack(po.read),
            po.byteEnable, pack(po.burst), pack(po.dataStrobe), pack(po.ack), pack(po.err),
            pack(qo.reset), pack(qo.mmioRequestValid), qo.mmioRequest.address,
            pack(qo.mmioRequest.write), qo.mmioRequest.byteEnable, qo.mmioRequest.writeData,
            pack(qo.mmioResponseReady), pack(qo.mmioCancel), pack(qo.notificationReady),
            eventName(cycle)
        );
    endaction
endfunction

module mkTbQICPhase2(Empty);
    PLIOQICPhase2Ifc dut <- mkPLIOQICPhase2;
    Reg#(Bit#(16)) cycle <- mkReg(0);

    rule run;
        PlioIn pi = stimulus(cycle);
        QliIn qi = qliStimulus(cycle);
        PlioOut po = dut.drivePlio(pi, qi);
        QliOut qo = dut.driveQli(pi, qi);

        if (po.request || po.spaceValid || po.addressStrobe || po.dataStrobe
            || qo.dmaRequestReady || qo.dmaReadValid || qo.dmaWriteReady
            || qo.dmaCompletionValid || qo.notificationReady) begin
            $display("FAIL Phase2 emitted manager/DMA/notification work cycle=%0d", cycle);
            $finish(1);
        end
        if (po.ack && po.err) begin
            $display("FAIL ACK and ERR both asserted cycle=%0d", cycle);
            $finish(1);
        end

        case (cycle)
            1, 8, 12, 15: if (!po.ack || po.err) begin
                $display("FAIL valid worker address cycle=%0d", cycle);
                $finish(1);
            end
            2: if (qo.mmioRequestValid) begin
                $display("FAIL read side effect before DS");
                $finish(1);
            end
            4: if (!qo.mmioRequestValid || qo.mmioRequest.address != 32'h100
                || qo.mmioRequest.write || qo.mmioRequest.byteEnable != 4'hf) begin
                $display("FAIL read QLI request");
                $finish(1);
            end
            6: if (qo.mmioResponseReady || po.ack || po.err) begin
                $display("FAIL response consumed without DS");
                $finish(1);
            end
            7: if (!qo.mmioResponseReady || !po.ack || po.err
                || !po.adValid || po.ad != 32'hdead_beef
                || !po.parValid || po.parity != oddParity32P2(32'hdead_beef)) begin
                $display("FAIL read response");
                $finish(1);
            end
            10: if (!qo.mmioRequestValid || !qo.mmioRequest.write
                || qo.mmioRequest.address != 32'h102 || qo.mmioRequest.byteEnable != 4'hc
                || qo.mmioRequest.writeData != 32'h1234_5678) begin
                $display("FAIL write QLI request");
                $finish(1);
            end
            11: if (!qo.mmioResponseReady || !po.ack || po.err) begin
                $display("FAIL write response");
                $finish(1);
            end
            13: if (!po.err || po.ack || qo.mmioRequestValid) begin
                $display("FAIL bad write parity reached QLI");
                $finish(1);
            end
            273: if (!po.err || !qo.mmioCancel || qo.mmioRequestValid) begin
                $display("FAIL accepted MMIO timeout did not ERR+cancel");
                $finish(1);
            end
        endcase

        emitTrace(cycle, pi, qi, po, qo);
        dut.advance(pi, qi);

        if (cycle == 274) begin
            $display("PASS QIC Phase2 worker-MMIO differential fixture");
            $finish(0);
        end
        else cycle <= cycle + 1;
    endrule
endmodule

endpackage
