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
    method Bool debugCpuResponsePending;
    method Bool debugPlioResponsePending;
    method Bool debugCyclePending;
    method Bool debugAdvanceReady;
    method MemoryControllerState debugMemoryControllerState;
    method Bool debugMemoryHostResponseValid;
    method Bool debugPlioMemoryRequestValid;
    method DmaM3State debugPlioDmaState;
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

    // CPU responses must survive the registered physical-cycle boundary. PLIO
    // request/response handshakes are completed atomically in dedicated rules
    // so MemoryController and PLIOHostCore cannot disagree about an accepted
    // request or consumed response.
    Reg#(Bool) cpuResponsePending <- mkReg(False);
    Reg#(Bool) cpuResponseFault <- mkReg(False);
    Reg#(Bool) cpuResponseReadDataValid <- mkReg(False);
    Reg#(Bit#(32)) cpuResponseReadData <- mkReg(0);

    FIFOF#(MainboardCycleInputs) cycleQ <- mkLFIFOF;

    rule applyReset (cycleQ.notEmpty && cycleQ.first.reset);
        let cycle = cycleQ.first;
        Vector#(8, PlioOut) logicalCards = plioCardsFromBackplane(cycle.cards);
        memory.resetController;
        memoryOwner <= MainMemNone;
        preferCpu <= True;
        cpuGrantHeld <= False;
        cpuRequestSeen <= False;
        cpuResponsePending <= False;
        cpuResponseFault <= False;
        cpuResponseReadDataValid <= False;
        cpuResponseReadData <= 0;
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
        && !cpuResponsePending
        && !cpuGrantHeld
        && memory.hostRequestReady
        && cycleQ.first.cpu.busRequest
        && (!host.memoryRequestValid || preferCpu)
        && !cycleQ.first.cpu.request);
        cpuGrantHeld <= True;
    endrule

    rule abandonCpuGrant (cycleQ.notEmpty && !cycleQ.first.reset
        && memoryOwner == MainMemNone
        && !cpuResponsePending
        && cpuGrantHeld
        && !cycleQ.first.cpu.busRequest
        && !cycleQ.first.cpu.request);
        cpuGrantHeld <= False;
        preferCpu <= False;
    endrule

    rule rearmCpuRequest (cycleQ.notEmpty && !cycleQ.first.reset
        && memoryOwner == MainMemNone
        && !cpuResponsePending
        && cpuRequestSeen
        && !cycleQ.first.cpu.request);
        cpuRequestSeen <= False;
    endrule

    rule retireCpuResponse (cycleQ.notEmpty && !cycleQ.first.reset
        && cpuResponsePending
        && !cycleQ.first.cpu.request);
        cpuResponsePending <= False;
        cpuResponseFault <= False;
        cpuResponseReadDataValid <= False;
        cpuResponseReadData <= 0;
        cpuRequestSeen <= False;
    endrule

    rule startCpuMemoryTransaction (cycleQ.notEmpty && !cycleQ.first.reset
        && memoryOwner == MainMemNone
        && !cpuResponsePending
        && memory.hostRequestReady
        && cycleQ.first.cpu.request
        && !cpuRequestSeen
        && (cpuGrantHeld
            || (cycleQ.first.cpu.busRequest
                && (!host.memoryRequestValid || preferCpu))));
        let cycle = cycleQ.first;
        memory.hostRequest(cycle.cpu.payload.write,
            cycle.cpu.payload.addr,
            cycle.cpu.payload.byteEnable,
            cycle.cpu.payload.writeData);
        memoryOwner <= MainMemCpu;
        cpuGrantHeld <= False;
        cpuRequestSeen <= True;
    endrule

    rule captureCpuMemoryResponse (!(cycleQ.notEmpty && cycleQ.first.reset)
        && memoryOwner == MainMemCpu
        && memory.hostResponseValid);
        cpuResponsePending <= True;
        cpuResponseFault <= memory.hostResponseFault;
        cpuResponseReadDataValid <= memory.hostReadDataValid;
        cpuResponseReadData <= memory.hostReadData;
        preferCpu <= False;
        memoryOwner <= MainMemNone;
        memory.hostResponseConsumed;
    endrule

    // PLIO request acceptance is one atomic rule: the MemoryController request
    // is created in the same clock that PLIOHostCore sees memoryRequestReady.
    // PLIO DMA remains a full 32-bit transfer and therefore always uses BE=f.
    rule advancePlioRequest (cycleQ.notEmpty && !cycleQ.first.reset
        && !cpuResponsePending
        && memoryOwner == MainMemNone
        && !cpuGrantHeld
        && memory.hostRequestReady
        && host.memoryRequestValid
        && (!cycleQ.first.cpu.busRequest || !preferCpu));
        let cycle = cycleQ.first;
        Vector#(8, PlioOut) logicalCards = plioCardsFromBackplane(cycle.cards);
        host.advance(logicalCards, cycle.workerValid, cycle.workerRequest,
            True, False, False, False, 0, False);
        memory.hostRequest(host.memoryWrite,
            host.memoryAddress,
            4'hf,
            host.memoryWriteData);
        memoryOwner <= MainMemPlio;
        cycleQ.deq;
    endrule

    // PLIO response delivery is also atomic: the response is presented to the
    // host in the same rule that consumes it from MemoryController.
    rule advancePlioResponse (cycleQ.notEmpty && !cycleQ.first.reset
        && memoryOwner == MainMemPlio
        && memory.hostResponseValid);
        let cycle = cycleQ.first;
        Vector#(8, PlioOut) logicalCards = plioCardsFromBackplane(cycle.cards);
        host.advance(logicalCards, cycle.workerValid, cycle.workerRequest,
            False, True,
            memory.hostResponseFault,
            memory.hostReadDataValid,
            memory.hostReadData,
            False);
        memory.hostResponseConsumed;
        memoryOwner <= MainMemNone;
        preferCpu <= True;
        cycleQ.deq;
    endrule

    // All remaining physical cycles advance the PLIO host without a memory
    // edge. The explicit negations make this rule mutually exclusive with the
    // two atomic PLIO memory rules above.
    rule advancePlioOrdinary (cycleQ.notEmpty && !cycleQ.first.reset
        && !(memoryOwner == MainMemPlio && memory.hostResponseValid)
        && !(!cpuResponsePending
            && memoryOwner == MainMemNone
            && !cpuGrantHeld
            && memory.hostRequestReady
            && host.memoryRequestValid
            && (!cycleQ.first.cpu.busRequest || !preferCpu)));
        let cycle = cycleQ.first;
        Vector#(8, PlioOut) logicalCards = plioCardsFromBackplane(cycle.cards);
        host.advance(logicalCards, cycle.workerValid, cycle.workerRequest,
            False, False, False, False, 0, False);
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
                && !cpuResponsePending
                && !cpuGrantHeld
                && memory.hostRequestReady;
            Bool selectCpu = canArbitrate
                && cpu.busRequest
                && (!plioWaiting || preferCpu);
            Bool cpuOwnsBus = cpuGrantHeld
                || selectCpu
                || memoryOwner == MainMemCpu
                || cpuResponsePending;
            if (cpuOwnsBus) begin
                out.busGrant = True;
                if (cpuResponsePending) begin
                    out.error = cpuResponseFault;
                    // ready denotes a terminal CPU response; error qualifies
                    // that response rather than suppressing it.
                    out.ready = True;
                    if (cpuResponseReadDataValid) out.readData = cpuResponseReadData;
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
    method Bool debugCpuResponsePending = cpuResponsePending;
    method Bool debugPlioResponsePending = memoryOwner == MainMemPlio
        && memory.hostResponseValid;
    method Bool debugCyclePending = cycleQ.notEmpty;
    method Bool debugAdvanceReady = cycleQ.notFull;
    method MemoryControllerState debugMemoryControllerState = memory.debugState;
    method Bool debugMemoryHostResponseValid = memory.hostResponseValid;
    method Bool debugPlioMemoryRequestValid = host.memoryRequestValid;
    method DmaM3State debugPlioDmaState = host.debugDmaState;
    method PLIOHostCoreRole debugPlioRole = host.debugRole;
    method Bool debugPlioFaultValid = host.debugFaultValid;
    method PLIOHostCoreFault debugPlioFault = host.debugFault;
endmodule

endpackage
