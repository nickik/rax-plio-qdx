package TbMemoryControllerSemantics;

import MemoryController::*;

function Bit#(32) expectedMasked(Bit#(4) be);
    return mergeMaskedWrite(32'h11223344, 32'haabbccdd, be);
endfunction

module mkTbMemoryControllerSemantics(Empty);
    MemoryControllerIfc mc <- mkMemoryController;
    FakeMemoryBackendIfc ram <- mkFakeMemoryBackend(8'd2);
    Reg#(Bit#(8)) phase <- mkReg(0);
    Reg#(Bit#(5)) mask <- mkReg(0);
    Reg#(Bit#(8)) watchdog <- mkReg(0);

    rule forwardBackendRequest (mc.backendRequestValid && ram.requestReady);
        ram.acceptRequest(mc.backendWrite, mc.backendAddress, mc.backendByteEnable, mc.backendWriteData);
        mc.backendRequestAccepted;
    endrule

    rule forwardBackendResponse (mc.backendResponseReady && ram.responseValid);
        mc.backendRespond(ram.responseFault, ram.responseReadDataValid, ram.responseReadData);
        ram.responseConsumed;
    endrule

    // For every BE value, restore the same old word, perform the masked write
    // through MemoryController -> FakeMemoryBackend, then read the complete word
    // back through the controller with a deliberately unrelated read BE.
    rule preloadMask (phase == 0 && mask < 16);
        Bit#(32) address = 32'h00000200 + (zeroExtend(mask[3:0]) << 2);
        ram.preload(address, 32'h11223344);
        phase <= 1;
    endrule

    rule issueMaskWrite (phase == 1 && mask < 16);
        Bit#(32) address = 32'h00000200 + (zeroExtend(mask[3:0]) << 2);
        mc.hostRequest(True, address, mask[3:0], 32'haabbccdd);
        watchdog <= 0;
        phase <= 2;
    endrule

    rule waitMaskWrite (phase == 2 && !mc.hostResponseValid);
        watchdog <= watchdog + 1;
        if (watchdog == 100) begin $display("FAIL mask write watchdog be=%x", mask[3:0]); $finish(1); end
    endrule

    rule finishMaskWrite (phase == 2 && mc.hostResponseValid);
        Bit#(32) address = 32'h00000200 + (zeroExtend(mask[3:0]) << 2);
        Bit#(32) expected = expectedMasked(mask[3:0]);
        if (mc.hostResponseFault || mc.hostReadDataValid || ram.peek(address) != expected) begin
            $display("FAIL mask write be=%x expected=%08x got=%08x", mask[3:0], expected, ram.peek(address));
            $finish(1);
        end
        mc.hostResponseConsumed;
        phase <= 3;
    endrule

    rule issueFullRead (phase == 3 && mask < 16);
        Bit#(32) address = 32'h00000200 + (zeroExtend(mask[3:0]) << 2);
        mc.hostRequest(False, address, ~mask[3:0], 0);
        watchdog <= 0;
        phase <= 4;
    endrule

    rule waitFullRead (phase == 4 && !mc.hostResponseValid);
        watchdog <= watchdog + 1;
        if (watchdog == 100) begin $display("FAIL mask read watchdog be=%x", mask[3:0]); $finish(1); end
    endrule

    rule finishFullRead (phase == 4 && mc.hostResponseValid);
        Bit#(32) expected = expectedMasked(mask[3:0]);
        if (mc.hostResponseFault || !mc.hostReadDataValid || mc.hostReadData != expected) begin
            $display("FAIL full read be=%x expected=%08x got=%08x", mask[3:0], expected, mc.hostReadData);
            $finish(1);
        end
        $display("MEMSEMTRACE|v1|mask=%x|value=%08x|read=full", mask[3:0], expected);
        mc.hostResponseConsumed;
        if (mask == 15) begin
            mask <= 16;
            phase <= 5;
        end
        else begin
            mask <= mask + 1;
            phase <= 0;
        end
    endrule

    // An aligned request outside FakeMemoryBackend's 4 KiB range reaches the
    // backend with its arbitrary/non-contiguous BE intact and must fault.
    rule issueFault (phase == 5);
        mc.hostRequest(True, 32'h00001000, 4'h5, 32'hcafebabe);
        watchdog <= 0;
        phase <= 6;
    endrule

    rule observeFaultRequest (phase == 6 && mc.backendRequestValid);
        if (mc.backendByteEnable != 4'h5 || mc.backendAddress != 32'h00001000 || mc.backendWriteData != 32'hcafebabe) begin
            $display("FAIL fault request changed before backend acceptance"); $finish(1);
        end
    endrule

    rule waitFault (phase == 6 && !mc.hostResponseValid);
        watchdog <= watchdog + 1;
        if (watchdog == 100) begin $display("FAIL fault watchdog"); $finish(1); end
    endrule

    rule finishFault (phase == 6 && mc.hostResponseValid);
        if (!mc.hostResponseFault || mc.hostReadDataValid) begin $display("FAIL arbitrary-BE backend fault not propagated"); $finish(1); end
        mc.hostResponseConsumed;
        $display("MEMSEMTRACE|v1|fault|be=5|status=propagated");
        phase <= 7;
    endrule

    // Reset only after the masked write has been accepted and the controller is
    // waiting for its backend response. The backend is intentionally not reset,
    // so its later completion is genuinely stale.
    rule issueResetWrite (phase == 7);
        mc.hostRequest(True, 32'h00000300, 4'h9, 32'hcafebabe);
        watchdog <= 0;
        phase <= 8;
    endrule

    rule waitAcceptedResetWrite (phase == 8 && mc.debugState != MemBackendResponse);
        watchdog <= watchdog + 1;
        if (watchdog == 100) begin $display("FAIL reset acceptance watchdog"); $finish(1); end
    endrule

    rule resetAcceptedWrite (phase == 8 && mc.debugState == MemBackendResponse && !ram.responseValid);
        mc.resetController;
        watchdog <= 0;
        phase <= 9;
    endrule

    rule waitStaleCompletion (phase == 9 && !ram.responseValid);
        if (mc.debugState != MemIdle || !mc.hostRequestReady || mc.hostResponseValid) begin
            $display("FAIL response/state appeared after reset before stale completion"); $finish(1);
        end
        watchdog <= watchdog + 1;
        if (watchdog == 100) begin $display("FAIL stale completion watchdog"); $finish(1); end
    endrule

    rule observeStaleCompletion (phase == 9 && ram.responseValid);
        if (mc.debugState != MemIdle || !mc.hostRequestReady || mc.hostResponseValid) begin
            $display("FAIL stale backend completion became host response"); $finish(1);
        end
        ram.resetBackend;
        $display("MEMSEMTRACE|v1|reset|be=9|stale=isolated");
        $display("PASS exhaustive memory controller byte-enable semantics");
        $finish(0);
    endrule
endmodule

endpackage
