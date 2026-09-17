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
    Bit#(5) n = 1;
    case (b)
        BurstOne: n = 1;
        BurstFour: n = 4;
        BurstEight: n = 8;
        BurstSixteen: n = 16;
    endcase
    return n;
endfunction

function Bool coreDmaAddressBasicValid(PlioOut c);
    Bool ok = c.adValid && c.parValid && c.spaceValid && c.space == PlioHostDma
              && c.byteEnable == 4'hf && c.ad[1:0] == 0;
    if (ok) ok = m2ParityMatches(c.ad, c.parity, 4'hf);
    return ok;
endfunction

interface PLIOHostCoreIfc;
    method Vector#(8, PlioIn) drive(Vector#(8, PlioOut) cards, Bool reset);
    method Action advance(Vector#(8, PlioOut) cards,
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
    Reg#(PLIOHostCoreRole) role <- mkReg(CoreIdle);
    Reg#(Bit#(3)) activeSlot <- mkReg(0);
    Reg#(Bit#(3)) cursor <- mkReg(0);
    Reg#(Bit#(9)) waitCycles <- mkReg(0);
    Reg#(Bool) faultValid <- mkReg(False);
    Reg#(PLIOHostCoreFault) faultReg <- mkReg(CoreNoFault);

    Reg#(Bool) queuedWorkerValid <- mkReg(False);
    Reg#(HostWorkerRequest) queuedWorker <- mkReg(HostWorkerRequest { slot:0, address:0, width:HostW32, write:False, value:0 });
    Reg#(HostWorkerRequest) workerReq <- mkReg(HostWorkerRequest { slot:0, address:0, width:HostW32, write:False, value:0 });
    Reg#(HostWorkerState) workerState <- mkReg(HostIdle);
    Reg#(Bit#(9)) workerWait <- mkReg(0);
    Array#(Reg#(Bool)) workerCompletionPending <- mkCReg(2, False);
    Reg#(HostWorkerCompletion) workerCompletionReg <- mkReg(HostWorkerCompletion { status:HostSuccess, data:0 });

    Reg#(Bit#(2)) notificationChannel <- mkReg(0);
    Reg#(Bit#(32)) notificationPendingBits <- mkReg(0);
    RegFile#(Bit#(5), Bit#(32)) notificationPayloadFile <- mkRegFileFull;
    Reg#(Bit#(32)) notificationEnabledBits <- mkReg('1);
    Reg#(Bit#(32)) notificationMaskedBits <- mkReg(0);
    RegFile#(Bit#(5), Bit#(4)) notificationClassFile <- mkRegFileFull;

    RegFile#(Bit#(7), DmaCapability) caps <- mkRegFileFull;
    Reg#(Bit#(128)) capValidMask <- mkReg(0);
    Reg#(Bit#(128)) capEverMask <- mkReg(0);
    Reg#(DmaM3State) dmaState <- mkReg(DmaIdle);
    Reg#(Bit#(4)) dmaChannel <- mkReg(0);
    Reg#(Bit#(4)) dmaGenerationReg <- mkReg(0);
    Reg#(Bool) dmaDirectionRead <- mkReg(False);
    Reg#(Bit#(32)) dmaPhysicalAddress <- mkReg(0);
    Reg#(Bit#(5)) dmaTotal <- mkReg(0);
    Reg#(Bit#(5)) dmaAcknowledged <- mkReg(0);
    Reg#(Bit#(32)) dmaPendingWrite <- mkReg(0);
    Reg#(Bit#(32)) dmaPendingRead <- mkReg(0);
    Reg#(Bit#(9)) dmaWait <- mkReg(0);
    Reg#(Bool) dmaRevokePending <- mkReg(False);
    Array#(Reg#(Bool)) dmaCompletionPending <- mkCReg(2, False);
    Reg#(DmaM3Status) dmaCompletionStatusReg <- mkReg(DmaOk);
    Reg#(Bit#(5)) dmaCompletionBeatsReg <- mkReg(0);
    Reg#(Bool) dmaAddressPending <- mkReg(False);
    Reg#(Bool) dmaAddressValid <- mkReg(False);
    Reg#(Bool) writeAckPending <- mkReg(False);

    function Action finishCard();
        action
            cursor <= activeSlot + 1;
            role <= CoreIdle;
            waitCycles <= 0;
            dmaAddressPending <= False;
            writeAckPending <= False;
        endaction
    endfunction

    function Action finishDma(DmaM3Status status, Bit#(5) beats);
        action
            dmaCompletionPending[0] <= True;
            dmaCompletionStatusReg <= status;
            dmaCompletionBeatsReg <= beats;
            dmaState <= DmaIdle;
            dmaWait <= 0;
            dmaRevokePending <= False;
        endaction
    endfunction

    method Vector#(8, PlioIn) drive(Vector#(8, PlioOut) cards, Bool reset);
        Vector#(8, PlioIn) outs = replicate(plioInDefault());
        if (reset) begin
            for (Integer i=0; i<8; i=i+1) outs[i].reset = True;
        end
        else begin
            case (role)
                CoreIdle: begin end
                CoreWorker: begin
                    PlioIn o = plioInDefault();
                    o.selected = True;
                    o.read = !workerReq.write;
                    o.byteEnable = hostByteEnable(workerReq);
                    o.burst = BurstOne;
                    if (workerState == HostAddress) begin
                        o.adValid=True; o.ad=workerReq.address; o.parValid=True; o.parity=hostOddParity32(workerReq.address);
                        o.spaceValid=True; o.space=PlioWorker; o.addressStrobe=True;
                    end
                    else if (workerState == HostData) begin
                        o.dataStrobe=True;
                        if (workerReq.write) begin
                            Bit#(32) d=hostBusWriteData(workerReq); o.adValid=True; o.ad=d; o.parValid=True; o.parity=hostOddParity32(d);
                        end
                    end
                    outs[activeSlot] = o;
                end
                CoreGrant: begin
                    outs[activeSlot].grant = True;
                    PlioOut c = cards[activeSlot];
                    if (dmaAddressPending) begin if (dmaAddressValid) outs[activeSlot].ack = True; else outs[activeSlot].err = True; end
                    else if (c.addressStrobe && c.spaceValid && c.space == PlioController) begin NotificationAddressCheck n=checkNotificationAddress(c); if (n.valid) outs[activeSlot].ack=True; else outs[activeSlot].err=True; end
                    else if (c.addressStrobe && !(c.spaceValid && c.space == PlioHostDma)) outs[activeSlot].err=True;
                    else if (waitCycles==255) outs[activeSlot].err=True;
                end
                CoreNotification: begin
                    outs[activeSlot].grant=True;
                    PlioOut c=cards[activeSlot];
                    if (c.dataStrobe) begin NotificationDataCheck n=checkNotificationData(c); if(n.valid) outs[activeSlot].ack=True; else outs[activeSlot].err=True; end
                    else if (waitCycles==255) outs[activeSlot].err=True;
                end
                CoreDma: begin
                    outs[activeSlot].grant=True;
                    PlioOut c=cards[activeSlot];
                    if (writeAckPending) outs[activeSlot].ack=True;
                    else if (dmaCompletionPending[0] && dmaCompletionStatusReg != DmaOk) outs[activeSlot].err=True;
                    else if (dmaState==DmaReadReady && c.dataStrobe) begin
                        outs[activeSlot].ack=True; outs[activeSlot].adValid=True; outs[activeSlot].ad=dmaPendingRead;
                        outs[activeSlot].parValid=True; outs[activeSlot].parity=oddParity32M3(dmaPendingRead);
                    end
                    else if (dmaWait==255 && dmaState!=DmaIdle) outs[activeSlot].err=True;
                end
            endcase
        end
        return outs;
    endmethod

    method Action advance(Vector#(8, PlioOut) cards,
        Bool workerValid, HostWorkerRequest workerRequest,
        Bool memoryRequestReady,
        Bool memoryResponseValid, Bool memoryFault, Bool memoryReadDataValid, Bit#(32) memoryReadData,
        Bool reset);
        action
            if (reset) begin
                if (role==CoreWorker) begin workerCompletionPending[0]<=True; workerCompletionReg<=HostWorkerCompletion{status:HostReset,data:0}; end
                // Reset abandons an in-flight DMA.  Do not leave a synthetic
                // DmaReset completion for a later fresh transaction.
                dmaCompletionPending[0]<=False; dmaCompletionStatusReg<=DmaOk;
                dmaCompletionBeatsReg<=0; dmaState<=DmaIdle; dmaWait<=0;
                dmaRevokePending<=False;
                role<=CoreIdle; activeSlot<=0; cursor<=0; waitCycles<=0; workerState<=HostIdle; workerWait<=0; queuedWorkerValid<=False;
                notificationPendingBits<=0; dmaAddressPending<=False; writeAckPending<=False; faultValid<=False;
            end
            else begin
                if (workerValid && !queuedWorkerValid) begin queuedWorker<=workerRequest; queuedWorkerValid<=True; end
                case (role)
                    CoreIdle: begin
                        if (queuedWorkerValid && !workerCompletionPending[0]) begin
                            if (hostRequestValid(queuedWorker)) begin workerReq<=queuedWorker; activeSlot<=queuedWorker.slot; workerState<=HostAddress; workerWait<=0; role<=CoreWorker; end
                            queuedWorkerValid<=False;
                        end
                        else if (!queuedWorkerValid && !workerValid) begin
                            GrantChoice g=chooseM2Request(cursor,cards);
                            if(g.valid) begin activeSlot<=g.slot; role<=CoreGrant; waitCycles<=0; faultValid<=False; end
                        end
                    end
                    CoreWorker: begin
                        PlioOut c=cards[activeSlot];
                        if (c.err) begin workerCompletionPending[0]<=True;workerCompletionReg<=HostWorkerCompletion{status:HostBusError,data:0};workerState<=HostIdle;role<=CoreIdle;workerWait<=0; end
                        else if (workerState==HostAddress && c.ack) begin workerState<=HostData;workerWait<=0; end
                        else if (workerState==HostData && c.ack) begin
                            if (workerReq.write) workerCompletionReg<=HostWorkerCompletion{status:HostSuccess,data:0};
                            else if(c.adValid&&c.parValid&&hostParityMatches(c.ad,c.parity,hostByteEnable(workerReq))) workerCompletionReg<=HostWorkerCompletion{status:HostSuccess,data:hostExtractReadData(workerReq,c.ad)};
                            else workerCompletionReg<=HostWorkerCompletion{status:HostParityError,data:0};
                            workerCompletionPending[0]<=True;workerState<=HostIdle;role<=CoreIdle;workerWait<=0;
                        end
                        else if(workerWait==255) begin workerCompletionPending[0]<=True;workerCompletionReg<=HostWorkerCompletion{status:HostTimeout,data:0};workerState<=HostIdle;role<=CoreIdle;workerWait<=0; end
                        else workerWait<=workerWait+1;
                    end
                    CoreGrant: begin
                        PlioOut c=cards[activeSlot];
                        if (dmaAddressPending) begin
                            if(dmaAddressValid) begin role<=CoreDma;waitCycles<=0;dmaAddressPending<=False; end
                            else begin dmaCompletionPending[0]<=True;dmaCompletionStatusReg<=DmaProtection;dmaCompletionBeatsReg<=0;faultValid<=True;faultReg<=CoreDmaProtection;finishCard(); end
                        end
                        else if(!c.request) begin faultValid<=True;faultReg<=CoreRequestDropped;finishCard(); end
                        else if(c.addressStrobe) begin
                            if(c.spaceValid&&c.space==PlioController) begin
                                NotificationAddressCheck n=checkNotificationAddress(c);
                                if(n.valid) begin notificationChannel<=n.channel;role<=CoreNotification;waitCycles<=0; end
                                else begin faultValid<=True;faultReg<=(n.fault==M2AddressParity)?CoreAddressParity:CoreBadManagerAddress;finishCard(); end
                            end
                            else if(c.spaceValid&&c.space==PlioHostDma) begin
                                Bool basic=coreDmaAddressBasicValid(c); Bool valid=False;
                                Bit#(4) channel=c.ad[31:28];Bit#(4) gen=c.ad[27:24];Bit#(24) off=c.ad[23:0];Bit#(7) idx={activeSlot,channel};Bit#(128) mark=128'h1<<idx;
                                DmaCapability cap=caps.sub(idx);Bit#(5) words=coreBurstWords(c.burst);Bit#(7) bytes=zeroExtend(words)<<2;Bit#(26) ending=zeroExtend(off)+zeroExtend(bytes);
                                Bool permission=c.read?cap.deviceRead:cap.deviceWrite;
                                valid=basic&&(capValidMask&mark)!=0&&cap.generation==gen&&permission&&ending<=zeroExtend(cap.length);
                                dmaAddressPending<=True;dmaAddressValid<=valid;dmaDirectionRead<=c.read;waitCycles<=0;
                                if(valid) begin dmaChannel<=channel;dmaGenerationReg<=gen;dmaPhysicalAddress<=cap.base+zeroExtend(off);dmaTotal<=words;dmaAcknowledged<=0;dmaWait<=0;dmaRevokePending<=False;dmaState<=c.read?DmaMemRequest:DmaAwaitWrite; end
                            end
                            else begin faultValid<=True;faultReg<=CoreBadManagerAddress;finishCard(); end
                        end
                        else if(waitCycles==255) begin faultValid<=True;faultReg<=CoreTimeout;finishCard(); end
                        else waitCycles<=waitCycles+1;
                    end
                    CoreNotification: begin
                        PlioOut c=cards[activeSlot];
                        if(!c.request) begin faultValid<=True;faultReg<=CoreRequestDropped;finishCard(); end
                        else if(c.dataStrobe) begin
                            NotificationDataCheck n=checkNotificationData(c);
                            if(n.valid) begin Bit#(5) idx={activeSlot,notificationChannel};notificationPendingBits<=notificationPendingBits|(32'b1<<idx);notificationPayloadFile.upd(idx,n.payload);faultValid<=False;finishCard(); end
                            else begin faultValid<=True;faultReg<=(n.fault==M2DataParity)?CoreDataParity:CoreBadManagerAddress;finishCard(); end
                        end
                        else if(waitCycles==255) begin faultValid<=True;faultReg<=CoreTimeout;finishCard(); end
                        else waitCycles<=waitCycles+1;
                    end
                    CoreDma: begin
                        PlioOut c=cards[activeSlot];
                        if(!c.request) begin finishDma(DmaReset,dmaAcknowledged);faultValid<=True;faultReg<=CoreRequestDropped;finishCard(); end
                        else if(writeAckPending) begin if(dmaState==DmaIdle) finishCard(); else writeAckPending<=False; end
                        else if(dmaCompletionPending[0]&&dmaCompletionStatusReg!=DmaOk) begin
                            case(dmaCompletionStatusReg) DmaProtection:faultReg<=CoreDmaProtection;DmaMemoryFault:faultReg<=CoreDmaMemory;DmaParity:faultReg<=CoreDmaParity;DmaTimeout:faultReg<=CoreTimeout;DmaReset:faultReg<=CoreDmaReset;DmaRevoked:faultReg<=CoreDmaRevoked;default:faultReg<=CoreNoFault;endcase
                            faultValid<=True;finishCard();
                        end
                        else begin
                            case(dmaState)
                                DmaAwaitWrite: begin
                                    if(c.dataStrobe&&c.adValid&&c.parValid) begin
                                        if(dmaRevokePending) finishDma(DmaRevoked,dmaAcknowledged);
                                        else if(!parityMatchesM3(c.ad,c.parity)) finishDma(DmaParity,dmaAcknowledged);
                                        else begin dmaPendingWrite<=c.ad;dmaWait<=0;dmaState<=DmaMemRequest; end
                                    end
                                    else if(dmaWait==255) finishDma(DmaTimeout,dmaAcknowledged); else dmaWait<=dmaWait+1;
                                end
                                DmaMemRequest: begin
                                    if(memoryRequestReady) begin dmaWait<=0;dmaState<=DmaMemResponse;end
                                    else if(dmaWait==255)finishDma(DmaTimeout,dmaAcknowledged);
                                    else dmaWait<=dmaWait+1;
                                end
                                DmaMemResponse: begin
                                    if(memoryResponseValid) begin
                                        if(memoryFault || (dmaDirectionRead&&!memoryReadDataValid)) finishDma(DmaMemoryFault,dmaAcknowledged);
                                        else if(dmaDirectionRead) begin dmaPendingRead<=memoryReadData;dmaWait<=0;dmaState<=DmaReadReady; end
                                        else begin
                                            Bit#(5) nxt=dmaAcknowledged+1;
                                            if(dmaRevokePending) begin dmaAcknowledged<=nxt;dmaPhysicalAddress<=dmaPhysicalAddress+4;writeAckPending<=True;finishDma(DmaRevoked,nxt); end
                                            else if(nxt==dmaTotal) begin dmaAcknowledged<=nxt;dmaPhysicalAddress<=dmaPhysicalAddress+4;writeAckPending<=True;finishDma(DmaOk,nxt); end
                                            else begin dmaAcknowledged<=nxt;dmaPhysicalAddress<=dmaPhysicalAddress+4;dmaWait<=0;writeAckPending<=True;dmaState<=DmaAwaitWrite; end
                                        end
                                    end
                                    else if(dmaWait==255)finishDma(DmaTimeout,dmaAcknowledged);
                                    else dmaWait<=dmaWait+1;
                                end
                                DmaReadReady: begin
                                    if(c.dataStrobe) begin
                                        Bit#(5) nxt=dmaAcknowledged+1;
                                        if(dmaRevokePending) begin dmaAcknowledged<=nxt;dmaPhysicalAddress<=dmaPhysicalAddress+4;finishDma(DmaRevoked,nxt); end
                                        else if(nxt==dmaTotal) begin dmaAcknowledged<=nxt;dmaPhysicalAddress<=dmaPhysicalAddress+4;finishDma(DmaOk,nxt);finishCard(); end
                                        else begin dmaAcknowledged<=nxt;dmaPhysicalAddress<=dmaPhysicalAddress+4;dmaWait<=0;dmaState<=DmaMemRequest; end
                                    end
                                    else if(dmaWait==255)finishDma(DmaTimeout,dmaAcknowledged);
                                    else dmaWait<=dmaWait+1;
                                end
                                DmaIdle: begin if(dmaCompletionPending[0]&&dmaCompletionStatusReg==DmaOk)finishCard(); end
                            endcase
                        end
                    end
                endcase
            end
        endaction
    endmethod

    method Bool memoryRequestValid = role==CoreDma && dmaState==DmaMemRequest;
    method Bool memoryWrite = !dmaDirectionRead;
    method Bit#(32) memoryAddress = dmaPhysicalAddress;
    method Bit#(32) memoryWriteData = dmaPendingWrite;

    method Action bindDma(Bit#(3) slot,Bit#(4) channel,Bit#(32) base,Bit#(25) length,Bool deviceRead,Bool deviceWrite);
        Bit#(7) idx={slot,channel};Bit#(128) mark=128'h1<<idx;Bool activeSame=role==CoreDma&&slot==activeSlot&&channel==dmaChannel;
        if(length!=0&&length<=25'h1000000&&base[1:0]==0&&!activeSame&&!dmaCompletionPending[0])begin Bit#(4) gen=0;if((capEverMask&mark)!=0)gen=caps.sub(idx).generation+1;caps.upd(idx,DmaCapability{base:base,length:length,deviceRead:deviceRead,deviceWrite:deviceWrite,generation:gen});capValidMask<=capValidMask|mark;capEverMask<=capEverMask|mark;end
    endmethod
    method Action revokeDma(Bit#(3) slot,Bit#(4) channel);Bit#(7)idx={slot,channel};Bit#(128)mark=128'h1<<idx;capValidMask<=capValidMask&~mark;if(role==CoreDma&&slot==activeSlot&&channel==dmaChannel)dmaRevokePending<=True;endmethod
    method Bit#(4) dmaGeneration(Bit#(3) slot,Bit#(4) channel);Bit#(7)idx={slot,channel};Bit#(128)mark=128'h1<<idx;return((capEverMask&mark)!=0)?caps.sub(idx).generation:0;endmethod

    method Bool workerCompletionValid=workerCompletionPending[1];
    method HostWorkerCompletion workerCompletion=workerCompletionReg;
    method Action clearWorkerCompletion;workerCompletionPending[1]<=False;endmethod
    method Bool dmaCompletionValid=dmaCompletionPending[1];
    method DmaM3Status dmaCompletionStatus=dmaCompletionStatusReg;
    method Bit#(5) dmaCompletionBeats=dmaCompletionBeatsReg;
    method Action clearDmaCompletion;dmaCompletionPending[1]<=False;endmethod

    method Bool notificationPending(Bit#(3) slot,Bit#(2) channel);Bit#(5)idx={slot,channel};return unpack(notificationPendingBits[idx]);endmethod
    method Bit#(32) notificationPayload(Bit#(3) slot,Bit#(2) channel)=notificationPayloadFile.sub({slot,channel});
    method Action setNotificationConfig(Bit#(3) slot,Bit#(2) channel,Bool en,Bool mask,Bit#(4) cls);Bit#(5)idx={slot,channel};Bit#(32)mark=32'b1<<idx;if(en)notificationEnabledBits<=notificationEnabledBits|mark;else notificationEnabledBits<=notificationEnabledBits&~mark;if(mask)notificationMaskedBits<=notificationMaskedBits|mark;else notificationMaskedBits<=notificationMaskedBits&~mark;notificationClassFile.upd(idx,cls);endmethod
    method Bool claimValid;ClaimChoice c=firstClaim(notificationPendingBits&notificationEnabledBits&~notificationMaskedBits);return c.valid;endmethod
    method Bit#(3) claimSlot;ClaimChoice c=firstClaim(notificationPendingBits&notificationEnabledBits&~notificationMaskedBits);return c.index[4:2];endmethod
    method Bit#(2) claimChannel;ClaimChoice c=firstClaim(notificationPendingBits&notificationEnabledBits&~notificationMaskedBits);return c.index[1:0];endmethod
    method Bit#(32) claimPayload;ClaimChoice c=firstClaim(notificationPendingBits&notificationEnabledBits&~notificationMaskedBits);return notificationPayloadFile.sub(c.index);endmethod
    method Bit#(4) claimClass;ClaimChoice c=firstClaim(notificationPendingBits&notificationEnabledBits&~notificationMaskedBits);return notificationClassFile.sub(c.index);endmethod
    method Action claimFirst;ClaimChoice c=firstClaim(notificationPendingBits&notificationEnabledBits&~notificationMaskedBits);if(c.valid)notificationPendingBits<=notificationPendingBits&~(32'b1<<c.index);endmethod

    method PLIOHostCoreRole debugRole=role;
    method Bool debugActiveSlotValid=role!=CoreIdle;
    method Bit#(3) debugActiveSlot=activeSlot;
    method Bit#(3) debugCursor=cursor;
    method Bit#(9) debugWaitCycles=(role==CoreWorker)?workerWait:((role==CoreDma)?dmaWait:waitCycles);
    method DmaM3State debugDmaState=dmaState;
    method Bit#(5) debugDmaAcknowledged=dmaAcknowledged;
    method Bool debugFaultValid=faultValid;
    method PLIOHostCoreFault debugFault=faultReg;
endmodule

endpackage
