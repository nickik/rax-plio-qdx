package TbMainboardLightingPlio0ClaimReset;

import Vector::*;
import QLITypes::*;
import QICInterfaces::*;
import PLIOTx::*;
import PLIOWorkerHost::*;
import LightingMemoryBusCompat::*;
import MainboardFPGA::*;

Bit#(32) plio0Base = 32'hffe0_0000;
Bit#(5) notificationIndex = 22; // slot 5, channel 2
Bit#(32) notificationMask = 32'h0040_0000;
Bit#(32) notificationPayload = 32'hfeed_beef;

function Bit#(4) parity(Bit#(32) word);
    return { ~(^word[31:24]), ~(^word[23:16]),
             ~(^word[15:8]), ~(^word[7:0]) };
endfunction

function BackplaneDrive notificationRequest();
    BackplaneDrive d = backplaneDriveDefault();
    d.request = True;
    return d;
endfunction

function BackplaneDrive notificationAddress(Bit#(2) channel);
    BackplaneDrive d = notificationRequest();
    Bit#(32) address = zeroExtend(channel) << 2;
    d.adParValid = True; d.ad = address; d.parity = parity(address);
    d.controlValid = True; d.control.space = pack(PlioController);
    d.control.addressStrobe = True; d.control.read = False;
    d.control.byteEnable = 4'hf; d.control.burstLen = pack(BurstOne);
    return d;
endfunction

function BackplaneDrive notificationData(Bit#(32) data);
    BackplaneDrive d = notificationRequest();
    d.adParValid = True; d.ad = data; d.parity = parity(data);
    d.controlValid = True; d.control.dataStrobe = True;
    d.control.byteEnable = 4'hf;
    return d;
endfunction

function Vector#(8, BackplaneDrive) idleCards();
    return replicate(backplaneDriveDefault());
endfunction

function HostWorkerRequest noWorkerRequest();
    return HostWorkerRequest { slot: 0, address: 0, width: HostW32,
                               write: False, value: 0 };
endfunction

function LightingBusMasterDrive cpuFor(Bit#(4) op, Bool active);
    LightingBusMasterDrive cpu = lightingBusMasterDriveDefault();
    cpu.busRequest = True;
    cpu.request = active;
    cpu.payload.byteEnable = 4'hf;
    case (op)
        0: begin cpu.payload.addr = plio0Base + 32'h100;
                 cpu.payload.write = True; cpu.payload.writeData = 32'h8000_0000; end
        1: begin cpu.payload.addr = plio0Base + 32'h18;
                 cpu.payload.write = True; cpu.payload.writeData = notificationMask; end
        2: begin cpu.payload.addr = plio0Base + 32'h1c;
                 cpu.payload.write = True; cpu.payload.writeData = 0; end
        3: begin cpu.payload.addr = plio0Base + 32'h458;
                 cpu.payload.write = True; cpu.payload.writeData = 32'ha; end
        4: begin cpu.payload.addr = plio0Base + 32'h14; cpu.payload.write = False; end
        5: begin cpu.payload.addr = plio0Base + 32'h20; cpu.payload.write = False; end
        6: begin cpu.payload.addr = plio0Base + 32'h24; cpu.payload.write = False; end
        7: begin cpu.payload.addr = plio0Base + 32'h0c;
                 cpu.payload.write = True; cpu.payload.writeData = 32'h3; end
        8: begin cpu.payload.addr = plio0Base + 32'h100; cpu.payload.write = False; end
        9: begin cpu.payload.addr = plio0Base + 32'h20; cpu.payload.write = False; end
        default: begin cpu.payload.addr = plio0Base + 32'h14; cpu.payload.write = False; end
    endcase
    return cpu;
endfunction

typedef enum { CpReset, CpBus, CpActive, CpWait, CpRetire,
               CpNotifyRequest, CpNotifyAddress, CpNotifyData, CpDone }
    ClaimPhase deriving (Bits, Eq, FShow);

module mkTbMainboardLightingPlio0ClaimReset(Empty);
    MainboardFPGAIfc board <- mkMainboardFPGA;
    Reg#(ClaimPhase) phase <- mkReg(CpReset);
    Reg#(Bit#(4)) operation <- mkReg(0);
    Reg#(Bit#(16)) watchdog <- mkReg(0);

    rule tick (phase != CpDone);
        watchdog <= watchdog + 1;
        if (watchdog == 4000) begin
            $display("FAIL|lighting-plio0-claim-reset|watchdog|phase=%0d|op=%0d",
                pack(phase), operation);
            $finish(1);
        end
    endrule

    rule driveCpu ((phase == CpReset || phase == CpBus || phase == CpActive
                   || phase == CpWait || phase == CpRetire)
                   && board.debugAdvanceReady);
        Bool reset = phase == CpReset;
        Bool active = phase == CpActive || phase == CpWait;
        LightingBusMasterDrive cpu = active ? cpuFor(operation, True)
            : (phase == CpBus ? cpuFor(operation, False)
               : lightingBusMasterDriveDefault());
        Vector#(8, BackplaneDrive) cards = idleCards();
        LightingBusInputs bus = board.lightingMemory(cards, cpu, reset);
        board.advance(cards, cpu, False, noWorkerRequest(),
            False, False, False, False, 0, reset);

        if (reset) phase <= CpBus;
        else if (phase == CpBus) begin
            if (!bus.busGrant || bus.ready || bus.error) begin
                $display("FAIL|lighting-plio0-claim-reset|grant|op=%0d|grant=%0d|ready=%0d|error=%0d",
                    operation, pack(bus.busGrant), pack(bus.ready), pack(bus.error));
                $finish(1);
            end
            phase <= CpActive;
        end
        else if (phase == CpActive) phase <= CpWait;
        else if (phase == CpWait && bus.ready) begin
            if (bus.error) begin
                $display("FAIL|lighting-plio0-claim-reset|mmio-error|op=%0d", operation);
                $finish(1);
            end
            if (operation == 4 && bus.readData != notificationMask) begin
                $display("FAIL|lighting-plio0-claim-reset|pending|data=%08x", bus.readData);
                $finish(1);
            end
            if (operation == 5 && bus.readData != 32'h0000_0156) begin
                $display("FAIL|lighting-plio0-claim-reset|claim|data=%08x", bus.readData);
                $finish(1);
            end
            if (operation == 6 && bus.readData != notificationPayload) begin
                $display("FAIL|lighting-plio0-claim-reset|claim-data|data=%08x", bus.readData);
                $finish(1);
            end
            if (operation == 8 && bus.readData != 0) begin
                $display("FAIL|lighting-plio0-claim-reset|reset-map|data=%08x", bus.readData);
                $finish(1);
            end
            if (operation == 9 && bus.readData != 32'hffff_ffff) begin
                $display("FAIL|lighting-plio0-claim-reset|reset-claim|data=%08x", bus.readData);
                $finish(1);
            end
            if (operation == 10 && bus.readData != 0) begin
                $display("FAIL|lighting-plio0-claim-reset|reset-pending|data=%08x", bus.readData);
                $finish(1);
            end
            phase <= CpRetire;
        end
        else if (phase == CpRetire) begin
            if (operation == 3) phase <= CpNotifyRequest;
            else if (operation == 10) phase <= CpDone;
            else begin operation <= operation + 1; phase <= CpBus; end
        end
    endrule

    rule notifyRequest (phase == CpNotifyRequest && board.debugAdvanceReady);
        Vector#(8, BackplaneDrive) cards = idleCards(); cards[5] = notificationRequest();
        board.advance(cards, lightingBusMasterDriveDefault(), False, noWorkerRequest(),
            False, False, False, False, 0, False);
        phase <= CpNotifyAddress;
    endrule

    rule notifyAddress (phase == CpNotifyAddress && board.debugAdvanceReady);
        Vector#(8, BackplaneDrive) cards = idleCards(); cards[5] = notificationAddress(2);
        Vector#(8, PlioIn) pins = board.plioSlots(cards, False);
        if (!pins[5].ack) begin
            $display("FAIL|lighting-plio0-claim-reset|notification-address-ack");
            $finish(1);
        end
        board.advance(cards, lightingBusMasterDriveDefault(), False, noWorkerRequest(),
            False, False, False, False, 0, False);
        phase <= CpNotifyData;
    endrule

    rule notifyData (phase == CpNotifyData && board.debugAdvanceReady);
        Vector#(8, BackplaneDrive) cards = idleCards(); cards[5] = notificationData(notificationPayload);
        Vector#(8, PlioIn) pins = board.plioSlots(cards, False);
        if (!pins[5].ack) begin
            $display("FAIL|lighting-plio0-claim-reset|notification-data-ack");
            $finish(1);
        end
        board.advance(cards, lightingBusMasterDriveDefault(), False, noWorkerRequest(),
            False, False, False, False, 0, False);
        operation <= 4; phase <= CpBus;
    endrule

    rule done (phase == CpDone);
        $display("MAINBOARDPLIO0CLAIMRESET|physical_notification=ok|slot=5|channel=2|payload=%08x|claim=mmio|reset=clears-map-pending", notificationPayload);
        $display("PASS|lighting-plio0-claim-reset|CPU MMIO configures, claims, and resets Mainboard PLIO controller state");
        $finish(0);
    endrule
endmodule

endpackage
