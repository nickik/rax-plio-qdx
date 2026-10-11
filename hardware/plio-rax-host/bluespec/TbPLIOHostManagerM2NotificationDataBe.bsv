package TbPLIOHostManagerM2NotificationDataBe;

import Vector::*;
import QLITypes::*;
import QICInterfaces::*;
import PLIOHostManagerM2::*;

function Vector#(8, PlioOut) requestCard(Bit#(3) slot);
    Vector#(8, PlioOut) cards = replicate(plioOutDefault());
    cards[slot].request = True;
    return cards;
endfunction

function Vector#(8, PlioOut) notificationAddress(Bit#(3) slot, Bit#(2) channel);
    Vector#(8, PlioOut) cards = requestCard(slot);
    Bit#(32) address = zeroExtend(channel) << 2;
    cards[slot].adValid = True;
    cards[slot].ad = address;
    cards[slot].parValid = True;
    cards[slot].parity = m2OddParity32(address);
    cards[slot].spaceValid = True;
    cards[slot].space = PlioController;
    cards[slot].addressStrobe = True;
    cards[slot].read = False;
    cards[slot].byteEnable = 4'hf;
    cards[slot].burst = BurstOne;
    return cards;
endfunction

function Vector#(8, PlioOut) notificationDataWithoutBe(Bit#(3) slot, Bit#(32) data);
    Vector#(8, PlioOut) cards = requestCard(slot);
    cards[slot].adValid = True;
    cards[slot].ad = data;
    cards[slot].parValid = True;
    cards[slot].parity = m2OddParity32(data);
    cards[slot].byteEnable = 4'h0;
    cards[slot].dataStrobe = True;
    return cards;
endfunction

module mkTbPLIOHostManagerM2NotificationDataBe(Empty);
    PLIOHostManagerM2Ifc manager <- mkPLIOHostManagerM2;
    Reg#(Bit#(3)) phase <- mkReg(0);

    rule run;
        case (phase)
            0: begin
                manager.advance(requestCard(0), True, False);
                phase <= 1;
            end
            1: begin
                Vector#(8, PlioOut) cards = notificationAddress(0, 2);
                Vector#(8, PlioIn) d = manager.drive(cards, True, False);
                if (!d[0].ack || d[0].err) begin
                    $display("FAIL notification address");
                    $finish(1);
                end
                manager.advance(cards, True, False);
                phase <= 2;
            end
            2: begin
                Vector#(8, PlioOut) cards = notificationDataWithoutBe(0, 32'hfeed_beef);
                Vector#(8, PlioIn) d = manager.drive(cards, True, False);
                if (!d[0].ack || d[0].err) begin
                    $display("FAIL notification data without data-phase BE");
                    $finish(1);
                end
                manager.advance(cards, True, False);
                phase <= 3;
            end
            3: begin
                if (!manager.notificationPending(0, 2)
                    || manager.notificationPayload(0, 2) != 32'hfeed_beef) begin
                    $display("FAIL notification payload/pending");
                    $finish(1);
                end
                $display("PASS notification data does not require data-phase BE");
                $finish(0);
            end
        endcase
    endrule
endmodule

endpackage
