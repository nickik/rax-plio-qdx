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
        if (cycles == 1000) begin
            $display("FAIL block RAM backend watchdog");
            $finish(1);
        end
    endrule

    rule forwardBackendRequest (mc.backendRequestValid && ram.requestReady);
        ram.acceptRequest(mc.backendWrite, mc.backendAddress, mc.backendWriteData);
        mc.backendRequestAccepted;
    endrule

    // During the reset-pending phase the backend response is intentionally not
    // forwarded: the coordinated controller/backend reset must cancel it.
    rule forwardBackendResponse (phase != 17 && mc.backendResponseReady && ram.responseValid);
        mc.backendRespond(ram.responseFault, ram.responseReadDataValid, ram.responseReadData);
        ram.responseConsumed;
    endrule

    rule phase0WriteA (phase == 0);
        mc.hostRequest(True, 32'h00000100, 32'h11111111);
        phase <= 1;
    endrule

    rule phase1WriteAResponse (phase == 1 && mc.hostResponseValid);
        if (mc.hostResponseFault || mc.hostReadDataValid) begin
            $display("FAIL block RAM write A response");
            $finish(1);
        end
        mc.hostResponseConsumed;
        phase <= 2;
    endrule

    rule phase2WriteB (phase == 2);
        mc.hostRequest(True, 32'h00000104, 32'h22222222);
        phase <= 3;
    endrule

    rule phase3WriteBResponse (phase == 3 && mc.hostResponseValid);
        if (mc.hostResponseFault || mc.hostReadDataValid) begin
            $display("FAIL block RAM write B response");
            $finish(1);
        end
        mc.hostResponseConsumed;
        phase <= 4;
    endrule

    rule phase4ReadA (phase == 4);
        mc.hostRequest(False, 32'h00000100, 0);
        phase <= 5;
    endrule

    rule phase5ReadAResponse (phase == 5 && mc.hostResponseValid);
        if (mc.hostResponseFault || !mc.hostReadDataValid || mc.hostReadData != 32'h11111111) begin
            $display("FAIL block RAM read A");
            $finish(1);
        end
        mc.hostResponseConsumed;
        phase <= 6;
    endrule

    rule phase6ReadB (phase == 6);
        mc.hostRequest(False, 32'h00000104, 0);
        phase <= 7;
    endrule

    rule phase7ReadBResponse (phase == 7 && mc.hostResponseValid);
        if (mc.hostResponseFault || !mc.hostReadDataValid || mc.hostReadData != 32'h22222222) begin
            $display("FAIL block RAM read B");
            $finish(1);
        end
        mc.hostResponseConsumed;
        $display("MEMBRAMTRACE|v1|case=multi_address|status=ok|a=11111111|b=22222222");
        phase <= 8;
    endrule

    rule phase8OverwriteA (phase == 8);
        mc.hostRequest(True, 32'h00000100, 32'h33333333);
        phase <= 9;
    endrule

    rule phase9OverwriteAResponse (phase == 9 && mc.hostResponseValid);
        if (mc.hostResponseFault) begin
            $display("FAIL block RAM overwrite response");
            $finish(1);
        end
        mc.hostResponseConsumed;
        phase <= 10;
    endrule

    rule phase10RawReadA (phase == 10);
        mc.hostRequest(False, 32'h00000100, 0);
        phase <= 11;
    endrule

    rule phase11RawReadAResponse (phase == 11 && mc.hostResponseValid);
        if (mc.hostResponseFault || !mc.hostReadDataValid || mc.hostReadData != 32'h33333333) begin
            $display("FAIL block RAM read-after-write A");
            $finish(1);
        end
        mc.hostResponseConsumed;
        phase <= 12;
    endrule

    rule phase12RawReadB (phase == 12);
        mc.hostRequest(False, 32'h00000104, 0);
        phase <= 13;
    endrule

    rule phase13RawReadBResponse (phase == 13 && mc.hostResponseValid);
        if (mc.hostResponseFault || !mc.hostReadDataValid || mc.hostReadData != 32'h22222222) begin
            $display("FAIL block RAM read-after-write aliasing");
            $finish(1);
        end
        mc.hostResponseConsumed;
        $display("MEMBRAMTRACE|v1|case=read_after_write|status=ok|a=33333333|b=22222222");
        phase <= 14;
    endrule

    rule phase14FaultIssue (phase == 14);
        // 0x10000 is exactly one byte past the 64 KiB default backend.
        mc.hostRequest(False, 32'h00010000, 0);
        phase <= 15;
    endrule

    rule phase15FaultResponse (phase == 15 && mc.hostResponseValid);
        if (!mc.hostResponseFault || mc.hostReadDataValid) begin
            $display("FAIL block RAM out-of-range fault");
            $finish(1);
        end
        mc.hostResponseConsumed;
        $display("MEMBRAMTRACE|v1|case=out_of_range|status=fault");
        phase <= 16;
    endrule

    rule phase16ResetIssue (phase == 16);
        mc.hostRequest(False, 32'h00000100, 0);
        phase <= 17;
    endrule

    rule phase17ResetOutstanding (phase == 17 && mc.debugState == MemBackendResponse);
        // The request has been accepted by the BRAM backend.  Its one-cycle
        // response is now pending, so reset both ends of the backend contract.
        mc.resetController;
        ram.resetBackend;
        phase <= 18;
    endrule

    rule phase18ResetCheckAndRecover (phase == 18);
        if (mc.debugState != MemIdle || mc.hostResponseValid || ram.responseValid) begin
            $display("FAIL block RAM stale response after reset");
            $finish(1);
        end
        $display("MEMBRAMTRACE|v1|case=reset_outstanding|status=no_stale_response");
        mc.hostRequest(False, 32'h00000100, 0);
        phase <= 19;
    endrule

    rule phase19RecoveryResponse (phase == 19 && mc.hostResponseValid);
        if (mc.hostResponseFault || !mc.hostReadDataValid || mc.hostReadData != 32'h33333333) begin
            $display("FAIL block RAM reset recovery");
            $finish(1);
        end
        mc.hostResponseConsumed;
        $display("MEMBRAMTRACE|v1|case=reset_recovery|status=ok|value=33333333");
        $display("PASS FPGA block RAM backend semantics");
        $finish(0);
    endrule
endmodule

endpackage
