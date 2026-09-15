package PLIOHostManagerM2;

import Vector::*;
import RegFile::*;
import QLITypes::*;
import QICInterfaces::*;

typedef enum { M2Idle, M2Grant, M2NotificationData } HostM2State deriving (Bits, Eq, FShow);
typedef enum {
    M2BadNotificationAddress,
    M2AddressParity,
    M2BadNotificationData,
    M2DataParity,
    M2Timeout,
    M2RequestDropped,
    M2Reset
} HostM2Fault deriving (Bits, Eq, FShow);

typedef struct {
    Bool valid;
    Bit#(3) slot;
} GrantChoice deriving (Bits, Eq, FShow);

typedef struct {
    Bool valid;
    Bit#(2) channel;
    HostM2Fault fault;
} NotificationAddressCheck deriving (Bits, Eq, FShow);

typedef struct {
    Bool valid;
    Bit#(32) payload;
    HostM2Fault fault;
} NotificationDataCheck deriving (Bits, Eq, FShow);

typedef struct {
    Bool valid;
    Bit#(5) index;
} ClaimChoice deriving (Bits, Eq, FShow);

function Bit#(4) m2OddParity32(Bit#(32) word);
    return { ~(^word[31:24]), ~(^word[23:16]), ~(^word[15:8]), ~(^word[7:0]) };
endfunction

