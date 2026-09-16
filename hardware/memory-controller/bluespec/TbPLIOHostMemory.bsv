package TbPLIOHostMemory;

import Vector::*;
import QLITypes::*;
import QICInterfaces::*;
import PLIOWorkerHost::*;
import PLIOHostDmaM3::*;
import PLIOHostCore::*;
import MemoryController::*;

function Bit#(4) tbParity(Bit#(32) word);
    return { ~(^word[31:24]), ~(^word[23:16]), ~(^word[15:8]), ~(^word[7:0]) };
endfunction

function PlioOut reqOnly();
    PlioOut c = plioOutDefault();
    c.request = True;
    return c;
endfunction

function PlioOut dmaAddr(Bit#(32) address, Bool rd);
    PlioOut c = reqOnly();
    c.adValid = True;
    c.ad = address;
    c.parValid = True;
    c.parity = tbParity(address);
    c.spaceValid = True;
    c.space = PlioHostDma;
    c.addressStrobe = True;
    c.read = rd;
    c.byteEnable = 4'hf;
    c.burst = BurstOne;
    return c;
endfunction

function PlioOut dmaData(Bit#(32) data);
    PlioOut c = reqOnly();
    c.adValid = True;
    c.ad = data;
    c.parValid = True;
    c.parity = tbParity(data);
    c.dataStrobe = True;
    c.byteEnable = 4'hf;
    return c;
endfunction

module mkTbPLIOHostMemory(Empty);
    PLIOHostCoreIfc core <- mkPLIOHostCore;
    MemoryControllerIfc mc <- mkMemoryController;
    FakeMemoryBackendIfc ram <- mkFakeMemoryBackend(8'd2);
    Reg#(Bit#(6)) phase <- mkReg(0);
    Reg#(Bit#(8)) watchdog <- mkReg(0);
    HostWorkerRequest dummyWorker = HostWorkerRequest { slot:0, address:0, width:HostW32, write:False, value:0 };

    // Keep the four mutually exclusive MemoryController actions in separate
    // rules.  Putting hostRequest/backendRequestAccepted/backendRespond/
    // hostResponseConsumed into the phase rule makes BSC conjoin their
    // readiness conditions and remove the whole rule as unsatisfiable.
    rule forwardBackendRequest (mc.backendRequestValid && ram.requestReady);
        ram.acceptRequest(mc.backendWrite, mc.backendAddress, mc.backendWriteData);
        mc.backendRequestAccepted;
    endrule

    rule forwardBackendResponse (mc.backendResponseReady && ram.responseValid);
        mc.backendRespond(ram.responseFault, ram.responseReadDataValid, ram.responseReadData);
        ram.responseConsumed;
    endrule

    rule acceptHostMemoryRequest (core.memoryRequestValid && mc.hostRequestReady);
        mc.hostRequest(core.memoryWrite, core.memoryAddress, core.memoryWriteData);
    endrule

    rule consumeHostMemoryResponse (mc.hostResponseValid && core.debugDmaState == DmaMemResponse);
        mc.hostResponseConsumed;
    endrule

    rule run;
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        Vector#(8, PlioIn) outs = replicate(plioInDefault());
        Bool advanceCore = True;

        case (phase)
            0: begin
                ram.preload(32'h00000100, 32'h55667788);
                ram.setRequestHoldoff(8'd3);
                core.bindDma(1, 3, 32'h00000100, 25'h00100, True, True);
                advanceCore = False;
                phase <= 1;
            end
            1: begin
                cards[1] = reqOnly();
                phase <= 2;
            end
            2: begin
                cards[1] = dmaAddr(32'h30000000, True);
                outs = core.drive(cards, False);
                if (outs[1].ack) begin $display("FAIL memory integration read address accepted early"); $finish(1); end
                phase <= 3;
            end
            3: begin
                cards[1] = dmaAddr(32'h30000000, True);
                outs = core.drive(cards, False);
                if (!outs[1].ack) begin $display("FAIL memory integration read address ACK"); $finish(1); end
                phase <= 4;
                watchdog <= 0;
            end
            4: begin
                cards[1] = reqOnly();
                if (core.debugDmaState == DmaReadReady) begin
                    cards[1].dataStrobe = True;
                    outs = core.drive(cards, False);
                    if (!outs[1].ack || !outs[1].adValid || outs[1].ad != 32'h55667788) begin
                        $display("FAIL memory integration read data");
                        $finish(1);
                    end
                    phase <= 5;
                end
                else begin
                    watchdog <= watchdog + 1;
                    if (watchdog == 40) begin $display("FAIL memory integration read watchdog"); $finish(1); end
                end
            end
            5: begin
                if (!core.dmaCompletionValid || core.dmaCompletionStatus != DmaOk || core.dmaCompletionBeats != 1) begin
                    $display("FAIL memory integration read completion");
                    $finish(1);
                end
                core.clearDmaCompletion;
                $display("MEMHOSTTRACE|v1|case=dma_read|status=ok|value=55667788|backend=fake");
                phase <= 6;
            end
            6: begin
                cards[1] = reqOnly();
                phase <= 7;
            end
            7: begin
                cards[1] = dmaAddr(32'h30000004, False);
                phase <= 8;
            end
            8: begin
                cards[1] = dmaAddr(32'h30000004, False);
                outs = core.drive(cards, False);
                if (!outs[1].ack) begin $display("FAIL memory integration write address ACK"); $finish(1); end
                phase <= 9;
            end
            9: begin
                cards[1] = dmaData(32'hcafebabe);
                phase <= 10;
                watchdog <= 0;
            end
            10: begin
                cards[1] = reqOnly();
                outs = core.drive(cards, False);
                if (outs[1].ack) begin
                    phase <= 11;
                end
                else begin
                    watchdog <= watchdog + 1;
                    if (watchdog == 40) begin $display("FAIL memory integration write watchdog"); $finish(1); end
                end
            end
            11: begin
                if (ram.peek(32'h00000104) != 32'hcafebabe) begin $display("FAIL memory integration write memory"); $finish(1); end
                if (!core.dmaCompletionValid || core.dmaCompletionStatus != DmaOk || core.dmaCompletionBeats != 1) begin
                    $display("FAIL memory integration write completion");
                    $finish(1);
                end
                core.clearDmaCompletion;
                $display("MEMHOSTTRACE|v1|case=dma_write|status=ok|value=cafebabe|backend=fake");
                phase <= 12;
            end
            12: begin
                core.bindDma(1, 4, 32'h00004000, 25'h00100, True, False);
                advanceCore = False;
                phase <= 13;
            end
            13: begin cards[1] = reqOnly(); phase <= 14; end
            14: begin cards[1] = dmaAddr(32'h40000000, True); phase <= 15; end
            15: begin
                cards[1] = dmaAddr(32'h40000000, True);
                outs = core.drive(cards, False);
                if (!outs[1].ack) begin $display("FAIL memory integration fault address ACK"); $finish(1); end
                phase <= 16;
                watchdog <= 0;
            end
            16: begin
                cards[1] = reqOnly();
                outs = core.drive(cards, False);
                if (outs[1].err) begin
                    phase <= 17;
                end
                else begin
                    watchdog <= watchdog + 1;
                    if (watchdog == 40) begin $display("FAIL memory integration fault watchdog"); $finish(1); end
                end
            end
            17: begin
                advanceCore = False;
                if (!core.dmaCompletionValid || core.dmaCompletionStatus != DmaMemoryFault) begin
                    $display("FAIL memory integration fault completion");
                    $finish(1);
                end
                $display("MEMHOSTTRACE|v1|case=backend_fault|status=memory_fault|backend=fake");
                $display("PASS memory controller Bluespec + PLIO host integration");
                $finish(0);
            end
        endcase

        if (advanceCore) begin
            Bool requestReady = mc.hostRequestReady;
            Bool responseValid = mc.hostResponseValid;
            Bool responseFault = mc.hostResponseFault;
            Bool readDataValid = mc.hostReadDataValid;
            Bit#(32) readData = mc.hostReadData;

            core.advance(cards, False, dummyWorker,
                requestReady, responseValid, responseFault, readDataValid, readData, False);
        end
    endrule
endmodule

endpackage
