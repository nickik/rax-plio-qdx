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
    Vector#(8, Bool) slotPresent;
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

// Lighting's CPU-visible PLIO0 aperture is a host-profile concern.  The
// cards still see only slot-relative worker transactions; no CPU address is
// ever exposed on the PLIO backplane.
Bit#(32) lightingPlio0Base = 32'hffe0_0000;
Bit#(32) lightingPlio0Size = 32'h0010_0000;
Bit#(32) lightingPlio0WorkerBase = 32'h0008_0000;
Bit#(32) lightingPlio0DmaTableBase = 32'h0000_1000;
Bit#(32) lightingPlio0DmaTableEnd = 32'h0000_1800;

function Bool isLightingPlio0(Bit#(32) address);
    return address >= lightingPlio0Base
        && address < lightingPlio0Base + lightingPlio0Size;
endfunction

function Bool isLightingPlio0Worker(Bit#(32) address);
    Bit#(32) offset = address - lightingPlio0Base;
    return isLightingPlio0(address) && offset >= lightingPlio0WorkerBase;
endfunction

function Bool workerByteEnableValid(Bit#(4) byteEnable);
    return byteEnable == 4'b0001 || byteEnable == 4'b0010
        || byteEnable == 4'b0100 || byteEnable == 4'b1000
        || byteEnable == 4'b0011 || byteEnable == 4'b1100
        || byteEnable == 4'b1111;
endfunction

function HostWorkerWidth workerWidth(Bit#(4) byteEnable);
    if (byteEnable == 4'b1111) return HostW32;
    else if (byteEnable == 4'b0011 || byteEnable == 4'b1100) return HostW16;
    else return HostW8;
endfunction

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
    method Action advanceWithSlotPresence(Vector#(8, BackplaneDrive) cards,
        Vector#(8, Bool) slotPresent,
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

    // The IOchannel map is deliberately owned by the Mainboard platform unit.
    // Its format is the frozen Lighting PLIO0 host-profile CSR encoding:
    // ENABLE[31] | SLOT[18:16] | PAGE[8:0].
    Vector#(8, Reg#(Bit#(32))) ioChannels <- replicateM(mkReg(0));
    Vector#(128, Reg#(Bit#(32))) dmaStagedBase <- replicateM(mkReg(0));
    Vector#(128, Reg#(Bit#(25))) dmaStagedLength <- replicateM(mkReg(0));
    Vector#(128, Reg#(Bit#(2))) dmaPermissions <- replicateM(mkReg(0));
    Vector#(128, Reg#(Bool)) dmaBound <- replicateM(mkReg(False));
    Reg#(Bool) cpuMmioWorkerPending <- mkReg(False);
    Reg#(Bool) cpuMmioWorkerIssued <- mkReg(False);
    Reg#(HostWorkerRequest) cpuMmioWorkerRequest <- mkReg(
        HostWorkerRequest { slot: 0, address: 0, width: HostW32,
                            write: False, value: 0 });

    // These are host-profile CSRs owned by the Mainboard platform unit.  The
    // PLIOHostCore retains protocol/arbitration ownership; this state only
    // exposes its frozen CPU-visible control plane.
    Reg#(Bool) plioEnabled <- mkReg(True);
    Reg#(Bool) plioError <- mkReg(False);
    Reg#(Bit#(32)) plioErrorInfo <- mkReg(0);
    Reg#(Bool) plioSoftResetPending <- mkReg(False);
    Reg#(Bit#(8)) slotPresentBits <- mkReg(0);
    Reg#(Bit#(32)) notificationClaimData <- mkReg(0);

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
        cpuMmioWorkerPending <= False;
        cpuMmioWorkerIssued <= False;
        plioEnabled <= True;
        plioError <= False;
        plioErrorInfo <= 0;
        plioSoftResetPending <= False;
        slotPresentBits <= 0;
        notificationClaimData <= 0;
        for (Integer channel = 0; channel < 8; channel = channel + 1)
            ioChannels[channel] <= 0;
        for (Integer entry = 0; entry < 128; entry = entry + 1) begin
            dmaStagedBase[entry] <= 0;
            dmaStagedLength[entry] <= 0;
            dmaPermissions[entry] <= 0;
            dmaBound[entry] <= False;
        end
        host.advance(logicalCards, cycle.workerValid, cycle.workerRequest,
            False, False, False, False, 0, True);
        cycleQ.deq;
    endrule

    rule acceptBackendRequest (cycleQ.notEmpty && !cycleQ.first.reset
        && !plioSoftResetPending
        && memory.backendRequestValid && cycleQ.first.backendRequestReady);
        memory.backendRequestAccepted;
    endrule

    rule acceptBackendResponse (cycleQ.notEmpty && !cycleQ.first.reset
        && !plioSoftResetPending
        && memory.backendResponseReady && cycleQ.first.backendResponseValid);
        let cycle = cycleQ.first;
        memory.backendRespond(cycle.backendFault,
            cycle.backendReadDataValid, cycle.backendReadData);
    endrule

    // CONTROL.RESET is a PLIO-host reset, not a machine-memory reset.  It
    // clears the host-visible control plane atomically with the reset image
    // delivered to PLIOHostCore and the physically attached cards.
    rule completePlioSoftReset (cycleQ.notEmpty && !cycleQ.first.reset
        && plioSoftResetPending);
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
        plioSoftResetPending <= False;
        plioEnabled <= True;
        plioError <= False;
        plioErrorInfo <= 0;
        notificationClaimData <= 0;
        slotPresentBits <= pack(cycle.slotPresent);
        cpuMmioWorkerPending <= False;
        cpuMmioWorkerIssued <= False;
        for (Integer channel = 0; channel < 8; channel = channel + 1)
            ioChannels[channel] <= 0;
        for (Integer entry = 0; entry < 128; entry = entry + 1) begin
            dmaStagedBase[entry] <= 0;
            dmaStagedLength[entry] <= 0;
            dmaPermissions[entry] <= 0;
            dmaBound[entry] <= False;
        end
        host.advance(logicalCards, False, cycle.workerRequest,
            False, False, False, False, 0, True);
        cycleQ.deq;
    endrule

    rule reserveCpuGrant (cycleQ.notEmpty && !cycleQ.first.reset
        && !plioSoftResetPending
        && memoryOwner == MainMemNone
        && !cpuResponsePending
        && !cpuGrantHeld
        && (memory.hostRequestReady
            || isLightingPlio0(cycleQ.first.cpu.payload.addr))
        && cycleQ.first.cpu.busRequest
        && (!host.memoryRequestValid || preferCpu)
        && !cycleQ.first.cpu.request);
        cpuGrantHeld <= True;
    endrule

    rule abandonCpuGrant (cycleQ.notEmpty && !cycleQ.first.reset
        && !plioSoftResetPending
        && memoryOwner == MainMemNone
        && !cpuResponsePending
        && cpuGrantHeld
        && !cycleQ.first.cpu.busRequest
        && !cycleQ.first.cpu.request);
        cpuGrantHeld <= False;
        preferCpu <= False;
    endrule

    rule rearmCpuRequest (cycleQ.notEmpty && !cycleQ.first.reset
        && !plioSoftResetPending
        && memoryOwner == MainMemNone
        && !cpuResponsePending
        && cpuRequestSeen
        && !cycleQ.first.cpu.request);
        cpuRequestSeen <= False;
    endrule

    rule retireCpuResponse (cycleQ.notEmpty && !cycleQ.first.reset
        && !plioSoftResetPending
        && cpuResponsePending
        && !cycleQ.first.cpu.request);
        cpuResponsePending <= False;
        cpuResponseFault <= False;
        cpuResponseReadDataValid <= False;
        cpuResponseReadData <= 0;
        cpuRequestSeen <= False;
    endrule

    rule startCpuMemoryTransaction (cycleQ.notEmpty && !cycleQ.first.reset
        && !plioSoftResetPending
        && memoryOwner == MainMemNone
        && !cpuResponsePending
        && !cpuMmioWorkerPending
        && cycleQ.first.cpu.request
        && !cpuRequestSeen
        && (cpuGrantHeld
            || (cycleQ.first.cpu.busRequest
                && (!host.memoryRequestValid || preferCpu))));
        let cycle = cycleQ.first;
        Bool plio0 = isLightingPlio0(cycle.cpu.payload.addr);
        if (!plio0 && memory.hostRequestReady) begin
            memory.hostRequest(cycle.cpu.payload.write,
                cycle.cpu.payload.addr,
                cycle.cpu.payload.byteEnable,
                cycle.cpu.payload.writeData);
            memoryOwner <= MainMemCpu;
        end
        else if (plio0) begin
            Bit#(32) offset = cycle.cpu.payload.addr - lightingPlio0Base;
            Bool controller = offset < lightingPlio0WorkerBase;
            Bool complete = False;
            Bool fault = False;
            Bit#(32) readData = 0;
            if (controller) begin
                // Controller CSRs are naturally aligned 32-bit accesses.
                // This is the frozen Lighting PLIO0 profile; the action path
                // below only programs PLIOHostCore, never a CPU-side device
                // shortcut or a direct RAM mapping.
                if (cycle.cpu.payload.byteEnable != 4'hf || offset[1:0] != 0) begin
                    complete = True; fault = True;
                end
                else if (offset == 32'h0000_0000 && !cycle.cpu.payload.write) begin
                    complete = True; readData = 32'h4f49_4c50; // "PLIO", LE
                end
                else if (offset == 32'h0000_0004 && !cycle.cpu.payload.write) begin
                    complete = True; readData = 32'h0000_0600;
                end
                else if (offset == 32'h0000_0008 && !cycle.cpu.payload.write) begin
                    complete = True;
                    readData[0] = pack(plioEnabled);
                    readData[1] = pack(plioError);
                    readData[2] = pack(slotPresentBits != 0);
                    readData[3] = pack(host.claimValid);
                end
                else if (offset == 32'h0000_000c) begin
                    complete = True;
                    if (cycle.cpu.payload.write) begin
                        plioEnabled <= unpack(cycle.cpu.payload.writeData[1]);
                        if (cycle.cpu.payload.writeData[0] == 1)
                            plioSoftResetPending <= True;
                    end
                    else begin
                        readData[0] = pack(plioSoftResetPending);
                        readData[1] = pack(plioEnabled);
                    end
                end
                else if (offset == 32'h0000_0010 && !cycle.cpu.payload.write) begin
                    complete = True; readData = zeroExtend(slotPresentBits);
                end
                else if (offset == 32'h0000_0014 && !cycle.cpu.payload.write) begin
                    complete = True; readData = host.notificationPendingMask;
                end
                else if (offset == 32'h0000_0018) begin
                    complete = True;
                    if (cycle.cpu.payload.write)
                        host.configureNotificationState(cycle.cpu.payload.writeData,
                            host.notificationMaskedMask, False, 0, 0, 0);
                    else readData = host.notificationEnabledMask;
                end
                else if (offset == 32'h0000_001c) begin
                    complete = True;
                    if (cycle.cpu.payload.write)
                        host.configureNotificationState(host.notificationEnabledMask,
                            cycle.cpu.payload.writeData, False, 0, 0, 0);
                    else readData = host.notificationMaskedMask;
                end
                else if (offset == 32'h0000_0020 && !cycle.cpu.payload.write) begin
                    complete = True;
                    if (host.claimValid) begin
                        readData = { 23'd0, host.claimClass, host.claimSlot,
                                     host.claimChannel };
                        notificationClaimData <= host.claimPayload;
                        host.claimFirst;
                    end
                    else readData = 32'hffff_ffff;
                end
                else if (offset == 32'h0000_0024 && !cycle.cpu.payload.write) begin
                    complete = True; readData = notificationClaimData;
                end
                else if (offset == 32'h0000_0028) begin
                    complete = True;
                    if (cycle.cpu.payload.write) begin
                        if (cycle.cpu.payload.writeData != 0) begin
                            plioError <= False;
                            plioErrorInfo <= 0;
                        end
                    end
                    else readData = zeroExtend(pack(plioError));
                end
                else if (offset == 32'h0000_002c && !cycle.cpu.payload.write) begin
                    complete = True; readData = plioErrorInfo;
                end
                else if (offset >= 32'h0000_0100 && offset < 32'h0000_0120) begin
                    Bit#(3) channel = truncate((offset - 32'h100) >> 2);
                    complete = True;
                    if (cycle.cpu.payload.write)
                        ioChannels[channel] <= cycle.cpu.payload.writeData;
                    else
                        readData = ioChannels[channel];
                end
                else if (offset >= 32'h0000_0400 && offset < 32'h0000_0480) begin
                    Bit#(5) notification = truncate((offset - 32'h400) >> 2);
                    Bit#(3) slot = notification[4:2];
                    Bit#(2) channel = notification[1:0];
                    complete = True;
                    if (cycle.cpu.payload.write)
                        host.configureNotificationState(host.notificationEnabledMask,
                            host.notificationMaskedMask, True, slot, channel,
                            cycle.cpu.payload.writeData[3:0]);
                    else readData = zeroExtend(host.notificationClass(slot, channel));
                end
                else if (offset >= lightingPlio0DmaTableBase
                    && offset < lightingPlio0DmaTableEnd) begin
                    Bit#(11) relative = truncate(offset
                        - lightingPlio0DmaTableBase);
                    Bit#(7) entry = relative[10:4];
                    Bit#(4) field = relative[3:0];
                    Bit#(3) slot = entry[6:4];
                    Bit#(4) channel = entry[3:0];
                    complete = True;
                    case (field)
                        4'h0: begin
                            if (cycle.cpu.payload.write) begin
                                if (dmaBound[entry]
                                    || cycle.cpu.payload.writeData[1:0] != 0)
                                    fault = True;
                                else dmaStagedBase[entry]
                                    <= cycle.cpu.payload.writeData;
                            end
                            else readData = dmaStagedBase[entry];
                        end
                        4'h4: begin
                            if (cycle.cpu.payload.write) begin
                                if (dmaBound[entry]
                                    || cycle.cpu.payload.writeData == 0
                                    || cycle.cpu.payload.writeData
                                        > 32'h0100_0000)
                                    fault = True;
                                else dmaStagedLength[entry]
                                    <= cycle.cpu.payload.writeData[24:0];
                            end
                            else readData = zeroExtend(dmaStagedLength[entry]);
                        end
                        4'h8: begin
                            if (cycle.cpu.payload.write) begin
                                Bit#(32) command = cycle.cpu.payload.writeData;
                                Bool doBind = unpack(command[0]);
                                Bool revoke = unpack(command[3]);
                                Bool deviceRead = unpack(command[1]);
                                Bool deviceWrite = unpack(command[2]);
                                Bool malformed = command[31:4] != 0
                                    || doBind == revoke;
                                if (doBind) malformed = malformed
                                    || dmaBound[entry]
                                    || (!deviceRead && !deviceWrite)
                                    || dmaStagedBase[entry][1:0] != 0
                                    || dmaStagedLength[entry] == 0;
                                if (malformed) fault = True;
                                else if (revoke) begin
                                    host.revokeDma(slot, channel);
                                    dmaBound[entry] <= False;
                                    dmaPermissions[entry] <= 0;
                                end
                                else begin
                                    host.bindDma(slot, channel,
                                        dmaStagedBase[entry],
                                        dmaStagedLength[entry],
                                        deviceRead, deviceWrite);
                                    dmaBound[entry] <= True;
                                    dmaPermissions[entry]
                                        <= { pack(deviceWrite),
                                            pack(deviceRead) };
                                end
                            end
                            else readData = { 28'b0, 1'b0,
                                dmaPermissions[entry],
                                pack(dmaBound[entry]) };
                        end
                        4'hc: begin
                            if (cycle.cpu.payload.write) fault = True;
                            else readData = zeroExtend(
                                host.dmaGeneration(slot, channel));
                        end
                        default: fault = True;
                    endcase
                end
                else begin
                    complete = True; fault = True;
                end
            end
            else begin
                Bit#(3) channel = truncate((offset - lightingPlio0WorkerBase) >> 16);
                Bit#(32) map = ioChannels[channel];
                Bool aligned = (cycle.cpu.payload.byteEnable == 4'hf)
                    || (cycle.cpu.payload.byteEnable == 4'b0011 && cycle.cpu.payload.addr[0] == 0)
                    || (cycle.cpu.payload.byteEnable == 4'b1100 && cycle.cpu.payload.addr[0] == 0)
                    || (cycle.cpu.payload.byteEnable != 0 && workerByteEnableValid(cycle.cpu.payload.byteEnable));
                if (!plioEnabled || map[31] == 0 || !aligned || !workerByteEnableValid(cycle.cpu.payload.byteEnable)) begin
                    complete = True; fault = True;
                end
                else begin
                    cpuMmioWorkerRequest <= HostWorkerRequest {
                        slot: map[18:16],
                        address: { 7'b0, map[8:0], cycle.cpu.payload.addr[15:0] },
                        width: workerWidth(cycle.cpu.payload.byteEnable),
                        write: cycle.cpu.payload.write,
                        value: cycle.cpu.payload.writeData >> ({ 3'b0, cycle.cpu.payload.addr[1:0] } << 3)
                    };
                    cpuMmioWorkerPending <= True;
                    cpuMmioWorkerIssued <= False;
                end
            end
            if (complete) begin
                cpuResponsePending <= True;
                cpuResponseFault <= fault;
                cpuResponseReadDataValid <= !fault && !cycle.cpu.payload.write;
                cpuResponseReadData <= readData;
                if (fault) begin
                    plioError <= True;
                    plioErrorInfo <= offset;
                end
            end
        end
        cpuGrantHeld <= False;
        cpuRequestSeen <= True;
    endrule

    // A worker MMIO transfer is an asynchronous CPU transaction, but it is
    // still driven exclusively by the real PLIO host state machine.  The CPU
    // remains granted until the resulting ACK/ERR completion is registered.
    rule captureCpuMmioWorkerCompletion (!plioSoftResetPending
        && cpuMmioWorkerPending
        && cpuMmioWorkerIssued && host.workerCompletionValid
        && !cpuResponsePending);
        let completion = host.workerCompletion;
        cpuResponsePending <= True;
        cpuResponseFault <= completion.status != HostSuccess;
        cpuResponseReadDataValid <= completion.status == HostSuccess
            && !cpuMmioWorkerRequest.write;
        cpuResponseReadData <= completion.data;
        cpuMmioWorkerPending <= False;
        cpuMmioWorkerIssued <= False;
        if (completion.status != HostSuccess) begin
            plioError <= True;
            plioErrorInfo <= zeroExtend(pack(completion.status));
        end
        host.clearWorkerCompletion;
    endrule

    rule captureCpuMemoryResponse (!plioSoftResetPending
        && !(cycleQ.notEmpty && cycleQ.first.reset)
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
        && !plioSoftResetPending
        && !cpuResponsePending
        && memoryOwner == MainMemNone
        && !cpuGrantHeld
        && memory.hostRequestReady
        && host.memoryRequestValid
        && (!cycleQ.first.cpu.busRequest || !preferCpu));
        let cycle = cycleQ.first;
        Vector#(8, PlioOut) logicalCards = plioCardsFromBackplane(cycle.cards);
        Bool useCpuWorker = cpuMmioWorkerPending && !cpuMmioWorkerIssued;
        host.advance(logicalCards, useCpuWorker ? True : cycle.workerValid,
            useCpuWorker ? cpuMmioWorkerRequest : cycle.workerRequest,
            True, False, False, False, 0, plioSoftResetPending);
        if (useCpuWorker) cpuMmioWorkerIssued <= True;
        memory.hostRequest(host.memoryWrite,
            host.memoryAddress,
            4'hf,
            host.memoryWriteData);
        memoryOwner <= MainMemPlio;
        slotPresentBits <= pack(cycle.slotPresent);
        cycleQ.deq;
    endrule

    // PLIO response delivery is also atomic: the response is presented to the
    // host in the same rule that consumes it from MemoryController.
    rule advancePlioResponse (cycleQ.notEmpty && !cycleQ.first.reset
        && !plioSoftResetPending
        && memoryOwner == MainMemPlio
        && memory.hostResponseValid);
        let cycle = cycleQ.first;
        Vector#(8, PlioOut) logicalCards = plioCardsFromBackplane(cycle.cards);
        Bool useCpuWorker = cpuMmioWorkerPending && !cpuMmioWorkerIssued;
        host.advance(logicalCards, useCpuWorker ? True : cycle.workerValid,
            useCpuWorker ? cpuMmioWorkerRequest : cycle.workerRequest,
            False, True,
            memory.hostResponseFault,
            memory.hostReadDataValid,
            memory.hostReadData,
            False);
        if (useCpuWorker) cpuMmioWorkerIssued <= True;
        memory.hostResponseConsumed;
        memoryOwner <= MainMemNone;
        preferCpu <= True;
        slotPresentBits <= pack(cycle.slotPresent);
        cycleQ.deq;
    endrule

    // All remaining physical cycles advance the PLIO host without a memory
    // edge. The explicit negations make this rule mutually exclusive with the
    // two atomic PLIO memory rules above.
    rule advancePlioOrdinary (cycleQ.notEmpty && !cycleQ.first.reset
        && !plioSoftResetPending
        && !(memoryOwner == MainMemPlio && memory.hostResponseValid)
        && !(!cpuResponsePending
            && memoryOwner == MainMemNone
            && !cpuGrantHeld
            && memory.hostRequestReady
            && host.memoryRequestValid
            && (!cycleQ.first.cpu.busRequest || !preferCpu)));
        let cycle = cycleQ.first;
        Vector#(8, PlioOut) logicalCards = plioCardsFromBackplane(cycle.cards);
        Bool useCpuWorker = cpuMmioWorkerPending && !cpuMmioWorkerIssued;
        host.advance(logicalCards, useCpuWorker ? True : cycle.workerValid,
            useCpuWorker ? cpuMmioWorkerRequest : cycle.workerRequest,
            False, False, False, False, 0, False);
        if (useCpuWorker) cpuMmioWorkerIssued <= True;
        slotPresentBits <= pack(cycle.slotPresent);
        cycleQ.deq;
    endrule

    method Vector#(8, PlioIn) plioSlots(Vector#(8, BackplaneDrive) cards, Bool reset);
        Vector#(8, PlioOut) logicalCards = plioCardsFromBackplane(cards);
        return host.drive(logicalCards, reset || plioSoftResetPending);
    endmethod

    method LightingBusInputs lightingMemory(Vector#(8, BackplaneDrive) cards,
        LightingBusMasterDrive cpu, Bool reset);
        LightingBusInputs out = lightingBusInputsDefault();
        if (!reset) begin
            Bool plioWaiting = host.memoryRequestValid;
            Bool canArbitrate = memoryOwner == MainMemNone
                && !cpuResponsePending
                && !cpuGrantHeld
                && (memory.hostRequestReady || isLightingPlio0(cpu.payload.addr));
            Bool selectCpu = canArbitrate
                && cpu.busRequest
                && (!plioWaiting || preferCpu);
            Bool cpuOwnsBus = cpuGrantHeld
                || selectCpu
                || memoryOwner == MainMemCpu
                || cpuResponsePending
                || cpuMmioWorkerPending;
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
            slotPresent: replicate(False),
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

    method Action advanceWithSlotPresence(Vector#(8, BackplaneDrive) cards,
        Vector#(8, Bool) slotPresent,
        LightingBusMasterDrive cpu,
        Bool workerValid, HostWorkerRequest workerRequest,
        Bool backendRequestReady,
        Bool backendResponseValid, Bool backendFault,
        Bool backendReadDataValid, Bit#(32) backendReadData,
        Bool reset) if (cycleQ.notFull);
        cycleQ.enq(MainboardCycleInputs {
            cards: cards,
            slotPresent: slotPresent,
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
        Bit#(5) index = {slot, channel};
        Bit#(32) mark = 32'b1 << index;
        Bit#(32) enableImage = enabled
            ? host.notificationEnabledMask | mark
            : host.notificationEnabledMask & ~mark;
        Bit#(32) maskedImage = masked
            ? host.notificationMaskedMask | mark
            : host.notificationMaskedMask & ~mark;
        host.configureNotificationState(enableImage, maskedImage, True,
            slot, channel, classCode);
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
