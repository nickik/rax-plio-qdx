package MainboardFPGA;

import Vector::*;
import FIFOF::*;
import QLITypes::*;
import QICInterfaces::*;
import PLIOTx::*;
import PLIOWorkerHost::*;
import PLIOHostDmaM3::*;
import PLIOHostCore::*;
import MemoryController::*;
import LightingMemoryBusCompat::*;

typedef enum {
    MainMemNone,
    MainMemCpu,
    MainMemPlio
} MainMemoryOwner deriving (Bits, Eq, FShow);

typedef struct {
    Vector#(8, BackplaneDrive) cards;
    LightingBusMasterDrive cpu;
    Bool workerValid;
    HostWorkerRequest workerRequest;
    Bool backendRequestReady;
    Bool backendResponseValid;
    Bool backendFault;
    Bool backendReadDataValid;
    Bit#(32) backendReadData;
    Bool reset;
} MainboardCycleInputs deriving (Bits, FShow);

// Convert the physical-cycle card boundary used by mkQDXBCard back into the
// logical PLIO image consumed by PLIOHostCore. This intentionally lives on
// the mainboard: cards do not need to know which host implementation is used.
function PlioOut plioOutFromBackplane(BackplaneDrive bp);
    PlioOut out = plioOutDefault();
    out.request = bp.request;

    if (bp.controlValid) begin
        out.spaceValid = True;
        out.space = unpack(bp.control.space);
        out.addressStrobe = bp.control.addressStrobe;
        out.read = bp.control.read;
        out.byteEnable = bp.control.byteEnable;
        out.burst = unpack(bp.control.burstLen);
        out.dataStrobe = bp.control.dataStrobe;
    end

    if (bp.adParValid) begin
        out.adValid = True;
        out.ad = bp.ad;
        out.parValid = True;
        out.parity = bp.parity;
    end

    if (bp.responseValid) begin
        out.ack = bp.ack;
        out.err = bp.err;
    end

    return out;
endfunction

function Vector#(8, PlioOut) plioCardsFromBackplane(Vector#(8, BackplaneDrive) cards);
    Vector#(8, PlioOut) out = replicate(plioOutDefault());
    for (Integer i = 0; i < 8; i = i + 1) begin
        out[i] = plioOutFromBackplane(cards[i]);
    end
    return out;
endfunction

