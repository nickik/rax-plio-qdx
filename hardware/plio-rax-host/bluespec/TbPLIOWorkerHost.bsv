package TbPLIOWorkerHost;

import QLITypes::*;
import QICInterfaces::*;
import PLIOWorkerHost::*;

typedef enum {
    CRead32,
    CWrite16,
    CWaitRead8,
    CAddressErr,
    CDataErr,
    CBadParity,
    CTimeout,
    CResetAddress,
    CResetData,
    CDone
} HostCase deriving (Bits, Eq, FShow);

function HostWorkerRequest requestFor(HostCase c);
    HostWorkerRequest r = HostWorkerRequest { slot: 0, address: 32'h100, width: HostW32, write: False, value: 0 };
    case (c)
        CRead32: r = HostWorkerRequest { slot: 2, address: 32'h100, width: HostW32, write: False, value: 0 };
        CWrite16: r = HostWorkerRequest { slot: 1, address: 32'h102, width: HostW16, write: True, value: 32'hbeef };
        CWaitRead8: r = HostWorkerRequest { slot: 0, address: 32'h101, width: HostW8, write: False, value: 0 };
        CBadParity: r = HostWorkerRequest { slot: 0, address: 32'h101, width: HostW8, write: False, value: 0 };
        CDataErr: r = HostWorkerRequest { slot: 0, address: 32'h100, width: HostW32, write: True, value: 32'h1122_3344 };
        default: r = r;
    endcase
    return r;
endfunction

function HostCase nextCase(HostCase c);
    case (c)
        CRead32: return CWrite16;
        CWrite16: return CWaitRead8;
        CWaitRead8: return CAddressErr;
        CAddressErr: return CDataErr;
        CDataErr: return CBadParity;
        CBadParity: return CTimeout;
        CTimeout: return CResetAddress;
        CResetAddress: return CResetData;
        CResetData: return CDone;
        default: return CDone;
    endcase
endfunction

module mkTbPLIOWorkerHost(Empty);
    PLIOWorkerHostIfc host <- mkPLIOWorkerHost;
    Reg#(HostCase) testCase <- mkReg(CRead32);
    Reg#(Bool) launched <- mkReg(False);
    Reg#(Bit#(9)) addressWaits <- mkReg(0);
    Reg#(Bit#(9)) dataWaits <- mkReg(0);

    rule launch (!launched && testCase != CDone && host.ready);
        host.start(requestFor(testCase));
        launched <= True;
        addressWaits <= 0;
        dataWaits <= 0;
    endrule

    rule run (launched && !host.completionValid);
        HostWorkerState s = host.debugState;
        PlioIn bus = host.drive(False);
        PlioOut card = plioOutDefault();
        Bool reset = False;

        if (s != HostIdle) begin
            if (!host.selectedSlotValid || !bus.selected || bus.burst != BurstOne) begin
                $display("FAIL host did not select one worker transaction");
                $finish(1);
            end
        end

        case (testCase)
            CRead32: begin
                if (s == HostAddress) begin
                    if (host.selectedSlot != 2 || !bus.addressStrobe || !bus.spaceValid || bus.space != PlioWorker
                        || !bus.adValid || bus.ad != 32'h100 || bus.parity != hostOddParity32(32'h100)
                        || !bus.read || bus.byteEnable != 4'hf) begin
                        $display("FAIL read32 address image"); $finish(1);
                    end
                    card.ack = True;
                end
                else if (s == HostData) begin
                    if (!bus.dataStrobe || bus.adValid || !bus.read) begin $display("FAIL read32 data image"); $finish(1); end
                    card.ack = True; card.adValid = True; card.ad = 32'hdead_beef;
                    card.parValid = True; card.parity = hostOddParity32(card.ad);
                end
            end
            CWrite16: begin
                if (s == HostAddress) begin
                    if (host.selectedSlot != 1 || bus.ad != 32'h102 || bus.byteEnable != 4'b1100 || bus.read) begin
                        $display("FAIL write16 address image"); $finish(1);
                    end
                    card.ack = True;
                end
                else if (s == HostData) begin
                    if (!bus.dataStrobe || !bus.adValid || bus.ad != 32'hbeef_0000 || bus.byteEnable != 4'b1100
                        || bus.parity != hostOddParity32(32'hbeef_0000)) begin
                        $display("FAIL write16 data image"); $finish(1);
                    end
                    card.ack = True;
                end
            end
            CWaitRead8: begin
                if (s == HostAddress) begin
                    if (bus.ad != 32'h101 || bus.byteEnable != 4'b0010) begin $display("FAIL wait read8 address stability"); $finish(1); end
                    if (addressWaits < 2) addressWaits <= addressWaits + 1;
                    else card.ack = True;
                end
                else if (s == HostData) begin
                    if (dataWaits < 2) dataWaits <= dataWaits + 1;
                    else begin
                        card.ack = True; card.adValid = True; card.ad = 32'h1234_5a78;
                        card.parValid = True; card.parity = hostOddParity32(card.ad);
                    end
                end
            end
            CAddressErr: if (s == HostAddress) card.err = True;
            CDataErr: begin
                if (s == HostAddress) card.ack = True;
                else if (s == HostData) card.err = True;
            end
            CBadParity: begin
                if (s == HostAddress) card.ack = True;
                else if (s == HostData) begin
                    card.ack = True; card.adValid = True; card.ad = 32'h0000_5a00;
                    card.parValid = True; card.parity = hostOddParity32(card.ad) ^ 4'b0010;
                end
            end
            CTimeout: noAction;
            CResetAddress: if (s == HostAddress) reset = True;
            CResetData: begin
                if (s == HostAddress) card.ack = True;
                else if (s == HostData) reset = True;
            end
            default: noAction;
        endcase

        host.advance(card, reset);
    endrule

    rule finishCase (launched && host.completionValid);
        HostWorkerCompletion c = host.completion;
        case (testCase)
            CRead32: begin
                if (c.status != HostSuccess || c.data != 32'hdead_beef) begin $display("FAIL read32 completion"); $finish(1); end
                $display("PLIOHOSTTRACE|v1|case=read32|status=ok|slot=2|value=deadbeef");
            end
            CWrite16: begin
                if (c.status != HostSuccess) begin $display("FAIL write16 completion"); $finish(1); end
                $display("PLIOHOSTTRACE|v1|case=write16|status=ok|slot=1|bus=beef0000");
            end
            CWaitRead8: begin
                if (c.status != HostSuccess || c.data != 32'h5a || addressWaits != 2 || dataWaits != 2) begin
                    $display("FAIL wait read8 completion"); $finish(1);
                end
                $display("PLIOHOSTTRACE|v1|case=wait_read8|status=ok|addr_wait=2|data_wait=2|value=5a");
            end
            CAddressErr: begin
                if (c.status != HostBusError) begin $display("FAIL address error completion"); $finish(1); end
                $display("PLIOHOSTTRACE|v1|case=address_err|status=bus_error");
            end
            CDataErr: begin
                if (c.status != HostBusError) begin $display("FAIL data error completion"); $finish(1); end
                $display("PLIOHOSTTRACE|v1|case=data_err|status=bus_error");
            end
            CBadParity: begin
                if (c.status != HostParityError) begin $display("FAIL bad parity completion"); $finish(1); end
                $display("PLIOHOSTTRACE|v1|case=bad_parity|status=parity_error");
            end
            CTimeout: begin
                if (c.status != HostTimeout) begin $display("FAIL timeout completion"); $finish(1); end
                $display("PLIOHOSTTRACE|v1|case=timeout|phase=address|cycles=256");
            end
            CResetAddress: begin
                if (c.status != HostReset) begin $display("FAIL reset-address completion"); $finish(1); end
                $display("PLIOHOSTTRACE|v1|case=reset_address|status=reset");
            end
            CResetData: begin
                if (c.status != HostReset) begin $display("FAIL reset-data completion"); $finish(1); end
                $display("PLIOHOSTTRACE|v1|case=reset_data|status=reset");
            end
            default: begin $display("FAIL unexpected case completion"); $finish(1); end
        endcase
        host.clearCompletion;
        testCase <= nextCase(testCase);
        launched <= False;
    endrule

    rule done (testCase == CDone && !launched && host.ready);
        $display("PASS PLIO host M1 Rust/Bluespec worker MMIO semantics");
        $finish(0);
    endrule
endmodule

endpackage
