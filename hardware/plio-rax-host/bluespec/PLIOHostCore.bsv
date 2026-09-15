package PLIOHostCore;

import Vector::*;
import RegFile::*;
import QLITypes::*;
import QICInterfaces::*;
import PLIOWorkerHost::*;
import PLIOHostManagerM2::*;
import PLIOHostDmaM3::*;

typedef enum { CoreIdle, CoreWorker, CoreGrant, CoreNotification, CoreDma } PLIOHostCoreRole deriving (Bits, Eq, FShow);
typedef enum {
    CoreNoFault, CoreBadManagerAddress, CoreAddressParity, CoreDataParity,
    CoreRequestDropped, CoreTimeout, CoreDmaProtection, CoreDmaParity,
    CoreDmaMemory, CoreDmaReset, CoreDmaRevoked
} PLIOHostCoreFault deriving (Bits, Eq, FShow);

function Bit#(5) coreBurstWords(BurstWords b);
    Bit#(5) words = 1;
    case (b)
        BurstOne: words = 1;
        BurstFour: words = 4;
        BurstEight: words = 8;
        BurstSixteen: words = 16;
    endcase
    return words;
endfunction

function GrantChoice coreChooseRequest(Bit#(3) cursor, Vector#(8, PlioOut) cards);
    return chooseM2Request(cursor, cards);
endfunction

function Bool coreDmaAddressBasicValid(PlioOut card);
    Bool ok = card.adValid && card.parValid && card.spaceValid && card.space == PlioHostDma
              && card.byteEnable == 4'hf && card.ad[1:0] == 0;
    if (ok) ok = m2ParityMatches(card.ad, card.parity, 4'hf);
    return ok;
endfunction

interface PLIOHostCoreIfc;
    method Vector#(8, PlioIn) drive(Vector#(8, PlioOut) cards, Bool reset);
    method Action advance(
        Vector#(8, PlioOut) cards,
        Bool workerValid, HostWorkerRequest workerRequest,
        Bool memoryRequestReady,
        Bool memoryResponseValid, Bool memoryFault, Bool memoryReadDataValid, Bit#(32) memoryReadData,
        Bool reset);

    method Bool memoryRequestValid;
    method Bool memoryWrite;
    method Bit#(32) memoryAddress;
    method Bit#(32) memoryWriteData;

    method Action bindDma(Bit#(3) slot, Bit#(4) channel, Bit#(32) base, Bit#(25) length, Bool deviceRead, Bool deviceWrite);
    method Action revokeDma(Bit#(3) slot, Bit#(4) channel);
    method Bit#(4) dmaGeneration(Bit#(3) slot, Bit#(4) channel);

    method Bool workerCompletionValid;
    method HostWorkerCompletion workerCompletion;
    method Action clearWorkerCompletion;
    method Bool dmaCompletionValid;
    method DmaM3Status dmaCompletionStatus;
    method Bit#(5) dmaCompletionBeats;
    method Action clearDmaCompletion;

    method Bool notificationPending(Bit#(3) slot, Bit#(2) channel);
    method Bit#(32) notificationPayload(Bit#(3) slot, Bit#(2) channel);
    method Action setNotificationConfig(Bit#(3) slot, Bit#(2) channel, Bool enabled, Bool masked, Bit#(4) classCode);
    method Bool claimValid;
    method Bit#(3) claimSlot;
    method Bit#(2) claimChannel;
    method Bit#(32) claimPayload;
    method Bit#(4) claimClass;
    method Action claimFirst;

    method PLIOHostCoreRole debugRole;
    method Bool debugActiveSlotValid;
    method Bit#(3) debugActiveSlot;
    method Bit#(3) debugCursor;
    method Bit#(9) debugWaitCycles;
    method DmaM3State debugDmaState;
    method Bit#(5) debugDmaAcknowledged;
    method Bool debugFaultValid;
    method PLIOHostCoreFault debugFault;
endinterface

module mkPLIOHostCore(PLIOHostCoreIfc);
    PLIOWorkerHostIfc worker <- mkPLIOWorkerHost;
    PLIOHostDmaM3Ifc dma <- mkPLIOHostDmaM3;

    Reg#(PLIOHostCoreRole) role <- mkReg(CoreIdle);
    Reg#(Bit#(3)) activeSlot <- mkReg(0);
    Reg#(Bit#(2)) notificationChannel <- mkReg(0);
    Reg#(Bit#(3)) cursor <- mkReg(0);
    Reg#(Bit#(9)) waitCycles <- mkReg(0);
    Reg#(Bool) queuedWorkerValid <- mkReg(False);
    Reg#(HostWorkerRequest) queuedWorker <- mkReg(HostWorkerRequest { slot: 0, address: 0, width: HostW32, write: False, value: 0 });
    Reg#(Bool) dmaAddressPending <- mkReg(False);
    Reg#(Bool) dmaAddressBasicValid <- mkReg(False);
    Reg#(Bool) dmaDirectionRead <- mkReg(False);
    Reg#(Bool) writeAckPending <- mkReg(False);
    Reg#(Bool) faultValid <- mkReg(False);
    Reg#(PLIOHostCoreFault) faultReg <- mkReg(CoreNoFault);

    Reg#(Bit#(32)) notificationPendingBits <- mkReg(0);
    RegFile#(Bit#(5), Bit#(32)) notificationPayloadFile <- mkRegFileFull;
    Reg#(Bit#(32)) notificationEnabledBits <- mkReg('1);
    Reg#(Bit#(32)) notificationMaskedBits <- mkReg(0);
    RegFile#(Bit#(5), Bit#(4)) notificationClassFile <- mkRegFileFull;

    function Action finishCard();
        action
            cursor <= activeSlot + 1;
            role <= CoreIdle;
            waitCycles <= 0;
            dmaAddressPending <= False;
            writeAckPending <= False;
        endaction
    endfunction

    method Vector#(8, PlioIn) drive(Vector#(8, PlioOut) cards, Bool reset);
        Vector#(8, PlioIn) outs = replicate(plioInDefault());
        if (reset) begin
            for (Integer i = 0; i < 8; i = i + 1) outs[i].reset = True;
        end
        else begin
            case (role)
                CoreIdle: begin end
                CoreWorker: begin
                    if (worker.selectedSlotValid) outs[worker.selectedSlot] = worker.drive(False);
                end
                CoreGrant: begin
                    outs[activeSlot].grant = True;
                    PlioOut card = cards[activeSlot];
                    if (dmaAddressPending) begin
                        if (!dmaAddressBasicValid || (dma.completionValid && dma.completionStatus == DmaProtection)) outs[activeSlot].err = True;
                        else if (dma.debugState != DmaIdle) outs[activeSlot].ack = True;
                    end
                    else if (card.addressStrobe) begin
                        if (card.spaceValid && card.space == PlioController) begin
                            NotificationAddressCheck c = checkNotificationAddress(card);
                            if (c.valid) outs[activeSlot].ack = True;
                            else outs[activeSlot].err = True;
                        end
                        else if (!(card.spaceValid && card.space == PlioHostDma)) begin
                            outs[activeSlot].err = True;
                        end
                    end
                    else if (waitCycles == 255) outs[activeSlot].err = True;
                end
                CoreNotification: begin
                    outs[activeSlot].grant = True;
                    PlioOut card = cards[activeSlot];
                    if (card.dataStrobe) begin
                        NotificationDataCheck c = checkNotificationData(card);
                        if (c.valid) outs[activeSlot].ack = True;
                        else outs[activeSlot].err = True;
                    end
                    else if (waitCycles == 255) outs[activeSlot].err = True;
                end
                CoreDma: begin
                    outs[activeSlot].grant = True;
                    PlioOut card = cards[activeSlot];
                    if (dma.completionValid && dma.completionStatus != DmaOk) begin
                        outs[activeSlot].err = True;
                    end
                    else if (writeAckPending) begin
                        outs[activeSlot].ack = True;
                    end
                    else if (dma.deviceReadValid && card.dataStrobe) begin
                        outs[activeSlot].ack = True;
                        outs[activeSlot].adValid = True;
                        outs[activeSlot].ad = dma.deviceReadData;
                        outs[activeSlot].parValid = True;
                        outs[activeSlot].parity = dma.deviceReadParity;
                    end
                end
            endcase
        end
        return outs;
    endmethod

    method Action advance(
        Vector#(8, PlioOut) cards,
        Bool workerValid, HostWorkerRequest workerRequest,
        Bool memoryRequestReady,
        Bool memoryResponseValid, Bool memoryFault, Bool memoryReadDataValid, Bit#(32) memoryReadData,
        Bool reset);
        action
            if (reset) begin
                if (!worker.completionValid) worker.advance(plioOutDefault(), True);
                dma.resetHost;
                role <= CoreIdle;
                activeSlot <= 0;
                cursor <= 0;
                waitCycles <= 0;
                queuedWorkerValid <= False;
                dmaAddressPending <= False;
                writeAckPending <= False;
                notificationPendingBits <= 0;
                faultValid <= False;
            end
            else begin
                if (workerValid && !queuedWorkerValid) begin
                    queuedWorker <= workerRequest;
                    queuedWorkerValid <= True;
                end

                case (role)
                    CoreIdle: begin
                        if (queuedWorkerValid && worker.ready) begin
                            worker.start(queuedWorker);
                            activeSlot <= queuedWorker.slot;
                            queuedWorkerValid <= False;
                            role <= CoreWorker;
                        end
                        else if (!queuedWorkerValid && !workerValid) begin
                            GrantChoice c = coreChooseRequest(cursor, cards);
                            if (c.valid) begin
                                activeSlot <= c.slot;
                                role <= CoreGrant;
                                waitCycles <= 0;
                                faultValid <= False;
                            end
                        end
                    end
                    CoreWorker: begin
                        if (worker.completionValid) begin
                            role <= CoreIdle;
                        end
                        else begin
                            worker.advance(cards[activeSlot], False);
                        end
                    end
                    CoreGrant: begin
                        PlioOut card = cards[activeSlot];
                        if (dmaAddressPending) begin
                            if (!dmaAddressBasicValid || (dma.completionValid && dma.completionStatus == DmaProtection)) begin
                                faultValid <= True;
                                faultReg <= CoreDmaProtection;
                                finishCard();
                            end
                            else if (dma.debugState != DmaIdle) begin
                                dmaAddressPending <= False;
                                role <= CoreDma;
                                waitCycles <= 0;
                            end
                        end
                        else if (!card.request) begin
                            faultValid <= True;
                            faultReg <= CoreRequestDropped;
                            finishCard();
                        end
                        else if (card.addressStrobe) begin
                            if (card.spaceValid && card.space == PlioController) begin
                                NotificationAddressCheck c = checkNotificationAddress(card);
                                if (c.valid) begin
                                    notificationChannel <= c.channel;
                                    role <= CoreNotification;
                                    waitCycles <= 0;
                                end
                                else begin
                                    faultValid <= True;
                                    faultReg <= (c.fault == M2AddressParity) ? CoreAddressParity : CoreBadManagerAddress;
                                    finishCard();
                                end
                            end
                            else if (card.spaceValid && card.space == PlioHostDma) begin
                                Bool basic = coreDmaAddressBasicValid(card);
                                dmaAddressBasicValid <= basic;
                                dmaDirectionRead <= card.read;
                                dmaAddressPending <= True;
                                waitCycles <= 0;
                                if (basic) dma.start(activeSlot, card.ad, coreBurstWords(card.burst), card.read);
                            end
                            else begin
                                faultValid <= True;
                                faultReg <= CoreBadManagerAddress;
                                finishCard();
                            end
                        end
                        else if (waitCycles == 255) begin
                            faultValid <= True;
                            faultReg <= CoreTimeout;
                            finishCard();
                        end
                        else waitCycles <= waitCycles + 1;
                    end
                    CoreNotification: begin
                        PlioOut card = cards[activeSlot];
                        if (!card.request) begin
                            faultValid <= True;
                            faultReg <= CoreRequestDropped;
                            finishCard();
                        end
                        else if (card.dataStrobe) begin
                            NotificationDataCheck c = checkNotificationData(card);
                            if (c.valid) begin
                                Bit#(5) idx = { activeSlot, notificationChannel };
                                notificationPendingBits <= notificationPendingBits | (32'b1 << idx);
                                notificationPayloadFile.upd(idx, c.payload);
                                faultValid <= False;
                                finishCard();
                            end
                            else begin
                                faultValid <= True;
                                faultReg <= (c.fault == M2DataParity) ? CoreDataParity : CoreBadManagerAddress;
                                finishCard();
                            end
                        end
                        else if (waitCycles == 255) begin
                            faultValid <= True;
                            faultReg <= CoreTimeout;
                            finishCard();
                        end
                        else waitCycles <= waitCycles + 1;
                    end
                    CoreDma: begin
                        PlioOut card = cards[activeSlot];
                        if (!card.request) begin
                            dma.resetHost;
                            faultValid <= True;
                            faultReg <= CoreRequestDropped;
                            finishCard();
                        end
                        else if (dma.completionValid && dma.completionStatus != DmaOk) begin
                            case (dma.completionStatus)
                                DmaProtection: faultReg <= CoreDmaProtection;
                                DmaMemoryFault: faultReg <= CoreDmaMemory;
                                DmaParity: faultReg <= CoreDmaParity;
                                DmaTimeout: faultReg <= CoreTimeout;
                                DmaReset: faultReg <= CoreDmaReset;
                                DmaRevoked: faultReg <= CoreDmaRevoked;
                                default: faultReg <= CoreNoFault;
                            endcase
                            faultValid <= True;
                            finishCard();
                        end
                        else if (writeAckPending) begin
                            writeAckPending <= False;
                            if (dma.completionValid) finishCard();
                        end
                        else begin
                            case (dma.debugState)
                                DmaAwaitWrite: begin
                                    if (card.dataStrobe && card.adValid && card.parValid) dma.offerDeviceWrite(card.ad, card.parity);
                                    else dma.waitCycle;
                                end
                                DmaMemRequest: begin
                                    if (memoryRequestReady) dma.memoryRequestAccepted;
                                    else dma.waitCycle;
                                end
                                DmaMemResponse: begin
                                    if (memoryResponseValid) begin
                                        dma.memoryResponse(memoryFault, memoryReadDataValid, memoryReadData);
                                        if (!dmaDirectionRead && !memoryFault) writeAckPending <= True;
                                    end
                                    else dma.waitCycle;
                                end
                                DmaReadReady: begin
                                    if (card.dataStrobe) dma.acknowledgeDeviceRead;
                                    else dma.waitCycle;
                                end
                                DmaIdle: begin
                                    if (dma.completionValid) finishCard();
                                end
                            endcase
                        end
                    end
                endcase
            end
        endaction
    endmethod

    method Bool memoryRequestValid = role == CoreDma && dma.memoryRequestValid;
    method Bool memoryWrite = dma.memoryWrite;
    method Bit#(32) memoryAddress = dma.memoryAddress;
    method Bit#(32) memoryWriteData = dma.memoryWriteData;

    method Action bindDma(Bit#(3) slot, Bit#(4) channel, Bit#(32) base, Bit#(25) length, Bool deviceRead, Bool deviceWrite);
        dma.bindCapability(slot, channel, base, length, deviceRead, deviceWrite);
    endmethod
    method Action revokeDma(Bit#(3) slot, Bit#(4) channel); dma.revoke(slot, channel); endmethod
    method Bit#(4) dmaGeneration(Bit#(3) slot, Bit#(4) channel) = dma.generation(slot, channel);

    method Bool workerCompletionValid = worker.completionValid;
    method HostWorkerCompletion workerCompletion = worker.completion;
    method Action clearWorkerCompletion; worker.clearCompletion; endmethod
    method Bool dmaCompletionValid = dma.completionValid;
    method DmaM3Status dmaCompletionStatus = dma.completionStatus;
    method Bit#(5) dmaCompletionBeats = dma.completionBeats;
    method Action clearDmaCompletion; dma.clearCompletion; endmethod

    method Bool notificationPending(Bit#(3) slot, Bit#(2) channel);
        Bit#(5) idx = { slot, channel };
        return unpack(notificationPendingBits[idx]);
    endmethod
    method Bit#(32) notificationPayload(Bit#(3) slot, Bit#(2) channel) = notificationPayloadFile.sub({slot, channel});
    method Action setNotificationConfig(Bit#(3) slot, Bit#(2) channel, Bool en, Bool mask, Bit#(4) cls);
        Bit#(5) idx = { slot, channel };
        Bit#(32) mark = 32'b1 << idx;
        if (en) notificationEnabledBits <= notificationEnabledBits | mark;
        else notificationEnabledBits <= notificationEnabledBits & ~mark;
        if (mask) notificationMaskedBits <= notificationMaskedBits | mark;
        else notificationMaskedBits <= notificationMaskedBits & ~mark;
        notificationClassFile.upd(idx, cls);
    endmethod
    method Bool claimValid;
        ClaimChoice c = firstClaim(notificationPendingBits & notificationEnabledBits & ~notificationMaskedBits);
        return c.valid;
    endmethod
    method Bit#(3) claimSlot;
        ClaimChoice c = firstClaim(notificationPendingBits & notificationEnabledBits & ~notificationMaskedBits);
        return c.index[4:2];
    endmethod
    method Bit#(2) claimChannel;
        ClaimChoice c = firstClaim(notificationPendingBits & notificationEnabledBits & ~notificationMaskedBits);
        return c.index[1:0];
    endmethod
    method Bit#(32) claimPayload;
        ClaimChoice c = firstClaim(notificationPendingBits & notificationEnabledBits & ~notificationMaskedBits);
        return notificationPayloadFile.sub(c.index);
    endmethod
    method Bit#(4) claimClass;
        ClaimChoice c = firstClaim(notificationPendingBits & notificationEnabledBits & ~notificationMaskedBits);
        return notificationClassFile.sub(c.index);
    endmethod
    method Action claimFirst;
        ClaimChoice c = firstClaim(notificationPendingBits & notificationEnabledBits & ~notificationMaskedBits);
        if (c.valid) notificationPendingBits <= notificationPendingBits & ~(32'b1 << c.index);
    endmethod

    method PLIOHostCoreRole debugRole = role;
    method Bool debugActiveSlotValid = role != CoreIdle;
    method Bit#(3) debugActiveSlot = activeSlot;
    method Bit#(3) debugCursor = cursor;
    method Bit#(9) debugWaitCycles = (role == CoreWorker) ? worker.debugWaitCycles : ((role == CoreDma) ? dma.debugWaitCycles : waitCycles);
    method DmaM3State debugDmaState = dma.debugState;
    method Bit#(5) debugDmaAcknowledged = dma.debugAcknowledged;
    method Bool debugFaultValid = faultValid;
    method PLIOHostCoreFault debugFault = faultReg;
endmodule

endpackage
