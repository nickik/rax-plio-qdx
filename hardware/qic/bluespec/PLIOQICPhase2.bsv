package PLIOQICPhase2;

import QLITypes::*;
import QICInterfaces::*;

function Bit#(4) oddParity32P2(Bit#(32) word);
    Bit#(1) p0 = ~(^word[7:0]);
    Bit#(1) p1 = ~(^word[15:8]);
    Bit#(1) p2 = ~(^word[23:16]);
    Bit#(1) p3 = ~(^word[31:24]);
    return { p3, p2, p1, p0 };
endfunction

function Bool validWorkerByteEnableP2(Bit#(32) address, Bit#(4) be);
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

function Bool workerAddressCycleP2(PlioIn bus);
    return bus.selected && bus.addressStrobe && bus.spaceValid && bus.space == PlioWorker;
endfunction

function Bool workerAddressValidP2(PlioIn bus);
    return bus.adValid
        && bus.parValid
        && bus.burst == BurstOne
        && bus.ad[31:25] == 0
        && validWorkerByteEnableP2(bus.ad, bus.byteEnable)
        && oddParity32P2(bus.ad) == bus.par;
endfunction

typedef enum {
    QicIdle,
    QicWorkerReadData,
    QicWorkerWriteData,
    QicWorkerOffer,
    QicWorkerResponse
} QicPhase2State deriving (Bits, Eq, FShow);

interface PLIOQICPhase2Ifc;
    method PlioOut drivePlio(PlioIn bus, QliIn qli);
    method QliOut driveQli(PlioIn bus, QliIn qli);
    method Action advance(PlioIn bus, QliIn qli);
    method QicPhase2State debugState;
    method Bit#(9) debugWait;
endinterface

module mkPLIOQICPhase2(PLIOQICPhase2Ifc);
    Reg#(QicPhase2State) state <- mkReg(QicIdle);
    Reg#(Bit#(32)) heldAddress <- mkReg(0);
    Reg#(Bit#(4)) heldBe <- mkReg(0);
    Reg#(Bit#(32)) heldWriteData <- mkReg(0);
    Reg#(Bool) heldWrite <- mkReg(False);
    Reg#(Bit#(9)) waitCount <- mkReg(0);

    method PlioOut drivePlio(PlioIn bus, QliIn qli);
        PlioOut out = plioOutDefault();

        if (!bus.reset) begin
            case (state)
                QicIdle: begin
                    if (workerAddressCycleP2(bus)) begin
                        if (workerAddressValidP2(bus)) out.ack = True;
                        else out.err = True;
                    end
                end
                QicWorkerReadData: begin
                    if (waitCount >= 255) out.err = True;
                end
                QicWorkerWriteData: begin
                    if (waitCount >= 255) begin
                        out.err = True;
                    end
                    else if (bus.dataStrobe
                        && (!bus.adValid || !bus.parValid
                            || ((oddParity32P2(bus.ad) & heldBe) != (bus.par & heldBe)))) begin
                        out.err = True;
                    end
                end
                QicWorkerOffer: begin
                    if (waitCount >= 255) out.err = True;
                end
                QicWorkerResponse: begin
                    if (waitCount >= 255) begin
                        out.err = True;
                    end
                    else if (bus.dataStrobe && qli.mmioResponseValid) begin
                        case (qli.mmioResponse.status)
                            MmioReadOk: begin
                                if (!heldWrite) begin
                                    out.adValid = True;
                                    out.ad = qli.mmioResponse.data;
                                    out.parValid = True;
                                    out.par = oddParity32P2(qli.mmioResponse.data);
                                    out.ack = True;
                                end
                                else out.err = True;
                            end
                            MmioWriteOk: begin
                                if (heldWrite) out.ack = True;
                                else out.err = True;
                            end
                            MmioError: out.err = True;
                        endcase
                    end
                end
            endcase
        end

        return out;
    endmethod

    method QliOut driveQli(PlioIn bus, QliIn qli);
        QliOut out = qliOutDefault();
        out.reset = bus.reset;

        if (!bus.reset) begin
            case (state)
                QicWorkerOffer: begin
                    if (waitCount < 255) begin
                        out.mmioRequestValid = True;
                        out.mmioRequest = MmioRequest {
                            address: heldAddress,
                            write: heldWrite,
                            byteEnable: heldBe,
                            writeData: heldWriteData
                        };
                    end
                end
                QicWorkerResponse: begin
                    if (waitCount >= 255) out.mmioCancel = True;
                    else out.mmioResponseReady = bus.dataStrobe;
                end
                default: noAction;
            endcase
        end

        return out;
    endmethod

    method Action advance(PlioIn bus, QliIn qli);
        action
            if (bus.reset) begin
                state <= QicIdle;
                heldAddress <= 0;
                heldBe <= 0;
                heldWriteData <= 0;
                heldWrite <= False;
                waitCount <= 0;
            end
            else begin
                case (state)
                    QicIdle: begin
                        if (workerAddressCycleP2(bus) && workerAddressValidP2(bus)) begin
                            heldAddress <= bus.ad;
                            heldBe <= bus.byteEnable;
                            heldWrite <= !bus.read;
                            heldWriteData <= 0;
                            waitCount <= 0;
                            if (bus.read) state <= QicWorkerReadData;
                            else state <= QicWorkerWriteData;
                        end
                    end
                    QicWorkerReadData: begin
                        if (waitCount >= 255) begin
                            state <= QicIdle;
                            waitCount <= 0;
                        end
                        else if (bus.dataStrobe) begin
                            heldWrite <= False;
                            heldWriteData <= 0;
                            state <= QicWorkerOffer;
                        end
                        else waitCount <= waitCount + 1;
                    end
                    QicWorkerWriteData: begin
                        if (waitCount >= 255) begin
                            state <= QicIdle;
                            waitCount <= 0;
                        end
                        else if (bus.dataStrobe) begin
                            if (bus.adValid && bus.parValid
                                && ((oddParity32P2(bus.ad) & heldBe) == (bus.par & heldBe))) begin
                                heldWrite <= True;
                                heldWriteData <= bus.ad;
                                waitCount <= 0;
                                state <= QicWorkerOffer;
                            end
                            else begin
                                state <= QicIdle;
                                waitCount <= 0;
                            end
                        end
                        else waitCount <= waitCount + 1;
                    end
                    QicWorkerOffer: begin
                        if (waitCount >= 255) begin
                            state <= QicIdle;
                            waitCount <= 0;
                        end
                        else if (qli.mmioReady) begin
                            state <= QicWorkerResponse;
                            // Deliberately keep waitCount: accepting QLI work
                            // does not restart the outstanding PLIO timeout.
                        end
                        else waitCount <= waitCount + 1;
                    end
                    QicWorkerResponse: begin
                        if (waitCount >= 255) begin
                            state <= QicIdle;
                            waitCount <= 0;
                        end
                        else if (bus.dataStrobe && qli.mmioResponseValid) begin
                            state <= QicIdle;
                            waitCount <= 0;
                        end
                        else waitCount <= waitCount + 1;
                    end
                endcase
            end
        endaction
    endmethod

    method QicPhase2State debugState = state;
    method Bit#(9) debugWait = waitCount;
endmodule

endpackage
