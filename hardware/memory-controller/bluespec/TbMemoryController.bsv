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

    rule phaseIdle (phase == 0);
        $display("MEMCTRLTRACE|v2|case=idle|state=%0d|host_ready=%0d|backend_valid=%0d|write=0|address=00000000|be=0|response=%0d",
            pack(mc.debugState), mc.hostRequestReady, mc.backendRequestValid,
            responseCode(mc.hostResponseValid, mc.hostResponseFault, mc.hostReadDataValid));
        mc.hostRequest(False, 32'h00000100, 4'hf, 0);
        phase <= 1;
    endrule

    rule phaseReadRequest (phase == 1);
        $display("MEMCTRLTRACE|v2|case=read_request|state=%0d|host_ready=%0d|backend_valid=%0d|write=%0d|address=%08x|be=%x|response=%0d",
            pack(mc.debugState), mc.hostRequestReady, mc.backendRequestValid, mc.backendWrite, mc.backendAddress, mc.backendByteEnable,
            responseCode(mc.hostResponseValid, mc.hostResponseFault, mc.hostReadDataValid));
        if (mc.backendByteEnable != 4'hf) begin $display("FAIL read byte enable"); $finish(1); end
        phase <= 2;
    endrule

    rule phaseReadStall (phase == 2);
        if (mc.backendByteEnable != 4'hf) begin $display("FAIL read byte enable changed under stall"); $finish(1); end
        mc.backendRequestAccepted;
        phase <= 3;
    endrule

    rule phaseReadWait (phase == 3);
        mc.backendRespond(False, True, 32'h11223344);
        phase <= 4;
    endrule

    rule phaseReadResponse (phase == 4);
        if (!mc.hostResponseValid || mc.hostResponseFault || !mc.hostReadDataValid || mc.hostReadData != 32'h11223344) begin
            $display("FAIL read response"); $finish(1);
        end
        mc.hostResponseConsumed;
        phase <= 5;
    endrule

    rule phaseWriteIssue (phase == 5);
        mc.hostRequest(True, 32'h00000104, 4'h5, 32'haabbccdd);
        phase <= 6;
    endrule

    rule phaseWriteRequest (phase == 6);
        $display("MEMCTRLTRACE|v2|case=write_request|state=%0d|host_ready=%0d|backend_valid=%0d|write=%0d|address=%08x|be=%x|data=%08x|response=%0d",
            pack(mc.debugState), mc.hostRequestReady, mc.backendRequestValid, mc.backendWrite, mc.backendAddress, mc.backendByteEnable, mc.backendWriteData,
            responseCode(mc.hostResponseValid, mc.hostResponseFault, mc.hostReadDataValid));
        if (!mc.backendWrite || mc.backendAddress != 32'h00000104 || mc.backendByteEnable != 4'h5 || mc.backendWriteData != 32'haabbccdd) begin
            $display("FAIL write request payload"); $finish(1);
        end
        phase <= 7;
    endrule

    rule phaseWriteStall (phase == 7);
        if (mc.backendByteEnable != 4'h5) begin $display("FAIL write byte enable changed under stall"); $finish(1); end
        mc.backendRequestAccepted;
        phase <= 8;
    endrule

    rule phaseWriteWait (phase == 8);
        mc.backendRespond(False, False, 0);
        phase <= 9;
    endrule

    rule phaseWriteResponse (phase == 9);
        if (!mc.hostResponseValid || mc.hostResponseFault || mc.hostReadDataValid) begin
            $display("FAIL write response"); $finish(1);
        end
        mc.hostResponseConsumed;
        phase <= 10;
    endrule

    rule phaseMisalignedIssue (phase == 10);
        mc.hostRequest(False, 32'h00000102, 4'hf, 0);
        phase <= 11;
    endrule

    rule phaseMisalignedResponse (phase == 11);
        if (!mc.hostResponseValid || !mc.hostResponseFault || mc.backendRequestValid) begin
            $display("FAIL misaligned request handling"); $finish(1);
        end
        mc.hostResponseConsumed;
        phase <= 12;
    endrule

    rule phaseFaultIssue (phase == 12);
        mc.hostRequest(False, 32'h00000200, 4'hf, 0);
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
        if (!mc.hostResponseValid || !mc.hostResponseFault) begin
            $display("FAIL backend fault propagation"); $finish(1);
        end
        mc.hostResponseConsumed;
        phase <= 16;
    endrule

    rule phaseResetIssue (phase == 16);
        mc.hostRequest(True, 32'h00000300, 4'ha, 32'hdeadbeef);
        phase <= 17;
    endrule

    rule phaseReset (phase == 17);
        if (mc.backendByteEnable != 4'ha) begin $display("FAIL reset precondition byte enable"); $finish(1); end
        mc.resetController;
        phase <= 18;
    endrule

    rule phaseResetCheck (phase == 18);
        if (mc.debugState != MemIdle || !mc.hostRequestReady || mc.hostResponseValid || mc.backendRequestValid || mc.backendByteEnable != 0) begin
            $display("FAIL memory controller reset state");
            $finish(1);
        end
        $display("MEMCTRLTRACE|v2|case=reset|status=ok|be=0");
        $display("PASS memory controller byte-enable semantics");
        $finish(0);
    endrule
endmodule

endpackage
