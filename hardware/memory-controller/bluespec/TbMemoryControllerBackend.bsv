package TbMemoryControllerBackend;

import MemoryController::*;

module mkTbMemoryControllerBackend(Empty);
    MemoryControllerIfc mc <- mkMemoryController;
    FakeMemoryBackendIfc ram <- mkFakeMemoryBackend(8'd8);
    Reg#(Bit#(5)) phase <- mkReg(0);
    Reg#(Bit#(8)) watchdog <- mkReg(0);

    rule forwardBackendRequest (mc.backendRequestValid && ram.requestReady);
        ram.acceptRequest(mc.backendWrite, mc.backendAddress, mc.backendWriteData);
        mc.backendRequestAccepted;
    endrule

    rule forwardBackendResponse (mc.backendResponseReady && ram.responseValid);
        mc.backendRespond(ram.responseFault, ram.responseReadDataValid, ram.responseReadData);
        ram.responseConsumed;
    endrule

    rule phase0WriteA (phase == 0);
        mc.hostRequest(True, 32'h00000100, 32'h11111111);
        watchdog <= 0;
        phase <= 1;
    endrule

    rule phase1WaitWriteA (phase == 1 && !mc.hostResponseValid);
        watchdog <= watchdog + 1;
        if (watchdog == 80) begin $display("FAIL backend sequence write A watchdog"); $finish(1); end
    endrule

    rule phase1DoneWriteA (phase == 1 && mc.hostResponseValid);
        if (mc.hostResponseFault || mc.hostReadDataValid || ram.peek(32'h00000100) != 32'h11111111) begin
            $display("FAIL backend sequence write A");
            $finish(1);
        end
        mc.hostResponseConsumed;
        phase <= 2;
    endrule

    rule phase2WriteB (phase == 2);
        mc.hostRequest(True, 32'h00000104, 32'h22222222);
        watchdog <= 0;
        phase <= 3;
    endrule

    rule phase3WaitWriteB (phase == 3 && !mc.hostResponseValid);
        watchdog <= watchdog + 1;
        if (watchdog == 80) begin $display("FAIL backend sequence write B watchdog"); $finish(1); end
    endrule

    rule phase3DoneWriteB (phase == 3 && mc.hostResponseValid);
        if (mc.hostResponseFault || mc.hostReadDataValid
            || ram.peek(32'h00000100) != 32'h11111111
            || ram.peek(32'h00000104) != 32'h22222222) begin
            $display("FAIL backend sequence write B / address alias");
            $finish(1);
        end
        mc.hostResponseConsumed;
        phase <= 4;
    endrule

    rule phase4ReadA (phase == 4);
        mc.hostRequest(False, 32'h00000100, 0);
        watchdog <= 0;
        phase <= 5;
    endrule

    rule phase5WaitReadA (phase == 5 && !mc.hostResponseValid);
        watchdog <= watchdog + 1;
        if (watchdog == 80) begin $display("FAIL backend sequence read A watchdog"); $finish(1); end
    endrule

    rule phase5DoneReadA (phase == 5 && mc.hostResponseValid);
        if (mc.hostResponseFault || !mc.hostReadDataValid || mc.hostReadData != 32'h11111111) begin
            $display("FAIL backend sequence read-after-write A");
            $finish(1);
        end
        mc.hostResponseConsumed;
        phase <= 6;
    endrule

    rule phase6ReadB (phase == 6);
        mc.hostRequest(False, 32'h00000104, 0);
        watchdog <= 0;
        phase <= 7;
    endrule

    rule phase7WaitReadB (phase == 7 && !mc.hostResponseValid);
        watchdog <= watchdog + 1;
        if (watchdog == 80) begin $display("FAIL backend sequence read B watchdog"); $finish(1); end
    endrule

    rule phase7DoneReadB (phase == 7 && mc.hostResponseValid);
        if (mc.hostResponseFault || !mc.hostReadDataValid || mc.hostReadData != 32'h22222222) begin
            $display("FAIL backend sequence read-after-write B");
            $finish(1);
        end
        mc.hostResponseConsumed;
        $display("MEMBACKENDTRACE|v1|case=raw_multi_address|status=ok|a=11111111|b=22222222");
        phase <= 8;
    endrule

    rule phase8IssueResetRead (phase == 8);
        mc.hostRequest(False, 32'h00000100, 0);
        watchdog <= 0;
        phase <= 9;
    endrule

    rule phase9WaitBackendAccept (phase == 9 && mc.debugState != MemBackendResponse);
        watchdog <= watchdog + 1;
        if (watchdog == 80) begin $display("FAIL backend sequence reset accept watchdog"); $finish(1); end
    endrule

    rule phase9ResetOutstanding (phase == 9 && mc.debugState == MemBackendResponse && !ram.responseValid);
        mc.resetController;
        watchdog <= 0;
        phase <= 10;
    endrule

    rule phase10WaitStaleBackend (phase == 10 && !ram.responseValid);
        if (mc.debugState != MemIdle || !mc.hostRequestReady || mc.hostResponseValid) begin
            $display("FAIL backend sequence stale host response after reset");
            $finish(1);
        end
        watchdog <= watchdog + 1;
        if (watchdog == 80) begin $display("FAIL backend sequence stale backend watchdog"); $finish(1); end
    endrule

    rule phase10ObserveStaleBackend (phase == 10 && ram.responseValid);
        if (mc.debugState != MemIdle || !mc.hostRequestReady || mc.hostResponseValid) begin
            $display("FAIL backend sequence stale host response after reset");
            $finish(1);
        end
        ram.resetBackend;
        $display("MEMBACKENDTRACE|v1|case=reset_pending|status=isolated");
        phase <= 11;
    endrule

    rule phase11RecoveryRead (phase == 11);
        mc.hostRequest(False, 32'h00000100, 0);
        watchdog <= 0;
        phase <= 12;
    endrule

    rule phase12WaitRecovery (phase == 12 && !mc.hostResponseValid);
        watchdog <= watchdog + 1;
        if (watchdog == 80) begin $display("FAIL backend sequence recovery watchdog"); $finish(1); end
    endrule

    rule phase12DoneRecovery (phase == 12 && mc.hostResponseValid);
        if (mc.hostResponseFault || !mc.hostReadDataValid || mc.hostReadData != 32'h11111111) begin
            $display("FAIL backend sequence recovery read");
            $finish(1);
        end
        mc.hostResponseConsumed;
        $display("MEMBACKENDTRACE|v1|case=reset_recovery|status=ok|value=11111111");
        $display("PASS memory controller backend sequence semantics");
        $finish(0);
    endrule
endmodule

endpackage
