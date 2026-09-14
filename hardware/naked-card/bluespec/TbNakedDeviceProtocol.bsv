package TbNakedDeviceProtocol;

import QLITypes::*;
import NakedDevice::*;

module mkTbNakedDeviceProtocol(Empty);
    NakedDeviceIfc dut <- mkNakedDevice;
    Reg#(Bit#(4)) step <- mkReg(0);
    Reg#(Bit#(2)) holdCount <- mkReg(0);
    Reg#(MmioResponse) held <- mkReg(mmioError());

    rule issueRead (step == 0 && dut.requestReady);
        dut.request(MmioRequest {
            address: 32'h0000_0000,
            write: False,
            byteEnable: 4'hf,
            writeData: 0
        });
        step <= 1;
    endrule

    rule captureResponse (step == 1 && dut.responseValid);
        MmioResponse got = dut.response;
        if (got != mmioReadOk(32'h504c_494f)) begin
            $display("FAIL first response");
            $finish(1);
        end
        held <= got;
        holdCount <= 0;
        step <= 2;
    endrule

    // Deliberately withhold responseTaken for three clocks. The response must
    // remain valid and stable and requestReady must remain false.
    rule holdResponse (step == 2 && dut.responseValid);
        if (dut.response != held || dut.requestReady) begin
            $display("FAIL response was not held stable under backpressure");
            $finish(1);
        end

        if (holdCount == 2) begin
            dut.responseTaken;
            step <= 3;
        end
        else begin
            holdCount <= holdCount + 1;
        end
    endrule

    rule issueSecond (step == 3 && dut.requestReady);
        dut.request(MmioRequest {
            address: 32'h0000_0010,
            write: False,
            byteEnable: 4'hf,
            writeData: 0
        });
        step <= 4;
    endrule

    // Cancel a pending response with resetDevice rather than consuming it.
    rule resetPending (step == 4 && dut.responseValid);
        dut.resetDevice;
        step <= 5;
    endrule

    rule verifyReset (step == 5);
        if (dut.responseValid || !dut.requestReady) begin
            $display("FAIL reset did not clear pending QLI response");
            $finish(1);
        end
        $display("PASS NakedDevice handshake/reset");
        step <= 6;
    endrule

    rule finish (step == 6);
        $finish(0);
    endrule
endmodule

endpackage
