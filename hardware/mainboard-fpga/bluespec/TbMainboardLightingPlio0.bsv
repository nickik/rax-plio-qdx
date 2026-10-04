package TbMainboardLightingPlio0;

import Vector::*;
import QLITypes::*;
import QICInterfaces::*;
import PLIOTx::*;
import QDXA::*;
import QDXBCard::*;
import PLIOWorkerHost::*;
import LightingMemoryBusCompat::*;
import MainboardFPGA::*;

Bit#(32) plio0Base = 32'hffe0_0000;
Bit#(32) map0Address = 32'hffe0_0100;
Bit#(32) worker0Address = 32'hffe8_1000;

function LightingBusMasterDrive cpuBusRequest();
    LightingBusMasterDrive d = lightingBusMasterDriveDefault();
    d.busRequest = True;
    return d;
endfunction

function LightingBusMasterDrive cpuRequest(Bit#(32) address, Bool write,
    Bit#(32) writeData);
    LightingBusMasterDrive d = cpuBusRequest();
    d.request = True;
    d.payload.addr = address;
    d.payload.write = write;
    d.payload.writeData = writeData;
    d.payload.byteEnable = 4'hf;
    return d;
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

typedef enum {
    LpReset,
    LpMapBusRequest,
    LpMapActive,
    LpMapWait,
    LpMapRetire,
    LpCapBusRequest,
    LpCapActive,
    LpCapWait,
    LpCapRetire,
    LpDone
} LpStage deriving (Bits, Eq, FShow);

module mkTbMainboardLightingPlio0(Empty);
    MainboardFPGAIfc board <- mkMainboardFPGA;
    QDXBCardIfc card <- mkQDXBCard;

    Reg#(LpStage) stage <- mkReg(LpReset);
    Reg#(BackplaneDrive) cardImage <- mkReg(backplaneDriveDefault());
    Reg#(Bool) launched <- mkReg(False);
    Reg#(Bit#(16)) physicalCycles <- mkReg(0);
    Reg#(Bit#(32)) clockTicks <- mkReg(0);

    function LightingBusMasterDrive activeCpu();
        LightingBusMasterDrive cpu = lightingBusMasterDriveDefault();
        case (stage)
            LpMapBusRequest: cpu = cpuBusRequest();
            LpMapActive: cpu = cpuRequest(map0Address, True, 32'h8000_0000);
            LpMapWait: cpu = cpuRequest(map0Address, True, 32'h8000_0000);
            LpCapBusRequest: cpu = cpuBusRequest();
            LpCapActive: cpu = cpuRequest(worker0Address, False, 0);
            LpCapWait: cpu = cpuRequest(worker0Address, False, 0);
            default: begin end
        endcase
        return cpu;
    endfunction

    rule tickWatchdog (stage != LpDone);
        clockTicks <= clockTicks + 1;
        if (clockTicks == 32'd300000) begin
            $display("FAIL|lighting-plio0|clock-watchdog|stage=%0d|physical_cycles=%0d",
                pack(stage), physicalCycles);
            $finish(1);
        end
    endrule

    // Every call of board.advance is paired with one completed physical card
    // cycle.  The CPU therefore reaches the card only through the Mainboard's
    // PLIO0 MMIO decoder and PLIOHostCore, never through a test-side worker.
    rule launchCardCycle (!launched && stage != LpDone && card.ready);
        Vector#(8, BackplaneDrive) cards = replicate(backplaneDriveDefault());
        cards[0] = cardImage;
        Bool reset = stage == LpReset;
        Vector#(8, PlioIn) slotInputs = board.plioSlots(cards, reset);
        card.startCycle(slotInputs[0]);
        launched <= True;
    endrule

    rule consumeCardCycle (launched && card.cycleDone);
        BackplaneDrive nextImage = card.backplane;
        Vector#(8, BackplaneDrive) cards = replicate(backplaneDriveDefault());
        cards[0] = nextImage;
        Bool reset = stage == LpReset;
        LightingBusMasterDrive cpu = activeCpu();
        LightingBusInputs bus = board.lightingMemory(cards, cpu, reset);

        if ((stage == LpMapBusRequest || stage == LpMapActive
            || stage == LpMapWait || stage == LpCapBusRequest
            || stage == LpCapActive || stage == LpCapWait)
            && (!bus.busGrant || bus.error)) begin
            $display("FAIL|lighting-plio0|cpu-grant|stage=%0d|grant=%0d|ready=%0d|error=%0d|role=%0d|worker_pending=%0d",
                pack(stage), pack(bus.busGrant), pack(bus.ready), pack(bus.error),
                pack(board.debugPlioRole), pack(board.workerCompletionValid));
            $finish(1);
        end

        board.advance(cards, cpu, False, noWorkerRequest(),
            False, False, False, False, 0, reset);

        if (reset) stage <= LpMapBusRequest;
        else if (stage == LpMapBusRequest) stage <= LpMapActive;
        else if (stage == LpMapActive) stage <= LpMapWait;
        else if (stage == LpMapWait && bus.ready) begin
            if (bus.error) begin
                $display("FAIL|lighting-plio0|map-response-error");
                $finish(1);
            end
            stage <= LpMapRetire;
        end
        else if (stage == LpMapRetire) stage <= LpCapBusRequest;
        else if (stage == LpCapBusRequest) stage <= LpCapActive;
        else if (stage == LpCapActive) stage <= LpCapWait;
        else if (stage == LpCapWait && bus.ready) begin
            if (bus.error || bus.readData != qdxCapValue) begin
                $display("FAIL|lighting-plio0|capability-response|error=%0d|data=%08x|expected=%08x|role=%0d|card_fault=%0d",
                    pack(bus.error), bus.readData, qdxCapValue,
                    pack(board.debugPlioRole), pack(card.protocolFault));
                $finish(1);
            end
            stage <= LpCapRetire;
        end
        else if (stage == LpCapRetire) stage <= LpDone;

        if (card.protocolFault) begin
            $display("FAIL|lighting-plio0|card-protocol-fault|stage=%0d|role=%0d|qic=%0d|qdx=%0d|fault=%0d",
                pack(stage), pack(board.debugPlioRole), pack(card.qicState),
                pack(card.qdxState), pack(board.debugPlioFault));
            $finish(1);
        end

        cardImage <= nextImage;
        card.finishCycle;
        launched <= False;
        physicalCycles <= physicalCycles + 1;
    endrule

    rule done (stage == LpDone && !launched);
        $display("MAINBOARDPLIO0TRACE|cpu_mmio=ok|iochannel=0|slot=0|worker=%08x|cap=%08x|physical_cycles=%0d|clock_ticks=%0d",
            regQdxCap, qdxCapValue, physicalCycles, clockTicks);
        $display("PASS|lighting-plio0|CPU MMIO reaches physical QDX-B through Mainboard PLIO host");
        $finish(0);
    endrule
endmodule

endpackage
