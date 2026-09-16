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
    method Bit#(4) memoryBackendByteEnable;
    method Bit#(32) memoryBackendWriteData;
    method Bool memoryBackendResponseReady;

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
    Reg#(Bool) cpuGrantHeld <- mkReg(False);
    Reg#(Bool) cpuRequestSeen <- mkReg(False);
    Reg#(Bool) cpuResponsePresented <- mkReg(False);
    FIFOF#(MainboardCycleInputs) cycleQ <- mkLFIFOF;

    rule applyReset (cycleQ.notEmpty && cycleQ.first.reset);
        let cycle = cycleQ.first;
        Vector#(8, PlioOut) logicalCards = plioCardsFromBackplane(cycle.cards);
        memory.resetController;
        memoryOwner <= MainMemNone;
        preferCpu <= True;
        cpuGrantHeld <= False;
        cpuRequestSeen <= False;
        cpuResponsePresented <= False;
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

    rule startMemoryTransaction (cycleQ.notEmpty && !cycleQ.first.reset
        && memoryOwner == MainMemNone
        && memory.hostRequestReady
        && ( (cycleQ.first.cpu.request
                && !cpuRequestSeen
                && (cpuGrantHeld
                    || (cycleQ.first.cpu.busRequest
                        && (!host.memoryRequestValid || preferCpu))))
            || (!cpuGrantHeld
                && host.memoryRequestValid
                && (!cycleQ.first.cpu.busRequest || !preferCpu)) ));
        let cycle = cycleQ.first;
        Bool selectCpu = cycle.cpu.request
            && !cpuRequestSeen
            && (cpuGrantHeld
                || (cycle.cpu.busRequest
                    && (!host.memoryRequestValid || preferCpu)));
        if (selectCpu) begin
            memory.hostRequest(cycle.cpu.payload.write,
                cycle.cpu.payload.addr,
                cycle.cpu.payload.byteEnable,
                cycle.cpu.payload.writeData);
            memoryOwner <= MainMemCpu;
            cpuGrantHeld <= False;
            cpuRequestSeen <= True;
            cpuResponsePresented <= False;
        end
        else begin
            // PLIO DMA remains an aligned, full 32-bit beat protocol.  The
            // shared memory controller is byte-aware without changing PLIO.
            memory.hostRequest(host.memoryWrite,
                host.memoryAddress,
                4'hf,
                host.memoryWriteData);
            memoryOwner <= MainMemPlio;
        end
    endrule

    // A CPU response is kept for at least one complete registered mainboard
    // cycle.  That makes READY/ERROR externally observable without making the
    // public advance() method read internal ownership or controller state.
    // PLIO responses are consumed atomically with the host.advance() call that
    // observes them.
    rule advancePlioHost (cycleQ.notEmpty && !cycleQ.first.reset);
        let cycle = cycleQ.first;
        Vector#(8, PlioOut) logicalCards = plioCardsFromBackplane(cycle.cards);
        Bool selectCpu = cycle.cpu.request
            && !cpuRequestSeen
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
        Bool cpuResponseValid = memoryOwner == MainMemCpu
            && memory.hostResponseValid;

        host.advance(logicalCards, cycle.workerValid, cycle.workerRequest,
            acceptPlio,
            plioResponseValid,
            memory.hostResponseFault,
            memory.hostReadDataValid,
            memory.hostReadData,
            False);

        if (cpuResponseValid) begin
            if (cpuResponsePresented) begin
                memory.hostResponseConsumed;
                cpuResponsePresented <= False;
                preferCpu <= False;
                memoryOwner <= MainMemNone;
            end
            else begin
                cpuResponsePresented <= True;
            end
        end
        else if (plioResponseValid) begin
            memory.hostResponseConsumed;
            preferCpu <= True;
            memoryOwner <= MainMemNone;
        end
        cycleQ.deq;
    endrule

    method Vector#(8, PlioIn) plioSlots(Vector#(8, BackplaneDrive) cards, Bool reset);
        Vector#(8, PlioOut) logicalCards = plioOutFromBackplane(cards[0]) == plioOutDefault() ? plioCardsFromBackplane(cards) : plioCardsFromBackplane(cards);
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
    method Bit#(4) memoryBackendByteEnable = memory.backendByteEnable;
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
