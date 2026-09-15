package TbPLIOHostManagerM2;

import Vector::*;
import QLITypes::*;
import QICInterfaces::*;
import PLIOHostManagerM2::*;

function Vector#(8, PlioOut) emptyCards();
    return replicate(plioOutDefault());
endfunction

function Vector#(8, PlioOut) requestCards(Bit#(8) reqMask);
    Vector#(8, PlioOut) cards = replicate(plioOutDefault());
    for (Integer i = 0; i < 8; i = i + 1) cards[i].request = unpack(reqMask[i]);
    return cards;
endfunction

function Vector#(8, PlioOut) notificationAddress(Bit#(3) slot, Bit#(2) channel, Bool badParity);
    Vector#(8, PlioOut) cards = replicate(plioOutDefault());
    Bit#(32) address = zeroExtend(channel) << 2;
    for (Integer i = 0; i < 8; i = i + 1) begin
        if (slot == fromInteger(i)) begin
            cards[i].request = True;
            cards[i].adValid = True;
            cards[i].ad = address;
            cards[i].parValid = True;
            cards[i].parity = m2OddParity32(address) ^ (badParity ? 4'b0001 : 4'b0000);
            cards[i].spaceValid = True;
            cards[i].space = PlioController;
            cards[i].addressStrobe = True;
            cards[i].read = False;
            cards[i].byteEnable = 4'hf;
            cards[i].burst = BurstOne;
        end
    end
    return cards;
endfunction

function Vector#(8, PlioOut) notificationData(Bit#(3) slot, Bit#(32) data, Bool badParity);
    Vector#(8, PlioOut) cards = replicate(plioOutDefault());
    for (Integer i = 0; i < 8; i = i + 1) begin
        if (slot == fromInteger(i)) begin
            cards[i].request = True;
            cards[i].adValid = True;
            cards[i].ad = data;
            cards[i].parValid = True;
            cards[i].parity = m2OddParity32(data) ^ (badParity ? 4'b0001 : 4'b0000);
            cards[i].byteEnable = 4'hf;
            cards[i].dataStrobe = True;
        end
    end
    return cards;
endfunction

