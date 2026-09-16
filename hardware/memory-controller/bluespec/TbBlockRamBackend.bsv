package TbBlockRamBackend;

import MemoryController::*;
import BlockRamBackend::*;

module mkTbBlockRamBackend(Empty);
    MemoryControllerIfc mc <- mkMemoryController;
    BlockRamBackendIfc ram <- mkDefaultBlockRamBackend;
    Reg#(Bit#(6)) phase <- mkReg(0);
    Reg#(Bit#(16)) cycles <- mkReg(0);

    rule watchdog;
        cycles <= cycles + 1;
        if (cycles == 1200) begin
            $display("FAIL block RAM backend watchdog");
            $finish(1);
        end
    endrule

    rule forwardBackendRequest (mc.backendRequestValid && ram.requestReady);
        ram.acceptRequest(mc.backendWrite, mc.backendAddress, mc.backendByteEnable, mc.backendWriteData);
        mc.backendRequestAccepted;
    endrule

    rule forwardBackendResponse (phase != 21 && mc.backendResponseReady && ram.responseValid);
        mc.backendRespond(ram.responseFault, ram.responseReadDataValid, ram.responseReadData);
        ram.responseConsumed;
    endrule

    rule phase0WriteA (phase == 0);
        mc.hostRequest(True, 32'h00000100, 4'hf, 32'h11223344);
        phase <= 1;
    endrule

    rule phase1WriteAResponse (phase == 1 && mc.hostResponseValid);
        if (mc.hostResponseFault || mc.hostReadDataValid) begin $display("FAIL block RAM write A response"); $finish(1); end
        mc.hostResponseConsumed;
        phase <= 2;
    endrule

    rule phase2MaskedA (phase == 2);
        mc.hostRequest(True, 32'h00000100, 4'h5, 32'haabbccdd);
        phase <= 3;
    endrule

    rule phase3MaskedAResponse (phase == 3 && mc.hostResponseValid);
        if (mc.hostResponseFault) begin $display("FAIL block RAM masked A response"); $finish(1); end
        mc.hostResponseConsumed;
        phase <= 4;
    endrule

    rule phase4ReadA (phase == 4);
        mc.hostRequest(False, 32'h00000100, 4'h0, 0);
        phase <= 5;
    endrule

    rule phase5ReadAResponse (phase == 5 && mc.hostResponseValid);
        if (mc.hostResponseFault || !mc.hostReadDataValid || mc.hostReadData != 32'h11bb33dd) begin
            $display("FAIL block RAM masked 0101 readback got=%08x", mc.hostReadData); $finish(1);
        end
        mc.hostResponseConsumed;
        $display("MEMBRAMTRACE|v2|case=mask0101|status=ok|value=11bb33dd");
        phase <= 6;
    endrule

    rule phase6WriteB (phase == 6);
        mc.hostRequest(True, 32'h00000104, 4'hf, 32'h55667788);
        phase <= 7;
    endrule

    rule phase7WriteBResponse (phase == 7 && mc.hostResponseValid);
        if (mc.hostResponseFault) begin $display("FAIL block RAM write B response"); $finish(1); end
        mc.hostResponseConsumed;
        phase <= 8;
    endrule

    rule phase8MaskedB (phase == 8);
        mc.hostRequest(True, 32'h00000104, 4'ha, 32'haabbccdd);
        phase <= 9;
    endrule

    rule phase9MaskedBResponse (phase == 9 && mc.hostResponseValid);
        if (mc.hostResponseFault) begin $display("FAIL block RAM masked B response"); $finish(1); end
        mc.hostResponseConsumed;
        phase <= 10;
    endrule

    rule phase10ReadB (phase == 10);
        mc.hostRequest(False, 32'h00000104, 4'hf, 0);
        phase <= 11;
    endrule

    rule phase11ReadBResponse (phase == 11 && mc.hostResponseValid);
        if (mc.hostResponseFault || !mc.hostReadDataValid || mc.hostReadData != 32'haa66cc88) begin
            $display("FAIL block RAM masked 1010 readback got=%08x", mc.hostReadData); $finish(1);
        end
        mc.hostResponseConsumed;
        $display("MEMBRAMTRACE|v2|case=mask1010|status=ok|value=aa66cc88");
        phase <= 12;
    endrule

    rule phase12ZeroMask (phase == 12);
        mc.hostRequest(True, 32'h00000100, 4'h0, 32'hffffffff);
        phase <= 13;
    endrule

    rule phase13ZeroMaskResponse (phase == 13 && mc.hostResponseValid);
        if (mc.hostResponseFault) begin $display("FAIL block RAM zero-mask response"); $finish(1); end
        mc.hostResponseConsumed;
        phase <= 14;
    endrule

    rule phase14ReadZeroMaskResult (phase == 14);
        mc.hostRequest(False, 32'h00000100, 4'h3, 0);
        phase <= 15;
    endrule

    rule phase15ReadZeroMaskResponse (phase == 15 && mc.hostResponseValid);
        if (mc.hostResponseFault || !mc.hostReadDataValid || mc.hostReadData != 32'h11bb33dd) begin
            $display("FAIL block RAM zero mask changed memory"); $finish(1);
        end
        mc.hostResponseConsumed;
        phase <= 16;
    endrule

    rule phase16FullOverwrite (phase == 16);
        mc.hostRequest(True, 32'h00000100, 4'hf, 32'h33333333);
        phase <= 17;
    endrule

    rule phase17FullOverwriteResponse (phase == 17 && mc.hostResponseValid);
        if (mc.hostResponseFault) begin $display("FAIL block RAM full overwrite response"); $finish(1); end
        mc.hostResponseConsumed;
        phase <= 18;
    endrule

    rule phase18FaultIssue (phase == 18);
        mc.hostRequest(False, 32'h00100000, 4'hf, 0);
        phase <= 19;
    endrule

    rule phase19FaultResponse (phase == 19 && mc.hostResponseValid);
        if (!mc.hostResponseFault || mc.hostReadDataValid) begin $display("FAIL block RAM out-of-range fault"); $finish(1); end
        mc.hostResponseConsumed;
        $display("MEMBRAMTRACE|v2|case=out_of_range|status=fault");
        phase <= 20;
    endrule

    rule phase20ResetIssue (phase == 20);
        mc.hostRequest(False, 32'h00000100, 4'hf, 0);
        phase <= 21;
    endrule

    rule phase21ResetOutstanding (phase == 21 && mc.debugState == MemBackendResponse);
        mc.resetController;
        ram.resetBackend;
        phase <= 22;
    endrule

    rule phase22ResetCheckAndRecover (phase == 22);
        if (mc.debugState != MemIdle || mc.hostResponseValid || ram.responseValid || mc.backendByteEnable != 0) begin
            $display("FAIL block RAM stale response/mask after reset"); $finish(1);
        end
        mc.hostRequest(False, 32'h00000100, 4'hf, 0);
        phase <= 23;
    endrule

    rule phase23RecoveryResponse (phase == 23 && mc.hostResponseValid);
        if (mc.hostResponseFault || !mc.hostReadDataValid || mc.hostReadData != 32'h33333333) begin
            $display("FAIL block RAM reset recovery"); $finish(1);
        end
        mc.hostResponseConsumed;
        $display("MEMBRAMTRACE|v2|case=reset_recovery|status=ok|value=33333333");
        $display("PASS FPGA byte-lane block RAM backend semantics");
        $finish(0);
    endrule
endmodule

endpackage
