package PLIOWorkerHost;

import QLITypes::*;
import QICInterfaces::*;

typedef enum { HostW8, HostW16, HostW32 } HostWorkerWidth deriving (Bits, Eq, FShow);
typedef enum { HostIdle, HostAddress, HostData } HostWorkerState deriving (Bits, Eq, FShow);
typedef enum { HostSuccess, HostBusError, HostParityError, HostTimeout, HostReset } HostWorkerStatus deriving (Bits, Eq, FShow);

typedef struct {
    Bit#(3) slot;
    Bit#(32) address;
    HostWorkerWidth width;
    Bool write;
    Bit#(32) value;
} HostWorkerRequest deriving (Bits, Eq, FShow);

typedef struct {
    HostWorkerStatus status;
    Bit#(32) data;
} HostWorkerCompletion deriving (Bits, Eq, FShow);

function Bit#(4) hostOddParity32(Bit#(32) word);
    return { ~(^word[31:24]), ~(^word[23:16]), ~(^word[15:8]), ~(^word[7:0]) };
endfunction

function Bit#(4) hostByteEnable(HostWorkerRequest r);
    Bit#(4) be = 0;
    case (r.width)
        HostW8: be = 4'b0001 << r.address[1:0];
        HostW16: be = 4'b0011 << r.address[1:0];
        HostW32: be = 4'b1111;
    endcase
    return be;
endfunction

function Bit#(32) hostValueMask(HostWorkerWidth w);
    Bit#(32) value = 32'hffff_ffff;
    case (w)
        HostW8: value = 32'h0000_00ff;
        HostW16: value = 32'h0000_ffff;
        default: value = 32'hffff_ffff;
    endcase
    return value;
endfunction

function Bit#(32) hostBusWriteData(HostWorkerRequest r);
    Bit#(5) shift = zeroExtend(r.address[1:0]) << 3;
    return (r.value & hostValueMask(r.width)) << shift;
endfunction

function Bit#(32) hostExtractReadData(HostWorkerRequest r, Bit#(32) word);
    Bit#(5) shift = zeroExtend(r.address[1:0]) << 3;
    return (word >> shift) & hostValueMask(r.width);
endfunction

function Bool hostParityMatches(Bit#(32) word, Bit#(4) parity, Bit#(4) be);
    Bit#(4) expected = hostOddParity32(word);
    return ((expected ^ parity) & be) == 0;
endfunction

function Bool hostRequestValid(HostWorkerRequest r);
    Bool aligned = False;
    case (r.width)
        HostW8: aligned = True;
        HostW16: aligned = r.address[0] == 0;
        HostW32: aligned = r.address[1:0] == 0;
    endcase
    Bool valueOk = !r.write || ((r.value & ~hostValueMask(r.width)) == 0);
    return r.address[31:25] == 0 && aligned && valueOk;
endfunction

interface PLIOWorkerHostIfc;
    method Bool ready;
    method Action start(HostWorkerRequest request);
    method PlioIn drive(Bool reset);
    method Bool selectedSlotValid;
    method Bit#(3) selectedSlot;
    method Action advance(PlioOut card, Bool reset);
    method Bool completionValid;
    method HostWorkerCompletion completion;
    method Action clearCompletion;
    method HostWorkerState debugState;
    method Bit#(9) debugWaitCycles;
endinterface

module mkPLIOWorkerHost(PLIOWorkerHostIfc);
    Reg#(HostWorkerState) state <- mkReg(HostIdle);
    Reg#(HostWorkerRequest) request <- mkReg(HostWorkerRequest { slot: 0, address: 0, width: HostW32, write: False, value: 0 });
    Reg#(Bit#(9)) waitCycles <- mkReg(0);
    Reg#(Bool) completionPending <- mkReg(False);
    Reg#(HostWorkerCompletion) completionReg <- mkReg(HostWorkerCompletion { status: HostSuccess, data: 0 });

    method Bool ready = state == HostIdle && !completionPending;

    method Action start(HostWorkerRequest r) if (state == HostIdle && !completionPending);
        action
            if (hostRequestValid(r)) begin
                request <= r;
                waitCycles <= 0;
                state <= HostAddress;
            end
        endaction
    endmethod

    method PlioIn drive(Bool reset);
        PlioIn out = plioInDefault();
        out.reset = reset;
        if (!reset && state != HostIdle) begin
            out.selected = True;
            out.read = !request.write;
            out.byteEnable = hostByteEnable(request);
            out.burst = BurstOne;
            if (state == HostAddress) begin
                out.adValid = True;
                out.ad = request.address;
                out.parValid = True;
                out.parity = hostOddParity32(request.address);
                out.spaceValid = True;
                out.space = PlioWorker;
                out.addressStrobe = True;
            end
            else begin
                out.dataStrobe = True;
                if (request.write) begin
                    Bit#(32) data = hostBusWriteData(request);
                    out.adValid = True;
                    out.ad = data;
                    out.parValid = True;
                    out.parity = hostOddParity32(data);
                end
            end
        end
        return out;
    endmethod

    method Bool selectedSlotValid = state != HostIdle;
    method Bit#(3) selectedSlot = request.slot;

    method Action advance(PlioOut card, Bool reset);
        action
            if (reset) begin
                if (state != HostIdle) begin
                    completionReg <= HostWorkerCompletion { status: HostReset, data: 0 };
                    completionPending <= True;
                end
                state <= HostIdle;
                waitCycles <= 0;
            end
            else begin
                case (state)
                    HostIdle: noAction;
                    HostAddress: begin
                        if (card.err) begin
                            completionReg <= HostWorkerCompletion { status: HostBusError, data: 0 };
                            completionPending <= True;
                            state <= HostIdle;
                            waitCycles <= 0;
                        end
                        else if (card.ack) begin
                            state <= HostData;
                            waitCycles <= 0;
                        end
                        else if (waitCycles == 255) begin
                            completionReg <= HostWorkerCompletion { status: HostTimeout, data: 0 };
                            completionPending <= True;
                            state <= HostIdle;
                            waitCycles <= 0;
                        end
                        else waitCycles <= waitCycles + 1;
                    end
                    HostData: begin
                        if (card.err) begin
                            completionReg <= HostWorkerCompletion { status: HostBusError, data: 0 };
                            completionPending <= True;
                            state <= HostIdle;
                            waitCycles <= 0;
                        end
                        else if (card.ack) begin
                            if (request.write) begin
                                completionReg <= HostWorkerCompletion { status: HostSuccess, data: 0 };
                            end
                            else if (card.adValid && card.parValid && hostParityMatches(card.ad, card.parity, hostByteEnable(request))) begin
                                completionReg <= HostWorkerCompletion { status: HostSuccess, data: hostExtractReadData(request, card.ad) };
                            end
                            else begin
                                completionReg <= HostWorkerCompletion { status: HostParityError, data: 0 };
                            end
                            completionPending <= True;
                            state <= HostIdle;
                            waitCycles <= 0;
                        end
                        else if (waitCycles == 255) begin
                            completionReg <= HostWorkerCompletion { status: HostTimeout, data: 0 };
                            completionPending <= True;
                            state <= HostIdle;
                            waitCycles <= 0;
                        end
                        else waitCycles <= waitCycles + 1;
                    end
                endcase
            end
        endaction
    endmethod

    method Bool completionValid = completionPending;
    method HostWorkerCompletion completion if (completionPending);
        return completionReg;
    endmethod
    method Action clearCompletion if (completionPending);
        completionPending <= False;
    endmethod
    method HostWorkerState debugState = state;
    method Bit#(9) debugWaitCycles = waitCycles;
endmodule

endpackage