function Bool oneHotGrant(Vector#(8, PlioIn) buses, Bit#(3) slot);
    Bool good = True;
    for (Integer i = 0; i < 8; i = i + 1) begin
        Bool expected = slot == fromInteger(i);
        if (buses[i].grant != expected) good = False;
    end
    return good;
endfunction

module mkTbPLIOHostManagerM2(Empty);
    PLIOHostManagerM2Ifc manager <- mkPLIOHostManagerM2;
    Reg#(Bit#(7)) phase <- mkReg(0);
    Reg#(Bit#(9)) waits <- mkReg(0);

    rule run;
        Vector#(8, PlioOut) none = emptyCards();

        case (phase)
            0: begin
                manager.advance(requestCards(8'hA4), True, False);
                phase <= 1;
            end
            1: begin
                Vector#(8, PlioOut) cards = notificationAddress(2, 0, False);
                Vector#(8, PlioIn) d = manager.drive(cards, True, False);
                if (!manager.debugGrantValid || manager.debugGrantSlot != 2 || !oneHotGrant(d, 2) || !d[2].ack) begin
                    $display("FAIL M2 first grant"); $finish(1);
                end
                manager.advance(cards, True, False);
                phase <= 2;
            end
            2: begin
                Vector#(8, PlioOut) cards = notificationData(2, 32'h22, False);
                manager.advance(cards, True, False);
                phase <= 3;
            end
            3: begin
                manager.advance(requestCards(8'hA4), True, False);
                phase <= 4;
            end
            4: begin
                if (!manager.debugGrantValid || manager.debugGrantSlot != 5) begin $display("FAIL M2 second grant"); $finish(1); end
                manager.advance(notificationAddress(5, 0, False), True, False);
                phase <= 5;
            end
            5: begin
                manager.advance(notificationData(5, 32'h55, False), True, False);
                phase <= 6;
            end
            6: begin
                manager.advance(requestCards(8'hA4), True, False);
                phase <= 7;
            end
            7: begin
                Vector#(8, PlioIn) d = manager.drive(requestCards(8'hA4), True, False);
                if (!manager.debugGrantValid || manager.debugGrantSlot != 7 || !oneHotGrant(d, 7)) begin
                    $display("FAIL M2 third grant"); $finish(1);
                end
                $display("PLIOHOSTM2TRACE|v1|case=round_robin|grants=2,5,7|one_hot=1");
                manager.advance(none, True, True);
                phase <= 8;
            end
            8: begin
                manager.advance(requestCards(8'h08), True, False);
                phase <= 9;
            end
            9: begin manager.advance(notificationAddress(3, 0, False), True, False); phase <= 10; end
            10: begin manager.advance(notificationData(3, 32'h31, False), True, False); phase <= 11; end
            11: begin manager.advance(requestCards(8'h08), True, False); phase <= 12; end
            12: begin
                if (!manager.debugGrantValid || manager.debugGrantSlot != 3 || manager.debugGrantCount(3) != 2) begin
                    $display("FAIL M2 repeated grant"); $finish(1);
                end
                $display("PLIOHOSTM2TRACE|v1|case=repeated|slot=3|grants=2");
                manager.advance(none, True, True);
                phase <= 13;
            end
            13: begin manager.advance(requestCards(8'h02), True, False); phase <= 14; end
            14: begin manager.advance(notificationAddress(1, 2, False), True, False); phase <= 15; end
            15, 16, 17: begin
                Vector#(8, PlioOut) cards = notificationData(1, 32'hfeed_beef, False);
                Vector#(8, PlioIn) d = manager.drive(cards, False, False);
                if (!d[1].grant || d[1].ack || d[1].err) begin $display("FAIL M2 backpressure drive"); $finish(1); end
                manager.advance(cards, False, False);
                phase <= phase + 1;
            end
            18: begin
                Vector#(8, PlioOut) cards = notificationData(1, 32'hfeed_beef, False);
                if (manager.debugWaitCycles != 3 || !manager.drive(cards, True, False)[1].ack) begin
                    $display("FAIL M2 backpressure count"); $finish(1);
                end
                manager.advance(cards, True, False);
                phase <= 19;
            end
            19: begin
                if (!manager.notificationPending(1, 2) || manager.notificationPayload(1, 2) != 32'hfeed_beef) begin
                    $display("FAIL M2 backpressure payload"); $finish(1);
                end
                $display("PLIOHOSTM2TRACE|v1|case=backpressure|slot=1|channel=2|wait=3|payload=feedbeef");
                manager.advance(none, True, True);
                phase <= 20;
            end
            20: begin manager.advance(requestCards(8'h01), True, False); phase <= 21; end
            21: begin
                Vector#(8, PlioOut) cards = notificationAddress(0, 0, True);
                if (!manager.drive(cards, True, False)[0].err) begin $display("FAIL M2 address parity response"); $finish(1); end
                manager.advance(cards, True, False);
                phase <= 22;
            end
            22: begin
                if (!manager.debugFaultValid || manager.debugFault != M2AddressParity) begin $display("FAIL M2 address parity fault"); $finish(1); end
                $display("PLIOHOSTM2TRACE|v1|case=address_parity|status=error");
                manager.advance(none, True, True);
                phase <= 23;
            end
            23: begin manager.advance(requestCards(8'h01), True, False); phase <= 24; end
            24: begin manager.advance(notificationAddress(0, 1, False), True, False); phase <= 25; end
            25: begin
                Vector#(8, PlioOut) cards = notificationData(0, 32'h1234_5678, True);
                if (!manager.drive(cards, True, False)[0].err) begin $display("FAIL M2 data parity response"); $finish(1); end
                manager.advance(cards, True, False);
                phase <= 26;
            end
            26: begin
                if (!manager.debugFaultValid || manager.debugFault != M2DataParity) begin $display("FAIL M2 data parity fault"); $finish(1); end
                $display("PLIOHOSTM2TRACE|v1|case=data_parity|status=error");
                manager.advance(none, True, True);
                phase <= 27;
            end
            27: begin
                manager.advance(requestCards(8'h40), True, False);
                waits <= 0;
                phase <= 28;
            end
            28: begin
                Vector#(8, PlioOut) cards = requestCards(8'h40);
                if (waits == 255) begin
                    if (!manager.drive(cards, True, False)[6].err) begin $display("FAIL M2 timeout response"); $finish(1); end
                    manager.advance(cards, True, False);
                    phase <= 29;
                end
                else begin
                    manager.advance(cards, True, False);
                    waits <= waits + 1;
                end
            end
            29: begin
                if (!manager.debugFaultValid || manager.debugFault != M2Timeout || manager.debugState != M2Idle) begin
                    $display("FAIL M2 timeout fault"); $finish(1);
                end
                $display("PLIOHOSTM2TRACE|v1|case=timeout|phase=grant|cycles=256");
                manager.advance(none, True, True);
                phase <= 30;
            end
            30: begin manager.advance(requestCards(8'h04), True, False); phase <= 31; end
            31: begin manager.advance(notificationAddress(2, 1, False), True, False); phase <= 32; end
            32: begin manager.advance(notificationData(2, 32'haa55_aa55, False), True, False); phase <= 33; end
            33: begin manager.advance(requestCards(8'h20), True, False); phase <= 34; end
            34: begin
                Vector#(8, PlioIn) d = manager.drive(requestCards(8'h20), True, True);
                for (Integer i = 0; i < 8; i = i + 1) begin
                    if (!d[i].reset || d[i].grant) begin $display("FAIL M2 reset drive"); $finish(1); end
                end
                manager.advance(requestCards(8'h20), True, True);
                phase <= 35;
            end
            35: begin
                if (manager.debugGrantValid || manager.notificationPending(2, 1) || manager.debugCursor != 0) begin
                    $display("FAIL M2 reset state"); $finish(1);
                end
                $display("PLIOHOSTM2TRACE|v1|case=reset|grant=withdrawn|pending=cleared|cursor=0");
                phase <= 36;
            end
            36: begin manager.advance(requestCards(8'h10), True, False); phase <= 37; end
            37: begin manager.advance(notificationAddress(4, 0, False), True, False); phase <= 38; end
            38: begin manager.advance(notificationData(4, 32'h40, False), True, False); phase <= 39; end
            39: begin manager.advance(requestCards(8'h02), True, False); phase <= 40; end
            40: begin manager.advance(notificationAddress(1, 3, False), True, False); phase <= 41; end
            41: begin manager.advance(notificationData(1, 32'h13, False), True, False); phase <= 42; end
            42: begin manager.advance(requestCards(8'h02), True, False); phase <= 43; end
            43: begin manager.advance(notificationAddress(1, 1, False), True, False); phase <= 44; end
            44: begin manager.advance(notificationData(1, 32'h11, False), True, False); phase <= 45; end
            45: begin manager.setNotificationConfig(1, 1, True, True, 2); phase <= 46; end
            46: begin manager.setNotificationConfig(1, 3, True, False, 7); phase <= 47; end
            47: begin manager.setNotificationConfig(4, 0, False, False, 9); phase <= 48; end
            48: begin
                if (!manager.claimValid || manager.claimSlot != 1 || manager.claimChannel != 3
                    || manager.claimPayload != 32'h13 || manager.claimClass != 7) begin
                    $display("FAIL M2 first claim"); $finish(1);
                end
                manager.claimFirst;
                phase <= 49;
            end
            49: begin manager.setNotificationConfig(1, 1, True, False, 2); phase <= 50; end
            50: begin
                if (!manager.claimValid || manager.claimSlot != 1 || manager.claimChannel != 1
                    || manager.claimPayload != 32'h11 || manager.claimClass != 2) begin
                    $display("FAIL M2 second claim"); $finish(1);
                end
                manager.claimFirst;
                phase <= 51;
            end
            51: begin
                if (manager.claimValid || !manager.notificationPending(4, 0)) begin $display("FAIL M2 disabled claim hold"); $finish(1); end
                $display("PLIOHOSTM2TRACE|v1|case=claim_order|first=1:3:7|second=1:1:2|disabled_4:0=held");
                $display("PASS PLIO host M2 arbitration/notification semantics");
                $finish(0);
            end
            default: begin $display("FAIL M2 unexpected phase"); $finish(1); end
        endcase
    endrule
endmodule

endpackage
