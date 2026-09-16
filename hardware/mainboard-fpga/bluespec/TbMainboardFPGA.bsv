package TbMainboardFPGA;

import Vector::*;
import QLITypes::*;
import QICInterfaces::*;
import PLIOTx::*;
import PLIOWorkerHost::*;
import PLIOHostDmaM3::*;
import MemoryController::*;
import LightingMemoryBusCompat::*;
import MainboardFPGA::*;

function Bit#(4) tbParity(Bit#(32) word);
    return { ~(^word[31:24]), ~(^word[23:16]), ~(^word[15:8]), ~(^word[7:0]) };
endfunction

function BackplaneDrive requestOnly();
    BackplaneDrive d = backplaneDriveDefault();
    d.request = True;
    return d;
endfunction

function BackplaneDrive dmaAddress(Bit#(32) address, Bool readDirection);
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
    d.ad = address;
    d.parity = tbParity(address);
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

function LightingBusMasterDrive cpuBusRequest();
    LightingBusMasterDrive d = lightingBusMasterDriveDefault();
    d.busRequest = True;
    return d;
endfunction

function LightingBusMasterDrive cpuRequest(Bit#(32) address, Bool write,
    Bit#(32) writeData, Bit#(4) byteEnable);
    LightingBusMasterDrive d = cpuBusRequest();
    d.request = True;
    d.payload.addr = address;
    d.payload.write = write;
    d.payload.writeData = writeData;
    d.payload.byteEnable = byteEnable;
    return d;
endfunction

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

typedef enum {
    TbReset,
    TbHoldoffSetup,
    TbCpuWriteBusReq,
    TbCpuWriteActive,
    TbCpuWriteWait,
    TbCpuReadBusReq,
    TbCpuReadActive,
    TbCpuReadWait,
    TbCpuPartialBusReq,
    TbCpuPartialActive,
    TbCpuFaultBusReq,
    TbCpuFaultActive,
    TbCpuFaultWait,
    TbResetSetup,
    TbResetBusReq,
    TbResetActive,
    TbResetOutstanding,
    TbResetCheck,
    TbRecoveryBusReq,
    TbRecoveryActive,
    TbRecoveryWait,
    TbBindDma,
    TbArbCpuBusReq,
    TbDmaRequest,
    TbDmaAddress0,
    TbDmaAddress1,
    TbDmaReadHold,
    TbArbCpuActive,
    TbArbCpuWait,
    TbDmaRead,
    TbDmaCompletion,
    TbDone
} TbStage deriving (Bits, Eq, FShow);

module mkTbMainboardFPGA(Empty);
    MainboardFPGAIfc board <- mkMainboardFPGA;
    FakeMemoryBackendIfc ram <- mkFakeMemoryBackend(8'd2);

    Reg#(TbStage) stage <- mkReg(TbReset);
    Reg#(Bit#(8)) watchdog <- mkReg(0);

    // Keep the fake backend's mutually exclusive request/response actions out
    // of the phase rules. This is the same scheduling discipline as the
    // MemoryController integration test: otherwise BSC can conjoin incompatible
    // ready conditions and remove the whole test rule as unsatisfiable.
    rule forwardBackendRequest (
        stage != TbReset && stage != TbResetOutstanding
        && board.memoryBackendRequestValid && ram.requestReady
    );
        ram.acceptRequest(board.memoryBackendWrite,
            board.memoryBackendAddress,
            board.memoryBackendWriteData);
    endrule

    rule forwardBackendResponse (
        stage != TbReset && stage != TbResetOutstanding
        && board.memoryBackendResponseReady && ram.responseValid
    );
        ram.responseConsumed;
    endrule

    rule doReset (stage == TbReset);
        Vector#(8, BackplaneDrive) cards = idleCards();
        LightingBusMasterDrive cpu = lightingBusMasterDriveDefault();
        board.advance(cards, cpu, False, noWorkerRequest(),
            False, False, False, False, 0, True);
        ram.resetBackend;
        stage <= TbHoldoffSetup;
    endrule

    rule setupInitialHoldoff (stage == TbHoldoffSetup);
        ram.setRequestHoldoff(8);
        stage <= TbCpuWriteBusReq;
    endrule

    rule cpuWriteBusReq (stage == TbCpuWriteBusReq);
        Vector#(8, BackplaneDrive) cards = idleCards();
        LightingBusMasterDrive cpu = cpuBusRequest();
        LightingBusInputs bus = board.lightingMemory(cards, cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL mainboard CPU write BUS_REQ/grant phase");
            $finish(1);
        end
        board.advance(cards, cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        stage <= TbCpuWriteActive;
    endrule

    rule cpuWriteActive (stage == TbCpuWriteActive);
        Vector#(8, BackplaneDrive) cards = idleCards();
        LightingBusMasterDrive cpu = cpuRequest(32'h0000_0100, True,
            32'h1122_3344, 4'hf);
        LightingBusInputs bus = board.lightingMemory(cards, cpu, False);
        // BUS_REQ was registered on the preceding external cycle; the internal
        // grant-retention register is updated at this edge. The combinational
        // bus grant must already remain asserted, but debugCpuGrantHeld is not
        // required to expose the post-edge value early.
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL mainboard CPU write active grant retention");
            $finish(1);
        end
        board.advance(cards, cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        stage <= TbCpuWriteWait;
        watchdog <= 0;
    endrule

    rule cpuWriteWait (stage == TbCpuWriteWait);
        Vector#(8, BackplaneDrive) cards = idleCards();
        LightingBusMasterDrive cpu = cpuRequest(32'h0000_0100, True,
            32'h1122_3344, 4'hf);
        LightingBusInputs bus = board.lightingMemory(cards, cpu, False);
        if (!bus.busGrant || bus.error) begin
            $display("FAIL mainboard CPU write wait/grant");
            $finish(1);
        end
        board.advance(cards, cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        if (bus.ready) begin
            if (ram.peek(32'h0000_0100) != 32'h1122_3344) begin
                $display("FAIL mainboard CPU write data");
                $finish(1);
            end
            stage <= TbCpuReadBusReq;
        end
        else begin
            watchdog <= watchdog + 1;
            if (watchdog == 80) begin
                $display("FAIL mainboard CPU write watchdog");
                $finish(1);
            end
        end
    endrule

    rule cpuReadBusReq (stage == TbCpuReadBusReq);
        Vector#(8, BackplaneDrive) cards = idleCards();
        LightingBusMasterDrive cpu = cpuBusRequest();
        LightingBusInputs bus = board.lightingMemory(cards, cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL mainboard CPU read BUS_REQ/grant phase");
            $finish(1);
        end
        board.advance(cards, cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        stage <= TbCpuReadActive;
    endrule

    rule cpuReadActive (stage == TbCpuReadActive);
        Vector#(8, BackplaneDrive) cards = idleCards();
        LightingBusMasterDrive cpu = cpuRequest(32'h0000_0100, False, 0, 4'hf);
        LightingBusInputs bus = board.lightingMemory(cards, cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL mainboard CPU read active grant retention");
            $finish(1);
        end
        board.advance(cards, cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        stage <= TbCpuReadWait;
        watchdog <= 0;
    endrule

    rule cpuReadWait (stage == TbCpuReadWait);
        Vector#(8, BackplaneDrive) cards = idleCards();
        LightingBusMasterDrive cpu = cpuRequest(32'h0000_0100, False, 0, 4'hf);
        LightingBusInputs bus = board.lightingMemory(cards, cpu, False);
        if (!bus.busGrant || bus.error) begin
            $display("FAIL mainboard CPU read response/grant");
            $finish(1);
        end
        board.advance(cards, cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        if (bus.ready) begin
            if (bus.readData != 32'h1122_3344) begin
                $display("FAIL mainboard CPU read data %08x", bus.readData);
                $finish(1);
            end
            stage <= TbCpuPartialBusReq;
        end
        else begin
            watchdog <= watchdog + 1;
            if (watchdog == 80) begin
                $display("FAIL mainboard CPU read watchdog");
                $finish(1);
            end
        end
    endrule

    rule cpuPartialBusReq (stage == TbCpuPartialBusReq);
        Vector#(8, BackplaneDrive) cards = idleCards();
        LightingBusMasterDrive cpu = cpuBusRequest();
        LightingBusInputs bus = board.lightingMemory(cards, cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL mainboard partial BUS_REQ/grant phase");
            $finish(1);
        end
        board.advance(cards, cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        stage <= TbCpuPartialActive;
    endrule

    rule cpuPartialActive (stage == TbCpuPartialActive);
        Vector#(8, BackplaneDrive) cards = idleCards();
        LightingBusMasterDrive cpu = cpuRequest(32'h0000_0100, True,
            32'haabb_ccdd, 4'h3);
        LightingBusInputs bus = board.lightingMemory(cards, cpu, False);
        if (!bus.busGrant || !bus.error || bus.ready) begin
            $display("FAIL mainboard partial access must terminate with ERROR");
            $finish(1);
        end
        if (ram.peek(32'h0000_0100) != 32'h1122_3344
            || board.memoryBackendRequestValid) begin
            $display("FAIL mainboard partial access reached/changed backend");
            $finish(1);
        end
        board.advance(cards, cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        stage <= TbCpuFaultBusReq;
    endrule

    rule cpuFaultBusReq (stage == TbCpuFaultBusReq);
        Vector#(8, BackplaneDrive) cards = idleCards();
        LightingBusMasterDrive cpu = cpuBusRequest();
        LightingBusInputs bus = board.lightingMemory(cards, cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL mainboard fault BUS_REQ/grant phase");
            $finish(1);
        end
        board.advance(cards, cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        stage <= TbCpuFaultActive;
    endrule

    rule cpuFaultActive (stage == TbCpuFaultActive);
        Vector#(8, BackplaneDrive) cards = idleCards();
        LightingBusMasterDrive cpu = cpuRequest(32'h0000_2000, False, 0, 4'hf);
        LightingBusInputs bus = board.lightingMemory(cards, cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL mainboard backend-fault active phase");
            $finish(1);
        end
        board.advance(cards, cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        stage <= TbCpuFaultWait;
        watchdog <= 0;
    endrule

    rule cpuFaultWait (stage == TbCpuFaultWait);
        Vector#(8, BackplaneDrive) cards = idleCards();
        LightingBusMasterDrive cpu = cpuRequest(32'h0000_2000, False, 0, 4'hf);
        LightingBusInputs bus = board.lightingMemory(cards, cpu, False);
        if (!bus.busGrant || bus.ready) begin
            $display("FAIL mainboard backend fault grant/READY");
            $finish(1);
        end
        board.advance(cards, cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        if (bus.error) begin
            stage <= TbResetSetup;
        end
        else begin
            watchdog <= watchdog + 1;
            if (watchdog == 80) begin
                $display("FAIL mainboard backend fault watchdog");
                $finish(1);
            end
        end
    endrule

    rule setupResetTest (stage == TbResetSetup);
        watchdog <= 0;
        stage <= TbResetBusReq;
    endrule

    rule resetTestBusReq (stage == TbResetBusReq);
        Vector#(8, BackplaneDrive) cards = idleCards();
        LightingBusMasterDrive cpu = cpuBusRequest();
        LightingBusInputs bus = board.lightingMemory(cards, cpu, False);
        if (!bus.busGrant) begin
            $display("FAIL mainboard reset test BUS_REQ/grant");
            $finish(1);
        end
        board.advance(cards, cpu, False, noWorkerRequest(),
            False, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        stage <= TbResetActive;
    endrule

    rule resetTestActive (stage == TbResetActive);
        Vector#(8, BackplaneDrive) cards = idleCards();
        LightingBusMasterDrive cpu = cpuRequest(32'h0000_0100, False, 0, 4'hf);
        LightingBusInputs bus = board.lightingMemory(cards, cpu, False);
        if (!bus.busGrant) begin
            $display("FAIL mainboard reset test active phase");
            $finish(1);
        end
        // Intentionally block the backend handshake. The registered request is
        // accepted internally on a following edge; TbResetOutstanding waits
        // until that transaction is observably pending before applying reset.
        board.advance(cards, cpu, False, noWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= TbResetOutstanding;
        watchdog <= 0;
    endrule

    rule resetOutstanding (stage == TbResetOutstanding);
        Vector#(8, BackplaneDrive) cards = idleCards();
        LightingBusMasterDrive cpu = cpuRequest(32'h0000_0100, False, 0, 4'hf);
        if (board.memoryBackendRequestValid
            && board.debugMemoryOwner == MainMemCpu) begin
            board.advance(cards, cpu, False, noWorkerRequest(),
                False, False, False, False, 0, True);
            stage <= TbResetCheck;
            watchdog <= 0;
        end
        else begin
            // Keep the externally visible request stable while the registered
            // active cycle crosses the mainboard boundary.
            board.advance(cards, cpu, False, noWorkerRequest(),
                False, False, False, False, 0, False);
            watchdog <= watchdog + 1;
            if (watchdog == 20) begin
                $display("FAIL mainboard reset did not catch outstanding backend request");
                $finish(1);
            end
        end
    endrule

    rule resetCheck (stage == TbResetCheck);
        if (board.debugMemoryOwner != MainMemNone
            || board.debugCpuGrantHeld
            || board.memoryBackendRequestValid
            || board.memoryBackendResponseReady) begin
            // Reset itself is registered too; allow it one internal cycle to
            // clear the controller before declaring stale state.
            watchdog <= watchdog + 1;
            if (watchdog == 20) begin
                $display("FAIL mainboard reset left stale memory transaction");
                $finish(1);
            end
        end
        else begin
            stage <= TbRecoveryBusReq;
            watchdog <= 0;
        end
    endrule

    rule recoveryBusReq (stage == TbRecoveryBusReq);
        Vector#(8, BackplaneDrive) cards = idleCards();
        LightingBusMasterDrive cpu = cpuBusRequest();
        LightingBusInputs bus = board.lightingMemory(cards, cpu, False);
        if (!bus.busGrant) begin
            $display("FAIL mainboard recovery BUS_REQ/grant");
            $finish(1);
        end
        board.advance(cards, cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        stage <= TbRecoveryActive;
    endrule

    rule recoveryActive (stage == TbRecoveryActive);
        Vector#(8, BackplaneDrive) cards = idleCards();
        LightingBusMasterDrive cpu = cpuRequest(32'h0000_0100, False, 0, 4'hf);
        LightingBusInputs bus = board.lightingMemory(cards, cpu, False);
        if (!bus.busGrant) begin
            $display("FAIL mainboard recovery active grant");
            $finish(1);
        end
        board.advance(cards, cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        stage <= TbRecoveryWait;
        watchdog <= 0;
    endrule

    rule recoveryWait (stage == TbRecoveryWait);
        Vector#(8, BackplaneDrive) cards = idleCards();
        LightingBusMasterDrive cpu = cpuRequest(32'h0000_0100, False, 0, 4'hf);
        LightingBusInputs bus = board.lightingMemory(cards, cpu, False);
        if (!bus.busGrant || bus.error) begin
            $display("FAIL mainboard post-reset recovery response");
            $finish(1);
        end
        board.advance(cards, cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        if (bus.ready) begin
            if (bus.readData != 32'h1122_3344) begin
                $display("FAIL mainboard reset destroyed backend RAM contents");
                $finish(1);
            end
            stage <= TbBindDma;
        end
        else begin
            watchdog <= watchdog + 1;
            if (watchdog == 80) begin
                $display("FAIL mainboard recovery watchdog");
                $finish(1);
            end
        end
    endrule

    rule bindDma (stage == TbBindDma);
        board.bindDma(1, 3, 32'h0000_0100, 25'h00100, True, True);
        stage <= TbArbCpuBusReq;
    endrule

    rule arbitrationCpuBusReq (stage == TbArbCpuBusReq);
        Vector#(8, BackplaneDrive) cards = idleCards();
        LightingBusMasterDrive cpu = cpuBusRequest();
        if (board.debugPreferCpu) begin
            $display("FAIL mainboard arbitration setup did not prefer PLIO");
            $finish(1);
        end
        LightingBusInputs bus = board.lightingMemory(cards, cpu, False);
        if (!bus.busGrant) begin
            $display("FAIL mainboard arbitration CPU initial grant");
            $finish(1);
        end
        board.advance(cards, cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        stage <= TbDmaRequest;
    endrule

    rule dmaRequest (stage == TbDmaRequest);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = requestOnly();
        LightingBusMasterDrive cpu = cpuBusRequest();
        LightingBusInputs bus = board.lightingMemory(cards, cpu, False);
        if (!bus.busGrant) begin
            $display("FAIL mainboard CPU grant not retained as PLIO requests");
            $finish(1);
        end
        board.advance(cards, cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        stage <= TbDmaAddress0;
    endrule

    rule dmaAddress0 (stage == TbDmaAddress0);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = dmaAddress(32'h3000_0000, True);
        LightingBusMasterDrive cpu = cpuBusRequest();
        LightingBusInputs bus = board.lightingMemory(cards, cpu, False);
        Vector#(8, PlioIn) slotInputs = board.plioSlots(cards, False);
        if (!bus.busGrant || slotInputs[1].ack || slotInputs[1].err) begin
            $display("FAIL mainboard PLIO DMA address/grant phase 0");
            $finish(1);
        end
        board.advance(cards, cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        stage <= TbDmaAddress1;
    endrule

    rule dmaAddress1 (stage == TbDmaAddress1);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = dmaAddress(32'h3000_0000, True);
        LightingBusMasterDrive cpu = cpuBusRequest();
        LightingBusInputs bus = board.lightingMemory(cards, cpu, False);
        Vector#(8, PlioIn) slotInputs = board.plioSlots(cards, False);
        if (!bus.busGrant || !slotInputs[1].ack || slotInputs[1].err) begin
            $display("FAIL mainboard PLIO DMA address ACK/grant retention");
            $finish(1);
        end
        board.advance(cards, cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        stage <= TbDmaReadHold;
        watchdog <= 0;
    endrule

    rule dmaReadHold (stage == TbDmaReadHold);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = dmaReadBeat();
        LightingBusMasterDrive cpu = cpuBusRequest();
        LightingBusInputs bus = board.lightingMemory(cards, cpu, False);
        Vector#(8, PlioIn) slotInputs = board.plioSlots(cards, False);
        if (!bus.busGrant || slotInputs[1].err || slotInputs[1].ack) begin
            $display("FAIL mainboard granted CPU was stolen by PLIO DMA");
            $finish(1);
        end
        board.advance(cards, cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        if (board.debugPlioMemoryRequestValid) begin
            if (!board.debugCpuGrantHeld || board.debugMemoryOwner != MainMemNone) begin
                $display("FAIL mainboard PLIO contention grant state");
                $finish(1);
            end
            stage <= TbArbCpuActive;
        end
        else begin
            watchdog <= watchdog + 1;
            if (watchdog == 60) begin
                $display("FAIL mainboard PLIO request formation watchdog");
                $finish(1);
            end
        end
    endrule

    rule arbitrationCpuActive (stage == TbArbCpuActive);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = dmaReadBeat();
        LightingBusMasterDrive cpu = cpuRequest(32'h0000_0100, False, 0, 4'hf);
        LightingBusInputs bus = board.lightingMemory(cards, cpu, False);
        Vector#(8, PlioIn) slotInputs = board.plioSlots(cards, False);
        if (!bus.busGrant || bus.ready || bus.error
            || slotInputs[1].ack || slotInputs[1].err) begin
            $display("FAIL mainboard CPU did not start ahead of waiting PLIO after held grant");
            $finish(1);
        end
        board.advance(cards, cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        stage <= TbArbCpuWait;
        watchdog <= 0;
    endrule

    rule arbitrationCpuWait (stage == TbArbCpuWait);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = dmaReadBeat();
        LightingBusMasterDrive cpu = cpuRequest(32'h0000_0100, False, 0, 4'hf);
        LightingBusInputs bus = board.lightingMemory(cards, cpu, False);
        Vector#(8, PlioIn) slotInputs = board.plioSlots(cards, False);
        if (!bus.busGrant || bus.error || slotInputs[1].err || slotInputs[1].ack) begin
            $display("FAIL mainboard CPU/PLIO arbitration during CPU wait");
            $finish(1);
        end
        board.advance(cards, cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        if (bus.ready) begin
            if (bus.readData != 32'h1122_3344) begin
                $display("FAIL mainboard arbitration CPU read data");
                $finish(1);
            end
            stage <= TbDmaRead;
            watchdog <= 0;
        end
        else begin
            watchdog <= watchdog + 1;
            if (watchdog == 80) begin
                $display("FAIL mainboard arbitration CPU watchdog");
                $finish(1);
            end
        end
    endrule

    rule dmaRead (stage == TbDmaRead);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = dmaReadBeat();
        LightingBusMasterDrive cpu = lightingBusMasterDriveDefault();
        Vector#(8, PlioIn) slotInputs = board.plioSlots(cards, False);
        if (slotInputs[1].err) begin
            $display("FAIL mainboard PLIO DMA read bus error");
            $finish(1);
        end
        board.advance(cards, cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        if (slotInputs[1].ack) begin
            if (!slotInputs[1].adValid || slotInputs[1].ad != 32'h1122_3344) begin
                $display("FAIL mainboard PLIO DMA read data");
                $finish(1);
            end
            stage <= TbDmaCompletion;
            watchdog <= 0;
        end
        else begin
            watchdog <= watchdog + 1;
            if (watchdog == 100) begin
                $display("FAIL mainboard PLIO DMA read watchdog");
                $finish(1);
            end
        end
    endrule

    rule dmaCompletionWait (stage == TbDmaCompletion && !board.dmaCompletionValid);
        Vector#(8, BackplaneDrive) cards = idleCards();
        LightingBusMasterDrive cpu = lightingBusMasterDriveDefault();
        board.advance(cards, cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        watchdog <= watchdog + 1;
        if (watchdog == 100) begin
            $display("FAIL mainboard PLIO DMA completion watchdog");
            $finish(1);
        end
    endrule

    rule dmaCompletionDone (stage == TbDmaCompletion && board.dmaCompletionValid);
        if (board.dmaCompletionStatus != DmaOk || board.dmaCompletionBeats != 1) begin
            $display("FAIL mainboard PLIO DMA completion status");
            $finish(1);
        end
        board.clearDmaCompletion;
        stage <= TbDone;
    endrule

    rule done (stage == TbDone);
        LightingModuleInterrupts irqs = board.interrupts(False, False);
        if (irqs.plioIrq || irqs.timerIrq || irqs.machineFault) begin
            $display("FAIL mainboard idle interrupt state");
            $finish(1);
        end
        $display("MAINBOARDTRACE|v3|registered_cycle=once|lighting_two_phase=ok|wait_states=ok|fault=ok|partial=error|reset=ok|grant_hold=ok|plio_dma_read=ok|backend=plugged");
        $display("PASS mainboard FPGA composition boundary");
        $finish(0);
    endrule
endmodule

endpackage
