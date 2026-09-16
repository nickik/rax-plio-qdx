package TbMainboardQDXBIntegration;

import Vector::*;
import QLITypes::*;
import QICInterfaces::*;
import PLIOTx::*;
import QDXA::*;
import QDXBCard::*;
import PLIOWorkerHost::*;
import LightingMemoryBusCompat::*;
import MainboardFPGA::*;

typedef enum {
    QbReset,
    QbReadCap,
    QbDone
} QbStage deriving (Bits, Eq, FShow);

function HostWorkerRequest qdxCapRead();
    return HostWorkerRequest {
        slot: 0,
        address: regQdxCap,
        width: HostW32,
        write: False,
        value: 0
    };
endfunction

module mkTbMainboardQDXBIntegration(Empty);
    MainboardFPGAIfc board <- mkMainboardFPGA;
    QDXBCardIfc card <- mkQDXBCard;

    Reg#(QbStage) stage <- mkReg(QbReset);
    Reg#(BackplaneDrive) cardImage <- mkReg(backplaneDriveDefault());
    Reg#(Bool) launched <- mkReg(False);
    Reg#(Bool) workerSent <- mkReg(False);
    Reg#(Bit#(16)) watchdog <- mkReg(0);
    Reg#(Bit#(32)) clockTicks <- mkReg(0);

    // Keep the wall-clock watchdog deliberately blind to board/card state.
    // Debug methods can expose FIFO/register reads that participate in rule
    // scheduling; an always-on observer of those methods previously became
    // more urgent than board_advancePlio* and stopped forward progress. Rich
    // state is therefore emitted only by the event rules below, which already
    // own the corresponding transition.
    rule tickWatchdog (stage != QbDone);
        clockTicks <= clockTicks + 1;
        if (clockTicks == 32'd200000) begin
            $display("FAIL|qdx-b|clock-watchdog|clock=%0d", clockTicks);
            $finish(1);
        end
    endrule

    // A physical QDX-B cycle is multi-cycle internally. The mainboard itself
    // advances once per completed physical card cycle, exactly like a real
    // card-edge connection rather than a direct logical PLIO shortcut.
    rule launchCardCycle (
        !launched && stage != QbDone && !board.workerCompletionValid && card.ready
    );
        Vector#(8, BackplaneDrive) cards = replicate(backplaneDriveDefault());
        cards[0] = cardImage;
        Bool reset = stage == QbReset;
        Vector#(8, PlioIn) slotInputs = board.plioSlots(cards, reset);
        card.startCycle(slotInputs[0]);
        launched <= True;
    endrule

    rule consumeCardCycle (launched && card.cycleDone);
        BackplaneDrive nextImage = card.backplane;
        Vector#(8, BackplaneDrive) cards = replicate(backplaneDriveDefault());
        // The completed card cycle is the image the mainboard must consume.
        // cardImage is the previous physical-cycle image used to drive the
        // host while this card cycle was in progress.
        cards[0] = nextImage;
        LightingBusMasterDrive cpu = lightingBusMasterDriveDefault();
        Bool reset = stage == QbReset;
        Bool sendWorker = stage == QbReadCap && !workerSent;
        Vector#(8, PlioIn) slotInputs = board.plioSlots(cards, reset);

        board.advance(cards, cpu, sendWorker, qdxCapRead(),
            False, False, False, False, 0, reset);

        if (watchdog[5:0] == 0) begin
            $display("DBG|qdx-b-cycle|physical_cycles=%0d|stage=%0d|reset=%0d|send_worker=%0d|request=%0d|control_valid=%0d|response_valid=%0d|slot_selected=%0d|slot_grant=%0d|slot_ack=%0d|slot_err=%0d|role=%0d|dma_state=%0d|qic=%0d|qdx=%0d|owner=%0d|mc_state=%0d|mc_host_resp=%0d|plio_mem_req=%0d|cycle_pending=%0d|advance_ready=%0d|backend_req=%0d|backend_resp_ready=%0d|host_fault_valid=%0d|host_fault=%0d|card_fault=%0d",
                watchdog, pack(stage), pack(reset),
                pack(sendWorker), pack(nextImage.request),
                pack(nextImage.controlValid), pack(nextImage.responseValid),
                pack(slotInputs[0].selected), pack(slotInputs[0].grant),
                pack(slotInputs[0].ack), pack(slotInputs[0].err),
                pack(board.debugPlioRole), pack(board.debugPlioDmaState),
                pack(card.qicState), pack(card.qdxState),
                pack(board.debugMemoryOwner), pack(board.debugMemoryControllerState),
                pack(board.debugMemoryHostResponseValid),
                pack(board.debugPlioMemoryRequestValid),
                pack(board.debugCyclePending), pack(board.debugAdvanceReady),
                pack(board.memoryBackendRequestValid),
                pack(board.memoryBackendResponseReady),
                pack(board.debugPlioFaultValid), pack(board.debugPlioFault),
                pack(card.protocolFault));
        end

        if (reset) begin
            stage <= QbReadCap;
            workerSent <= False;
        end
        else if (sendWorker) begin
            workerSent <= True;
        end

        if (card.protocolFault) begin
            $display("FAIL|qdx-b|physical-protocol-fault|physical_cycles=%0d|role=%0d|dma_state=%0d|qic=%0d|qdx=%0d|cycle_pending=%0d|host_fault_valid=%0d|host_fault=%0d",
                watchdog, pack(board.debugPlioRole), pack(board.debugPlioDmaState),
                pack(card.qicState), pack(card.qdxState),
                pack(board.debugCyclePending), pack(board.debugPlioFaultValid),
                pack(board.debugPlioFault));
            $finish(1);
        end

        cardImage <= nextImage;
        card.finishCycle;
        launched <= False;
        watchdog <= watchdog + 1;
        if (watchdog > 2000) begin
            $display("FAIL|qdx-b|physical-cycle-watchdog|role=%0d|dma_state=%0d|qic=%0d|qdx=%0d|owner=%0d|mc_state=%0d|mc_host_resp=%0d|plio_mem_req=%0d|cycle_pending=%0d|advance_ready=%0d|backend_req=%0d|backend_resp_ready=%0d|host_fault_valid=%0d|host_fault=%0d",
                pack(board.debugPlioRole), pack(board.debugPlioDmaState),
                pack(card.qicState), pack(card.qdxState),
                pack(board.debugMemoryOwner), pack(board.debugMemoryControllerState),
                pack(board.debugMemoryHostResponseValid),
                pack(board.debugPlioMemoryRequestValid),
                pack(board.debugCyclePending), pack(board.debugAdvanceReady),
                pack(board.memoryBackendRequestValid),
                pack(board.memoryBackendResponseReady),
                pack(board.debugPlioFaultValid), pack(board.debugPlioFault));
            $finish(1);
        end
    endrule

    rule checkWorkerCompletion (
        !launched && stage == QbReadCap && board.workerCompletionValid
    );
        HostWorkerCompletion c = board.workerCompletion;
        if (c.status != HostSuccess || c.data != qdxCapValue) begin
            $display("FAIL|qdx-b|discovery|status=%0d|data=%08x|expected=%08x|physical_cycles=%0d|role=%0d|dma_state=%0d|qic=%0d|qdx=%0d|cycle_pending=%0d|host_fault_valid=%0d|host_fault=%0d",
                pack(c.status), c.data, qdxCapValue, watchdog,
                pack(board.debugPlioRole), pack(board.debugPlioDmaState),
                pack(card.qicState), pack(card.qdxState),
                pack(board.debugCyclePending), pack(board.debugPlioFaultValid),
                pack(board.debugPlioFault));
            $finish(1);
        end
        if (card.protocolFault || card.qdxError != QdxErrNone) begin
            $display("FAIL|qdx-b|final-card-state|card_fault=%0d|qdx_error=%0d|role=%0d|dma_state=%0d|cycle_pending=%0d|host_fault_valid=%0d|host_fault=%0d",
                pack(card.protocolFault), pack(card.qdxError),
                pack(board.debugPlioRole), pack(board.debugPlioDmaState),
                pack(board.debugCyclePending), pack(board.debugPlioFaultValid),
                pack(board.debugPlioFault));
            $finish(1);
        end
        board.clearWorkerCompletion;
        stage <= QbDone;
    endrule

    rule done (stage == QbDone && !launched);
        $display("MAINBOARDQDXBTRACE|v6|registered_fifo=once|debug_event_driven=1|physical_slot=ok|worker_read=ok|cap=%08x|physical_cycles=%0d|clock_ticks=%0d",
            qdxCapValue, watchdog, clockTicks);
        $display("PASS mainboard FPGA <-> physical mkQDXBCard integration");
        $finish(0);
    endrule
endmodule

endpackage
