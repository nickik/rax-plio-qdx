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

    rule phase0Preload (phase == 0);
        ram.preload(32'h00000100, 32'h11223344);
        ram.preload(32'h00000104, 32'h55667788);
        phase <= 1;
    endrule

    rule phase1Masked0101 (phase == 1);
        mc.hostRequest(True, 32'h00000100, 4'h5, 32'haabbccdd);
        watchdog <= 0;
        phase <= 2;
    endrule

    rule phase2Wait0101 (phase == 2 && !mc.hostResponseValid);
        watchdog <= watchdog + 1;
        if (watchdog == 80) begin $display("FAIL masked 0101 watchdog"); $finish(1); end
    endrule

    rule phase2Done0101 (phase == 2 && mc.hostResponseValid);
        if (mc.hostResponseFault || mc.hostReadDataValid || ram.peek(32'h00000100) != 32'h11bb33dd) begin
            $display("FAIL masked 0101 got=%08x", ram.peek(32'h00000100));
            $finish(1);
        end
        mc.hostResponseConsumed;
        phase <= 3;
    endrule

    rule phase3Masked1010 (phase == 3);
        mc.hostRequest(True, 32'h00000104, 4'ha, 32'haabbccdd);
        watchdog <= 0;
        phase <= 4;
    endrule

    rule phase4Wait1010 (phase == 4 && !mc.hostResponseValid);
        watchdog <= watchdog + 1;
        if (watchdog == 80) begin $display("FAIL masked 1010 watchdog"); $finish(1); end
    endrule

    rule phase4Done1010 (phase == 4 && mc.hostResponseValid);
        if (mc.hostResponseFault || ram.peek(32'h00000104) != 32'haa66cc88) begin
            $display("FAIL masked 1010 got=%08x", ram.peek(32'h00000104));
            $finish(1);
        end
        mc.hostResponseConsumed;
        phase <= 5;
    endrule

    rule phase5Masked0000 (phase == 5);
        mc.hostRequest(True, 32'h00000100, 4'h0, 32'hffffffff);
        phase <= 6;
    endrule

    rule phase6Wait0000 (phase == 6 && !mc.hostResponseValid);
        watchdog <= watchdog + 1;
        if (watchdog == 80) begin $display("FAIL masked 0000 watchdog"); $finish(1); end
    endrule

    rule phase6Done0000 (phase == 6 && mc.hostResponseValid);
        if (mc.hostResponseFault || ram.peek(32'h00000100) != 32'h11bb33dd) begin
            $display("FAIL masked 0000 changed memory"); $finish(1);
        end
        mc.hostResponseConsumed;
        phase <= 7;
    endrule

    rule phase7Masked1111 (phase == 7);
        mc.hostRequest(True, 32'h00000100, 4'hf, 32'hdeadbeef);
        phase <= 8;
    endrule

    rule phase8Wait1111 (phase == 8 && !mc.hostResponseValid);
        watchdog <= watchdog + 1;
        if (watchdog == 80) begin $display("FAIL masked 1111 watchdog"); $finish(1); end
    endrule

    rule phase8Done1111 (phase == 8 && mc.hostResponseValid);
        if (mc.hostResponseFault || ram.peek(32'h00000100) != 32'hdeadbeef) begin
            $display("FAIL masked 1111 full write"); $finish(1);
        end
        mc.hostResponseConsumed;
        phase <= 9;
    endrule

    rule phase9Readback (phase == 9);
        mc.hostRequest(False, 32'h00000100, 4'h3, 0);
        phase <= 10;
    endrule

    rule phase10WaitReadback (phase == 10 && !mc.hostResponseValid);
        watchdog <= watchdog + 1;
        if (watchdog == 80) begin $display("FAIL readback watchdog"); $finish(1); end
    endrule

    rule phase10DoneReadback (phase == 10 && mc.hostResponseValid);
        if (mc.hostResponseFault || !mc.hostReadDataValid || mc.hostReadData != 32'hdeadbeef) begin
            $display("FAIL read semantics depend on BE"); $finish(1);
        end
        mc.hostResponseConsumed;
        $display("MEMBACKENDTRACE|v2|case=masked|status=ok|m5=11bb33dd|ma=aa66cc88|full=deadbeef");
        phase <= 11;
    endrule

    rule phase11Backpressure (phase == 11);
        ram.setRequestHoldoff(4);
        mc.hostRequest(True, 32'h00000108, 4'h6, 32'h12345678);
        watchdog <= 0;
        phase <= 12;
    endrule

    rule phase12ObserveBackpressure (phase == 12 && mc.backendRequestValid);
        if (mc.backendByteEnable != 4'h6 || mc.backendWriteData != 32'h12345678) begin
            $display("FAIL BE/data unstable under backend backpressure"); $finish(1);
        end
        watchdog <= watchdog + 1;
        if (watchdog == 80) begin $display("FAIL backpressure watchdog"); $finish(1); end
    endrule

    rule phase12DoneBackpressure (phase == 12 && mc.hostResponseValid);
        if (mc.hostResponseFault || ram.peek(32'h00000108) != 32'h00345600) begin
            $display("FAIL backpressure masked write got=%08x", ram.peek(32'h00000108)); $finish(1);
        end
        mc.hostResponseConsumed;
        phase <= 13;
    endrule

    rule phase13IssueResetWrite (phase == 13);
        mc.hostRequest(True, 32'h0000010c, 4'h9, 32'hcafebabe);
        watchdog <= 0;
        phase <= 14;
    endrule

    rule phase14WaitBackendAccept (phase == 14 && mc.debugState != MemBackendResponse);
        watchdog <= watchdog + 1;
        if (watchdog == 80) begin $display("FAIL reset accept watchdog"); $finish(1); end
    endrule

    rule phase14ResetOutstanding (phase == 14 && mc.debugState == MemBackendResponse && !ram.responseValid);
        mc.resetController;
        watchdog <= 0;
        phase <= 15;
    endrule

    rule phase15WaitStaleBackend (phase == 15 && !ram.responseValid);
        if (mc.debugState != MemIdle || !mc.hostRequestReady || mc.hostResponseValid) begin
            $display("FAIL stale host response after reset"); $finish(1);
        end
        watchdog <= watchdog + 1;
        if (watchdog == 80) begin $display("FAIL stale backend watchdog"); $finish(1); end
    endrule

    rule phase15ObserveStaleBackend (phase == 15 && ram.responseValid);
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
