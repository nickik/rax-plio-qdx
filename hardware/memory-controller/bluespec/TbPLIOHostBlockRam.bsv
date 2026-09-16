package TbPLIOHostBlockRam;

import Vector::*;
import QLITypes::*;
import QICInterfaces::*;
import PLIOWorkerHost::*;
import PLIOHostDmaM3::*;
import PLIOHostCore::*;
import MemoryController::*;
import BlockRamBackend::*;

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

module mkTbPLIOHostBlockRam(Empty);
    PLIOHostCoreIfc core <- mkPLIOHostCore;
    MemoryControllerIfc mc <- mkMemoryController;
    BlockRamBackendIfc ram <- mkDefaultBlockRamBackend;
    Reg#(Bit#(6)) phase <- mkReg(0);
    Reg#(Bit#(8)) watchdog <- mkReg(0);
    Reg#(Bool) initIssued <- mkReg(False);
    Reg#(Bool) initialized <- mkReg(False);
    HostWorkerRequest dummyWorker = HostWorkerRequest { slot:0, address:0, width:HostW32, write:False, value:0 };

    // Seed the BRAM through its real write interface; there is no simulation
    // preload hook in the hardware backend.
    rule initializeRam (!initIssued && ram.requestReady);
        ram.acceptRequest(True, 32'h00000100, 32'h55667788);
        initIssued <= True;
    endrule

    rule finishRamInitialization (initIssued && !initialized && ram.responseValid);
        if (ram.responseFault || ram.responseReadDataValid) begin
            $display("FAIL BRAM integration initialization");
            $finish(1);
        end
        ram.responseConsumed;
        initialized <= True;
    endrule

    rule forwardBackendRequest (mc.backendRequestValid && ram.requestReady);
        ram.acceptRequest(mc.backendWrite, mc.backendAddress, mc.backendWriteData);
        mc.backendRequestAccepted;
    endrule

    rule forwardBackendResponse (mc.backendResponseReady && ram.responseValid);
        mc.backendRespond(ram.responseFault, ram.responseReadDataValid, ram.responseReadData);
        ram.responseConsumed;
    endrule

    rule phase0Init (phase == 0 && initialized);
        core.bindDma(1, 3, 32'h00000100, 25'h00100, True, True);
        phase <= 1;
    endrule

    rule phase1Request (phase == 1);
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        cards[1] = reqOnly();
        core.advance(cards, False, dummyWorker, False, False, False, False, 0, False);
        phase <= 2;
    endrule

    rule phase2ReadAddress (phase == 2);
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        cards[1] = dmaAddr(32'h30000000, True);
        Vector#(8, PlioIn) outs = core.drive(cards, False);
        if (outs[1].ack) begin
            $display("FAIL BRAM integration read address accepted early");
            $finish(1);
        end
        core.advance(cards, False, dummyWorker, False, False, False, False, 0, False);
        phase <= 3;
    endrule

    rule phase3ReadAddressAck (phase == 3);
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        cards[1] = dmaAddr(32'h30000000, True);
        Vector#(8, PlioIn) outs = core.drive(cards, False);
        if (!outs[1].ack) begin
            $display("FAIL BRAM integration read address ACK");
            $finish(1);
        end
        core.advance(cards, False, dummyWorker, False, False, False, False, 0, False);
        watchdog <= 0;
        phase <= 4;
    endrule

    rule phase4ReadMemRequestReady (phase == 4 && core.debugDmaState == DmaMemRequest && mc.hostRequestReady);
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        cards[1] = reqOnly();
        mc.hostRequest(core.memoryWrite, core.memoryAddress, core.memoryWriteData);
        core.advance(cards, False, dummyWorker, True, False, False, False, 0, False);
        watchdog <= watchdog + 1;
        if (watchdog == 40) begin $display("FAIL BRAM integration read watchdog"); $finish(1); end
    endrule

    rule phase4ReadMemRequestStall (phase == 4 && core.debugDmaState == DmaMemRequest && !mc.hostRequestReady);
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        cards[1] = reqOnly();
        core.advance(cards, False, dummyWorker, False, False, False, False, 0, False);
        watchdog <= watchdog + 1;
        if (watchdog == 40) begin $display("FAIL BRAM integration read watchdog"); $finish(1); end
    endrule

    rule phase4ReadMemResponseReady (phase == 4 && core.debugDmaState == DmaMemResponse && mc.hostResponseValid);
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        cards[1] = reqOnly();
        Bool fault = mc.hostResponseFault;
        Bool readValid = mc.hostReadDataValid;
        Bit#(32) readData = mc.hostReadData;
        core.advance(cards, False, dummyWorker, False, True, fault, readValid, readData, False);
        mc.hostResponseConsumed;
        watchdog <= watchdog + 1;
        if (watchdog == 40) begin $display("FAIL BRAM integration read watchdog"); $finish(1); end
    endrule

    rule phase4ReadMemResponseWait (phase == 4 && core.debugDmaState == DmaMemResponse && !mc.hostResponseValid);
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        cards[1] = reqOnly();
        core.advance(cards, False, dummyWorker, False, False, False, False, 0, False);
        watchdog <= watchdog + 1;
        if (watchdog == 40) begin $display("FAIL BRAM integration read watchdog"); $finish(1); end
    endrule

    rule phase4ReadReady (phase == 4 && core.debugDmaState == DmaReadReady);
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        cards[1] = reqOnly();
        cards[1].dataStrobe = True;
        Vector#(8, PlioIn) outs = core.drive(cards, False);
        if (!outs[1].ack || !outs[1].adValid || outs[1].ad != 32'h55667788) begin
            $display("FAIL BRAM integration read data");
            $finish(1);
        end
        core.advance(cards, False, dummyWorker, False, False, False, False, 0, False);
        phase <= 5;
    endrule

    rule phase4ReadUnexpected (phase == 4 && core.debugDmaState != DmaMemRequest && core.debugDmaState != DmaMemResponse && core.debugDmaState != DmaReadReady);
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        cards[1] = reqOnly();
        core.advance(cards, False, dummyWorker, False, False, False, False, 0, False);
        watchdog <= watchdog + 1;
        if (watchdog == 40) begin $display("FAIL BRAM integration read watchdog"); $finish(1); end
    endrule

    rule phase5ReadCompletion (phase == 5);
        if (!core.dmaCompletionValid || core.dmaCompletionStatus != DmaOk || core.dmaCompletionBeats != 1) begin
            $display("FAIL BRAM integration read completion");
            $finish(1);
        end
        core.clearDmaCompletion;
        $display("MEMHOSTTRACE|v1|case=dma_read|status=ok|value=55667788|backend=bram");
        phase <= 6;
    endrule

    rule phase6WriteRequest (phase == 6);
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        cards[1] = reqOnly();
        core.advance(cards, False, dummyWorker, False, False, False, False, 0, False);
        phase <= 7;
    endrule

    rule phase7WriteAddress (phase == 7);
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        cards[1] = dmaAddr(32'h30000004, False);
        core.advance(cards, False, dummyWorker, False, False, False, False, 0, False);
        phase <= 8;
    endrule

    rule phase8WriteAddressAck (phase == 8);
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        cards[1] = dmaAddr(32'h30000004, False);
        Vector#(8, PlioIn) outs = core.drive(cards, False);
        if (!outs[1].ack) begin
            $display("FAIL BRAM integration write address ACK");
            $finish(1);
        end
        core.advance(cards, False, dummyWorker, False, False, False, False, 0, False);
        phase <= 9;
    endrule

    rule phase9WriteData (phase == 9);
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        cards[1] = dmaData(32'hcafebabe);
        core.advance(cards, False, dummyWorker, False, False, False, False, 0, False);
        watchdog <= 0;
        phase <= 10;
    endrule

    rule phase10WriteMemRequestReady (phase == 10 && core.debugDmaState == DmaMemRequest && mc.hostRequestReady);
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        cards[1] = reqOnly();
        mc.hostRequest(core.memoryWrite, core.memoryAddress, core.memoryWriteData);
        core.advance(cards, False, dummyWorker, True, False, False, False, 0, False);
        watchdog <= watchdog + 1;
        if (watchdog == 40) begin $display("FAIL BRAM integration write watchdog"); $finish(1); end
    endrule

    rule phase10WriteMemRequestStall (phase == 10 && core.debugDmaState == DmaMemRequest && !mc.hostRequestReady);
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        cards[1] = reqOnly();
        core.advance(cards, False, dummyWorker, False, False, False, False, 0, False);
        watchdog <= watchdog + 1;
        if (watchdog == 40) begin $display("FAIL BRAM integration write watchdog"); $finish(1); end
    endrule

    rule phase10WriteMemResponseReady (phase == 10 && core.debugDmaState == DmaMemResponse && mc.hostResponseValid);
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        cards[1] = reqOnly();
        Bool fault = mc.hostResponseFault;
        Bool readValid = mc.hostReadDataValid;
        Bit#(32) readData = mc.hostReadData;
        core.advance(cards, False, dummyWorker, False, True, fault, readValid, readData, False);
        mc.hostResponseConsumed;
        watchdog <= watchdog + 1;
        if (watchdog == 40) begin $display("FAIL BRAM integration write watchdog"); $finish(1); end
    endrule

    rule phase10WriteMemResponseWait (phase == 10 && core.debugDmaState == DmaMemResponse && !mc.hostResponseValid);
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        cards[1] = reqOnly();
        core.advance(cards, False, dummyWorker, False, False, False, False, 0, False);
        watchdog <= watchdog + 1;
        if (watchdog == 40) begin $display("FAIL BRAM integration write watchdog"); $finish(1); end
    endrule

    rule phase10WriteAck (phase == 10 && core.debugDmaState != DmaMemRequest && core.debugDmaState != DmaMemResponse);
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        cards[1] = reqOnly();
        Vector#(8, PlioIn) outs = core.drive(cards, False);
        core.advance(cards, False, dummyWorker, False, False, False, False, 0, False);
        if (outs[1].ack) begin
            phase <= 11;
        end
        else begin
            watchdog <= watchdog + 1;
            if (watchdog == 40) begin $display("FAIL BRAM integration write watchdog"); $finish(1); end
        end
    endrule

    rule phase11WriteCompletion (phase == 11);
        if (!core.dmaCompletionValid || core.dmaCompletionStatus != DmaOk || core.dmaCompletionBeats != 1) begin
            $display("FAIL BRAM integration write completion");
            $finish(1);
        end
        core.clearDmaCompletion;
        $display("MEMHOSTTRACE|v1|case=dma_write|status=ok|value=cafebabe|backend=bram");
        phase <= 12;
    endrule

    rule phase12FaultBind (phase == 12);
        // Default BRAM is 64 KiB; 0x10000 is the first invalid byte address.
        core.bindDma(1, 4, 32'h00010000, 25'h00100, True, False);
        phase <= 13;
    endrule

    rule phase13FaultRequest (phase == 13);
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        cards[1] = reqOnly();
        core.advance(cards, False, dummyWorker, False, False, False, False, 0, False);
        phase <= 14;
    endrule

    rule phase14FaultAddress (phase == 14);
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        cards[1] = dmaAddr(32'h40000000, True);
        core.advance(cards, False, dummyWorker, False, False, False, False, 0, False);
        phase <= 15;
    endrule

    rule phase15FaultAddressAck (phase == 15);
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        cards[1] = dmaAddr(32'h40000000, True);
        Vector#(8, PlioIn) outs = core.drive(cards, False);
        if (!outs[1].ack) begin
            $display("FAIL BRAM integration fault address ACK");
            $finish(1);
        end
        core.advance(cards, False, dummyWorker, False, False, False, False, 0, False);
        watchdog <= 0;
        phase <= 16;
    endrule

    rule phase16FaultMemRequestReady (phase == 16 && core.debugDmaState == DmaMemRequest && mc.hostRequestReady);
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        cards[1] = reqOnly();
        mc.hostRequest(core.memoryWrite, core.memoryAddress, core.memoryWriteData);
        core.advance(cards, False, dummyWorker, True, False, False, False, 0, False);
        watchdog <= watchdog + 1;
        if (watchdog == 40) begin $display("FAIL BRAM integration fault watchdog"); $finish(1); end
    endrule

    rule phase16FaultMemRequestStall (phase == 16 && core.debugDmaState == DmaMemRequest && !mc.hostRequestReady);
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        cards[1] = reqOnly();
        core.advance(cards, False, dummyWorker, False, False, False, False, 0, False);
        watchdog <= watchdog + 1;
        if (watchdog == 40) begin $display("FAIL BRAM integration fault watchdog"); $finish(1); end
    endrule

    rule phase16FaultMemResponseReady (phase == 16 && core.debugDmaState == DmaMemResponse && mc.hostResponseValid);
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        cards[1] = reqOnly();
        Bool fault = mc.hostResponseFault;
        Bool readValid = mc.hostReadDataValid;
        Bit#(32) readData = mc.hostReadData;
        core.advance(cards, False, dummyWorker, False, True, fault, readValid, readData, False);
        mc.hostResponseConsumed;
        watchdog <= watchdog + 1;
        if (watchdog == 40) begin $display("FAIL BRAM integration fault watchdog"); $finish(1); end
    endrule

    rule phase16FaultMemResponseWait (phase == 16 && core.debugDmaState == DmaMemResponse && !mc.hostResponseValid);
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        cards[1] = reqOnly();
        core.advance(cards, False, dummyWorker, False, False, False, False, 0, False);
        watchdog <= watchdog + 1;
        if (watchdog == 40) begin $display("FAIL BRAM integration fault watchdog"); $finish(1); end
    endrule

    rule phase16FaultErr (phase == 16 && core.debugDmaState != DmaMemRequest && core.debugDmaState != DmaMemResponse);
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        cards[1] = reqOnly();
        Vector#(8, PlioIn) outs = core.drive(cards, False);
        core.advance(cards, False, dummyWorker, False, False, False, False, 0, False);
        if (outs[1].err) begin
            phase <= 17;
        end
        else begin
            watchdog <= watchdog + 1;
            if (watchdog == 40) begin $display("FAIL BRAM integration fault watchdog"); $finish(1); end
        end
    endrule

    rule phase17FaultCompletion (phase == 17);
        if (!core.dmaCompletionValid || core.dmaCompletionStatus != DmaMemoryFault) begin
            $display("FAIL BRAM integration fault completion");
            $finish(1);
        end
        $display("MEMHOSTTRACE|v1|case=backend_fault|status=memory_fault|backend=bram");
        $display("PASS block RAM PLIO host integration");
        $finish(0);
    endrule
endmodule

endpackage
