package TbMemoryControllerBackend;

import MemoryController::*;

module mkTbMemoryControllerBackend(Empty);
    MemoryControllerIfc mc <- mkMemoryController;
    FakeMemoryBackendIfc ram <- mkFakeMemoryBackend(8'd2);
    Reg#(Bit#(6)) phase <- mkReg(0);
    Reg#(Bit#(8)) watchdog <- mkReg(0);

    rule forwardBackendRequest (mc.backendRequestValid && ram.requestReady);
        ram.acceptRequest(mc.backendWrite, mc.backendAddress, mc.backendByteEnable, mc.backendWriteData);
        mc.backendRequestAccepted;
    endrule

    rule forwardBackendResponse (mc.backendResponseReady && ram.responseValid);
        mc.backendRespond(ram.responseFault, ram.responseReadDataValid, ram.responseReadData);
        ram.responseConsumed;
    endrule

    rule phase0Preload100 (phase == 0);
        ram.preload(32'h00000100, 32'h11223344);
        phase <= 1;
    endrule

    rule phase1Preload104 (phase == 1);
        ram.preload(32'h00000104, 32'h55667788);
        phase <= 2;
    endrule

    rule phase2Preload108 (phase == 2);
        ram.preload(32'h00000108, 32'h00000000);
        phase <= 3;
    endrule

    rule phase3Masked0101 (phase == 3);
        mc.hostRequest(True, 32'h00000100, 4'h5, 32'haabbccdd);
        watchdog <= 0;
        phase <= 4;
    endrule

    rule phase4Wait0101 (phase == 4 && !mc.hostResponseValid);
        watchdog <= watchdog + 1;
        if (watchdog == 80) begin $display("FAIL masked 0101 watchdog"); $finish(1); end
    endrule

    rule phase4Done0101 (phase == 4 && mc.hostResponseValid);
        if (mc.hostResponseFault || mc.hostReadDataValid || ram.peek(32'h00000100) != 32'h11bb33dd) begin
            $display("FAIL masked 0101 got=%08x", ram.peek(32'h00000100));
            $finish(1);
        end
        mc.hostResponseConsumed;
        phase <= 5;
    endrule

    rule phase5Masked1010 (phase == 5);
        mc.hostRequest(True, 32'h00000104, 4'ha, 32'haabbccdd);
        watchdog <= 0;
        phase <= 6;
    endrule

    rule phase6Wait1010 (phase == 6 && !mc.hostResponseValid);
        watchdog <= watchdog + 1;
        if (watchdog == 80) begin $display("FAIL masked 1010 watchdog"); $finish(1); end
    endrule

    rule phase6Done1010 (phase == 6 && mc.hostResponseValid);
        if (mc.hostResponseFault || ram.peek(32'h00000104) != 32'haa66cc88) begin
            $display("FAIL masked 1010 got=%08x", ram.peek(32'h00000104));
            $finish(1);
        end
        mc.hostResponseConsumed;
        phase <= 7;
    endrule

    rule phase7Masked0000 (phase == 7);
        mc.hostRequest(True, 32'h00000100, 4'h0, 32'hffffffff);
        phase <= 8;
    endrule

    rule phase8Wait0000 (phase == 8 && !mc.hostResponseValid);
        watchdog <= watchdog + 1;
        if (watchdog == 80) begin $display("FAIL masked 0000 watchdog"); $finish(1); end
    endrule

    rule phase8Done0000 (phase == 8 && mc.hostResponseValid);
        if (mc.hostResponseFault || ram.peek(32'h00000100) != 32'h11bb33dd) begin
            $display("FAIL masked 0000 changed memory"); $finish(1);
        end
        mc.hostResponseConsumed;
        phase <= 9;
    endrule

    rule phase9Masked1111 (phase == 9);
        mc.hostRequest(True, 32'h00000100, 4'hf, 32'hdeadbeef);
        phase <= 10;
    endrule

    rule phase10Wait1111 (phase == 10 && !mc.hostResponseValid);
        watchdog <= watchdog + 1;
        if (watchdog == 80) begin $display("FAIL masked 1111 watchdog"); $finish(1); end
    endrule

    rule phase10Done1111 (phase == 10 && mc.hostResponseValid);
        if (mc.hostResponseFault || ram.peek(32'h00000100) != 32'hdeadbeef) begin
            $display("FAIL masked 1111 full write"); $finish(1);
        end
        mc.hostResponseConsumed;
        phase <= 11;
    endrule

    rule phase11Readback (phase == 11);
        mc.hostRequest(False, 32'h00000100, 4'h3, 0);
        phase <= 12;
    endrule

    rule phase12WaitReadback (phase == 12 && !mc.hostResponseValid);
        watchdog <= watchdog + 1;
        if (watchdog == 80) begin $display("FAIL readback watchdog"); $finish(1); end
    endrule

    rule phase12DoneReadback (phase == 12 && mc.hostResponseValid);
        if (mc.hostResponseFault || !mc.hostReadDataValid || mc.hostReadData != 32'hdeadbeef) begin
            $display("FAIL read semantics depend on BE"); $finish(1);
        end
        mc.hostResponseConsumed;
        $display("MEMBACKENDTRACE|v2|case=masked|status=ok|m5=11bb33dd|ma=aa66cc88|full=deadbeef");
        phase <= 13;
    endrule

    rule phase13Backpressure (phase == 13);
        ram.setRequestHoldoff(4);
        mc.hostRequest(True, 32'h00000108, 4'h6, 32'h12345678);
        watchdog <= 0;
        phase <= 14;
    endrule

    rule phase14ObserveBackpressure (phase == 14 && mc.backendRequestValid);
        if (mc.backendByteEnable != 4'h6 || mc.backendWriteData != 32'h12345678) begin
            $display("FAIL BE/data unstable under backend backpressure"); $finish(1);
        end
        watchdog <= watchdog + 1;
        if (watchdog == 80) begin $display("FAIL backpressure watchdog"); $finish(1); end
    endrule

    rule phase14DoneBackpressure (phase == 14 && mc.hostResponseValid);
        if (mc.hostResponseFault || ram.peek(32'h00000108) != 32'h00345600) begin
            $display("FAIL backpressure masked write got=%08x", ram.peek(32'h00000108)); $finish(1);
        end
        mc.hostResponseConsumed;
        phase <= 15;
    endrule

    rule phase15IssueResetWrite (phase == 15);
        mc.hostRequest(True, 32'h0000010c, 4'h9, 32'hcafebabe);
        watchdog <= 0;
        phase <= 16;
    endrule

    rule phase16WaitBackendAccept (phase == 16 && mc.debugState != MemBackendResponse);
        watchdog <= watchdog + 1;
        if (watchdog == 80) begin $display("FAIL reset accept watchdog"); $finish(1); end
    endrule

    rule phase16ResetOutstanding (phase == 16 && mc.debugState == MemBackendResponse && !ram.responseValid);
        mc.resetController;
        watchdog <= 0;
        phase <= 17;
    endrule

    rule phase17WaitStaleBackend (phase == 17 && !ram.responseValid);
        if (mc.debugState != MemIdle || !mc.hostRequestReady || mc.hostResponseValid) begin
            $display("FAIL stale host response after reset"); $finish(1);
        end
        watchdog <= watchdog + 1;
        if (watchdog == 80) begin $display("FAIL stale backend watchdog"); $finish(1); end
    endrule

    rule phase17ObserveStaleBackend (phase == 17 && ram.responseValid);
        if (mc.debugState != MemIdle || !mc.hostRequestReady || mc.hostResponseValid) begin
            $display("FAIL stale host response after reset"); $finish(1);
        end
        ram.resetBackend;
        $display("MEMBACKENDTRACE|v2|case=reset_pending_masked|status=isolated");
        $display("PASS memory controller backend masked-write semantics");
        $finish(0);
    endrule
endmodule

endpackage