interface MainboardFPGAIfc;
    method Vector#(8, PlioIn) plioSlots(Vector#(8, BackplaneDrive) cards, Bool reset);

    method LightingBusInputs lightingMemory(Vector#(8, BackplaneDrive) cards,
        LightingBusMasterDrive cpu, Bool reset);

    method LightingModuleInterrupts interrupts(Bool timerIrq, Bool machineFault);

    method Bool memoryBackendRequestValid;
    method Bool memoryBackendWrite;
    method Bit#(32) memoryBackendAddress;
    method Bit#(32) memoryBackendWriteData;
    method Bool memoryBackendResponseReady;

    // Queue one physical board-cycle image. The method is guarded by queue
    // capacity, so a producer cannot overwrite an unconsumed registered image.
    // mkPipelineFIFOF preserves the registered boundary while allowing a new
    // image to follow a consumed image without an artificial testbench bubble.
    method Action advance(Vector#(8, BackplaneDrive) cards,
        LightingBusMasterDrive cpu,
        Bool workerValid, HostWorkerRequest workerRequest,
        Bool backendRequestReady,
        Bool backendResponseValid, Bool backendFault,
        Bool backendReadDataValid, Bit#(32) backendReadData,
        Bool reset);

    method Action bindDma(Bit#(3) slot, Bit#(4) channel, Bit#(32) base,
        Bit#(25) length, Bool deviceRead, Bool deviceWrite);
    method Action revokeDma(Bit#(3) slot, Bit#(4) channel);
    method Bit#(4) dmaGeneration(Bit#(3) slot, Bit#(4) channel);

    method Bool workerCompletionValid;
    method HostWorkerCompletion workerCompletion;
    method Action clearWorkerCompletion;
    method Bool dmaCompletionValid;
    method DmaM3Status dmaCompletionStatus;
    method Bit#(5) dmaCompletionBeats;
    method Action clearDmaCompletion;

    method Action setNotificationConfig(Bit#(3) slot, Bit#(2) channel,
        Bool enabled, Bool masked, Bit#(4) classCode);
    method Bool claimValid;
    method Bit#(3) claimSlot;
    method Bit#(2) claimChannel;
    method Bit#(32) claimPayload;
    method Bit#(4) claimClass;
    method Action claimFirst;

    method MainMemoryOwner debugMemoryOwner;
    method Bool debugPreferCpu;
    method Bool debugCpuGrantHeld;
    method Bool debugCpuRequestSeen;
    method Bool debugCyclePending;
    method Bool debugAdvanceReady;
    method Bool debugPlioMemoryRequestValid;
    method PLIOHostCoreRole debugPlioRole;
    method Bool debugPlioFaultValid;
    method PLIOHostCoreFault debugPlioFault;
endinterface

module mkMainboardFPGA(MainboardFPGAIfc);
    PLIOHostCoreIfc host <- mkPLIOHostCore;
    MemoryControllerIfc memory <- mkMemoryController;

    Reg#(MainMemoryOwner) memoryOwner <- mkReg(MainMemNone);
    Reg#(Bool) preferCpu <- mkReg(True);

    // LightingMemoryBus is explicitly two phase: BUS_REQ obtains BUS_GRANT,
    // and REQ is asserted only after the module has observed that grant. Keep
    // the grant reserved across that boundary so a newly arriving PLIO DMA
    // request cannot steal a bus that has already been granted to the CPU.
    Reg#(Bool) cpuGrantHeld <- mkReg(False);

    // A completed CPU request remains consumed until a sampled cycle observes
    // REQ deasserted. The cycle in which READY/ERROR is observed still contains
    // the old asserted REQ and must not become a second transaction later.
    Reg#(Bool) cpuRequestSeen <- mkReg(False);

    // The old epoch register could be overwritten by a producer that called
    // advance() on consecutive BSV clocks while the internal consumer was
    // scheduled later. A real queue makes acceptance atomic and backpressured.
    FIFOF#(MainboardCycleInputs) cycleQ <- mkPipelineFIFOF;

    rule applyReset (cycleQ.notEmpty && cycleQ.first.reset);
        let cycle = cycleQ.first;
        Vector#(8, PlioOut) logicalCards = plioCardsFromBackplane(cycle.cards);
        memory.resetController;
        memoryOwner <= MainMemNone;
        preferCpu <= True;
        cpuGrantHeld <= False;
        cpuRequestSeen <= False;
        host.advance(logicalCards, cycle.workerValid, cycle.workerRequest,
            False, False, False, False, 0, True);
        cycleQ.deq;
    endrule

    rule acceptBackendRequest (cycleQ.notEmpty && !cycleQ.first.reset
        && memory.backendRequestValid && cycleQ.first.backendRequestReady);
        memory.backendRequestAccepted;
    endrule

    rule acceptBackendResponse (cycleQ.notEmpty && !cycleQ.first.reset
        && memory.backendResponseReady && cycleQ.first.backendResponseValid);
        let cycle = cycleQ.first;
        memory.backendRespond(cycle.backendFault,
            cycle.backendReadDataValid, cycle.backendReadData);
    endrule

    rule reserveCpuGrant (cycleQ.notEmpty && !cycleQ.first.reset
        && memoryOwner == MainMemNone
        && !cpuGrantHeld
        && memory.hostRequestReady
        && cycleQ.first.cpu.busRequest
        && (!host.memoryRequestValid || preferCpu)
        && !cycleQ.first.cpu.request);
        cpuGrantHeld <= True;
    endrule

    rule abandonCpuGrant (cycleQ.notEmpty && !cycleQ.first.reset
        && memoryOwner == MainMemNone
        && cpuGrantHeld
        && !cycleQ.first.cpu.busRequest
        && !cycleQ.first.cpu.request);
        cpuGrantHeld <= False;
        preferCpu <= False;
    endrule

    rule rearmCpuRequest (cycleQ.notEmpty && !cycleQ.first.reset
        && memoryOwner == MainMemNone
        && cpuRequestSeen
        && !cycleQ.first.cpu.request);
        cpuRequestSeen <= False;
    endrule

    rule rejectPartialCpu (cycleQ.notEmpty && !cycleQ.first.reset
        && memoryOwner == MainMemNone
        && cycleQ.first.cpu.request
        && cycleQ.first.cpu.payload.byteEnable != 4'hf
        && (cpuGrantHeld
            || (!cpuGrantHeld && memory.hostRequestReady
                && cycleQ.first.cpu.busRequest
                && (!host.memoryRequestValid || preferCpu))));
        cpuGrantHeld <= False;
        preferCpu <= False;
    endrule

    rule startMemoryTransaction (cycleQ.notEmpty && !cycleQ.first.reset
        && memoryOwner == MainMemNone
        && memory.hostRequestReady
        && ( (cycleQ.first.cpu.request
                && !cpuRequestSeen
                && cycleQ.first.cpu.payload.byteEnable == 4'hf
                && (cpuGrantHeld
                    || (cycleQ.first.cpu.busRequest
                        && (!host.memoryRequestValid || preferCpu))))
            || (!cpuGrantHeld
                && host.memoryRequestValid
                && (!cycleQ.first.cpu.busRequest || !preferCpu)) ));

        let cycle = cycleQ.first;
        Bool selectCpu = cycle.cpu.request
            && !cpuRequestSeen
            && cycle.cpu.payload.byteEnable == 4'hf
            && (cpuGrantHeld
                || (cycle.cpu.busRequest
                    && (!host.memoryRequestValid || preferCpu)));

        if (selectCpu) begin
            memory.hostRequest(cycle.cpu.payload.write,
                cycle.cpu.payload.addr,
                cycle.cpu.payload.writeData);
            memoryOwner <= MainMemCpu;
            cpuGrantHeld <= False;
            cpuRequestSeen <= True;
        end
        else begin
            memory.hostRequest(host.memoryWrite,
                host.memoryAddress,
                host.memoryWriteData);
            memoryOwner <= MainMemPlio;
        end
    endrule

    rule completeMemoryTransaction (cycleQ.notEmpty && !cycleQ.first.reset
        && memoryOwner != MainMemNone
        && memory.hostResponseValid);
        memory.hostResponseConsumed;
        if (memoryOwner == MainMemCpu) preferCpu <= False;
        else preferCpu <= True;
        memoryOwner <= MainMemNone;
    endrule

    // Commit exactly one queued physical board-cycle image. Reset has its own
    // mutually-exclusive rule above. Dequeueing is the sole non-reset commit
    // point, so an image cannot be replayed or overwritten before consumption.
    rule advancePlioHost (cycleQ.notEmpty && !cycleQ.first.reset);
        let cycle = cycleQ.first;
        Vector#(8, PlioOut) logicalCards = plioCardsFromBackplane(cycle.cards);

        Bool selectCpu = cycle.cpu.request
            && !cpuRequestSeen
            && cycle.cpu.payload.byteEnable == 4'hf
            && memoryOwner == MainMemNone
            && memory.hostRequestReady
            && (cpuGrantHeld
                || (cycle.cpu.busRequest
                    && (!host.memoryRequestValid || preferCpu)));

        Bool acceptPlio = memoryOwner == MainMemNone
            && !cpuGrantHeld
            && memory.hostRequestReady
            && host.memoryRequestValid
            && (!cycle.cpu.busRequest || !preferCpu)
            && !selectCpu;

        Bool plioResponseValid = memoryOwner == MainMemPlio
            && memory.hostResponseValid;

        host.advance(logicalCards, cycle.workerValid, cycle.workerRequest,
            acceptPlio,
            plioResponseValid,
            memory.hostResponseFault,
            memory.hostReadDataValid,
            memory.hostReadData,
            False);
        cycleQ.deq;
    endrule

    method Vector#(8, PlioIn) plioSlots(Vector#(8, BackplaneDrive) cards, Bool reset);
        Vector#(8, PlioOut) logicalCards = plioCardsFromBackplane(cards);
        return host.drive(logicalCards, reset);
    endmethod

    method LightingBusInputs lightingMemory(Vector#(8, BackplaneDrive) cards,
        LightingBusMasterDrive cpu, Bool reset);
        LightingBusInputs out = lightingBusInputsDefault();

        if (!reset) begin
            Bool plioWaiting = host.memoryRequestValid;
            Bool canArbitrate = memoryOwner == MainMemNone
                && !cpuGrantHeld
                && memory.hostRequestReady;
            Bool selectCpu = canArbitrate
                && cpu.busRequest
                && (!plioWaiting || preferCpu);
            Bool cpuOwnsBus = cpuGrantHeld
                || selectCpu
                || memoryOwner == MainMemCpu;

            if (cpuOwnsBus) begin
                out.busGrant = True;

                if (memoryOwner == MainMemCpu && memory.hostResponseValid) begin
                    out.error = memory.hostResponseFault;
                    out.ready = !memory.hostResponseFault;
                    if (memory.hostReadDataValid) out.readData = memory.hostReadData;
                end
                else if ((cpuGrantHeld || selectCpu)
                    && cpu.request
                    && cpu.payload.byteEnable != 4'hf) begin
                    out.error = True;
                end
            end
        end

        return out;
    endmethod

    method LightingModuleInterrupts interrupts(Bool timerIrq, Bool machineFault);
        return LightingModuleInterrupts {
            plioIrq: host.claimValid,
            timerIrq: timerIrq,
            machineFault: machineFault
        };
    endmethod

    method Bool memoryBackendRequestValid = memory.backendRequestValid;
    method Bool memoryBackendWrite = memory.backendWrite;
    method Bit#(32) memoryBackendAddress = memory.backendAddress;
    method Bit#(32) memoryBackendWriteData = memory.backendWriteData;
    method Bool memoryBackendResponseReady = memory.backendResponseReady;

    method Action advance(Vector#(8, BackplaneDrive) cards,
        LightingBusMasterDrive cpu,
        Bool workerValid, HostWorkerRequest workerRequest,
        Bool backendRequestReady,
        Bool backendResponseValid, Bool backendFault,
        Bool backendReadDataValid, Bit#(32) backendReadData,
        Bool reset) if (cycleQ.notFull);
        cycleQ.enq(MainboardCycleInputs {
            cards: cards,
            cpu: cpu,
            workerValid: workerValid,
            workerRequest: workerRequest,
            backendRequestReady: backendRequestReady,
            backendResponseValid: backendResponseValid,
            backendFault: backendFault,
            backendReadDataValid: backendReadDataValid,
            backendReadData: backendReadData,
            reset: reset
        });
    endmethod

    method Action bindDma(Bit#(3) slot, Bit#(4) channel, Bit#(32) base,
        Bit#(25) length, Bool deviceRead, Bool deviceWrite);
        host.bindDma(slot, channel, base, length, deviceRead, deviceWrite);
    endmethod

    method Action revokeDma(Bit#(3) slot, Bit#(4) channel);
        host.revokeDma(slot, channel);
    endmethod

    method Bit#(4) dmaGeneration(Bit#(3) slot, Bit#(4) channel)
        = host.dmaGeneration(slot, channel);

    method Bool workerCompletionValid = host.workerCompletionValid;
    method HostWorkerCompletion workerCompletion = host.workerCompletion;

    method Action clearWorkerCompletion;
        host.clearWorkerCompletion;
    endmethod

    method Bool dmaCompletionValid = host.dmaCompletionValid;
    method DmaM3Status dmaCompletionStatus = host.dmaCompletionStatus;
    method Bit#(5) dmaCompletionBeats = host.dmaCompletionBeats;

    method Action clearDmaCompletion;
        host.clearDmaCompletion;
    endmethod

    method Action setNotificationConfig(Bit#(3) slot, Bit#(2) channel,
        Bool enabled, Bool masked, Bit#(4) classCode);
        host.setNotificationConfig(slot, channel, enabled, masked, classCode);
    endmethod

    method Bool claimValid = host.claimValid;
    method Bit#(3) claimSlot = host.claimSlot;
    method Bit#(2) claimChannel = host.claimChannel;
    method Bit#(32) claimPayload = host.claimPayload;
    method Bit#(4) claimClass = host.claimClass;

    method Action claimFirst;
        host.claimFirst;
    endmethod

    method MainMemoryOwner debugMemoryOwner = memoryOwner;
    method Bool debugPreferCpu = preferCpu;
    method Bool debugCpuGrantHeld = cpuGrantHeld;
    method Bool debugCpuRequestSeen = cpuRequestSeen;
    method Bool debugCyclePending = cycleQ.notEmpty;
    method Bool debugAdvanceReady = cycleQ.notFull;
    method Bool debugPlioMemoryRequestValid = host.memoryRequestValid;
    method PLIOHostCoreRole debugPlioRole = host.debugRole;
    method Bool debugPlioFaultValid = host.debugFaultValid;
    method PLIOHostCoreFault debugPlioFault = host.debugFault;
endmodule

endpackage
