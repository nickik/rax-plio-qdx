package TbMemoryController;

import MemoryController::*;

function Bit#(2) responseCode(Bool valid, Bool fault, Bool readValid);
    Bit#(2) code = 0;
    if (valid) begin
        if (fault) code = 3;
        else if (readValid) code = 1;
        else code = 2;
    end
    return code;
endfunction

module mkTbMemoryController(Empty);
    MemoryControllerIfc mc <- mkMemoryController;
    Reg#(Bit#(6)) phase <- mkReg(0);

    // Keep each phase in its own rule.  Combining calls to methods whose
    // readiness guards are mutually exclusive in one large case rule causes
    // BSC to conjoin those implicit conditions and remove the rule as
    // unsatisfiable.
    rule phaseIdle (phase == 0);
        $display("MEMCTRLTRACE|v1|case=idle|state=%0d|host_ready=%0d|backend_valid=%0d|write=0|address=00000000|response=%0d",
            pack(mc.debugState), mc.hostRequestReady, mc.backendRequestValid,
            responseCode(mc.hostResponseValid, mc.hostResponseFault, mc.hostReadDataValid));
        mc.hostRequest(False, 32'h00000100, 0);
        phase <= 1;
    endrule

    rule phaseReadRequest (phase == 1);
        $display("MEMCTRLTRACE|v1|case=read_request|state=%0d|host_ready=%0d|backend_valid=%0d|write=%0d|address=%08x|response=%0d",
            pack(mc.debugState), mc.hostRequestReady, mc.backendRequestValid, mc.backendWrite, mc.backendAddress,
            responseCode(mc.hostResponseValid, mc.hostResponseFault, mc.hostReadDataValid));
        phase <= 2;
    endrule

    rule phaseReadStall (phase == 2);
        $display("MEMCTRLTRACE|v1|case=read_stall|state=%0d|host_ready=%0d|backend_valid=%0d|write=%0d|address=%08x|response=%0d",
            pack(mc.debugState), mc.hostRequestReady, mc.backendRequestValid, mc.backendWrite, mc.backendAddress,
            responseCode(mc.hostResponseValid, mc.hostResponseFault, mc.hostReadDataValid));
        mc.backendRequestAccepted;
        phase <= 3;
    endrule

    rule phaseReadWait (phase == 3);
        $display("MEMCTRLTRACE|v1|case=read_wait|state=%0d|host_ready=%0d|backend_valid=%0d|write=%0d|address=%08x|response=%0d",
            pack(mc.debugState), mc.hostRequestReady, mc.backendRequestValid, mc.backendWrite, mc.backendAddress,
            responseCode(mc.hostResponseValid, mc.hostResponseFault, mc.hostReadDataValid));
        mc.backendRespond(False, True, 32'h11223344);
        phase <= 4;
    endrule

    rule phaseReadResponse (phase == 4);
        $display("MEMCTRLTRACE|v1|case=read_response|state=%0d|host_ready=%0d|backend_valid=%0d|write=0|address=00000000|response=%0d",
            pack(mc.debugState), mc.hostRequestReady, mc.backendRequestValid,
            responseCode(mc.hostResponseValid, mc.hostResponseFault, mc.hostReadDataValid));
        phase <= 5;
    endrule

    rule phaseResponseStall (phase == 5);
        $display("MEMCTRLTRACE|v1|case=response_stall|state=%0d|host_ready=%0d|backend_valid=%0d|write=0|address=00000000|response=%0d",
            pack(mc.debugState), mc.hostRequestReady, mc.backendRequestValid,
            responseCode(mc.hostResponseValid, mc.hostResponseFault, mc.hostReadDataValid));
        mc.hostResponseConsumed;
        phase <= 6;
    endrule

    rule phaseWriteIssue (phase == 6);
        mc.hostRequest(True, 32'h00000104, 32'haabbccdd);
        phase <= 7;
    endrule

    rule phaseWriteRequest (phase == 7);
        $display("MEMCTRLTRACE|v1|case=write_request|state=%0d|host_ready=%0d|backend_valid=%0d|write=%0d|address=%08x|response=%0d",
            pack(mc.debugState), mc.hostRequestReady, mc.backendRequestValid, mc.backendWrite, mc.backendAddress,
            responseCode(mc.hostResponseValid, mc.hostResponseFault, mc.hostReadDataValid));
        mc.backendRequestAccepted;
        phase <= 8;
    endrule

    rule phaseWriteWait (phase == 8);
        $display("MEMCTRLTRACE|v1|case=write_wait|state=%0d|host_ready=%0d|backend_valid=%0d|write=%0d|address=%08x|response=%0d",
            pack(mc.debugState), mc.hostRequestReady, mc.backendRequestValid, mc.backendWrite, mc.backendAddress,
            responseCode(mc.hostResponseValid, mc.hostResponseFault, mc.hostReadDataValid));
        mc.backendRespond(False, False, 0);
        phase <= 9;
    endrule

    rule phaseWriteResponse (phase == 9);
        $display("MEMCTRLTRACE|v1|case=write_response|state=%0d|host_ready=%0d|backend_valid=%0d|write=0|address=00000000|response=%0d",
            pack(mc.debugState), mc.hostRequestReady, mc.backendRequestValid,
            responseCode(mc.hostResponseValid, mc.hostResponseFault, mc.hostReadDataValid));
        mc.hostResponseConsumed;
        phase <= 10;
    endrule

    rule phaseMisalignedIssue (phase == 10);
        mc.hostRequest(False, 32'h00000102, 0);
        phase <= 11;
    endrule

    rule phaseMisalignedResponse (phase == 11);
        $display("MEMCTRLTRACE|v1|case=misaligned|state=%0d|host_ready=%0d|backend_valid=%0d|write=0|address=00000000|response=%0d",
            pack(mc.debugState), mc.hostRequestReady, mc.backendRequestValid,
            responseCode(mc.hostResponseValid, mc.hostResponseFault, mc.hostReadDataValid));
        mc.hostResponseConsumed;
        phase <= 12;
    endrule

    rule phaseFaultIssue (phase == 12);
        mc.hostRequest(False, 32'h00000200, 0);
        phase <= 13;
    endrule

    rule phaseFaultAccept (phase == 13);
        mc.backendRequestAccepted;
        phase <= 14;
    endrule

    rule phaseFaultRespond (phase == 14);
        mc.backendRespond(True, False, 0);
        phase <= 15;
    endrule

    rule phaseFaultResponse (phase == 15);
        $display("MEMCTRLTRACE|v1|case=backend_fault|state=%0d|host_ready=%0d|backend_valid=%0d|write=0|address=00000000|response=%0d",
            pack(mc.debugState), mc.hostRequestReady, mc.backendRequestValid,
            responseCode(mc.hostResponseValid, mc.hostResponseFault, mc.hostReadDataValid));
        mc.hostResponseConsumed;
        phase <= 16;
    endrule

    rule phaseResetIssue (phase == 16);
        mc.hostRequest(False, 32'h00000300, 0);
        phase <= 17;
    endrule

    rule phaseReset (phase == 17);
        mc.resetController;
        phase <= 18;
    endrule

    rule phaseResetCheck (phase == 18);
        $display("MEMCTRLTRACE|v1|case=reset|state=%0d|host_ready=%0d|backend_valid=%0d|write=0|address=00000000|response=%0d",
            pack(mc.debugState), mc.hostRequestReady, mc.backendRequestValid,
            responseCode(mc.hostResponseValid, mc.hostResponseFault, mc.hostReadDataValid));
        if (mc.debugState != MemIdle || !mc.hostRequestReady || mc.hostResponseValid) begin
            $display("FAIL memory controller reset state");
            $finish(1);
        end
        $display("PASS memory controller Bluespec deterministic semantics");
        $finish(0);
    endrule
endmodule

endpackage
