package TbMainboardByteEnable;

import Vector::*;
import QLITypes::*;
import QICInterfaces::*;
import PLIOWorkerHost::*;
import MemoryController::*;
import LightingMemoryBusCompat::*;
import MainboardFPGA::*;

function Vector#(8, BackplaneDrive) idleCards();
    return replicate(backplaneDriveDefault());
endfunction

function HostWorkerRequest noWorkerRequest();
    return HostWorkerRequest { slot: 0, address: 0, width: HostW32, write: False, value: 0 };
endfunction

function LightingBusMasterDrive cpuBusRequest();
    LightingBusMasterDrive d = lightingBusMasterDriveDefault();
    d.busRequest = True;
    return d;
endfunction

function LightingBusMasterDrive cpuWrite(Bit#(4) be, Bit#(32) data);
    LightingBusMasterDrive d = cpuBusRequest();
    d.request = True;
    d.payload.addr = 32'h0000_0100;
    d.payload.write = True;
    d.payload.writeData = data;
    d.payload.byteEnable = be;
    return d;
endfunction

function LightingBusMasterDrive cpuRead();
    LightingBusMasterDrive d = cpuBusRequest();
    d.request = True;
    d.payload.addr = 32'h0000_0100;
    d.payload.write = False;
    d.payload.writeData = 0;
    d.payload.byteEnable = 4'hf;
    return d;
endfunction

function Bit#(4) caseMask(Bit#(4) n);
    case (n)
        0: return 4'h1;
        1: return 4'h2;
        2: return 4'h4;
        3: return 4'h8;
        4: return 4'h3;
        5: return 4'hc;
        6: return 4'h5;
        7: return 4'ha;
        8: return 4'h0;
        default: return 4'hf;
    endcase
endfunction

function Bit#(32) caseData(Bit#(4) n);
    case (n)
        0,1,2,3: return 32'haabb_ccdd;
        4: return 32'h0102_0304;
        5: return 32'h1122_3344;
        6: return 32'hdead_beef;
        7: return 32'h5566_7788;
        8: return 32'hffff_ffff;
        default: return 32'hcafe_babe;
    endcase
endfunction

function Bit#(32) caseExpected(Bit#(4) n);
    case (n)
        0: return 32'h1122_33dd;
        1: return 32'h1122_ccdd;
        2: return 32'h11bb_ccdd;
        3: return 32'haabb_ccdd;
        4: return 32'haabb_0304;
        5: return 32'h1122_0304;
        6: return 32'h11ad_03ef;
        7: return 32'h55ad_77ef;
        8: return 32'h55ad_77ef;
        default: return 32'hcafe_babe;
    endcase
endfunction

typedef enum { BeReset, BeResetDrain, BeSeed, BeGrant, BeActive, BeWait, BeReadGrant, BeReadActive, BeReadWait, BeDone } BeStage deriving (Bits, Eq, FShow);

module mkTbMainboardByteEnable(Empty);
    MainboardFPGAIfc board <- mkMainboardFPGA;
    FakeMemoryBackendIfc ram <- mkFakeMemoryBackend(8'd2);
    Reg#(BeStage) stage <- mkReg(BeReset);
    Reg#(Bit#(4)) caseNo <- mkReg(0);
    Reg#(Bit#(8)) watchdog <- mkReg(0);

    rule forwardBackendRequest (stage != BeReset && board.memoryBackendRequestValid && ram.requestReady);
        ram.acceptRequest(board.memoryBackendWrite, board.memoryBackendAddress,
            board.memoryBackendByteEnable, board.memoryBackendWriteData);
    endrule

    rule forwardBackendResponse (stage != BeReset && board.memoryBackendResponseReady && ram.responseValid);
        ram.responseConsumed;
    endrule

    rule resetSubmit (stage == BeReset);
        board.advance(idleCards(), lightingBusMasterDriveDefault(), False, noWorkerRequest(),
            False, False, False, False, 0, True);
        ram.resetBackend;
        stage <= BeResetDrain;
    endrule

    rule resetDrain (stage == BeResetDrain);
        stage <= BeSeed;
    endrule

    rule seed (stage == BeSeed);
        ram.preload(32'h0000_0100, 32'h1122_3344);
        caseNo <= 0;
        stage <= BeGrant;
    endrule

    rule grant (stage == BeGrant);
        LightingBusMasterDrive cpu = cpuBusRequest();
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL|mainboard-be|case=%0d|phase=grant", caseNo); $finish(1);
        end
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        stage <= BeActive;
    endrule

    rule active (stage == BeActive);
        Bit#(4) be = caseMask(caseNo);
        Bit#(32) data = caseData(caseNo);
        LightingBusMasterDrive cpu = cpuWrite(be, data);
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL|mainboard-be|case=%0d|phase=active|be=%x", caseNo, be); $finish(1);
        end
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        watchdog <= 0;
        stage <= BeWait;
    endrule

    rule waitWrite (stage == BeWait);
        Bit#(4) be = caseMask(caseNo);
        Bit#(32) data = caseData(caseNo);
        LightingBusMasterDrive cpu = cpuWrite(be, data);
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        if (!bus.busGrant || bus.error) begin
            $display("FAIL|mainboard-be|case=%0d|phase=wait|be=%x", caseNo, be); $finish(1);
        end
        if (board.memoryBackendRequestValid && board.memoryBackendByteEnable != be) begin
            $display("FAIL|mainboard-be|case=%0d|backend-be=%x|expected=%x", caseNo, board.memoryBackendByteEnable, be); $finish(1);
        end
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        if (bus.ready) begin
            Bit#(32) expected = caseExpected(caseNo);
            Bit#(32) actual = ram.peek(32'h0000_0100);
            if (actual != expected) begin
                $display("FAIL|mainboard-be|case=%0d|be=%x|actual=%08x|expected=%08x", caseNo, be, actual, expected); $finish(1);
            end
            $display("MAINBOARDBETRACE|v1|case=%0d|be=%x|value=%08x|status=ok", caseNo, be, actual);
            if (caseNo == 9) stage <= BeReadGrant;
            else begin caseNo <= caseNo + 1; stage <= BeGrant; end
        end else begin
            watchdog <= watchdog + 1;
            if (watchdog == 80) begin $display("FAIL|mainboard-be|case=%0d|watchdog", caseNo); $finish(1); end
        end
    endrule

    rule readGrant (stage == BeReadGrant);
        LightingBusMasterDrive cpu = cpuBusRequest();
        if (!board.lightingMemory(idleCards(), cpu, False).busGrant) begin $display("FAIL|mainboard-be|read-grant"); $finish(1); end
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        stage <= BeReadActive;
    endrule

    rule readActive (stage == BeReadActive);
        LightingBusMasterDrive cpu = cpuRead();
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin $display("FAIL|mainboard-be|read-active"); $finish(1); end
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        watchdog <= 0;
        stage <= BeReadWait;
    endrule

    rule readWait (stage == BeReadWait);
        LightingBusMasterDrive cpu = cpuRead();
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        if (!bus.busGrant || bus.error) begin $display("FAIL|mainboard-be|read-wait"); $finish(1); end
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            ram.requestReady, ram.responseValid, ram.responseFault,
            ram.responseReadDataValid, ram.responseReadData, False);
        if (bus.ready) begin
            if (bus.readData != 32'hcafe_babe) begin $display("FAIL|mainboard-be|readback=%08x|expected=cafebabe", bus.readData); $finish(1); end
            stage <= BeDone;
        end else begin
            watchdog <= watchdog + 1;
            if (watchdog == 80) begin $display("FAIL|mainboard-be|read-watchdog"); $finish(1); end
        end
    endrule

    rule done (stage == BeDone);
        $display("PASS mainboard CPU byte/halfword/non-contiguous byte-enable integration");
        $finish(0);
    endrule
endmodule

endpackage
