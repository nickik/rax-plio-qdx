package TbBlockRamByteLanes;

import BlockRamBackend::*;

module mkTbBlockRamByteLanes(Empty);
    BlockRamBackendIfc ram <- mkDefaultBlockRamBackend;
    Reg#(Bit#(6)) phase <- mkReg(0);
    Reg#(Bit#(16)) cycles <- mkReg(0);

    rule watchdog;
        cycles <= cycles + 1;
        if (cycles == 1200) begin
            $display("FAIL BRAM byte-lane watchdog");
            $finish(1);
        end
    endrule

    function Action issueWrite(Bit#(32) address, Bit#(4) be, Bit#(32) data);
        action
            ram.acceptRequest(True, address, be, data);
        endaction
    endfunction

    function Action issueRead(Bit#(32) address);
        action
            ram.acceptRequest(False, address, 4'hf, 0);
        endaction
    endfunction

    function Action consumeWrite(Bit#(6) nextPhase);
        action
            if (ram.responseFault || ram.responseReadDataValid) begin
                $display("FAIL BRAM write response phase=%0d", phase);
                $finish(1);
            end
            ram.responseConsumed;
            phase <= nextPhase;
        endaction
    endfunction

    function Action checkRead(Bit#(32) expected, Bit#(6) nextPhase, String label);
        action
            if (ram.responseFault || !ram.responseReadDataValid || ram.responseReadData != expected) begin
                $display("FAIL BRAM %s expected=%08x got=%08x", label, expected, ram.responseReadData);
                $finish(1);
            end
            $display("MEMBRAMLANE|case=%s|status=ok|value=%08x", label, ram.responseReadData);
            ram.responseConsumed;
            phase <= nextPhase;
        endaction
    endfunction

    // Seed five independent words. Four prove each physical byte lane; the fifth
    // proves BE=0000 leaves every lane untouched.
    rule p0 (phase == 0 && ram.requestReady); issueWrite(32'h200, 4'hf, 32'h11223344); phase <= 1; endrule
    rule p1 (phase == 1 && ram.responseValid); consumeWrite(2); endrule
    rule p2 (phase == 2 && ram.requestReady); issueWrite(32'h204, 4'hf, 32'h11223344); phase <= 3; endrule
    rule p3 (phase == 3 && ram.responseValid); consumeWrite(4); endrule
    rule p4 (phase == 4 && ram.requestReady); issueWrite(32'h208, 4'hf, 32'h11223344); phase <= 5; endrule
    rule p5 (phase == 5 && ram.responseValid); consumeWrite(6); endrule
    rule p6 (phase == 6 && ram.requestReady); issueWrite(32'h20c, 4'hf, 32'h11223344); phase <= 7; endrule
    rule p7 (phase == 7 && ram.responseValid); consumeWrite(8); endrule
    rule p8 (phase == 8 && ram.requestReady); issueWrite(32'h210, 4'hf, 32'h11223344); phase <= 9; endrule
    rule p9 (phase == 9 && ram.responseValid); consumeWrite(10); endrule

    rule p10 (phase == 10 && ram.requestReady); issueWrite(32'h200, 4'h1, 32'haabbccdd); phase <= 11; endrule
    rule p11 (phase == 11 && ram.responseValid); consumeWrite(12); endrule
    rule p12 (phase == 12 && ram.requestReady); issueWrite(32'h204, 4'h2, 32'haabbccdd); phase <= 13; endrule
    rule p13 (phase == 13 && ram.responseValid); consumeWrite(14); endrule
    rule p14 (phase == 14 && ram.requestReady); issueWrite(32'h208, 4'h4, 32'haabbccdd); phase <= 15; endrule
    rule p15 (phase == 15 && ram.responseValid); consumeWrite(16); endrule
    rule p16 (phase == 16 && ram.requestReady); issueWrite(32'h20c, 4'h8, 32'haabbccdd); phase <= 17; endrule
    rule p17 (phase == 17 && ram.responseValid); consumeWrite(18); endrule
    rule p18 (phase == 18 && ram.requestReady); issueWrite(32'h210, 4'h0, 32'hffffffff); phase <= 19; endrule
    rule p19 (phase == 19 && ram.responseValid); consumeWrite(20); endrule

    rule p20 (phase == 20 && ram.requestReady); issueRead(32'h200); phase <= 21; endrule
    rule p21 (phase == 21 && ram.responseValid); checkRead(32'h112233dd, 22, "lane0"); endrule
    rule p22 (phase == 22 && ram.requestReady); issueRead(32'h204); phase <= 23; endrule
    rule p23 (phase == 23 && ram.responseValid); checkRead(32'h1122cc44, 24, "lane1"); endrule
    rule p24 (phase == 24 && ram.requestReady); issueRead(32'h208); phase <= 25; endrule
    rule p25 (phase == 25 && ram.responseValid); checkRead(32'h11bb3344, 26, "lane2"); endrule
    rule p26 (phase == 26 && ram.requestReady); issueRead(32'h20c); phase <= 27; endrule
    rule p27 (phase == 27 && ram.responseValid); checkRead(32'haa223344, 28, "lane3"); endrule
    rule p28 (phase == 28 && ram.requestReady); issueRead(32'h210); phase <= 29; endrule
    rule p29 (phase == 29 && ram.responseValid);
        if (ram.responseFault || !ram.responseReadDataValid || ram.responseReadData != 32'h11223344) begin
            $display("FAIL BRAM zero-mask expected=11223344 got=%08x", ram.responseReadData);
            $finish(1);
        end
        $display("MEMBRAMLANE|case=mask0000|status=ok|value=11223344");
        ram.responseConsumed;
        $display("PASS FPGA BRAM independent byte-lane semantics");
        $finish(0);
    endrule
endmodule

endpackage
