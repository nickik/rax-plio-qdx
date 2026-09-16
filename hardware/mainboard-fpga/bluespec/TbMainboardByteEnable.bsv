package TbMainboardByteEnable;

import Vector::*;
import QLITypes::*;
import QICInterfaces::*;
import PLIOTx::*;
import PLIOWorkerHost::*;
import MainboardFPGA::*;
import LightingMemoryBusCompat::*;

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

function LightingBusMasterDrive cpuRequest(Bit#(32) addr, Bit#(4) be, Bit#(32) data);
    LightingBusMasterDrive cpu = lightingBusMasterDriveDefault();
    cpu.busRequest = True;
    cpu.request = True;
    cpu.payload = LightingBusPayload {
        addr: addr,
        writeData: data,
        byteEnable: be,
        write: True
    };
    return cpu;
endfunction

(* synthesize *)
module mkTbMainboardByteEnable(Empty);
    MainboardFPGAIfc dut <- mkMainboardFPGA;
    Reg#(Bit#(5)) phase <- mkReg(0);
    Reg#(Bit#(4)) maskIndex <- mkReg(0);
    Reg#(Bit#(8)) heldCycles <- mkReg(0);
    Reg#(Bit#(32)) watchdog <- mkReg(0);

    Vector#(10, Bit#(4)) masks = vec(4'b0001, 4'b0010, 4'b0100, 4'b1000,
        4'b0011, 4'b1100, 4'b0101, 4'b1010, 4'b0000, 4'b1111);

    rule tick;
        watchdog <= watchdog + 1;
        if (watchdog == 10000) begin
            $display("FAIL|byte-enable|watchdog phase=%0d maskIndex=%0d", phase, maskIndex);
            $finish(1);
        end
    endrule

    rule issueMask (phase == 0 && maskIndex < 10 && dut.debugAdvanceReady);
        Bit#(4) be = masks[maskIndex];
        Bit#(32) addr = 32'h00001000 + zeroExtend(maskIndex) * 4;
        Bit#(32) data = 32'ha5a50000 | zeroExtend(be);
        dut.advance(idleCards(), cpuRequest(addr, be, data), False, noWorkerRequest(),
            False, False, False, False, 0, False);
        phase <= 1;
    endrule

    rule waitBackend (phase == 1);
        Bit#(4) be = masks[maskIndex];
        Bit#(32) addr = 32'h00001000 + zeroExtend(maskIndex) * 4;
        Bit#(32) data = 32'ha5a50000 | zeroExtend(be);
        if (dut.memoryBackendRequestValid) begin
            if (dut.memoryBackendAddress != addr || !dut.memoryBackendWrite
                || dut.memoryBackendWriteData != data
                || dut.memoryBackendByteEnable != be) begin
                $display("FAIL|byte-enable|forward mask=%04b addr=%08h/%08h data=%08h/%08h be=%04b",
                    be, dut.memoryBackendAddress, addr,
                    dut.memoryBackendWriteData, data, dut.memoryBackendByteEnable);
                $finish(1);
            end
            heldCycles <= 0;
            phase <= 2;
        end
    endrule

    rule proveStable (phase == 2 && heldCycles < 4);
        Bit#(4) be = masks[maskIndex];
        Bit#(32) addr = 32'h00001000 + zeroExtend(maskIndex) * 4;
        Bit#(32) data = 32'ha5a50000 | zeroExtend(be);
        if (!dut.memoryBackendRequestValid
            || dut.memoryBackendAddress != addr
            || !dut.memoryBackendWrite
            || dut.memoryBackendWriteData != data
            || dut.memoryBackendByteEnable != be) begin
            $display("FAIL|byte-enable|backpressure mask=%04b cycle=%0d valid=%0d addr=%08h data=%08h be=%04b",
                be, heldCycles, dut.memoryBackendRequestValid,
                dut.memoryBackendAddress, dut.memoryBackendWriteData,
                dut.memoryBackendByteEnable);
            $finish(1);
        end
        heldCycles <= heldCycles + 1;
    endrule

    rule acceptBackend (phase == 2 && heldCycles == 4 && dut.debugAdvanceReady);
        dut.advance(idleCards(), lightingBusMasterDriveDefault(), False, noWorkerRequest(),
            True, False, False, False, 0, False);
        phase <= 3;
    endrule

    rule waitResponseReady (phase == 3 && dut.debugAdvanceReady);
        if (dut.memoryBackendResponseReady) begin
            dut.advance(idleCards(), lightingBusMasterDriveDefault(), False, noWorkerRequest(),
                False, True, False, False, 0, False);
            phase <= 4;
        end
        else begin
            dut.advance(idleCards(), lightingBusMasterDriveDefault(), False, noWorkerRequest(),
                False, False, False, False, 0, False);
        end
    endrule

    rule retire (phase == 4 && dut.debugAdvanceReady);
        dut.advance(idleCards(), lightingBusMasterDriveDefault(), False, noWorkerRequest(),
            False, False, False, False, 0, False);
        $display("MAINBOARDBETRACE|mask=%04b|status=ok", masks[maskIndex]);
        if (maskIndex == 9) begin
            $display("PASS|byte-enable|CPU to Mainboard to MemoryController propagation and backpressure stability");
            $finish(0);
        end
        else begin
            maskIndex <= maskIndex + 1;
            phase <= 0;
        end
    endrule
endmodule

endpackage
