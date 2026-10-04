package TbMainboardLightingPlio0NotifyClaim;

import Vector::*;
import QLITypes::*;
import QICInterfaces::*;
import PLIOTx::*;
import PLIOWorkerHost::*;
import LightingMemoryBusCompat::*;
import MainboardFPGA::*;

Bit#(32) notifyConfig = 32'hffe0_1860; // slot 1, channel 2
Bit#(32) claimSource = 32'hffe0_1a00;
Bit#(32) claimPayload = 32'hffe0_1a04;

function Bit#(4) tbParity(Bit#(32) word);
    return { ~(^word[31:24]), ~(^word[23:16]),
        ~(^word[15:8]), ~(^word[7:0]) };
endfunction

function Vector#(8, BackplaneDrive) idleCards();
    return replicate(backplaneDriveDefault());
endfunction

function Vector#(8, BackplaneDrive) card1(BackplaneDrive drive);
    Vector#(8, BackplaneDrive) cards = idleCards();
    cards[1] = drive;
    return cards;
endfunction

function BackplaneDrive requestOnly();
    BackplaneDrive drive = backplaneDriveDefault();
    drive.request = True;
    return drive;
endfunction

function BackplaneDrive notificationAddress();
    BackplaneDrive drive = requestOnly();
    BackplaneControl control = backplaneControlDefault();
    Bit#(32) address = 8;
    control.space = pack(PlioController);
    control.addressStrobe = True;
    control.byteEnable = 4'hf;
    control.burstLen = pack(BurstOne);
    drive.controlValid = True;
    drive.control = control;
    drive.adParValid = True;
    drive.ad = address;
    drive.parity = tbParity(address);
    return drive;
endfunction

function BackplaneDrive notificationData();
    BackplaneDrive drive = requestOnly();
    BackplaneControl control = backplaneControlDefault();
    control.dataStrobe = True;
    control.byteEnable = 4'hf;
    drive.controlValid = True;
    drive.control = control;
    drive.adParValid = True;
    drive.ad = 32'hfeed_beef;
    drive.parity = tbParity(32'hfeed_beef);
    return drive;
endfunction

function HostWorkerRequest noWorkerRequest();
    return HostWorkerRequest {
        slot: 0, address: 0, width: HostW32, write: False, value: 0
    };
endfunction

function LightingBusMasterDrive cpuOperation(Bit#(2) operation, Bool request);
    LightingBusMasterDrive cpu = lightingBusMasterDriveDefault();
    cpu.busRequest = True;
    cpu.request = request;
    cpu.payload.byteEnable = 4'hf;
    case (operation)
        0: begin
            cpu.payload.addr = notifyConfig;
            cpu.payload.write = True;
            cpu.payload.writeData = 32'h0000_0071;
        end
        1: cpu.payload.addr = claimSource;
        2: cpu.payload.addr = claimPayload;
        default: cpu.payload.addr = notifyConfig + 4;
    endcase
    return cpu;
endfunction

typedef enum {
    NcReset, NcCpuBus, NcCpuActive, NcCpuRetire,
    NcRequest, NcAddress, NcData, NcSettle, NcDone
} NotifyClaimStage deriving (Bits, Eq, FShow);

(* synthesize *)
module mkTbMainboardLightingPlio0NotifyClaim(Empty);
    MainboardFPGAIfc board <- mkMainboardFPGA;
    Reg#(NotifyClaimStage) stage <- mkReg(NcReset);
    Reg#(Bit#(2)) operation <- mkReg(0);
    Reg#(Bit#(16)) watchdog <- mkReg(0);

    rule tick;
        watchdog <= watchdog + 1;
        if (watchdog == 3000) begin
            $display("FAIL|lighting-plio0-notify-claim|watchdog|stage=%0d|op=%0d",
                pack(stage), operation);
            $finish(1);
        end
    endrule

    rule driveEpoch (stage != NcDone && board.debugAdvanceReady);
        Vector#(8, BackplaneDrive) cards = idleCards();
        LightingBusMasterDrive cpu = lightingBusMasterDriveDefault();
        Bool reset = stage == NcReset;
        if (stage == NcCpuBus) cpu = cpuOperation(operation, False);
        else if (stage == NcCpuActive) cpu = cpuOperation(operation, True);
        else if (stage == NcRequest) cards = card1(requestOnly());
        else if (stage == NcAddress) cards = card1(notificationAddress());
        else if (stage == NcData) cards = card1(notificationData());

        LightingBusInputs bus = board.lightingMemory(cards, cpu, reset);
        Vector#(8, PlioIn) slots = board.plioSlots(cards, reset);
        let irqs = board.interrupts(False, False);
        board.advance(cards, cpu, False, noWorkerRequest(),
            False, False, False, False, 0, reset);

        if (reset) stage <= NcCpuBus;
        else if (stage == NcCpuBus) begin
            if (!bus.busGrant || bus.ready || bus.error) begin
                $display("FAIL|lighting-plio0-notify-claim|grant|op=%0d", operation);
                $finish(1);
            end
            stage <= NcCpuActive;
        end
        else if (stage == NcCpuActive && bus.ready) begin
            if (bus.error) begin
                $display("FAIL|lighting-plio0-notify-claim|response|op=%0d", operation);
                $finish(1);
            end
            if (operation == 1 && bus.readData != 32'h8000_0392) begin
                $display("FAIL|lighting-plio0-notify-claim|source|value=%08x", bus.readData);
                $finish(1);
            end
            if (operation == 2 && bus.readData != 32'hfeed_beef) begin
                $display("FAIL|lighting-plio0-notify-claim|payload|value=%08x", bus.readData);
                $finish(1);
            end
            if (operation == 3 && bus.readData != 0) begin
                $display("FAIL|lighting-plio0-notify-claim|pending-after-claim|value=%08x", bus.readData);
                $finish(1);
            end
            stage <= NcCpuRetire;
        end
        else if (stage == NcCpuRetire) begin
            if (operation == 0) stage <= NcRequest;
            else if (operation == 3) begin
                if (irqs.plioIrq) begin
                    $display("FAIL|lighting-plio0-notify-claim|irq-not-cleared");
                    $finish(1);
                end
                stage <= NcDone;
            end
            else begin operation <= operation + 1; stage <= NcCpuBus; end
        end
        else if (stage == NcRequest) stage <= NcAddress;
        else if (stage == NcAddress) begin
            if (!slots[1].ack || slots[1].err) begin
                $display("FAIL|lighting-plio0-notify-claim|notification-address");
                $finish(1);
            end
            stage <= NcData;
        end
        else if (stage == NcData) begin
            if (!slots[1].ack || slots[1].err) begin
                $display("FAIL|lighting-plio0-notify-claim|notification-data");
                $finish(1);
            end
            stage <= NcSettle;
        end
        else if (stage == NcSettle) begin
            if (!irqs.plioIrq) begin
                $display("FAIL|lighting-plio0-notify-claim|irq-not-raised");
                $finish(1);
            end
            operation <= 1;
            stage <= NcCpuBus;
        end
    endrule

    rule done (stage == NcDone);
        $display("MAINBOARDPLIO0NOTIFY|slot=1|channel=2|class=7|payload=feedbeef|claim=atomic");
        $display("PASS|lighting-plio0-notify-claim|CPU configures and atomically claims one card notification");
        $finish(0);
    endrule
endmodule

endpackage
