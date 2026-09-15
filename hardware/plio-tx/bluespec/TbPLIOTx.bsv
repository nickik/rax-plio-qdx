package TbPLIOTx;

import PTIEncoding::*;
import PLIOTx::*;

function PtiControlImage outboundControl();
    return PtiControlImage {
        space: 1,
        addressStrobe: True,
        read: True,
        byteEnable: 4'hf,
        burstLen: 2,
        dataStrobe: False,
        driveAdPar: True,
        driveControl: True
    };
endfunction

function PtiControlImage dataOnlyControl();
    return PtiControlImage {
        space: 0,
        addressStrobe: False,
        read: False,
        byteEnable: 4'hf,
        burstLen: 0,
        dataStrobe: True,
        driveAdPar: True,
        driveControl: False
    };
endfunction

function QicPtiDrive qicStimulus(Bit#(8) s);
    QicPtiDrive q = qicPtiDriveDefault();
    case (s)
        1: q.token = controlToken(outboundControl());
        2: q.token = dataLo(32'h89ab_cdef, 4'ha);
        3: q.token = dataHi(32'h89ab_cdef, 4'ha);
        4: begin q.direction = PtiQicToTx; q.token = ptiToken(PtiIdle, 0, 0); end
        5: begin q.driveEnable = True; q.busRequest = True; end
        6: begin q.responseEnable = True; q.responseAck = True; end
        7: begin q.direction = PtiTxToQic; q.token = ptiToken(PtiIdle, 0, 0); end
        8: begin q.direction = PtiTxToQic; q.token = ptiToken(PtiControl, 0, 0); end
        9: begin q.direction = PtiTxToQic; q.token = ptiToken(PtiDataLo, 0, 0); end
        10, 11: begin q.direction = PtiTxToQic; q.token = ptiToken(PtiDataHi, 0, 0); end
        13: q.token = ptiToken(PtiDataHi, 16'h1234, 2);
        15: q.token = controlToken(PtiControlImage {
                space: 0, addressStrobe: False, read: False, byteEnable: 0,
                burstLen: 0, dataStrobe: False, driveAdPar: False, driveControl: True
            });
        16: q.driveEnable = True;
        18: q.token = controlToken(dataOnlyControl());
        19: q.token = dataLo(32'h0102_0304, 4'hf);
        20: q.token = dataHi(32'h0102_0304, 4'hf);
        21: begin q.direction = PtiQicToTx; q.token = ptiToken(PtiIdle, 0, 0); end
        22: q.driveEnable = True;
        24: begin q.responseEnable = True; q.responseAck = True; q.responseErr = True; end
    endcase
    return q;
endfunction

function BackplaneSample busStimulus(Bit#(8) s);
    BackplaneSample b = backplaneSampleDefault();
    case (s)
        6: begin b.ack = True; b.selected = True; b.grant = True; end
        8: begin
            b.control = BackplaneControl {
                space: 2,
                addressStrobe: True,
                read: False,
                byteEnable: 4'hc,
                burstLen: 3,
                dataStrobe: True
            };
            b.ack = True;
            b.selected = True;
            b.grant = True;
        end
        9: begin b.ad = 32'h1122_3344; b.par = 4'ha; end
        10: begin b.ad = 32'haabb_ccdd; b.par = 4'h5; end
        22: b.externalAdParDrive = True;
    endcase
    return b;
endfunction

function Bool resetStimulus(Bit#(8) s);
    return s == 0 || s == 12 || s == 14 || s == 17 || s == 23;
endfunction

function Bit#(16) packBusControl(BackplaneControl c);
    return {
        5'b00000,
        pack(c.dataStrobe),
        c.burstLen,
        c.byteEnable,
        pack(c.read),
        pack(c.addressStrobe),
        c.space
    };
endfunction

function Action emitTrace(Bit#(8) s, BackplaneDrive bp, PtiObserve obs);
    action
        $display(
            "TXTRACE|v1|s=%02x|bp=%0d.%08x.%01x.%0d.%04x.%0d.%0d.%0d.%0d|rx=%0d.%0d.%05x|st=%0d.%0d.%0d.%0d.%0d.%0d",
            s,
            pack(bp.adParValid), bp.ad, bp.par,
            pack(bp.controlValid), packBusControl(bp.control),
            pack(bp.responseValid), pack(bp.ack), pack(bp.err), pack(bp.request),
            pack(obs.rxValid), pack(obs.rxToken.kind), obs.rxToken.ptd,
            pack(obs.sampleAck), pack(obs.sampleErr), pack(obs.sampleSelected), pack(obs.sampleGrant),
            pack(obs.protocolFault), pack(obs.contention)
        );
    endaction
endfunction

module mkTbPLIOTx(Empty);
    PLIOTxIfc dut <- mkPLIOTx;
    Reg#(Bit#(8)) s <- mkReg(0);

    rule run;
        Bool reset = resetStimulus(s);
        QicPtiDrive qic = qicStimulus(s);
        BackplaneSample bus = busStimulus(s);
        BackplaneDrive bp = dut.driveBackplane(reset, qic, bus);
        PtiObserve obs = dut.observeQic(reset, qic, bus);

        if (s == 5) begin
            if (!bp.adParValid || bp.ad != 32'h89ab_cdef || bp.par != 4'ha
                || !bp.controlValid || !bp.request || obs.protocolFault) begin
                $display("FAIL outbound wide drive");
                $finish(1);
            end
        end

        if (s == 6) begin
            if (!bp.responseValid || !bp.ack || bp.err || obs.sampleAck) begin
                $display("FAIL response direction");
                $finish(1);
            end
        end

        if (s == 8) begin
            if (!obs.rxValid || obs.rxToken.kind != PtiControl || ptiParity(obs.rxToken) != 0
                || ptiData(obs.rxToken)[12:11] != 0 || !obs.sampleAck || !obs.sampleSelected || !obs.sampleGrant) begin
                $display("FAIL receive control/status");
                $finish(1);
            end
        end

        if (s == 9) begin
            if (!obs.rxValid || obs.rxToken.kind != PtiDataLo
                || ptiData(obs.rxToken) != 16'h3344 || ptiParity(obs.rxToken) != 2'b10) begin
                $display("FAIL receive low half");
                $finish(1);
            end
        end

        if (s == 10) begin
            if (!obs.rxValid || obs.rxToken.kind != PtiDataHi
                || ptiData(obs.rxToken) != 16'h1122 || ptiParity(obs.rxToken) != 2'b10) begin
                $display("FAIL coherent receive high half");
                $finish(1);
            end
        end

        if (s == 11 && (!obs.protocolFault || obs.rxValid)) begin
            $display("FAIL repeated HI malformed handling");
            $finish(1);
        end

        if (s == 13 && (!obs.protocolFault || bp.adParValid)) begin
            $display("FAIL HI without LO");
            $finish(1);
        end

        if (s == 16 && (!obs.protocolFault || bp.controlValid || bp.adParValid)) begin
            $display("FAIL TX_DRIVE turnaround safety");
            $finish(1);
        end

        if (s == 22 && (!bp.adParValid || bp.ad != 32'h0102_0304 || !obs.contention)) begin
            $display("FAIL contention observation");
            $finish(1);
        end

        if (s == 24 && (!obs.protocolFault || bp.responseValid)) begin
            $display("FAIL simultaneous ACK ERR suppression");
            $finish(1);
        end

        emitTrace(s, bp, obs);
        dut.advance(reset, qic, bus);

        if (s == 24) begin
            $display("PASS PLIO-TX logical differential fixture");
            $finish(0);
        end
        else s <= s + 1;
    endrule
endmodule

endpackage
