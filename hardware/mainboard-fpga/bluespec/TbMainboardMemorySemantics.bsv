package TbMainboardMemorySemantics;

import Vector::*;
import QLITypes::*;
import QICInterfaces::*;
import PLIOTx::*;
import PLIOWorkerHost::*;
import PLIOHostDmaM3::*;
import MemoryController::*;
import LightingMemoryBusCompat::*;
import MainboardFPGA::*;

function Vector#(8, BackplaneDrive) idleCards();
    return replicate(backplaneDriveDefault());
endfunction

function HostWorkerRequest noWorkerRequest();
    return HostWorkerRequest {
        slot: 0,
        address: 0,
        width: HostW32,
        write: False,
        value: 0
    };
endfunction

function Bit#(4) parity32(Bit#(32) word);
    return { ~(^word[31:24]), ~(^word[23:16]), ~(^word[15:8]), ~(^word[7:0]) };
endfunction

function BackplaneDrive requestOnly();
    BackplaneDrive d = backplaneDriveDefault();
    d.request = True;
    return d;
endfunction

function BackplaneDrive dmaAddress(Bit#(32) handle, Bool readDirection);
    BackplaneDrive d = requestOnly();
    BackplaneControl c = backplaneControlDefault();
    c.space = pack(PlioHostDma);
    c.addressStrobe = True;
    c.read = readDirection;
    c.byteEnable = 4'hf;
    c.burstLen = pack(BurstOne);
    d.controlValid = True;
    d.control = c;
    d.adParValid = True;
    d.ad = handle;
    d.parity = parity32(handle);
    return d;
endfunction

function BackplaneDrive dmaReadBeat();
    BackplaneDrive d = requestOnly();
    BackplaneControl c = backplaneControlDefault();
    c.dataStrobe = True;
    d.controlValid = True;
    d.control = c;
    return d;
endfunction

function BackplaneDrive dmaWriteBeat(Bit#(32) data);
    BackplaneDrive d = dmaReadBeat();
    d.adParValid = True;
    d.ad = data;
    d.parity = parity32(data);
    return d;
endfunction

function LightingBusMasterDrive cpuBusRequest();
    LightingBusMasterDrive d = lightingBusMasterDriveDefault();
    d.busRequest = True;
    return d;
endfunction

function LightingBusMasterDrive cpuRequest(Bit#(32) address, Bool write,
    Bit#(4) byteEnable, Bit#(32) writeData);
    LightingBusMasterDrive d = cpuBusRequest();
    d.request = True;
    d.payload.addr = address;
    d.payload.write = write;
    d.payload.byteEnable = byteEnable;
    d.payload.writeData = writeData;
    return d;
endfunction

function Bit#(4) maskForIndex(Bit#(4) index);
    case (index)
        0: return 4'b0001;
        1: return 4'b0010;
        2: return 4'b0100;
        3: return 4'b1000;
        4: return 4'b0011;
        5: return 4'b1100;
        6: return 4'b0101;
        7: return 4'b1010;
        8: return 4'b0000;
        9: return 4'b1111;
        default: return 4'b0000;
    endcase
endfunction

function Bit#(32) expectedMasked(Bit#(32) oldValue, Bit#(32) newValue,
    Bit#(4) byteEnable);
    Bit#(32) mask = 0;
    if (byteEnable[0] == 1'b1) mask = mask | 32'h0000_00ff;
    if (byteEnable[1] == 1'b1) mask = mask | 32'h0000_ff00;
    if (byteEnable[2] == 1'b1) mask = mask | 32'h00ff_0000;
    if (byteEnable[3] == 1'b1) mask = mask | 32'hff00_0000;
    return (oldValue & ~mask) | (newValue & mask);
endfunction

(* synthesize *)
module mkTbMainboardMemorySemantics(Empty);
    MainboardFPGAIfc board <- mkMainboardFPGA;
    FakeMemoryBackendIfc ram <- mkFakeMemoryBackend(8'd2);

    Bit#(32) testAddress = 32'h0000_0400;
    Bit#(32) initialValue = 32'h1122_3344;
    Bit#(32) writeValue = 32'haa_bb_cc_dd;
    Bit#(32) plioWriteValue = 32'h5566_7788;

    Reg#(Bit#(6)) stage <- mkReg(0);
    Reg#(Bit#(4)) maskIndex <- mkReg(0);
    Reg#(Bit#(16)) cycles <- mkReg(0);
    Reg#(Bit#(16)) watchdog <- mkReg(0);

    rule globalWatchdog;
        watchdog <= watchdog + 1;
        if (watchdog == 16000) begin
            $display("FAIL|memory-semantics|watchdog|stage=%0d|mask_index=%0d", stage, maskIndex);
            $finish(1);
        end
    endrule

    rule resetSubmit (stage == 0 && board.debugAdvanceReady);
        board.advance(idleCards(), lightingBusMasterDriveDefault(), False,
            noWorkerRequest(), False, False, False, False, 0, True);
        ram.resetBackend;
        stage <= 1;
    endrule

    rule resetDrain (stage == 1);
        stage <= 2;
    endrule

    rule seedCase (stage == 2);
        ram.preload(testAddress, initialValue);
        cycles <= 0;
        stage <= 3;
    endrule

    rule cpuWriteBusReq (stage == 3 && board.debugAdvanceReady);
        LightingBusMasterDrive cpu = cpuBusRequest();
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL|memory-semantics|cpu-write-bus-req|mask=%04b", maskForIndex(maskIndex));
            $finish(1);
        end
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= 4;
    endrule

    rule cpuWriteActive (stage == 4 && board.debugAdvanceReady);
        Bit#(4) be = maskForIndex(maskIndex);
        LightingBusMasterDrive cpu = cpuRequest(testAddress, True, be, writeValue);
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL|memory-semantics|cpu-write-active|mask=%04b", be);
            $finish(1);
        end
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            False, False, False, False, 0, False);
        cycles <= 0;
        stage <= 5;
    endrule

    rule cpuWriteWait (stage == 5 && board.debugAdvanceReady);
        Bit#(4) be = maskForIndex(maskIndex);
        LightingBusMasterDrive cpu = cpuRequest(testAddress, True, be, writeValue);
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        if (bus.error) begin
            $display("FAIL|memory-semantics|cpu-write-error|mask=%04b", be);
            $finish(1);
        end
        if (board.memoryBackendRequestValid
            && (!board.memoryBackendWrite
                || board.memoryBackendAddress != testAddress
                || board.memoryBackendByteEnable != be
                || board.memoryBackendWriteData != writeValue)) begin
            $display("FAIL|memory-semantics|cpu-write-request|mask=%04b|write=%0d|addr=%08x|be=%04b|data=%08x",
                be, pack(board.memoryBackendWrite), board.memoryBackendAddress,
                board.memoryBackendByteEnable, board.memoryBackendWriteData);
            $finish(1);
        end

        if (bus.ready) begin
            board.advance(idleCards(), cpu, False, noWorkerRequest(),
                False, False, False, False, 0, False);
            stage <= 6;
        end
        else if (board.memoryBackendRequestValid && ram.requestReady) begin
            ram.acceptRequest(board.memoryBackendWrite, board.memoryBackendAddress,
                board.memoryBackendByteEnable, board.memoryBackendWriteData);
            board.advance(idleCards(), cpu, False, noWorkerRequest(),
                True, False, False, False, 0, False);
        end
        else if (board.memoryBackendResponseReady && ram.responseValid) begin
            board.advance(idleCards(), cpu, False, noWorkerRequest(),
                False, True, ram.responseFault, ram.responseReadDataValid,
                ram.responseReadData, False);
            ram.responseConsumed;
        end
        else begin
            board.advance(idleCards(), cpu, False, noWorkerRequest(),
                False, False, False, False, 0, False);
        end

        cycles <= cycles + 1;
        if (cycles == 100) begin
            $display("FAIL|memory-semantics|cpu-write-watchdog|mask=%04b", be);
            $finish(1);
        end
    endrule

    rule cpuWriteRetire (stage == 6 && board.debugAdvanceReady);
        board.advance(idleCards(), lightingBusMasterDriveDefault(), False,
            noWorkerRequest(), False, False, False, False, 0, False);
        stage <= 7;
    endrule

    rule cpuWriteRetireDrain (stage == 7 && !board.debugCpuResponsePending
        && board.debugAdvanceReady);
        stage <= 8;
    endrule

    rule cpuReadBusReq (stage == 8 && board.debugAdvanceReady);
        LightingBusMasterDrive cpu = cpuBusRequest();
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL|memory-semantics|cpu-read-bus-req|mask=%04b", maskForIndex(maskIndex));
            $finish(1);
        end
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= 9;
    endrule

    rule cpuReadActive (stage == 9 && board.debugAdvanceReady);
        LightingBusMasterDrive cpu = cpuRequest(testAddress, False, 4'hf, 0);
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL|memory-semantics|cpu-read-active|mask=%04b", maskForIndex(maskIndex));
            $finish(1);
        end
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            False, False, False, False, 0, False);
        cycles <= 0;
        stage <= 10;
    endrule

    rule cpuReadWait (stage == 10 && board.debugAdvanceReady);
        Bit#(4) be = maskForIndex(maskIndex);
        Bit#(32) expected = expectedMasked(initialValue, writeValue, be);
        LightingBusMasterDrive cpu = cpuRequest(testAddress, False, 4'hf, 0);
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        if (bus.error) begin
            $display("FAIL|memory-semantics|cpu-read-error|mask=%04b", be);
            $finish(1);
        end
        if (board.memoryBackendRequestValid
            && (board.memoryBackendWrite
                || board.memoryBackendAddress != testAddress)) begin
            $display("FAIL|memory-semantics|cpu-read-request|mask=%04b|write=%0d|addr=%08x",
                be, pack(board.memoryBackendWrite), board.memoryBackendAddress);
            $finish(1);
        end

        if (bus.ready) begin
            Bit#(32) backendValue = ram.peek(testAddress);
            if (bus.readData != expected || backendValue != expected) begin
                $display("FAIL|memory-semantics|value|mask=%04b|initial=%08x|write=%08x|expected=%08x|observed=%08x|backend=%08x",
                    be, initialValue, writeValue, expected, bus.readData, backendValue);
                $finish(1);
            end
            $display("MAINBOARDMEMTRACE|mask=%04b|initial=%08x|write=%08x|expected=%08x|observed=%08x|status=ok",
                be, initialValue, writeValue, expected, bus.readData);
            board.advance(idleCards(), cpu, False, noWorkerRequest(),
                False, False, False, False, 0, False);
            stage <= 11;
        end
        else if (board.memoryBackendRequestValid && ram.requestReady) begin
            ram.acceptRequest(board.memoryBackendWrite, board.memoryBackendAddress,
                board.memoryBackendByteEnable, board.memoryBackendWriteData);
            board.advance(idleCards(), cpu, False, noWorkerRequest(),
                True, False, False, False, 0, False);
        end
        else if (board.memoryBackendResponseReady && ram.responseValid) begin
            board.advance(idleCards(), cpu, False, noWorkerRequest(),
                False, True, ram.responseFault, ram.responseReadDataValid,
                ram.responseReadData, False);
            ram.responseConsumed;
        end
        else begin
            board.advance(idleCards(), cpu, False, noWorkerRequest(),
                False, False, False, False, 0, False);
        end

        cycles <= cycles + 1;
        if (cycles == 100) begin
            $display("FAIL|memory-semantics|cpu-read-watchdog|mask=%04b", be);
            $finish(1);
        end
    endrule

    rule cpuReadRetire (stage == 11 && board.debugAdvanceReady);
        board.advance(idleCards(), lightingBusMasterDriveDefault(), False,
            noWorkerRequest(), False, False, False, False, 0, False);
        stage <= 12;
    endrule

    rule cpuReadRetireDrain (stage == 12 && !board.debugCpuResponsePending
        && board.debugAdvanceReady);
        if (maskIndex == 9) begin
            stage <= 13;
        end
        else begin
            maskIndex <= maskIndex + 1;
            stage <= 2;
        end
    endrule

    // The final CPU case is BE=1111, so testAddress contains writeValue here.
    rule bindPlio (stage == 13);
        board.bindDma(1, 3, testAddress, 25'h00100, True, True);
        stage <= 14;
    endrule

    rule plioReadRequest (stage == 14 && board.debugAdvanceReady);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = requestOnly();
        board.advance(cards, lightingBusMasterDriveDefault(), False,
            noWorkerRequest(), False, False, False, False, 0, False);
        stage <= 15;
    endrule

    rule plioReadAddress0 (stage == 15 && board.debugAdvanceReady);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = dmaAddress(32'h3000_0000, True);
        Vector#(8, PlioIn) slotInputs = board.plioSlots(cards, False);
        if (slotInputs[1].ack || slotInputs[1].err) begin
            $display("FAIL|memory-semantics|plio-read-address0");
            $finish(1);
        end
        board.advance(cards, lightingBusMasterDriveDefault(), False,
            noWorkerRequest(), False, False, False, False, 0, False);
        stage <= 16;
    endrule

    rule plioReadAddress1 (stage == 16 && board.debugAdvanceReady);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = dmaAddress(32'h3000_0000, True);
        Vector#(8, PlioIn) slotInputs = board.plioSlots(cards, False);
        if (!slotInputs[1].ack || slotInputs[1].err) begin
            $display("FAIL|memory-semantics|plio-read-address1|ack=%0d|err=%0d",
                pack(slotInputs[1].ack), pack(slotInputs[1].err));
            $finish(1);
        end
        board.advance(cards, lightingBusMasterDriveDefault(), False,
            noWorkerRequest(), False, False, False, False, 0, False);
        cycles <= 0;
        stage <= 17;
    endrule

    rule plioReadBeatRule (stage == 17 && board.debugAdvanceReady);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = dmaReadBeat();
        Vector#(8, PlioIn) slotInputs = board.plioSlots(cards, False);
        if (slotInputs[1].err) begin
            $display("FAIL|memory-semantics|plio-read-bus-error");
            $finish(1);
        end
        if (board.memoryBackendRequestValid
            && (board.memoryBackendWrite
                || board.memoryBackendAddress != testAddress
                || board.memoryBackendByteEnable != 4'hf)) begin
            $display("FAIL|memory-semantics|plio-read-request|write=%0d|addr=%08x|be=%04b",
                pack(board.memoryBackendWrite), board.memoryBackendAddress,
                board.memoryBackendByteEnable);
            $finish(1);
        end

        if (slotInputs[1].ack) begin
            if (!slotInputs[1].adValid || slotInputs[1].ad != writeValue) begin
                $display("FAIL|memory-semantics|plio-read-data|valid=%0d|actual=%08x|expected=%08x",
                    pack(slotInputs[1].adValid), slotInputs[1].ad, writeValue);
                $finish(1);
            end
            board.advance(cards, lightingBusMasterDriveDefault(), False,
                noWorkerRequest(), False, False, False, False, 0, False);
            stage <= 18;
        end
        else if (board.memoryBackendRequestValid && ram.requestReady) begin
            ram.acceptRequest(board.memoryBackendWrite, board.memoryBackendAddress,
                board.memoryBackendByteEnable, board.memoryBackendWriteData);
            board.advance(cards, lightingBusMasterDriveDefault(), False,
                noWorkerRequest(), True, False, False, False, 0, False);
        end
        else if (board.memoryBackendResponseReady && ram.responseValid) begin
            board.advance(cards, lightingBusMasterDriveDefault(), False,
                noWorkerRequest(), False, True, ram.responseFault,
                ram.responseReadDataValid, ram.responseReadData, False);
            ram.responseConsumed;
        end
        else begin
            board.advance(cards, lightingBusMasterDriveDefault(), False,
                noWorkerRequest(), False, False, False, False, 0, False);
        end

        cycles <= cycles + 1;
        if (cycles == 120) begin
            $display("FAIL|memory-semantics|plio-read-watchdog");
            $finish(1);
        end
    endrule

    rule plioReadCompletion (stage == 18 && board.debugAdvanceReady);
        if (board.dmaCompletionValid) begin
            if (board.dmaCompletionStatus != DmaOk || board.dmaCompletionBeats != 1) begin
                $display("FAIL|memory-semantics|plio-read-completion|status=%0d|beats=%0d",
                    pack(board.dmaCompletionStatus), board.dmaCompletionBeats);
                $finish(1);
            end
            board.clearDmaCompletion;
            stage <= 19;
        end
        else begin
            board.advance(idleCards(), lightingBusMasterDriveDefault(), False,
                noWorkerRequest(), False, False, False, False, 0, False);
        end
    endrule

    rule plioWriteRequest (stage == 19 && board.debugAdvanceReady);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = requestOnly();
        board.advance(cards, lightingBusMasterDriveDefault(), False,
            noWorkerRequest(), False, False, False, False, 0, False);
        stage <= 20;
    endrule

    rule plioWriteAddress0 (stage == 20 && board.debugAdvanceReady);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = dmaAddress(32'h3000_0000, False);
        Vector#(8, PlioIn) slotInputs = board.plioSlots(cards, False);
        if (slotInputs[1].ack || slotInputs[1].err) begin
            $display("FAIL|memory-semantics|plio-write-address0");
            $finish(1);
        end
        board.advance(cards, lightingBusMasterDriveDefault(), False,
            noWorkerRequest(), False, False, False, False, 0, False);
        stage <= 21;
    endrule

    rule plioWriteAddress1 (stage == 21 && board.debugAdvanceReady);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = dmaAddress(32'h3000_0000, False);
        Vector#(8, PlioIn) slotInputs = board.plioSlots(cards, False);
        if (!slotInputs[1].ack || slotInputs[1].err) begin
            $display("FAIL|memory-semantics|plio-write-address1|ack=%0d|err=%0d",
                pack(slotInputs[1].ack), pack(slotInputs[1].err));
            $finish(1);
        end
        board.advance(cards, lightingBusMasterDriveDefault(), False,
            noWorkerRequest(), False, False, False, False, 0, False);
        cycles <= 0;
        stage <= 22;
    endrule

    rule plioWriteBeatRule (stage == 22 && board.debugAdvanceReady);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = dmaWriteBeat(plioWriteValue);
        Vector#(8, PlioIn) slotInputs = board.plioSlots(cards, False);
        if (slotInputs[1].err) begin
            $display("FAIL|memory-semantics|plio-write-bus-error");
            $finish(1);
        end
        if (board.memoryBackendRequestValid
            && (!board.memoryBackendWrite
                || board.memoryBackendAddress != testAddress
                || board.memoryBackendByteEnable != 4'hf
                || board.memoryBackendWriteData != plioWriteValue)) begin
            $display("FAIL|memory-semantics|plio-write-request|write=%0d|addr=%08x|be=%04b|data=%08x",
                pack(board.memoryBackendWrite), board.memoryBackendAddress,
                board.memoryBackendByteEnable, board.memoryBackendWriteData);
            $finish(1);
        end

        if (slotInputs[1].ack) begin
            if (ram.peek(testAddress) != plioWriteValue) begin
                $display("FAIL|memory-semantics|plio-write-backend|actual=%08x|expected=%08x",
                    ram.peek(testAddress), plioWriteValue);
                $finish(1);
            end
            board.advance(cards, lightingBusMasterDriveDefault(), False,
                noWorkerRequest(), False, False, False, False, 0, False);
            stage <= 23;
        end
        else if (board.memoryBackendRequestValid && ram.requestReady) begin
            ram.acceptRequest(board.memoryBackendWrite, board.memoryBackendAddress,
                board.memoryBackendByteEnable, board.memoryBackendWriteData);
            board.advance(cards, lightingBusMasterDriveDefault(), False,
                noWorkerRequest(), True, False, False, False, 0, False);
        end
        else if (board.memoryBackendResponseReady && ram.responseValid) begin
            board.advance(cards, lightingBusMasterDriveDefault(), False,
                noWorkerRequest(), False, True, ram.responseFault,
                ram.responseReadDataValid, ram.responseReadData, False);
            ram.responseConsumed;
        end
        else begin
            board.advance(cards, lightingBusMasterDriveDefault(), False,
                noWorkerRequest(), False, False, False, False, 0, False);
        end

        cycles <= cycles + 1;
        if (cycles == 120) begin
            $display("FAIL|memory-semantics|plio-write-watchdog");
            $finish(1);
        end
    endrule

    rule plioWriteCompletion (stage == 23 && board.debugAdvanceReady);
        if (board.dmaCompletionValid) begin
            if (board.dmaCompletionStatus != DmaOk || board.dmaCompletionBeats != 1) begin
                $display("FAIL|memory-semantics|plio-write-completion|status=%0d|beats=%0d",
                    pack(board.dmaCompletionStatus), board.dmaCompletionBeats);
                $finish(1);
            end
            board.clearDmaCompletion;
            stage <= 24;
        end
        else begin
            board.advance(idleCards(), lightingBusMasterDriveDefault(), False,
                noWorkerRequest(), False, False, False, False, 0, False);
        end
    endrule

    rule finalCpuReadBusReq (stage == 24 && board.debugAdvanceReady);
        LightingBusMasterDrive cpu = cpuBusRequest();
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL|memory-semantics|final-cpu-read-bus-req");
            $finish(1);
        end
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= 25;
    endrule

    rule finalCpuReadActive (stage == 25 && board.debugAdvanceReady);
        LightingBusMasterDrive cpu = cpuRequest(testAddress, False, 4'hf, 0);
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL|memory-semantics|final-cpu-read-active");
            $finish(1);
        end
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            False, False, False, False, 0, False);
        cycles <= 0;
        stage <= 26;
    endrule

    rule finalCpuReadWait (stage == 26 && board.debugAdvanceReady);
        LightingBusMasterDrive cpu = cpuRequest(testAddress, False, 4'hf, 0);
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        if (bus.error) begin
            $display("FAIL|memory-semantics|final-cpu-read-error");
            $finish(1);
        end
        if (bus.ready) begin
            if (bus.readData != plioWriteValue || ram.peek(testAddress) != plioWriteValue) begin
                $display("FAIL|memory-semantics|final-cpu-read-data|observed=%08x|backend=%08x|expected=%08x",
                    bus.readData, ram.peek(testAddress), plioWriteValue);
                $finish(1);
            end
            $display("MAINBOARDMEMSHARED|cpu_to_plio=ok|plio_to_cpu=ok|plio_be=1111|status=ok");
            board.advance(idleCards(), cpu, False, noWorkerRequest(),
                False, False, False, False, 0, False);
            stage <= 27;
        end
        else if (board.memoryBackendRequestValid && ram.requestReady) begin
            ram.acceptRequest(board.memoryBackendWrite, board.memoryBackendAddress,
                board.memoryBackendByteEnable, board.memoryBackendWriteData);
            board.advance(idleCards(), cpu, False, noWorkerRequest(),
                True, False, False, False, 0, False);
        end
        else if (board.memoryBackendResponseReady && ram.responseValid) begin
            board.advance(idleCards(), cpu, False, noWorkerRequest(),
                False, True, ram.responseFault, ram.responseReadDataValid,
                ram.responseReadData, False);
            ram.responseConsumed;
        end
        else begin
            board.advance(idleCards(), cpu, False, noWorkerRequest(),
                False, False, False, False, 0, False);
        end

        cycles <= cycles + 1;
        if (cycles == 100) begin
            $display("FAIL|memory-semantics|final-cpu-read-watchdog");
            $finish(1);
        end
    endrule

    rule finalCpuReadRetire (stage == 27 && board.debugAdvanceReady);
        board.advance(idleCards(), lightingBusMasterDriveDefault(), False,
            noWorkerRequest(), False, False, False, False, 0, False);
        stage <= 28;
    endrule

    rule done (stage == 28 && !board.debugCpuResponsePending);
        $display("PASS|memory-semantics|CPU partial stores, full reads, and CPU/PLIO shared memory semantics");
        $finish(0);
    endrule
endmodule

endpackage
