package TbQICPhase3;

import QLITypes::*;
import QICInterfaces::*;
import PLIOQICPhase1::*;
import PLIOQICPhase3::*;

function PlioIn busStimulus(Bit#(16) c);
    PlioIn b = plioInDefault();
    if (c == 0 || c == 6 || c == 14 || c == 21 || c == 282 || c == 287)
        b.reset = True;
    else if (c == 3 || c == 4 || c == 9 || c == 10 || c == 11
          || c == 17 || c == 18 || (c >= 24 && c <= 280)
          || (c >= 283 && c <= 286))
        b.grant = True;

    if (c == 5 || c == 286)
        b.ack = True;
    if (c == 11)
        b.err = True;
    return b;
endfunction

function DmaRequest dmaReq(Bit#(32) address, DmaDirection direction, BurstWords words);
    return DmaRequest { direction: direction, address: address, words: words };
endfunction

function QliIn qliStimulus(Bit#(16) c);
    QliIn q = qliInDefault();

    if (c >= 1 && c <= 5) begin
        q.dmaRequestValid = True;
        q.dmaRequest = dmaReq(32'h2200_1000, HostToDevice, BurstFour);
        q.notificationValid = True;
        q.notification = NotificationRequest { channel: 2 };
    end
    else if (c == 7) begin
        q.dmaRequestValid = True;
        q.dmaRequest = dmaReq(32'h3300_2000, DeviceToHost, BurstFour);
    end
    else if (c == 13 || c == 20 || c == 281) begin
        q.dmaCompletionReady = True;
    end
    else if (c == 15) begin
        q.dmaRequestValid = True;
        q.dmaRequest = dmaReq(32'h4400_0000, HostToDevice, BurstOne);
    end
    else if (c == 22) begin
        q.dmaRequestValid = True;
        q.dmaRequest = dmaReq(32'h5500_0000, HostToDevice, BurstSixteen);
    end
    else if (c == 283) begin
        q.dmaRequestValid = True;
        q.dmaRequest = dmaReq(32'h6600_1000, HostToDevice, BurstFour);
    end
    else if (c == 288) begin
        q.dmaRequestValid = True;
        q.dmaRequest = dmaReq(32'h7000_0002, HostToDevice, BurstOne);
    end
    else if (c == 289) begin
        q.notificationValid = True;
        q.notification = NotificationRequest { channel: 4 };
    end

    return q;
endfunction

function String eventName(Bit#(16) c);
    if (c == 0 || c == 6 || c == 14 || c == 21 || c == 282 || c == 287)
        return "reset";
    if (c == 11 || c == 19 || c == 280)
        return "fault";
    if (c == 12 || c == 13 || c == 20 || c == 281)
        return "dma_complete";
    if (c == 4 || c == 5 || c == 10 || c == 11 || c == 18
        || (c >= 25 && c <= 280) || c == 285 || c == 286)
        return "manager_address";
    if ((c >= 1 && c <= 3) || (c >= 7 && c <= 9)
        || (c >= 15 && c <= 17) || (c >= 22 && c <= 24)
        || c == 283 || c == 284)
        return "manager_request";
    return "idle";
endfunction

function Bit#(2) dmaDirectionCode(QliIn q);
    return q.dmaRequestValid ? zeroExtend(pack(q.dmaRequest.direction)) : 0;
endfunction

function Bit#(2) dmaWordsCode(QliIn q);
    return q.dmaRequestValid ? pack(q.dmaRequest.words) : 0;
endfunction

function Bit#(32) dmaAddressTrace(QliIn q);
    return q.dmaRequestValid ? q.dmaRequest.address : 0;
endfunction

function Bit#(8) notificationChannelTrace(QliIn q);
    return q.notificationValid ? q.notification.channel : 0;
endfunction

function Bit#(8) completionStatusTrace(QliOut q);
    return q.dmaCompletionValid ? zeroExtend(pack(q.dmaCompletion.status)) : 0;
endfunction

function Bit#(5) completionWordsTrace(QliOut q);
    return q.dmaCompletionValid ? q.dmaCompletion.wordsCompleted : 0;
endfunction

function Action emitTrace(Bit#(16) cycle, PlioIn pi, QliIn qi, PlioOut po, QliOut qo);
    action
        $display(
            "TRACE|v1|c=%08x|pi=%0d.%0d.%0d.%0d.%08x.%0d.%01x.%0d.%01x.%0d.%0d.%01x.%01x.%0d.%0d.%0d|qi=0.0.0.00000000.%0d.%0d.%08x.%01x.0.0.00000000.%0d.%0d.%01x|po=%0d.%0d.%08x.%0d.%01x.%0d.%01x.%0d.%0d.%01x.%01x.%0d.%0d.%0d|qo=%0d.0.00000000.0.0.00000000.0.0.%0d.0.00000000.0.%0d.%02x.%01x.0|ev=%s",
            zeroExtend(cycle),
            pack(pi.reset), pack(pi.selected), pack(pi.grant), pack(pi.adValid), pi.ad,
            pack(pi.parValid), pi.par, pack(pi.spaceValid), pack(pi.space),
            pack(pi.addressStrobe), pack(pi.read), pi.byteEnable, pack(pi.burst),
            pack(pi.dataStrobe), pack(pi.ack), pack(pi.err),
            pack(qi.dmaRequestValid), dmaDirectionCode(qi), dmaAddressTrace(qi), dmaWordsCode(qi),
            pack(qi.dmaCompletionReady), pack(qi.notificationValid), notificationChannelTrace(qi),
            pack(po.request), pack(po.adValid), po.ad, pack(po.parValid), po.par,
            pack(po.spaceValid), pack(po.space), pack(po.addressStrobe), pack(po.read),
            po.byteEnable, pack(po.burst), pack(po.dataStrobe), pack(po.ack), pack(po.err),
            pack(qo.reset), pack(qo.dmaRequestReady), pack(qo.dmaCompletionValid),
            completionStatusTrace(qo), completionWordsTrace(qo), eventName(cycle)
        );
    endaction
endfunction

module mkTbQICPhase3(Empty);
    PLIOQICPhase3Ifc dut <- mkPLIOQICPhase3;
    Reg#(Bit#(16)) cycle <- mkReg(0);

    rule run;
        PlioIn pi = busStimulus(cycle);
        QliIn qi = qliStimulus(cycle);
        PlioOut po = dut.drivePlio(pi, qi);
        QliOut qo = dut.driveQli(pi, qi);

        if (po.ack || po.err || po.dataStrobe || qo.notificationReady
            || qo.mmioRequestValid || qo.mmioResponseReady || qo.mmioCancel
            || qo.dmaReadValid || qo.dmaWriteReady) begin
            $display("FAIL Phase3 emitted data/worker completion cycle=%0d", cycle);
            $finish(1);
        end

        // Notification wins over the simultaneously presented DMA.
        if (cycle == 1 && qo.dmaRequestReady) begin
            $display("FAIL notification did not block DMA acceptance");
            $finish(1);
        end

        // RequestBus may assert BR but must not drive manager address/control.
        if ((cycle == 2 || cycle == 3 || cycle == 8 || cycle == 9
            || cycle == 16 || cycle == 17 || cycle == 23 || cycle == 24
            || cycle == 284)
            && (!po.request || po.addressStrobe || po.adValid || po.parValid || po.spaceValid)) begin
            $display("FAIL RequestBus drive cycle=%0d", cycle);
            $finish(1);
        end

        if (cycle == 4 || cycle == 5) begin
            if (!po.request || !po.addressStrobe || !po.adValid || po.ad != 32'h8
                || !po.parValid || po.par != oddParity32P1(32'h8)
                || !po.spaceValid || po.space != PlioController
                || po.read || po.byteEnable != 4'hf || po.burst != BurstOne) begin
                $display("FAIL notification address cycle=%0d", cycle);
                $finish(1);
            end
        end

        if (cycle == 10 || cycle == 11) begin
            if (!po.request || !po.addressStrobe || po.ad != 32'h3300_2000
                || po.space != PlioHostDma || po.read || po.byteEnable != 4'hf
                || po.burst != BurstFour) begin
                $display("FAIL DMA address/ERR setup cycle=%0d", cycle);
                $finish(1);
            end
        end

        if (cycle == 12 || cycle == 13) begin
            if (!qo.dmaCompletionValid || qo.dmaCompletion.status != DmaBusError
                || qo.dmaCompletion.wordsCompleted != 0) begin
                $display("FAIL BusError completion hold cycle=%0d", cycle);
                $finish(1);
            end
        end

        if (cycle == 19 && (!po.request || po.addressStrobe || po.adValid)) begin
            $display("FAIL BG loss should withdraw address drive immediately");
            $finish(1);
        end
        if (cycle == 20 && (!qo.dmaCompletionValid || qo.dmaCompletion.status != DmaProtocolError)) begin
            $display("FAIL BG loss ProtocolError completion");
            $finish(1);
        end

        // waitCount reaches 255 on cycle 280: BR remains asserted but AS/AD/PAR
        // are withdrawn before the timeout transition, exactly like Rust.
        if (cycle == 280 && (!po.request || po.addressStrobe || po.adValid || po.parValid)) begin
            $display("FAIL address timeout drive image");
            $finish(1);
        end
        if (cycle == 281 && (!qo.dmaCompletionValid || qo.dmaCompletion.status != DmaTimeout)) begin
            $display("FAIL timeout completion");
            $finish(1);
        end

        // Fresh-grant rule with BG already high: cycle 283 accepts locally,
        // cycle 284 is still BR-only, and only cycle 285 drives AS.
        if (cycle == 283 && (!qo.dmaRequestReady || po.request || po.addressStrobe)) begin
            $display("FAIL fresh request acceptance boundary");
            $finish(1);
        end
        if (cycle == 285 && (!po.request || !po.addressStrobe || po.ad != 32'h6600_1000)) begin
            $display("FAIL fresh request did not wait through RequestBus");
            $finish(1);
        end

        if ((cycle == 288 || cycle == 289) && (po.request || qo.dmaRequestReady)) begin
            $display("FAIL invalid local request was accepted cycle=%0d", cycle);
            $finish(1);
        end

        emitTrace(cycle, pi, qi, po, qo);
        dut.advance(pi, qi);

        if (cycle == 289) begin
            $display("PASS QIC Phase3 manager-address differential fixture");
            $finish(0);
        end
        else cycle <= cycle + 1;
    endrule
endmodule

endpackage
