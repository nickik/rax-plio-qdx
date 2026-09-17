package TbMainboardLightingPlio0DmaCsr;

import Vector::*;
import QLITypes::*;
import QICInterfaces::*;
import PLIOTx::*;
import PLIOWorkerHost::*;
import LightingMemoryBusCompat::*;
import MainboardFPGA::*;

Bit#(32) dmaEntry = 32'hffe0_1130; // slot 1, DMA channel 3

function Vector#(8, BackplaneDrive) idleCards();
    return replicate(backplaneDriveDefault());
endfunction

function HostWorkerRequest noWorkerRequest();
    return HostWorkerRequest {
        slot: 0, address: 0, width: HostW32, write: False, value: 0
    };
endfunction

function LightingBusMasterDrive dmaOperation(Bit#(4) operation, Bool request);
    LightingBusMasterDrive cpu = lightingBusMasterDriveDefault();
    cpu.busRequest = True;
    cpu.request = request;
    cpu.payload.byteEnable = 4'hf;
    case (operation)
        0: begin cpu.payload.addr = dmaEntry; cpu.payload.write = True;
            cpu.payload.writeData = 32'h0000_2000; end
        1: begin cpu.payload.addr = dmaEntry + 4; cpu.payload.write = True;
            cpu.payload.writeData = 32'h0000_0100; end
        2: begin cpu.payload.addr = dmaEntry + 8; cpu.payload.write = True;
            cpu.payload.writeData = 7; end
        3: begin cpu.payload.addr = dmaEntry + 12; end
        4: begin cpu.payload.addr = dmaEntry + 8; cpu.payload.write = True;
            cpu.payload.writeData = 8; end
        5: begin cpu.payload.addr = dmaEntry; cpu.payload.write = True;
            cpu.payload.writeData = 32'h0000_3000; end
        6: begin cpu.payload.addr = dmaEntry + 8; cpu.payload.write = True;
            cpu.payload.writeData = 7; end
        default: begin cpu.payload.addr = dmaEntry + 12; end
    endcase
    return cpu;
endfunction

typedef enum { DcReset, DcBus, DcActive, DcRetire, DcDone }
    DmaCsrStage deriving (Bits, Eq, FShow);

(* synthesize *)
module mkTbMainboardLightingPlio0DmaCsr(Empty);
    MainboardFPGAIfc board <- mkMainboardFPGA;
    Reg#(DmaCsrStage) stage <- mkReg(DcReset);
    Reg#(Bit#(4)) operation <- mkReg(0);
    Reg#(Bit#(16)) watchdog <- mkReg(0);

    rule tick;
        watchdog <= watchdog + 1;
        if (watchdog == 2000) begin
            $display("FAIL|lighting-plio0-dma-csr|watchdog|stage=%0d|op=%0d",
                pack(stage), operation);
            $finish(1);
        end
    endrule

    rule driveEpoch (stage != DcDone && board.debugAdvanceReady);
        LightingBusMasterDrive cpu = lightingBusMasterDriveDefault();
        Bool reset = stage == DcReset;
        if (stage == DcBus) cpu = dmaOperation(operation, False);
        else if (stage == DcActive) cpu = dmaOperation(operation, True);
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, reset);

        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            False, False, False, False, 0, reset);

        if (reset) stage <= DcBus;
        else if (stage == DcBus) begin
            if (!bus.busGrant || bus.ready || bus.error) begin
                $display("FAIL|lighting-plio0-dma-csr|grant|op=%0d|grant=%0d|ready=%0d|error=%0d",
                    operation, pack(bus.busGrant), pack(bus.ready), pack(bus.error));
                $finish(1);
            end
            stage <= DcActive;
        end
        else if (stage == DcActive && bus.ready) begin
            if (bus.error) begin
                $display("FAIL|lighting-plio0-dma-csr|response|op=%0d",
                    operation);
                $finish(1);
            end
            if (operation == 3 && bus.readData != 0) begin
                $display("FAIL|lighting-plio0-dma-csr|first-generation|value=%0d",
                    bus.readData);
                $finish(1);
            end
            if (operation == 7 && bus.readData != 1) begin
                $display("FAIL|lighting-plio0-dma-csr|rebind-generation|value=%0d",
                    bus.readData);
                $finish(1);
            end
            stage <= DcRetire;
        end
        else if (stage == DcRetire) begin
            if (operation == 7) stage <= DcDone;
            else begin operation <= operation + 1; stage <= DcBus; end
        end
    endrule

    rule done (stage == DcDone);
        $display("MAINBOARDPLIO0DMACSR|slot=1|channel=3|bind=ok|revoke=ok|generation=1");
        $display("PASS|lighting-plio0-dma-csr|CPU programs frozen DMA table through Mainboard host state");
        $finish(0);
    endrule
endmodule

endpackage
