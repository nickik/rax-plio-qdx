package TbMainboardP0PlioResponse;

import Vector::*;
import QLITypes::*;
import QICInterfaces::*;
import PLIOTx::*;
import PLIOWorkerHost::*;
import PLIOHostDmaM3::*;
import PLIOHostCore::*;
import LightingMemoryBusCompat::*;
import MainboardFPGA::*;

function Bit#(4) p0Parity(Bit#(32) word);
    return { ~(^word[31:24]), ~(^word[23:16]), ~(^word[15:8]), ~(^word[7:0]) };
endfunction

function Vector#(8, BackplaneDrive) idleCards();
    return replicate(backplaneDriveDefault());
endfunction

function HostWorkerRequest noWorkerRequest();
    return HostWorkerRequest {
        slot: 0,
        address: 0,
        width: HostW32,
        write: False,
        value: 0
    };
endfunction

function BackplaneDrive requestOnly();
    BackplaneDrive d = backplaneDriveDefault();
    d.request = True;
    return d;
endfunction

function BackplaneDrive dmaAddress(Bit#(32) address);
    BackplaneDrive d = requestOnly();
    BackplaneControl c = backplaneControlDefault();
    c.space = pack(PlioHostDma);
    c.addressStrobe = True;
    c.read = True;
    c.byteEnable = 4'hf;
    c.burstLen = pack(BurstOne);
    d.controlValid = True;
    d.control = c;
    d.adParValid = True;
    d.ad = address;
    d.parity = p0Parity(address);
    return d;
endfunction

function BackplaneDrive dmaReadBeat();
    BackplaneDrive d = requestOnly();
    BackplaneControl c = backplaneControlDefault();
    c.dataStrobe = True;
    d.controlValid = True;
    d.control = c;
    return d;
endfunction

typedef enum {
    P0PlioResetSubmit,
    P0PlioResetDrain,
    P0PlioBind,
    P0PlioRequest,
    P0PlioAddress0,
    P0PlioAddress1,
    P0PlioRead,
    P0PlioRetire,
    P0PlioRegrant
} P0PlioStage deriving (Bits, Eq, FShow);

module mkTbP0PlioResponse(Empty);
    MainboardFPGAIfc board <- mkMainboardFPGA;
    Reg#(P0PlioStage) stage <- mkReg(P0PlioResetSubmit);
    Reg#(Bit#(8)) cycle <- mkReg(0);
    Reg#(Bool) backendResponseSubmitted <- mkReg(False);

    rule resetSubmit (stage == P0PlioResetSubmit);
        board.advance(idleCards(), lightingBusMasterDriveDefault(),
            False, noWorkerRequest(),
            False, False, False, False, 0, True);
        stage <= P0PlioResetDrain;
    endrule

    rule resetDrain (stage == P0PlioResetDrain);
        stage <= P0PlioBind;
    endrule

    rule bindChannel (stage == P0PlioBind);
        board.bindDma(1, 3, 32'h0000_0100, 25'h00100, True, True);
        stage <= P0PlioRequest;
    endrule

    rule request (stage == P0PlioRequest);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = requestOnly();
        board.advance(cards, lightingBusMasterDriveDefault(),
            False, noWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= P0PlioAddress0;
    endrule

    rule address0 (stage == P0PlioAddress0);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = dmaAddress(32'h3000_0000);
        Vector#(8, PlioIn) slotInputs = board.plioSlots(cards, False);
        $display("TRACE|p0-plio-response|phase=address0|grant=%0d|ack=%0d|err=%0d|role=%0d|dma_state=%0d|plio_req=%0d|fault_valid=%0d|fault=%0d",
            pack(slotInputs[1].grant), pack(slotInputs[1].ack),
            pack(slotInputs[1].err), pack(board.debugPlioRole),
            pack(board.debugPlioDmaState), pack(board.debugPlioMemoryRequestValid),
            pack(board.debugPlioFaultValid), pack(board.debugPlioFault));
        if (!slotInputs[1].grant || slotInputs[1].ack || slotInputs[1].err) begin
            $display("FAIL|p0-plio-response|phase=address0|grant=%0d|ack=%0d|err=%0d",
                pack(slotInputs[1].grant), pack(slotInputs[1].ack),
                pack(slotInputs[1].err));
            $finish(1);
        end
        board.advance(cards, lightingBusMasterDriveDefault(),
            False, noWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= P0PlioAddress1;
    endrule

    rule address1 (stage == P0PlioAddress1);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = dmaAddress(32'h3000_0000);
        Vector#(8, PlioIn) slotInputs = board.plioSlots(cards, False);
        $display("TRACE|p0-plio-response|phase=address1|grant=%0d|ack=%0d|err=%0d|role=%0d|dma_state=%0d|plio_req=%0d|fault_valid=%0d|fault=%0d",
            pack(slotInputs[1].grant), pack(slotInputs[1].ack),
            pack(slotInputs[1].err), pack(board.debugPlioRole),
            pack(board.debugPlioDmaState), pack(board.debugPlioMemoryRequestValid),
            pack(board.debugPlioFaultValid), pack(board.debugPlioFault));
        if (!slotInputs[1].grant || !slotInputs[1].ack || slotInputs[1].err) begin
            $display("FAIL|p0-plio-response|phase=address1|grant=%0d|ack=%0d|err=%0d",
                pack(slotInputs[1].grant), pack(slotInputs[1].ack),
                pack(slotInputs[1].err));
            $finish(1);
        end
        board.advance(cards, lightingBusMasterDriveDefault(),
            False, noWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= P0PlioRead;
        cycle <= 0;
    endrule

    rule readResponse (stage == P0PlioRead);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = dmaReadBeat();
        Vector#(8, PlioIn) slotInputs = board.plioSlots(cards, False);
        Bool submitResponse = board.memoryBackendResponseReady
            && !backendResponseSubmitted;

        $display("TRACE|p0-plio-response|phase=read|cycle=%0d|grant=%0d|ack=%0d|err=%0d|ad_valid=%0d|ad=%08x|role=%0d|dma_state=%0d|owner=%0d|plio_req=%0d|plio_resp=%0d|cpu_resp=%0d|mc_state=%0d|mc_host_resp=%0d|cycle_pending=%0d|advance_ready=%0d|backend_req=%0d|backend_wr=%0d|backend_addr=%08x|backend_resp_ready=%0d|submit_resp=%0d|response_submitted=%0d|fault_valid=%0d|fault=%0d",
            cycle, pack(slotInputs[1].grant), pack(slotInputs[1].ack),
            pack(slotInputs[1].err), pack(slotInputs[1].adValid), slotInputs[1].ad,
            pack(board.debugPlioRole), pack(board.debugPlioDmaState),
            pack(board.debugMemoryOwner), pack(board.debugPlioMemoryRequestValid),
            pack(board.debugPlioResponsePending), pack(board.debugCpuResponsePending),
            pack(board.debugMemoryControllerState),
            pack(board.debugMemoryHostResponseValid), pack(board.debugCyclePending),
            pack(board.debugAdvanceReady), pack(board.memoryBackendRequestValid),
            pack(board.memoryBackendWrite), board.memoryBackendAddress,
            pack(board.memoryBackendResponseReady), pack(submitResponse),
            pack(backendResponseSubmitted), pack(board.debugPlioFaultValid),
            pack(board.debugPlioFault));

        if (!slotInputs[1].grant || slotInputs[1].err) begin
            $display("FAIL|p0-plio-response|slot-state|grant=%0d|err=%0d",
                pack(slotInputs[1].grant), pack(slotInputs[1].err));
            $finish(1);
        end
        if (board.memoryBackendRequestValid
            && (board.memoryBackendWrite
                || board.memoryBackendAddress != 32'h0000_0100)) begin
            $display("FAIL|p0-plio-response|backend-request|write=%0d|addr=%08x",
                pack(board.memoryBackendWrite), board.memoryBackendAddress);
            $finish(1);
        end

        // The completed data-beat image still has to cross the registered
        // board boundary. Do not declare success merely because drive()
        // exposes the final ACK/data; enqueue that image so host.advance()
        // retires the PLIO transaction and grant epoch.
        board.advance(cards, lightingBusMasterDriveDefault(),
            False, noWorkerRequest(),
            True, submitResponse, False, submitResponse, 32'h1122_3344, False);
        if (submitResponse) backendResponseSubmitted <= True;

        if (slotInputs[1].ack) begin
            if (!slotInputs[1].adValid || slotInputs[1].ad != 32'h1122_3344) begin
                $display("FAIL|p0-plio-response|read-data|valid=%0d|actual=%08x",
                    pack(slotInputs[1].adValid), slotInputs[1].ad);
                $finish(1);
            end
            $display("TRACE|p0-plio-response|phase=final-ack|grant=1|data=11223344|queued_for_retire=1");
            stage <= P0PlioRetire;
            cycle <= 0;
        end
        else begin
            cycle <= cycle + 1;
            if (cycle == 16) begin
                $display("FAIL|p0-plio-response|short-watchdog|role=%0d|dma_state=%0d|owner=%0d|plio_resp=%0d|mc_state=%0d|mc_host_resp=%0d|backend_req=%0d|backend_resp_ready=%0d|fault_valid=%0d|fault=%0d",
                    pack(board.debugPlioRole), pack(board.debugPlioDmaState),
                    pack(board.debugMemoryOwner), pack(board.debugPlioResponsePending),
                    pack(board.debugMemoryControllerState),
                    pack(board.debugMemoryHostResponseValid),
                    pack(board.memoryBackendRequestValid),
                    pack(board.memoryBackendResponseReady),
                    pack(board.debugPlioFaultValid), pack(board.debugPlioFault));
                $finish(1);
            end
        end
    endrule

    // Hold BR continuously high after the final ACK. The board must consume
    // the queued final data-beat image, after which PLIOHostCore must finish
    // the old grant epoch and expose a sampled BG-low cycle. This test does
    // not inspect the host completion CReg; the separate plio-dma diagnostic
    // already proves DmaOk/beats=1 and keeping this smoke independent avoids
    // coupling board-boundary validation to completion-register scheduling.
    rule retireResponse (stage == P0PlioRetire);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = requestOnly();
        Vector#(8, PlioIn) slotInputs = board.plioSlots(cards, False);

        $display("TRACE|p0-plio-response|phase=retire|cycle=%0d|br=1|grant=%0d|ack=%0d|err=%0d|role=%0d|dma_state=%0d|cycle_pending=%0d|advance_ready=%0d|fault_valid=%0d|fault=%0d",
            cycle, pack(slotInputs[1].grant), pack(slotInputs[1].ack),
            pack(slotInputs[1].err), pack(board.debugPlioRole),
            pack(board.debugPlioDmaState), pack(board.debugCyclePending),
            pack(board.debugAdvanceReady), pack(board.debugPlioFaultValid),
            pack(board.debugPlioFault));

        if (slotInputs[1].ack || slotInputs[1].err) begin
            $display("FAIL|p0-plio-response|retire-response-leaked|ack=%0d|err=%0d",
                pack(slotInputs[1].ack), pack(slotInputs[1].err));
            $finish(1);
        end

        if (!slotInputs[1].grant) begin
            if (board.debugPlioRole != CoreIdle || board.debugPlioDmaState != DmaIdle) begin
                $display("FAIL|p0-plio-response|bg-low-with-active-state|role=%0d|dma_state=%0d",
                    pack(board.debugPlioRole), pack(board.debugPlioDmaState));
                $finish(1);
            end
            $display("TRACE|p0-plio-response|phase=bg-low|br=1|grant=0|role=idle|dma_state=idle");
            board.advance(cards, lightingBusMasterDriveDefault(),
                False, noWorkerRequest(),
                False, False, False, False, 0, False);
            stage <= P0PlioRegrant;
            cycle <= 0;
        end
        else begin
            board.advance(cards, lightingBusMasterDriveDefault(),
                False, noWorkerRequest(),
                False, False, False, False, 0, False);
            cycle <= cycle + 1;
            if (cycle == 16) begin
                $display("FAIL|p0-plio-response|retire-watchdog|grant=%0d|role=%0d|dma_state=%0d|cycle_pending=%0d|fault_valid=%0d|fault=%0d",
                    pack(slotInputs[1].grant), pack(board.debugPlioRole),
                    pack(board.debugPlioDmaState), pack(board.debugCyclePending),
                    pack(board.debugPlioFaultValid), pack(board.debugPlioFault));
                $finish(1);
            end
        end
    endrule

    // BR is still high. Once the BG-low image is sampled, CoreIdle may select
    // the same slot again, but that is necessarily a fresh grant epoch.
    rule freshGrant (stage == P0PlioRegrant);
        Vector#(8, BackplaneDrive) cards = idleCards();
        cards[1] = requestOnly();
        Vector#(8, PlioIn) slotInputs = board.plioSlots(cards, False);

        $display("TRACE|p0-plio-response|phase=regrant|cycle=%0d|br=1|grant=%0d|ack=%0d|err=%0d|role=%0d|dma_state=%0d|cycle_pending=%0d|fault_valid=%0d|fault=%0d",
            cycle, pack(slotInputs[1].grant), pack(slotInputs[1].ack),
            pack(slotInputs[1].err), pack(board.debugPlioRole),
            pack(board.debugPlioDmaState), pack(board.debugCyclePending),
            pack(board.debugPlioFaultValid), pack(board.debugPlioFault));

        if (slotInputs[1].ack || slotInputs[1].err) begin
            $display("FAIL|p0-plio-response|fresh-grant-response-leaked|ack=%0d|err=%0d",
                pack(slotInputs[1].ack), pack(slotInputs[1].err));
            $finish(1);
        end

        if (slotInputs[1].grant) begin
            if (board.debugPlioRole != CoreGrant) begin
                $display("FAIL|p0-plio-response|fresh-grant-role|grant=%0d|role=%0d",
                    pack(slotInputs[1].grant), pack(board.debugPlioRole));
                $finish(1);
            end
            $display("PASS|p0-plio-response|final beat retires, BG-low boundary observed, continuous BR receives fresh grant");
            $finish(0);
        end

        board.advance(cards, lightingBusMasterDriveDefault(),
            False, noWorkerRequest(),
            False, False, False, False, 0, False);
        cycle <= cycle + 1;
        if (cycle == 16) begin
            $display("FAIL|p0-plio-response|regrant-watchdog|role=%0d|dma_state=%0d|cycle_pending=%0d|fault_valid=%0d|fault=%0d",
                pack(board.debugPlioRole), pack(board.debugPlioDmaState),
                pack(board.debugCyclePending), pack(board.debugPlioFaultValid),
                pack(board.debugPlioFault));
            $finish(1);
        end
    endrule
endmodule

endpackage
