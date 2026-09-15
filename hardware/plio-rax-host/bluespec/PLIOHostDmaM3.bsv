package PLIOHostDmaM3;

import RegFile::*;
import QLITypes::*;
import QICInterfaces::*;

typedef enum { DmaIdle, DmaAwaitWrite, DmaMemRequest, DmaMemResponse, DmaReadReady } DmaM3State deriving (Bits, Eq, FShow);
typedef enum { DmaOk, DmaProtection, DmaMemoryFault, DmaParity, DmaTimeout, DmaReset, DmaRevoked } DmaM3Status deriving (Bits, Eq, FShow);

typedef struct {
    Bit#(32) base;
    Bit#(25) length;
    Bool deviceRead;
    Bool deviceWrite;
    Bit#(4) generation;
} DmaCapability deriving (Bits, Eq, FShow);

function Bit#(7) capIndex(Bit#(3) slot, Bit#(4) channel);
    return { slot, channel };
endfunction

function Bit#(4) oddParity32M3(Bit#(32) word);
    return { ~(^word[31:24]), ~(^word[23:16]), ~(^word[15:8]), ~(^word[7:0]) };
endfunction

function Bool parityMatchesM3(Bit#(32) word, Bit#(4) parity);
    return oddParity32M3(word) == parity;
endfunction

interface PLIOHostDmaM3Ifc;
    method Action bindCapability(Bit#(3) slot, Bit#(4) channel, Bit#(32) base, Bit#(25) length, Bool deviceRead, Bool deviceWrite);
    method Action revoke(Bit#(3) slot, Bit#(4) channel);
    method Bit#(4) generation(Bit#(3) slot, Bit#(4) channel);
    method Bool capabilityValid(Bit#(3) slot, Bit#(4) channel);

    method Action start(Bit#(3) slot, Bit#(32) dmaAddress, Bit#(5) words, Bool deviceRead);
    method Action offerDeviceWrite(Bit#(32) word, Bit#(4) parity);
    method Bool memoryRequestValid;
    method Bool memoryWrite;
    method Bit#(32) memoryAddress;
    method Bit#(32) memoryWriteData;
    method Action memoryRequestAccepted;
    method Action memoryResponse(Bool fault, Bool readDataValid, Bit#(32) readData);
    method Bool deviceReadValid;
    method Bit#(32) deviceReadData;
    method Bit#(4) deviceReadParity;
    method Action acknowledgeDeviceRead;
    method Action waitCycle;
    method Action resetHost;

    method Bool completionValid;
    method DmaM3Status completionStatus;
    method Bit#(5) completionBeats;
    method Action clearCompletion;

    method DmaM3State debugState;
    method Bit#(5) debugAcknowledged;
    method Bit#(9) debugWaitCycles;
    method Bool debugRevokePending;
endinterface

module mkPLIOHostDmaM3(PLIOHostDmaM3Ifc);
    RegFile#(Bit#(7), DmaCapability) caps <- mkRegFileFull();
    Reg#(Bit#(128)) validMask <- mkReg(0);
    Reg#(Bit#(128)) everMask <- mkReg(0);

    Reg#(DmaM3State) state <- mkReg(DmaIdle);
    Reg#(Bit#(3)) activeSlot <- mkReg(0);
    Reg#(Bit#(4)) activeChannel <- mkReg(0);
    Reg#(Bit#(4)) activeGeneration <- mkReg(0);
    Reg#(Bool) activeDeviceRead <- mkReg(False);
    Reg#(Bit#(32)) physicalAddress <- mkReg(0);
    Reg#(Bit#(5)) totalBeats <- mkReg(0);
    Reg#(Bit#(5)) acknowledged <- mkReg(0);
    Reg#(Bit#(32)) pendingWrite <- mkReg(0);
    Reg#(Bit#(32)) pendingRead <- mkReg(0);
    Reg#(Bit#(9)) waitCycles <- mkReg(0);
    Reg#(Bool) revokePending <- mkReg(False);

    Reg#(Bool) completionPending <- mkReg(False);
    Reg#(DmaM3Status) completionStatusReg <- mkReg(DmaOk);
    Reg#(Bit#(5)) completionBeatsReg <- mkReg(0);

    function Action finish(DmaM3Status status, Bit#(5) beats);
        action
            completionPending <= True;
            completionStatusReg <= status;
            completionBeatsReg <= beats;
            state <= DmaIdle;
            waitCycles <= 0;
            revokePending <= False;
        endaction
    endfunction

    method Action bindCapability(Bit#(3) slot, Bit#(4) channel, Bit#(32) base, Bit#(25) length, Bool deviceRead, Bool deviceWrite)
        if (!completionPending && length != 0 && length <= 25'h1000000 && base[1:0] == 0
            && !(state != DmaIdle && slot == activeSlot && channel == activeChannel));
        Bit#(7) idx = capIndex(slot, channel);
        Bit#(128) bitMask = 128'h1 << idx;
        Bit#(4) gen = 0;
        if ((everMask & bitMask) != 0) gen = caps.sub(idx).generation + 1;
        caps.upd(idx, DmaCapability { base: base, length: length, deviceRead: deviceRead, deviceWrite: deviceWrite, generation: gen });
        validMask <= validMask | bitMask;
        everMask <= everMask | bitMask;
    endmethod

    method Action revoke(Bit#(3) slot, Bit#(4) channel);
        Bit#(7) idx = capIndex(slot, channel);
        Bit#(128) bitMask = 128'h1 << idx;
        validMask <= validMask & ~bitMask;
        if (state != DmaIdle && slot == activeSlot && channel == activeChannel)
            revokePending <= True;
    endmethod

    method Bit#(4) generation(Bit#(3) slot, Bit#(4) channel);
        Bit#(7) idx = capIndex(slot, channel);
        Bit#(128) bitMask = 128'h1 << idx;
        return ((everMask & bitMask) != 0) ? caps.sub(idx).generation : 0;
    endmethod

    method Bool capabilityValid(Bit#(3) slot, Bit#(4) channel);
        Bit#(7) idx = capIndex(slot, channel);
        Bit#(128) bitMask = 128'h1 << idx;
        return (validMask & bitMask) != 0;
    endmethod

    method Action start(Bit#(3) slot, Bit#(32) dmaAddress, Bit#(5) words, Bool deviceRead)
        if (state == DmaIdle && !completionPending);
        Bit#(4) channel = dmaAddress[31:28];
        Bit#(4) gen = dmaAddress[27:24];
        Bit#(24) offset = dmaAddress[23:0];
        Bit#(7) idx = capIndex(slot, channel);
        Bit#(128) bitMask = 128'h1 << idx;
        DmaCapability cap = caps.sub(idx);
        Bit#(7) transferBytes = zeroExtend(words) << 2;
        Bit#(26) endOffset = zeroExtend(offset) + zeroExtend(transferBytes);
        Bool burstOk = words == 1 || words == 4 || words == 8 || words == 16;
        Bool permission = deviceRead ? cap.deviceRead : cap.deviceWrite;
        Bool valid = (validMask & bitMask) != 0 && cap.generation == gen && offset[1:0] == 0 && burstOk && permission && endOffset <= zeroExtend(cap.length);
        if (!valid) begin
            completionPending <= True;
            completionStatusReg <= DmaProtection;
            completionBeatsReg <= 0;
        end
        else begin
            activeSlot <= slot;
            activeChannel <= channel;
            activeGeneration <= gen;
            activeDeviceRead <= deviceRead;
            physicalAddress <= cap.base + zeroExtend(offset);
            totalBeats <= words;
            acknowledged <= 0;
            waitCycles <= 0;
            revokePending <= False;
            state <= deviceRead ? DmaMemRequest : DmaAwaitWrite;
        end
    endmethod

    method Action offerDeviceWrite(Bit#(32) word, Bit#(4) parity) if (state == DmaAwaitWrite);
        if (revokePending) finish(DmaRevoked, acknowledged);
        else if (!parityMatchesM3(word, parity)) finish(DmaParity, acknowledged);
        else begin
            pendingWrite <= word;
            waitCycles <= 0;
            state <= DmaMemRequest;
        end
    endmethod

    method Bool memoryRequestValid = state == DmaMemRequest;
    method Bool memoryWrite = !activeDeviceRead;
    method Bit#(32) memoryAddress = physicalAddress;
    method Bit#(32) memoryWriteData = pendingWrite;

    method Action memoryRequestAccepted if (state == DmaMemRequest);
        waitCycles <= 0;
        state <= DmaMemResponse;
    endmethod

    method Action memoryResponse(Bool fault, Bool readDataValid, Bit#(32) readData) if (state == DmaMemResponse);
        if (fault) finish(DmaMemoryFault, acknowledged);
        else if (activeDeviceRead) begin
            if (!readDataValid) finish(DmaMemoryFault, acknowledged);
            else begin
                pendingRead <= readData;
                waitCycles <= 0;
                state <= DmaReadReady;
            end
        end
        else begin
            Bit#(5) next = acknowledged + 1;
            if (revokePending) finish(DmaRevoked, next);
            else if (next == totalBeats) finish(DmaOk, next);
            else begin
                acknowledged <= next;
                physicalAddress <= physicalAddress + 4;
                waitCycles <= 0;
                state <= DmaAwaitWrite;
            end
        end
    endmethod

    method Bool deviceReadValid = state == DmaReadReady;
    method Bit#(32) deviceReadData = pendingRead;
    method Bit#(4) deviceReadParity = oddParity32M3(pendingRead);

    method Action acknowledgeDeviceRead if (state == DmaReadReady);
        Bit#(5) next = acknowledged + 1;
        if (revokePending) finish(DmaRevoked, next);
        else if (next == totalBeats) finish(DmaOk, next);
        else begin
            acknowledged <= next;
            physicalAddress <= physicalAddress + 4;
            waitCycles <= 0;
            state <= DmaMemRequest;
        end
    endmethod

    method Action waitCycle if (state != DmaIdle);
        if (waitCycles == 255) finish(DmaTimeout, acknowledged);
        else waitCycles <= waitCycles + 1;
    endmethod

    method Action resetHost;
        if (state != DmaIdle) begin
            completionPending <= True;
            completionStatusReg <= DmaReset;
            completionBeatsReg <= acknowledged;
        end
        state <= DmaIdle;
        waitCycles <= 0;
        revokePending <= False;
    endmethod

    method Bool completionValid = completionPending;
    method DmaM3Status completionStatus if (completionPending);
        return completionStatusReg;
    endmethod
    method Bit#(5) completionBeats if (completionPending);
        return completionBeatsReg;
    endmethod
    method Action clearCompletion if (completionPending);
        completionPending <= False;
    endmethod

    method DmaM3State debugState = state;
    method Bit#(5) debugAcknowledged = acknowledged;
    method Bit#(9) debugWaitCycles = waitCycles;
    method Bool debugRevokePending = revokePending;
endmodule

endpackage