function Bool m2ParityMatches(Bit#(32) word, Bit#(4) parity, Bit#(4) be);
    return ((m2OddParity32(word) ^ parity) & be) == 0;
endfunction

function GrantChoice chooseM2Request(Bit#(3) cursor, Vector#(8, PlioOut) cards);
    GrantChoice choice = GrantChoice { valid: False, slot: 0 };
    Bool found = False;
    for (Integer i = 0; i < 8; i = i + 1) begin
        Bit#(3) slot = cursor + fromInteger(i);
        if (!found && cards[slot].request) begin
            choice = GrantChoice { valid: True, slot: slot };
            found = True;
        end
    end
    return choice;
endfunction

function ClaimChoice firstClaim(Bit#(32) eligible);
    ClaimChoice choice = ClaimChoice { valid: False, index: 0 };
    Bool found = False;
    for (Integer i = 0; i < 32; i = i + 1) begin
        if (!found && unpack(eligible[i])) begin
            choice = ClaimChoice { valid: True, index: fromInteger(i) };
            found = True;
        end
    end
    return choice;
endfunction

function NotificationAddressCheck checkNotificationAddress(PlioOut card);
    NotificationAddressCheck result = NotificationAddressCheck {
        valid: False, channel: 0, fault: M2BadNotificationAddress
    };
    if (card.adValid && card.parValid) begin
        if (!m2ParityMatches(card.ad, card.parity, 4'hf)) begin
            result.fault = M2AddressParity;
        end
        else if (card.spaceValid && card.space == PlioController
                 && !card.read && card.byteEnable == 4'hf
                 && card.burst == BurstOne && card.ad[31:4] == 0
                 && card.ad[1:0] == 0) begin
            result.valid = True;
            result.channel = card.ad[3:2];
        end
    end
    else if (card.adValid && !card.parValid) begin
        result.fault = M2AddressParity;
    end
    return result;
endfunction

function NotificationDataCheck checkNotificationData(PlioOut card);
    NotificationDataCheck result = NotificationDataCheck {
        valid: False, payload: 0, fault: M2BadNotificationData
    };
    if (card.adValid && card.parValid && card.byteEnable == 4'hf) begin
        if (m2ParityMatches(card.ad, card.parity, 4'hf)) begin
            result.valid = True;
            result.payload = card.ad;
        end
        else begin
            result.fault = M2DataParity;
        end
    end
    else if (card.adValid && !card.parValid) begin
        result.fault = M2DataParity;
    end
    return result;
endfunction

interface PLIOHostManagerM2Ifc;
    method Vector#(8, PlioIn) drive(Vector#(8, PlioOut) cards, Bool notificationReady, Bool reset);
    method Action advance(Vector#(8, PlioOut) cards, Bool notificationReady, Bool reset);
    method HostM2State debugState;
    method Bool debugGrantValid;
    method Bit#(3) debugGrantSlot;
    method Bit#(3) debugCursor;
    method Bit#(9) debugWaitCycles;
    method Bool debugFaultValid;
    method HostM2Fault debugFault;
    method Bit#(16) debugGrantCount(Bit#(3) slot);
    method Bool notificationPending(Bit#(3) slot, Bit#(2) channel);
    method Bit#(32) notificationPayload(Bit#(3) slot, Bit#(2) channel);
    method Action setNotificationConfig(Bit#(3) slot, Bit#(2) channel, Bool enabled, Bool masked, Bit#(4) classCode);
    method Bool claimValid;
    method Bit#(3) claimSlot;
    method Bit#(2) claimChannel;
    method Bit#(32) claimPayload;
    method Bit#(4) claimClass;
    method Action claimFirst;
endinterface

module mkPLIOHostManagerM2(PLIOHostManagerM2Ifc);
    Reg#(HostM2State) state <- mkReg(M2Idle);
    Reg#(Bit#(3)) activeSlot <- mkReg(0);
    Reg#(Bit#(2)) activeChannel <- mkReg(0);
    Reg#(Bit#(3)) cursor <- mkReg(0);
    Reg#(Bit#(9)) waitCycles <- mkReg(0);
    Reg#(Bool) faultValid <- mkReg(False);
    Reg#(HostM2Fault) faultReg <- mkReg(M2Reset);

    Vector#(8, Reg#(Bit#(16))) grantCounts <- replicateM(mkReg(0));
    Reg#(Bit#(32)) pendingBits <- mkReg(0);
    Reg#(Bit#(32)) enabledBits <- mkReg('1);
    Reg#(Bit#(32)) maskedBits <- mkReg(0);
    RegFile#(Bit#(5), Bit#(32)) payloadFile <- mkRegFileFull;
    RegFile#(Bit#(5), Bit#(4)) classFile <- mkRegFileFull;

    method Vector#(8, PlioIn) drive(Vector#(8, PlioOut) cards, Bool notificationReady, Bool reset);
        Vector#(8, PlioIn) outs = replicate(plioInDefault());
        if (reset) begin
            for (Integer i = 0; i < 8; i = i + 1) outs[i].reset = True;
        end
        else if (state != M2Idle) begin
            PlioOut card = cards[activeSlot];
            for (Integer i = 0; i < 8; i = i + 1) begin
                if (activeSlot == fromInteger(i)) begin
                    outs[i].grant = True;
                    if (state == M2Grant) begin
                        if (card.addressStrobe) begin
                            NotificationAddressCheck c = checkNotificationAddress(card);
                            if (c.valid) outs[i].ack = True;
                            else outs[i].err = True;
                        end
                        else if (waitCycles == 255) outs[i].err = True;
                    end
                    else begin
                        if (card.dataStrobe && notificationReady) begin
                            NotificationDataCheck c = checkNotificationData(card);
                            if (c.valid) outs[i].ack = True;
                            else outs[i].err = True;
                        end
                        else if (waitCycles == 255) outs[i].err = True;
                    end
                end
            end
        end
        return outs;
    endmethod

    method Action advance(Vector#(8, PlioOut) cards, Bool notificationReady, Bool reset);
        action
            if (reset) begin
                if (state != M2Idle) begin
                    faultValid <= True;
                    faultReg <= M2Reset;
                end
                state <= M2Idle;
                cursor <= 0;
                waitCycles <= 0;
                pendingBits <= 0;
            end
            else begin
                case (state)
                    M2Idle: begin
                        GrantChoice choice = chooseM2Request(cursor, cards);
                        if (choice.valid) begin
                            activeSlot <= choice.slot;
                            state <= M2Grant;
                            waitCycles <= 0;
                            faultValid <= False;
                            for (Integer i = 0; i < 8; i = i + 1)
                                if (choice.slot == fromInteger(i)) grantCounts[i] <= grantCounts[i] + 1;
                        end
                    end
                    M2Grant: begin
                        PlioOut card = cards[activeSlot];
                        if (!card.request) begin
                            state <= M2Idle;
                            cursor <= activeSlot + 1;
                            waitCycles <= 0;
                            faultValid <= True;
                            faultReg <= M2RequestDropped;
                        end
                        else if (card.addressStrobe) begin
                            NotificationAddressCheck c = checkNotificationAddress(card);
                            if (c.valid) begin
                                activeChannel <= c.channel;
                                state <= M2NotificationData;
                                waitCycles <= 0;
                            end
                            else begin
                                state <= M2Idle;
                                cursor <= activeSlot + 1;
                                waitCycles <= 0;
                                faultValid <= True;
                                faultReg <= c.fault;
                            end
                        end
                        else if (waitCycles == 255) begin
                            state <= M2Idle;
                            cursor <= activeSlot + 1;
                            waitCycles <= 0;
                            faultValid <= True;
                            faultReg <= M2Timeout;
                        end
                        else waitCycles <= waitCycles + 1;
                    end
                    M2NotificationData: begin
                        PlioOut card = cards[activeSlot];
                        if (!card.request) begin
                            state <= M2Idle;
                            cursor <= activeSlot + 1;
                            waitCycles <= 0;
                            faultValid <= True;
                            faultReg <= M2RequestDropped;
                        end
                        else if (card.dataStrobe && notificationReady) begin
                            NotificationDataCheck c = checkNotificationData(card);
                            if (c.valid) begin
                                Bit#(5) idx = { activeSlot, activeChannel };
                                Bit#(32) mark = 32'b1 << idx;
                                pendingBits <= pendingBits | mark;
                                payloadFile.upd(idx, c.payload);
                                state <= M2Idle;
                                cursor <= activeSlot + 1;
                                waitCycles <= 0;
                                faultValid <= False;
                            end
                            else begin
                                state <= M2Idle;
                                cursor <= activeSlot + 1;
                                waitCycles <= 0;
                                faultValid <= True;
                                faultReg <= c.fault;
                            end
                        end
                        else if (waitCycles == 255) begin
                            state <= M2Idle;
                            cursor <= activeSlot + 1;
                            waitCycles <= 0;
                            faultValid <= True;
                            faultReg <= M2Timeout;
                        end
                        else waitCycles <= waitCycles + 1;
                    end
                endcase
            end
        endaction
    endmethod

    method HostM2State debugState = state;
    method Bool debugGrantValid = state != M2Idle;
    method Bit#(3) debugGrantSlot = activeSlot;
    method Bit#(3) debugCursor = cursor;
    method Bit#(9) debugWaitCycles = waitCycles;
    method Bool debugFaultValid = faultValid;
    method HostM2Fault debugFault = faultReg;

    method Bit#(16) debugGrantCount(Bit#(3) slot);
        Bit#(16) value = 0;
        for (Integer i = 0; i < 8; i = i + 1)
            if (slot == fromInteger(i)) value = grantCounts[i];
        return value;
    endmethod

    method Bool notificationPending(Bit#(3) slot, Bit#(2) channel);
        Bit#(5) idx = { slot, channel };
        return unpack(pendingBits[idx]);
    endmethod

    method Bit#(32) notificationPayload(Bit#(3) slot, Bit#(2) channel);
        Bit#(5) idx = { slot, channel };
        return payloadFile.sub(idx);
    endmethod

    method Action setNotificationConfig(Bit#(3) slot, Bit#(2) channel, Bool en, Bool mask, Bit#(4) cls);
        action
            Bit#(5) idx = { slot, channel };
            Bit#(32) mark = 32'b1 << idx;
            if (en) enabledBits <= enabledBits | mark;
            else enabledBits <= enabledBits & ~mark;
            if (mask) maskedBits <= maskedBits | mark;
            else maskedBits <= maskedBits & ~mark;
            classFile.upd(idx, cls);
        endaction
    endmethod

    method Bool claimValid;
        ClaimChoice c = firstClaim(pendingBits & enabledBits & ~maskedBits);
        return c.valid;
    endmethod

    method Bit#(3) claimSlot;
        ClaimChoice c = firstClaim(pendingBits & enabledBits & ~maskedBits);
        return c.index[4:2];
    endmethod

    method Bit#(2) claimChannel;
        ClaimChoice c = firstClaim(pendingBits & enabledBits & ~maskedBits);
        return c.index[1:0];
    endmethod

    method Bit#(32) claimPayload;
        ClaimChoice c = firstClaim(pendingBits & enabledBits & ~maskedBits);
        return payloadFile.sub(c.index);
    endmethod

    method Bit#(4) claimClass;
        ClaimChoice c = firstClaim(pendingBits & enabledBits & ~maskedBits);
        return classFile.sub(c.index);
    endmethod

    method Action claimFirst;
        action
            ClaimChoice c = firstClaim(pendingBits & enabledBits & ~maskedBits);
            if (c.valid) begin
                Bit#(32) mark = 32'b1 << c.index;
                pendingBits <= pendingBits & ~mark;
            end
        endaction
    endmethod
endmodule

endpackage
