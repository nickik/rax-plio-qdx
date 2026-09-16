package TbMainboardLifecycleCoverage;

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

function LightingBusMasterDrive cpuBusRequest();
    LightingBusMasterDrive d = lightingBusMasterDriveDefault();
    d.busRequest = True;
    return d;
endfunction

function LightingBusMasterDrive cpuRead(Bit#(32) address);
    LightingBusMasterDrive d = cpuBusRequest();
    d.request = True;
    d.payload.addr = address;
    d.payload.write = False;
    d.payload.writeData = 0;
    d.payload.byteEnable = 4'hf;
    return d;
endfunction

function Bit#(4) parity32(Bit#(32) word);
    return { ~(^word[31:24]), ~(^word[23:16]), ~(^word[15:8]), ~(^word[7:0]) };
endfunction

function BackplaneDrive dmaRequestOnly();
    BackplaneDrive d = backplaneDriveDefault();
    d.request = True;
    return d;
endfunction

function BackplaneDrive dmaAddress(Bit#(32) address);
    BackplaneDrive d = dmaRequestOnly();
    BackplaneControl c = backplaneControlDefault();
    c.space = pack(PlioHostDma);
    c.addressStrobe = True;
    c.read = True;
    c.byteEnable = 4'hf;
    c.burstLen = pack(BurstOne);
    d.controlValid = True;
    d.control = c;
    d.adParValid = True;
    d.ad = address;
    d.parity = parity32(address);
    return d;
endfunction

function BackplaneDrive dmaReadBeat();
    BackplaneDrive d = dmaRequestOnly();
    BackplaneControl c = backplaneControlDefault();
    c.dataStrobe = True;
    d.controlValid = True;
    d.control = c;
    return d;
endfunction

typedef enum {
    LcResetSubmit,
    LcResetDrain,
    LcBusReq,
    LcActive,
    LcWaitOutstanding,
    LcWaitClear,
    LcInjectStale,
    LcCheckStale,
    LcFreshBusReq,
    LcFreshActive,
    LcFreshWait,
    LcFreshRelease,
    LcFreshReleaseCheck,
    LcDmaBind,
    LcDmaRequest,
    LcDmaAddress0,
    LcDmaAddress1,
    LcDmaRead,
    LcDmaCompletion
} LifecycleStage deriving (Bits, Eq, FShow);

(* synthesize *)
module mkTbMainboardLifecycleCoverage(Empty);
    MainboardFPGAIfc board <- mkMainboardFPGA;
    Reg#(LifecycleStage) stage <- mkReg(LcResetSubmit);
    Reg#(Bit#(16)) watchdog <- mkReg(0);
    Reg#(Bool) responseQueued <- mkReg(False);
    Reg#(Bool) sawPlioBackend <- mkReg(False);

    rule globalWatchdog;
        watchdog <= watchdog + 1;
        if (watchdog == 20000) begin
            $display("FAIL|lifecycle-coverage|watchdog|stage=%0d", pack(stage));
            $finish(1);
        end
    endrule

    rule resetSubmit (stage == LcResetSubmit && board.debugAdvanceReady);
        board.advance(idleCards(), lightingBusMasterDriveDefault(), False,
            noWorkerRequest(), False, False, False, False, 0, True);
        stage <= LcResetDrain;
    endrule

    rule resetDrain (stage == LcResetDrain);
        if (board.debugMemoryOwner == MainMemNone
            && board.debugMemoryControllerState == MemIdle
            && !board.debugCpuResponsePending
            && !board.debugMemoryHostResponseValid) begin
            stage <= LcBusReq;
        end
    endrule

    rule busReq (stage == LcBusReq && board.debugAdvanceReady);
        LightingBusMasterDrive cpu = cpuBusRequest();
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL|lifecycle-coverage|reset-bus-request|grant=%0d|ready=%0d|error=%0d",
                pack(bus.busGrant), pack(bus.ready), pack(bus.error));
            $finish(1);
        end
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= LcActive;
    endrule

    rule active (stage == LcActive && board.debugAdvanceReady);
        LightingBusMasterDrive cpu = cpuRead(32'h0000_0300);
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL|lifecycle-coverage|reset-active|grant=%0d|ready=%0d|error=%0d",
                pack(bus.busGrant), pack(bus.ready), pack(bus.error));
            $finish(1);
        end
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= LcWaitOutstanding;
    endrule

    rule waitOutstanding (stage == LcWaitOutstanding && board.debugAdvanceReady
        && board.memoryBackendRequestValid);
        if (board.debugMemoryOwner != MainMemCpu
            || board.debugMemoryControllerState != MemBackendRequest
            || board.memoryBackendWrite
            || board.memoryBackendAddress != 32'h0000_0300) begin
            $display("FAIL|lifecycle-coverage|outstanding-shape|owner=%0d|mc=%0d|write=%0d|addr=%08x",
                pack(board.debugMemoryOwner), pack(board.debugMemoryControllerState),
                pack(board.memoryBackendWrite), board.memoryBackendAddress);
            $finish(1);
        end
        board.advance(idleCards(), cpuRead(32'h0000_0300), False,
            noWorkerRequest(), False, False, False, False, 0, True);
        stage <= LcWaitClear;
    endrule

    rule waitClear (stage == LcWaitClear);
        if (board.debugMemoryOwner == MainMemNone
            && board.debugMemoryControllerState == MemIdle
            && !board.debugCpuGrantHeld
            && !board.debugCpuResponsePending
            && !board.debugMemoryHostResponseValid
            && !board.memoryBackendRequestValid
            && !board.memoryBackendResponseReady) begin
            stage <= LcInjectStale;
        end
    endrule

    rule injectStale (stage == LcInjectStale && board.debugAdvanceReady);
        board.advance(idleCards(), lightingBusMasterDriveDefault(), False,
            noWorkerRequest(), False, True, False, True, 32'hdead_beef, False);
        stage <= LcCheckStale;
    endrule

    rule checkStale (stage == LcCheckStale);
        LightingBusInputs bus = board.lightingMemory(idleCards(),
            lightingBusMasterDriveDefault(), False);
        if (board.debugMemoryOwner != MainMemNone
            || board.debugMemoryControllerState != MemIdle
            || board.debugCpuResponsePending
            || board.debugMemoryHostResponseValid
            || board.memoryBackendRequestValid
            || board.memoryBackendResponseReady
            || bus.ready || bus.error) begin
            $display("FAIL|lifecycle-coverage|stale-response-survived|owner=%0d|mc=%0d|cpu_resp=%0d|host_resp=%0d|backend_req=%0d|backend_resp_ready=%0d|ready=%0d|error=%0d",
                pack(board.debugMemoryOwner), pack(board.debugMemoryControllerState),
                pack(board.debugCpuResponsePending), pack(board.debugMemoryHostResponseValid),
                pack(board.memoryBackendRequestValid), pack(board.memoryBackendResponseReady),
                pack(bus.ready), pack(bus.error));
            $finish(1);
        end
        $display("MAINBOARDLIFECYCLE|reset_outstanding=ok|stale_internal_state=ok");
        stage <= LcFreshBusReq;
    endrule

    rule freshBusReq (stage == LcFreshBusReq && board.debugAdvanceReady);
        LightingBusMasterDrive cpu = cpuBusRequest();
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL|lifecycle-coverage|fresh-bus-request");
            $finish(1);
        end
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= LcFreshActive;
    endrule

    rule freshActive (stage == LcFreshActive && board.debugAdvanceReady);
        LightingBusMasterDrive cpu = cpuRead(32'h0000_0304);
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= LcFreshWait;
        responseQueued <= False;
    endrule

    rule freshWait (stage == LcFreshWait && board.debugAdvanceReady);
        LightingBusMasterDrive cpu = cpuRead(32'h0000_0304);
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        Bool queueResponse = board.memoryBackendResponseReady && !responseQueued;
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            True, queueResponse, False, queueResponse, 32'h1357_9bdf, False);
        if (queueResponse) responseQueued <= True;
        if (bus.error) begin
            $display("FAIL|lifecycle-coverage|fresh-error");
            $finish(1);
        end
        if (bus.ready) begin
            if (bus.readData != 32'h1357_9bdf) begin
                $display("FAIL|lifecycle-coverage|fresh-data|actual=%08x", bus.readData);
                $finish(1);
            end
            stage <= LcFreshRelease;
        end
    endrule

    rule freshRelease (stage == LcFreshRelease && board.debugAdvanceReady);
        board.advance(idleCards(), lightingBusMasterDriveDefault(), False,
            noWorkerRequest(), False, False, False, False, 0, False);
        stage <= LcFreshReleaseCheck;
    endrule

    rule freshReleaseCheck (stage == LcFreshReleaseCheck);
        if (!board.debugCpuResponsePending && board.debugMemoryOwner == MainMemNone
            && board.debugMemoryControllerState == MemIdle) begin
            $display("MAINBOARDLIFECYCLE|fresh_recovery=ok");
            stage <= LcDmaBind;
        end
    endrule

    rule dmaBind (stage == LcDmaBind);
        board.bindDma(1, 3, 32'h0000_0100, 25'h00100, True, True);
        stage <= LcDmaRequest;
    endrule

    rule dmaRequest (stage == LcDmaRequest && board.debugAdvanceReady);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = dmaRequestOnly();
        board.advance(cards, lightingBusMasterDriveDefault(), False,
            noWorkerRequest(), False, False, False, False, 0, False);
        stage <= LcDmaAddress0;
    endrule

    rule dmaAddress0 (stage == LcDmaAddress0 && board.debugAdvanceReady);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = dmaAddress(32'h3000_0000);
        Vector#(8, PlioIn) slots = board.plioSlots(cards, False);
        if (slots[1].ack || slots[1].err) begin
            $display("FAIL|lifecycle-coverage|dma-address0");
            $finish(1);
        end
        board.advance(cards, lightingBusMasterDriveDefault(), False,
            noWorkerRequest(), False, False, False, False, 0, False);
        stage <= LcDmaAddress1;
    endrule

    rule dmaAddress1 (stage == LcDmaAddress1 && board.debugAdvanceReady);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = dmaAddress(32'h3000_0000);
        Vector#(8, PlioIn) slots = board.plioSlots(cards, False);
        if (!slots[1].ack || slots[1].err) begin
            $display("FAIL|lifecycle-coverage|dma-address1|ack=%0d|err=%0d",
                pack(slots[1].ack), pack(slots[1].err));
            $finish(1);
        end
        board.advance(cards, lightingBusMasterDriveDefault(), False,
            noWorkerRequest(), False, False, False, False, 0, False);
        stage <= LcDmaRead;
        responseQueued <= False;
    endrule

    rule dmaRead (stage == LcDmaRead && board.debugAdvanceReady);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = dmaReadBeat();
        Vector#(8, PlioIn) slots = board.plioSlots(cards, False);
        Bool queueResponse = board.memoryBackendResponseReady && !responseQueued;

        if (slots[1].err) begin
            $display("FAIL|lifecycle-coverage|dma-bus-error");
            $finish(1);
        end
        if (board.memoryBackendRequestValid) begin
            if (board.debugMemoryOwner != MainMemPlio
                || board.debugMemoryControllerState != MemBackendRequest
                || board.memoryBackendWrite
                || board.memoryBackendAddress != 32'h0000_0100
                || board.memoryBackendByteEnable != 4'hf) begin
                $display("FAIL|lifecycle-coverage|dma-backend-shape|owner=%0d|mc=%0d|write=%0d|addr=%08x|be=%04b",
                    pack(board.debugMemoryOwner), pack(board.debugMemoryControllerState),
                    pack(board.memoryBackendWrite), board.memoryBackendAddress,
                    board.memoryBackendByteEnable);
                $finish(1);
            end
            sawPlioBackend <= True;
        end

        board.advance(cards, lightingBusMasterDriveDefault(), False,
            noWorkerRequest(), True, queueResponse, False, queueResponse,
            32'h1122_3344, False);
        if (queueResponse) responseQueued <= True;

        if (slots[1].ack) begin
            if (!sawPlioBackend || !slots[1].adValid
                || slots[1].ad != 32'h1122_3344) begin
                $display("FAIL|lifecycle-coverage|dma-read-complete|saw_backend=%0d|valid=%0d|data=%08x",
                    pack(sawPlioBackend), pack(slots[1].adValid), slots[1].ad);
                $finish(1);
            end
            stage <= LcDmaCompletion;
        end
    endrule

    rule dmaCompletion (stage == LcDmaCompletion && board.dmaCompletionValid);
        if (board.dmaCompletionStatus != DmaOk || board.dmaCompletionBeats != 1) begin
            $display("FAIL|lifecycle-coverage|dma-completion|status=%0d|beats=%0d",
                pack(board.dmaCompletionStatus), board.dmaCompletionBeats);
            $finish(1);
        end
        $display("MAINBOARDLIFECYCLE|plio_memory_path=ok|plio_be=1111|status=ok");
        $display("PASS|lifecycle-coverage|reset stale-state isolation, fresh recovery, and PLIO full-word memory path");
        $finish(0);
    endrule
endmodule

endpackage
