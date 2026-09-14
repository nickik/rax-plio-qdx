package PLIOQICPhase1;

import QLITypes::*;
import QICInterfaces::*;

typedef enum {
    QicIdle,
    QicWorkerReadData,
    QicWorkerWriteData
} QicPhase1State deriving (Bits, Eq, FShow);

function Bit#(4) oddParity32P1(Bit#(32) word);
    Bit#(1) p0 = ~(^word[7:0]);
    Bit#(1) p1 = ~(^word[15:8]);
    Bit#(1) p2 = ~(^word[23:16]);
    Bit#(1) p3 = ~(^word[31:24]);
    return { p3, p2, p1, p0 };
endfunction

function Bool workerAddressCycleP1(PlioIn bus);
    return bus.selected
        && bus.addressStrobe
        && bus.spaceValid
        && bus.space == PlioWorker;
endfunction

function Bool validWorkerByteEnableP1(Bit#(32) address, Bit#(4) be);
    Bool result = False;
    case (be)
        4'b0001: result = (address[1:0] == 2'b00);
        4'b0010: result = (address[1:0] == 2'b01);
        4'b0100: result = (address[1:0] == 2'b10);
        4'b1000: result = (address[1:0] == 2'b11);
        4'b0011: result = (address[1:0] == 2'b00);
        4'b1100: result = (address[1:0] == 2'b10);
        4'b1111: result = (address[1:0] == 2'b00);
        default: result = False;
    endcase
    return result;
endfunction

function Bool workerAddressValidP1(PlioIn bus);
    return bus.adValid
        && bus.parValid
        && bus.burst == BurstOne
        && bus.ad[31:25] == 0
        && validWorkerByteEnableP1(bus.ad, bus.byteEnable)
        && oddParity32P1(bus.ad) == bus.par;
endfunction

interface PLIOQICPhase1Ifc;
    method PlioOut drivePlio(PlioIn bus, QliIn qli);
    method QliOut driveQli(PlioIn bus, QliIn qli);
    method Action advance(PlioIn bus, QliIn qli);
    method QicPhase1State debugState;
endinterface

module mkPLIOQICPhase1(PLIOQICPhase1Ifc);
    Reg#(QicPhase1State) state <- mkReg(QicIdle);

    method PlioOut drivePlio(PlioIn bus, QliIn qli);
        PlioOut out = plioOutDefault();

        if (!bus.reset && state == QicIdle && workerAddressCycleP1(bus)) begin
            if (workerAddressValidP1(bus))
                out.ack = True;
            else
                out.err = True;
        end

        return out;
    endmethod

    method QliOut driveQli(PlioIn bus, QliIn qli);
        QliOut out = qliOutDefault();
        out.reset = bus.reset;
        return out;
    endmethod

    method Action advance(PlioIn bus, QliIn qli);
        action
            if (bus.reset) begin
                state <= QicIdle;
            end
            else begin
                case (state)
                    QicIdle: begin
                        if (workerAddressCycleP1(bus) && workerAddressValidP1(bus)) begin
                            if (bus.read)
                                state <= QicWorkerReadData;
                            else
                                state <= QicWorkerWriteData;
                        end
                    end
                    // Phase 1 deliberately stops after accepting the worker
                    // address. Phase 2 will define the data-phase machinery.
                    QicWorkerReadData: noAction;
                    QicWorkerWriteData: noAction;
                endcase
            end
        endaction
    endmethod

    method QicPhase1State debugState = state;
endmodule

endpackage
