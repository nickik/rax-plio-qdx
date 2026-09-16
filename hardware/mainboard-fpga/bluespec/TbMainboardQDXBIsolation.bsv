package TbMainboardQDXBIsolation;

import Vector::*;
import QICInterfaces::*;
import PLIOTx::*;
import QDXBCard::*;
import PLIOWorkerHost::*;
import LightingMemoryBusCompat::*;
import MainboardFPGA::*;

function HostWorkerRequest noWorker();
    return HostWorkerRequest { slot: 0, address: 0, width: HostW32,
        write: False, value: 0 };
endfunction

module mkTbQDXBCardResetCycle(Empty);
    QDXBCardIfc card <- mkQDXBCard;
    Reg#(Bool) launched <- mkReg(False);
    Reg#(Bit#(8)) ticks <- mkReg(0);

    rule launch (!launched && card.ready);
        PlioIn image = plioInDefault();
        image.reset = True;
        $display("DBG|qdx-card-cycle|launch|qic=%0d|qdx=%0d|fault=%0d",
            pack(card.qicState), pack(card.qdxState), pack(card.protocolFault));
        card.startCycle(image);
        launched <= True;
    endrule

    rule waitCycle (launched && !card.cycleDone);
        $display("DBG|qdx-card-cycle|wait=%0d|qic=%0d|qdx=%0d|fault=%0d",
            ticks, pack(card.qicState), pack(card.qdxState), pack(card.protocolFault));
        ticks <= ticks + 1;
        if (ticks == 32) begin
            $display("FAIL|qdx-card-cycle|watchdog");
            $finish(1);
        end
    endrule

    rule complete (launched && card.cycleDone);
        BackplaneDrive d = card.backplane;
        if (card.protocolFault || d.request || d.controlValid || d.adParValid || d.responseValid) begin
            $display("FAIL|qdx-card-cycle|reset-drive");
            $finish(1);
        end
        card.finishCycle;
        $display("PASS|qdx-card-cycle|raw reset cycle completes");
        $finish(0);
    endrule
endmodule

module mkTbMainboardQDXBResetCycle(Empty);
    MainboardFPGAIfc board <- mkMainboardFPGA;
    QDXBCardIfc card <- mkQDXBCard;
    Reg#(Bool) launched <- mkReg(False);
    Reg#(Bit#(8)) ticks <- mkReg(0);

    rule launch (!launched && card.ready);
        Vector#(8, BackplaneDrive) cards = replicate(backplaneDriveDefault());
        Vector#(8, PlioIn) slots = board.plioSlots(cards, True);
        $display("DBG|qdx-slot-cycle|launch|role=%0d|owner=%0d|qic=%0d|qdx=%0d",
            pack(board.debugPlioRole), pack(board.debugMemoryOwner),
            pack(card.qicState), pack(card.qdxState));
        card.startCycle(slots[0]);
        launched <= True;
    endrule

    rule waitCycle (launched && !card.cycleDone);
        $display("DBG|qdx-slot-cycle|wait=%0d|role=%0d|owner=%0d|qic=%0d|qdx=%0d|fault=%0d",
            ticks, pack(board.debugPlioRole), pack(board.debugMemoryOwner),
            pack(card.qicState), pack(card.qdxState), pack(card.protocolFault));
        ticks <= ticks + 1;
        if (ticks == 32) begin
            $display("FAIL|qdx-slot-cycle|watchdog");
            $finish(1);
        end
    endrule

    rule complete (launched && card.cycleDone);
        BackplaneDrive d = card.backplane;
        Vector#(8, BackplaneDrive) cards = replicate(backplaneDriveDefault());
        cards[0] = d;
        if (card.protocolFault || d.request || d.controlValid || d.adParValid || d.responseValid) begin
            $display("FAIL|qdx-slot-cycle|reset-drive");
            $finish(1);
        end
        board.advance(cards, lightingBusMasterDriveDefault(), False, noWorker(),
            False, False, False, False, 0, True);
        card.finishCycle;
        $display("PASS|qdx-slot-cycle|mainboard slot reset cycle completes");
        $finish(0);
    endrule
endmodule

endpackage
