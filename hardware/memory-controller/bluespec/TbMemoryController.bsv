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

    rule run;
        case (phase)
            0: begin
                $display("MEMCTRLTRACE|v1|case=idle|state=%0d|host_ready=%0d|backend_valid=%0d|write=0|address=00000000|response=%0d",
                    pack(mc.debugState), mc.hostRequestReady, mc.backendRequestValid,
                    responseCode(mc.hostResponseValid, mc.hostResponseFault, mc.hostReadDataValid));
                mc.hostRequest(False, 32'h00000100, 0);
                phase <= 1;
            end
            1: begin
                $display("MEMCTRLTRACE|v1|case=read_request|state=%0d|host_ready=%0d|backend_valid=%0d|write=%0d|address=%08x|response=%0d",
                    pack(mc.debugState), mc.hostRequestReady, mc.backendRequestValid, mc.backendWrite, mc.backendAddress,
                    responseCode(mc.hostResponseValid, mc.hostResponseFault, mc.hostReadDataValid));
                phase <= 2;
            end
            2: begin
                $display("MEMCTRLTRACE|v1|case=read_stall|state=%0d|host_ready=%0d|backend_valid=%0d|write=%0d|address=%08x|response=%0d",
                    pack(mc.debugState), mc.hostRequestReady, mc.backendRequestValid, mc.backendWrite, mc.backendAddress,
                    responseCode(mc.hostResponseValid, mc.hostResponseFault, mc.hostReadDataValid));
                mc.backendRequestAccepted;
                phase <= 3;
            end
            3: begin
                $display("MEMCTRLTRACE|v1|case=read_wait|state=%0d|host_ready=%0d|backend_valid=%0d|write=%0d|address=%08x|response=%0d",
                    pack(mc.debugState), mc.hostRequestReady, mc.backendRequestValid, mc.backendWrite, mc.backendAddress,
                    responseCode(mc.hostResponseValid, mc.hostResponseFault, mc.hostReadDataValid));
                mc.backendRespond(False, True, 32'h11223344);
                phase <= 4;
            end
            4: begin
                $display("MEMCTRLTRACE|v1|case=read_response|state=%0d|host_ready=%0d|backend_valid=%0d|write=0|address=00000000|response=%0d",
                    pack(mc.debugState), mc.hostRequestReady, mc.backendRequestValid,
                    responseCode(mc.hostResponseValid, mc.hostResponseFault, mc.hostReadDataValid));
                phase <= 5;
            end
            5: begin
                $display("MEMCTRLTRACE|v1|case=response_stall|state=%0d|host_ready=%0d|backend_valid=%0d|write=0|address=00000000|response=%0d",
                    pack(mc.debugState), mc.hostRequestReady, mc.backendRequestValid,
                    responseCode(mc.hostResponseValid, mc.hostResponseFault, mc.hostReadDataValid));
                mc.hostResponseConsumed;
                phase <= 6;
            end
            6: begin
                mc.hostRequest(True, 32'h00000104, 32'haabbccdd);
                phase <= 7;
            end
            7: begin
                $display("MEMCTRLTRACE|v1|case=write_request|state=%0d|host_ready=%0d|backend_valid=%0d|write=%0d|address=%08x|response=%0d",
                    pack(mc.debugState), mc.hostRequestReady, mc.backendRequestValid, mc.backendWrite, mc.backendAddress,
                    responseCode(mc.hostResponseValid, mc.hostResponseFault, mc.hostReadDataValid));
                mc.backendRequestAccepted;
                phase <= 8;
            end
            8: begin
                $display("MEMCTRLTRACE|v1|case=write_wait|state=%0d|host_ready=%0d|backend_valid=%0d|write=%0d|address=%08x|response=%0d",
                    pack(mc.debugState), mc.hostRequestReady, mc.backendRequestValid, mc.backendWrite, mc.backendAddress,
                    responseCode(mc.hostResponseValid, mc.hostResponseFault, mc.hostReadDataValid));
                mc.backendRespond(False, False, 0);
                phase <= 9;
            end
            9: begin
                $display("MEMCTRLTRACE|v1|case=write_response|state=%0d|host_ready=%0d|backend_valid=%0d|write=0|address=00000000|response=%0d",
                    pack(mc.debugState), mc.hostRequestReady, mc.backendRequestValid,
                    responseCode(mc.hostResponseValid, mc.hostResponseFault, mc.hostReadDataValid));
                mc.hostResponseConsumed;
                phase <= 10;
            end
            10: begin
                mc.hostRequest(False, 32'h00000102, 0);
                phase <= 11;
            end
            11: begin
                $display("MEMCTRLTRACE|v1|case=misaligned|state=%0d|host_ready=%0d|backend_valid=%0d|write=0|address=00000000|response=%0d",
                    pack(mc.debugState), mc.hostRequestReady, mc.backendRequestValid,
                    responseCode(mc.hostResponseValid, mc.hostResponseFault, mc.hostReadDataValid));
                mc.hostResponseConsumed;
                phase <= 12;
            end
            12: begin mc.hostRequest(False, 32'h00000200, 0); phase <= 13; end
            13: begin mc.backendRequestAccepted; phase <= 14; end
            14: begin mc.backendRespond(True, False, 0); phase <= 15; end
            15: begin
                $display("MEMCTRLTRACE|v1|case=backend_fault|state=%0d|host_ready=%0d|backend_valid=%0d|write=0|address=00000000|response=%0d",
                    pack(mc.debugState), mc.hostRequestReady, mc.backendRequestValid,
                    responseCode(mc.hostResponseValid, mc.hostResponseFault, mc.hostReadDataValid));
                mc.hostResponseConsumed;
                phase <= 16;
            end
            16: begin mc.hostRequest(False, 32'h00000300, 0); phase <= 17; end
            17: begin mc.resetController; phase <= 18; end
            18: begin
                $display("MEMCTRLTRACE|v1|case=reset|state=%0d|host_ready=%0d|backend_valid=%0d|write=0|address=00000000|response=%0d",
                    pack(mc.debugState), mc.hostRequestReady, mc.backendRequestValid,
                    responseCode(mc.hostResponseValid, mc.hostResponseFault, mc.hostReadDataValid));
                if (mc.debugState != MemIdle || !mc.hostRequestReady || mc.hostResponseValid) begin
                    $display("FAIL memory controller reset state");
                    $finish(1);
                end
                $display("PASS memory controller Bluespec deterministic semantics");
                $finish(0);
            end
        endcase
    endrule
endmodule

endpackage
