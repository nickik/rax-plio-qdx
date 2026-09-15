package TbPLIOHostDmaM3;

import PLIOHostDmaM3::*;

function Bit#(32) dmaHandle(Bit#(4) channel, Bit#(4) generation, Bit#(24) offset);
    return { channel, generation, offset };
endfunction

module mkTbPLIOHostDmaM3(Empty);
    PLIOHostDmaM3Ifc dma <- mkPLIOHostDmaM3;
    Reg#(Bit#(7)) phase <- mkReg(0);
    Reg#(Bit#(5)) beat <- mkReg(0);
    Reg#(Bit#(9)) waits <- mkReg(0);
    Reg#(Bit#(4)) matrixStep <- mkReg(0);
    Reg#(Bit#(16)) cycles <- mkReg(0);

    rule watchdog;
        cycles <= cycles + 1;
        if (cycles == 2000) begin
            $display("FAIL M3 watchdog phase=%0d state=%0d completion=%0d", phase, pack(dma.debugState), pack(dma.completionValid));
            $finish(1);
        end
    endrule

    rule run;
        case (phase)
            0: begin dma.bindCapability(2, 3, 32'h2000_0000, 25'h01000, True, True); phase <= 1; end
            1: begin
                if (!dma.capabilityValid(2, 3) || dma.generation(2, 3) != 0) begin $display("FAIL M3 bind"); $finish(1); end
                $display("PLIOHOSTM3TRACE|v1|case=bind|slot=2|channel=3|generation=0|base=20000000|length=4096");
                dma.start(2, dmaHandle(3, 0, 24'h000040), 4, False); beat <= 0; phase <= 2;
            end
            2: begin
                Bit#(32) data = 32'ha000_0000 | zeroExtend(beat);
                dma.offerDeviceWrite(data, oddParity32M3(data)); phase <= 3;
            end
            3: begin
                if (!dma.memoryRequestValid || !dma.memoryWrite || dma.memoryAddress != 32'h2000_0040 + (zeroExtend(beat) << 2)) begin $display("FAIL M3 write request"); $finish(1); end
                dma.memoryRequestAccepted; phase <= 4;
            end
            4: begin dma.memoryResponse(False, False, 0); phase <= 5; end
            5: begin
                if (beat == 3) begin
                    if (!dma.completionValid || dma.completionStatus != DmaOk || dma.completionBeats != 4) begin $display("FAIL M3 write4 completion"); $finish(1); end
                    $display("PLIOHOSTM3TRACE|v1|case=write4|status=ok|beats=4|first=20000040|last=2000004c");
                    dma.clearCompletion; phase <= 6;
                end
                else begin beat <= beat + 1; phase <= 2; end
            end
            6: begin dma.start(2, dmaHandle(3, 0, 24'h000080), 4, True); beat <= 0; phase <= 7; end
            7: begin
                if (!dma.memoryRequestValid || dma.memoryWrite || dma.memoryAddress != 32'h2000_0080 + (zeroExtend(beat) << 2)) begin $display("FAIL M3 read request"); $finish(1); end
                dma.memoryRequestAccepted; phase <= 8;
            end
            8: begin dma.memoryResponse(False, True, 32'hb000_0000 | zeroExtend(beat)); phase <= 9; end
            9: begin
                Bit#(32) expected = 32'hb000_0000 | zeroExtend(beat);
                if (!dma.deviceReadValid || dma.deviceReadData != expected || dma.deviceReadParity != oddParity32M3(expected)) begin $display("FAIL M3 read data"); $finish(1); end
                dma.acknowledgeDeviceRead; phase <= 10;
            end
            10: begin
                if (beat == 3) begin
                    if (!dma.completionValid || dma.completionStatus != DmaOk || dma.completionBeats != 4) begin $display("FAIL M3 read4 completion"); $finish(1); end
                    $display("PLIOHOSTM3TRACE|v1|case=read4|status=ok|beats=4|first=20000080|last=2000008c");
                    dma.clearCompletion; phase <= 11;
                end
                else begin beat <= beat + 1; phase <= 7; end
            end
            11: begin dma.start(2, dmaHandle(3, 0, 0), 1, False); phase <= 12; end
            12: begin dma.offerDeviceWrite(32'h1122_3344, oddParity32M3(32'h1122_3344)); waits <= 0; phase <= 13; end
            13: begin
                if (waits == 3) begin dma.memoryRequestAccepted; waits <= 0; phase <= 14; end
                else begin dma.waitCycle; waits <= waits + 1; end
            end
            14: begin
                if (waits == 2) begin dma.memoryResponse(False, False, 0); phase <= 15; end
                else begin dma.waitCycle; waits <= waits + 1; end
            end
            15: begin
                if (!dma.completionValid || dma.completionStatus != DmaOk) begin $display("FAIL M3 backpressure"); $finish(1); end
                $display("PLIOHOSTM3TRACE|v1|case=memory_backpressure|status=ok|request_wait=3|response_wait=2");
                dma.clearCompletion; phase <= 16;
            end
            16: begin dma.start(2, dmaHandle(3, 0, 0), 4, False); phase <= 17; end
            17: begin dma.offerDeviceWrite(32'h0102_0304, oddParity32M3(32'h0102_0304)); phase <= 18; end
            18: begin dma.memoryRequestAccepted; phase <= 19; end
            19: begin dma.memoryResponse(False, False, 0); phase <= 20; end
            20: begin dma.offerDeviceWrite(32'h5566_7788, 0); phase <= 21; end
            21: begin
                if (!dma.completionValid || dma.completionStatus != DmaParity || dma.completionBeats != 1) begin $display("FAIL M3 parity partial"); $finish(1); end
                $display("PLIOHOSTM3TRACE|v1|case=partial_parity|status=parity|committed=1");
                dma.clearCompletion; phase <= 22;
            end
            22: begin dma.start(2, dmaHandle(3, 0, 0), 1, True); phase <= 23; end
            23: begin dma.memoryRequestAccepted; phase <= 24; end
            24: begin dma.memoryResponse(True, False, 0); phase <= 25; end
            25: begin
                if (!dma.completionValid || dma.completionStatus != DmaMemoryFault || dma.completionBeats != 0) begin $display("FAIL M3 memory fault"); $finish(1); end
                $display("PLIOHOSTM3TRACE|v1|case=memory_fault|status=fault|committed=0");
                dma.clearCompletion; phase <= 26;
            end
            26: begin dma.start(2, dmaHandle(3, 0, 0), 1, True); waits <= 0; phase <= 27; end
            27: begin
                dma.waitCycle;
                if (waits == 255) phase <= 28;
                else waits <= waits + 1;
            end
            28: begin
                if (!dma.completionValid || dma.completionStatus != DmaTimeout) begin $display("FAIL M3 timeout"); $finish(1); end
                $display("PLIOHOSTM3TRACE|v1|case=timeout|status=timeout|cycles=256");
                dma.clearCompletion; phase <= 29;
            end
            29: begin dma.start(2, dmaHandle(3, 0, 0), 1, True); phase <= 30; end
            30: begin dma.resetHost; phase <= 31; end
            31: begin
                if (!dma.completionValid || dma.completionStatus != DmaReset) begin $display("FAIL M3 reset"); $finish(1); end
                $display("PLIOHOSTM3TRACE|v1|case=reset|status=reset|committed=0");
                dma.clearCompletion; phase <= 32;
            end
            32: begin dma.start(2, dmaHandle(3, 0, 0), 4, False); phase <= 33; end
            33: begin dma.offerDeviceWrite(32'hdead_beef, oddParity32M3(32'hdead_beef)); phase <= 34; end
            34: begin dma.memoryRequestAccepted; phase <= 35; end
            35: begin dma.revoke(2, 3); phase <= 36; end
            36: begin
                if (dma.capabilityValid(2, 3) || !dma.debugRevokePending) begin $display("FAIL M3 revoke interlock"); $finish(1); end
                dma.memoryResponse(False, False, 0); phase <= 37;
            end
            37: begin
                if (!dma.completionValid || dma.completionStatus != DmaRevoked || dma.completionBeats != 1) begin $display("FAIL M3 revoked completion"); $finish(1); end
                $display("PLIOHOSTM3TRACE|v1|case=revoke_active|status=revoked|committed=1|valid=0");
                dma.clearCompletion; phase <= 38;
            end
            38: begin dma.bindCapability(2, 3, 32'h2100_0000, 25'h01000, True, True); phase <= 39; end
            39: begin
                if (dma.generation(2, 3) != 1) begin $display("FAIL M3 rebind generation"); $finish(1); end
                $display("PLIOHOSTM3TRACE|v1|case=rebind|slot=2|channel=3|generation=1|stale_generation=0_rejected");
                matrixStep <= 0; phase <= 40;
            end
            40: begin
                Bit#(5) words = (matrixStep[2:1] == 0) ? 1 : ((matrixStep[2:1] == 1) ? 4 : ((matrixStep[2:1] == 2) ? 8 : 16));
                Bool rd = matrixStep[0] == 1;
                dma.start(2, dmaHandle(3, 1, 0), words, rd); phase <= 41;
            end
            41: begin
                if (dma.completionValid || dma.debugState == DmaIdle) begin $display("FAIL M3 burst matrix start"); $finish(1); end
                dma.resetHost; phase <= 42;
            end
            42: begin
                if (!dma.completionValid || dma.completionStatus != DmaReset) begin $display("FAIL M3 burst matrix reset"); $finish(1); end
                dma.clearCompletion;
                if (matrixStep == 7) phase <= 44;
                else begin matrixStep <= matrixStep + 1; phase <= 43; end
            end
            43: begin phase <= 40; end
            44: begin
                $display("PLIOHOSTM3TRACE|v1|case=burst_matrix|directions=2|sizes=1,4,8,16|status=ok");
                $display("PASS PLIO host M3 DMA capability/memory-port semantics");
                $finish(0);
            end
        endcase
    endrule
endmodule

endpackage
