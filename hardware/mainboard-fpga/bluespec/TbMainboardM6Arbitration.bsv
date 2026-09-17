package TbMainboardM6Arbitration;

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
    return HostWorkerRequest { slot: 0, address: 0, width: HostW32,
        write: False, value: 0 };
endfunction

function Bit#(4) parity32(Bit#(32) word);
    return { ~(^word[31:24]), ~(^word[23:16]), ~(^word[15:8]), ~(^word[7:0]) };
endfunction

function BackplaneDrive requestOnly();
    BackplaneDrive d = backplaneDriveDefault();
    d.request = True;
    return d;
endfunction

function BackplaneDrive dmaAddress(Bit#(32) handle);
    BackplaneDrive d = requestOnly();
    BackplaneControl c = backplaneControlDefault();
    c.space = pack(PlioHostDma);
    c.addressStrobe = True;
    c.read = True;
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

function Vector#(8, BackplaneDrive) plioReadCards();
    Vector#(8, BackplaneDrive) cards = idleCards();
    cards[1] = dmaReadBeat();
    return cards;
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
    d.payload.byteEnable = 4'hf;
    d.payload.writeData = 0;
    return d;
endfunction

(* synthesize *)
module mkTbMainboardM6Arbitration(Empty);
    MainboardFPGAIfc board <- mkMainboardFPGA;

    Bit#(32) cpuAddress = 32'h0000_0800;
    Bit#(32) plioAddress = 32'h0000_0c00;
    Bit#(32) cpuData = 32'hc0de_6001;
    Bit#(32) plioData = 32'hc0de_6002;

    Reg#(Bit#(6)) stage <- mkReg(0);
    Reg#(Bit#(4)) stallCount <- mkReg(0);
    Reg#(Bit#(4)) backendAccepts <- mkReg(0);
    Reg#(Bit#(4)) backendResponses <- mkReg(0);
    Reg#(Bit#(16)) watchdog <- mkReg(0);

    rule watchdogRule;
        watchdog <= watchdog + 1;
        if (watchdog == 12000) begin
            $display("FAIL|m6.1|watchdog|stage=%0d|owner=%0d|accepts=%0d|responses=%0d",
                stage, pack(board.debugMemoryOwner), backendAccepts, backendResponses);
            $finish(1);
        end
    endrule

    rule resetSubmit (stage == 0 && board.debugAdvanceReady);
        board.advance(idleCards(), lightingBusMasterDriveDefault(), False,
            noWorkerRequest(), False, False, False, False, 0, True);
        stage <= 1;
    endrule

    rule resetDrain (stage == 1);
        if (board.debugMemoryOwner != MainMemNone || board.debugCpuGrantHeld
            || board.debugCpuResponsePending) begin
            $display("FAIL|m6.1|reset-state");
            $finish(1);
        end
        board.bindDma(1, 3, plioAddress, 25'h00100, True, True);
        stage <= 2;
    endrule

    // Build a real PLIO DMA read until PLIOHostCore has a memory request pending.
    rule plioRequest (stage == 2 && board.debugAdvanceReady);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = requestOnly();
        board.advance(cards, lightingBusMasterDriveDefault(), False,
            noWorkerRequest(), False, False, False, False, 0, False);
        stage <= 3;
    endrule

    rule plioAddress0 (stage == 3 && board.debugAdvanceReady);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = dmaAddress(32'h3000_0000);
        board.advance(cards, lightingBusMasterDriveDefault(), False,
            noWorkerRequest(), False, False, False, False, 0, False);
        stage <= 4;
    endrule

    rule plioAddress1 (stage == 4 && board.debugAdvanceReady);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = dmaAddress(32'h3000_0000);
        Vector#(8, PlioIn) slotInputs = board.plioSlots(cards, False);
        if (!slotInputs[1].ack || slotInputs[1].err) begin
            $display("FAIL|m6.1|plio-address|ack=%0d|err=%0d",
                pack(slotInputs[1].ack), pack(slotInputs[1].err));
            $finish(1);
        end
        board.advance(cards, lightingBusMasterDriveDefault(), False,
            noWorkerRequest(), False, False, False, False, 0, False);
        stage <= 5;
    endrule

    // Both contenders are now present. Reset policy is preferCpu=True, so the
    // physical CPU bus must receive the grant while the PLIO request stays pending.
    rule simultaneousContention (stage == 5 && board.debugAdvanceReady
        && board.debugPlioMemoryRequestValid);
        LightingBusMasterDrive cpu = cpuBusRequest();
        LightingBusInputs bus = board.lightingMemory(plioReadCards(), cpu, False);
        if (!bus.busGrant || board.debugMemoryOwner != MainMemNone
            || !board.debugPreferCpu) begin
            $display("FAIL|m6.1|cpu-priority|grant=%0d|owner=%0d|prefer_cpu=%0d",
                pack(bus.busGrant), pack(board.debugMemoryOwner), pack(board.debugPreferCpu));
            $finish(1);
        end
        board.advance(plioReadCards(), cpu, False, noWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= 6;
    endrule

    rule startCpu (stage == 6 && board.debugAdvanceReady);
        LightingBusMasterDrive cpu = cpuRead(cpuAddress);
        LightingBusInputs bus = board.lightingMemory(plioReadCards(), cpu, False);
        if (!bus.busGrant || !board.debugCpuGrantHeld
            || !board.debugPlioMemoryRequestValid) begin
            $display("FAIL|m6.1|cpu-start|grant=%0d|grant_held=%0d|plio_pending=%0d",
                pack(bus.busGrant), pack(board.debugCpuGrantHeld),
                pack(board.debugPlioMemoryRequestValid));
            $finish(1);
        end
        board.advance(plioReadCards(), cpu, False, noWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= 7;
    endrule

    // Deliberately stall the memory backend. The CPU must remain the sole owner,
    // its request payload must remain stable, and the losing PLIO request must survive.
    rule stallCpuBackend (stage == 7 && board.debugAdvanceReady
        && board.memoryBackendRequestValid && stallCount < 4);
        if (board.debugMemoryOwner != MainMemCpu
            || !board.debugPlioMemoryRequestValid
            || board.memoryBackendWrite
            || board.memoryBackendAddress != cpuAddress
            || board.memoryBackendByteEnable != 4'hf) begin
            $display("FAIL|m6.1|cpu-stall|cycle=%0d|owner=%0d|plio_pending=%0d|write=%0d|addr=%08x|be=%04b",
                stallCount, pack(board.debugMemoryOwner),
                pack(board.debugPlioMemoryRequestValid), pack(board.memoryBackendWrite),
                board.memoryBackendAddress, board.memoryBackendByteEnable);
            $finish(1);
        end
        board.advance(plioReadCards(), cpuRead(cpuAddress), False,
            noWorkerRequest(), False, False, False, False, 0, False);
        stallCount <= stallCount + 1;
    endrule

    rule acceptCpuBackend (stage == 7 && board.debugAdvanceReady
        && board.memoryBackendRequestValid && stallCount == 4);
        if (backendAccepts != 0 || board.debugMemoryOwner != MainMemCpu
            || !board.debugPlioMemoryRequestValid) begin
            $display("FAIL|m6.1|cpu-accept|accepts=%0d|owner=%0d|plio_pending=%0d",
                backendAccepts, pack(board.debugMemoryOwner),
                pack(board.debugPlioMemoryRequestValid));
            $finish(1);
        end
        board.advance(plioReadCards(), cpuRead(cpuAddress), False,
            noWorkerRequest(), True, False, False, False, 0, False);
        backendAccepts <= backendAccepts + 1;
        stage <= 8;
    endrule

    rule respondCpu (stage == 8 && board.debugAdvanceReady
        && board.memoryBackendResponseReady);
        if (board.debugMemoryOwner != MainMemCpu || backendAccepts != 1) begin
            $display("FAIL|m6.1|cpu-response-owner|owner=%0d|accepts=%0d",
                pack(board.debugMemoryOwner), backendAccepts);
            $finish(1);
        end
        board.advance(plioReadCards(), cpuRead(cpuAddress), False,
            noWorkerRequest(), False, True, False, True, cpuData, False);
        backendResponses <= backendResponses + 1;
        stage <= 9;
    endrule

    rule observeCpuCompletion (stage == 9 && board.debugAdvanceReady
        && board.debugCpuResponsePending);
        LightingBusMasterDrive cpu = cpuRead(cpuAddress);
        LightingBusInputs bus = board.lightingMemory(plioReadCards(), cpu, False);
        if (!bus.ready || bus.error || bus.readData != cpuData
            || board.debugMemoryOwner != MainMemNone
            || !board.debugPlioMemoryRequestValid) begin
            $display("FAIL|m6.1|cpu-complete|ready=%0d|error=%0d|data=%08x|owner=%0d|plio_pending=%0d",
                pack(bus.ready), pack(bus.error), bus.readData,
                pack(board.debugMemoryOwner), pack(board.debugPlioMemoryRequestValid));
            $finish(1);
        end
        $display("M6ARBITRATION|winner=cpu|loser=plio|stall_cycles=4|owner_stable=1|pending_preserved=1|status=ok");
        board.advance(plioReadCards(), cpu, False, noWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= 10;
    endrule

    // Drop CPU request to retire its response. preferCpu must now be False,
    // which makes the still-pending PLIO request the deterministic next winner.
    rule retireCpu (stage == 10 && board.debugAdvanceReady);
        board.advance(plioReadCards(), lightingBusMasterDriveDefault(), False,
            noWorkerRequest(), False, False, False, False, 0, False);
        stage <= 11;
    endrule

    rule waitPlioOwnership (stage == 11 && board.debugAdvanceReady
        && !board.debugCpuResponsePending);
        if (board.debugPreferCpu || !board.debugPlioMemoryRequestValid) begin
            $display("FAIL|m6.1|plio-next-policy|prefer_cpu=%0d|plio_pending=%0d",
                pack(board.debugPreferCpu), pack(board.debugPlioMemoryRequestValid));
            $finish(1);
        end
        // Keep a new CPU contender asserted. PLIO must win because preferCpu=False.
        board.advance(plioReadCards(), cpuBusRequest(), False, noWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= 12;
        stallCount <= 0;
    endrule

    rule stallPlioBackend (stage == 12 && board.debugAdvanceReady
        && board.memoryBackendRequestValid && stallCount < 4);
        LightingBusInputs bus = board.lightingMemory(plioReadCards(), cpuBusRequest(), False);
        if (board.debugMemoryOwner != MainMemPlio
            || board.memoryBackendWrite
            || board.memoryBackendAddress != plioAddress
            || board.memoryBackendByteEnable != 4'hf
            || bus.busGrant) begin
            $display("FAIL|m6.1|plio-stall|cycle=%0d|owner=%0d|addr=%08x|be=%04b|cpu_grant=%0d",
                stallCount, pack(board.debugMemoryOwner), board.memoryBackendAddress,
                board.memoryBackendByteEnable, pack(bus.busGrant));
            $finish(1);
        end
        board.advance(plioReadCards(), cpuBusRequest(), False, noWorkerRequest(),
            False, False, False, False, 0, False);
        stallCount <= stallCount + 1;
    endrule

    rule acceptPlioBackend (stage == 12 && board.debugAdvanceReady
        && board.memoryBackendRequestValid && stallCount == 4);
        if (backendAccepts != 1 || board.debugMemoryOwner != MainMemPlio) begin
            $display("FAIL|m6.1|plio-accept|accepts=%0d|owner=%0d",
                backendAccepts, pack(board.debugMemoryOwner));
            $finish(1);
        end
        board.advance(plioReadCards(), cpuBusRequest(), False, noWorkerRequest(),
            True, False, False, False, 0, False);
        backendAccepts <= backendAccepts + 1;
        stage <= 13;
    endrule

    rule respondPlio (stage == 13 && board.debugAdvanceReady
        && board.memoryBackendResponseReady);
        if (board.debugMemoryOwner != MainMemPlio || backendAccepts != 2) begin
            $display("FAIL|m6.1|plio-response-owner|owner=%0d|accepts=%0d",
                pack(board.debugMemoryOwner), backendAccepts);
            $finish(1);
        end
        board.advance(plioReadCards(), cpuBusRequest(), False, noWorkerRequest(),
            False, True, False, True, plioData, False);
        backendResponses <= backendResponses + 1;
        stage <= 14;
    endrule

    rule observePlioData (stage == 14 && board.debugAdvanceReady);
        Vector#(8, BackplaneDrive) cards = plioReadCards();
        Vector#(8, PlioIn) slotInputs = board.plioSlots(cards, False);
        if (slotInputs[1].err) begin
            $display("FAIL|m6.1|plio-bus-error");
            $finish(1);
        end
        if (slotInputs[1].ack) begin
            if (!slotInputs[1].adValid || slotInputs[1].ad != plioData
                || backendAccepts != 2 || backendResponses != 2) begin
                $display("FAIL|m6.1|plio-data|valid=%0d|data=%08x|accepts=%0d|responses=%0d",
                    pack(slotInputs[1].adValid), slotInputs[1].ad,
                    backendAccepts, backendResponses);
                $finish(1);
            end
            $display("M6ARBITRATION|winner=plio|loser=cpu|stall_cycles=4|owner_stable=1|no_duplicate=1|status=ok");
            stage <= 15;
        end
        board.advance(cards, cpuBusRequest(), False, noWorkerRequest(),
            False, False, False, False, 0, False);
    endrule

    rule finishTest (stage == 15);
        if (backendAccepts != 2 || backendResponses != 2) begin
            $display("FAIL|m6.1|counts|accepts=%0d|responses=%0d",
                backendAccepts, backendResponses);
            $finish(1);
        end
        $display("PASS|m6.1|deterministic CPU/PLIO arbitration, stable ownership, preserved loser, backpressure, no loss or duplication");
        $finish(0);
    endrule
endmodule

endpackage
