package PLIOQICPhase2;

import QLITypes::*;
import QICInterfaces::*;
import PLIOQICPhase1::oddParity32P1;
import PLIOQICPhase1::workerAddressCycleP1;
import PLIOQICPhase1::workerAddressValidP1;

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

    function Bool timedOut();
        return waitCount >= 255;
    endfunction

    function MmioRequest heldRequest();
        return MmioRequest {
            address: heldAddress,
            write: heldWrite,
            byteEnable: heldBe,
            writeData: heldWriteData
        };
    endfunction

    method PlioOut drivePlio(PlioIn bus, QliIn qli);
        PlioOut out = plioOutDefault();

        if (!bus.reset) begin
            case (state)
                QicIdle: begin
                    if (workerAddressCycleP1(bus)) begin
                        if (workerAddressValidP1(bus))
                            out.ack = True;
                        else
                            out.err = True;
                    end
                end
                QicWorkerReadData: begin
                    if (timedOut())
                        out.err = True;
                end
                QicWorkerWriteData: begin
                    if (timedOut()) begin
                        out.err = True;
                    end
                    else if (bus.dataStrobe
                        && (!bus.adValid || !bus.parValid
                            || ((oddParity32P1(bus.ad) & heldBe) != (bus.par & heldBe)))) begin
                        out.err = True;
                    end
                end
                QicWorkerOffer: begin
                    if (timedOut())
                        out.err = True;
                end
                QicWorkerResponse: begin
                    if (timedOut()) begin
                        out.err = True;
                    end
                    else if (bus.dataStrobe && qli.mmioResponseValid) begin
                        case (qli.mmioResponse.status)
                            MmioReadOk: begin
                                if (!heldWrite) begin
                                    out.adValid = True;
                                    out.ad = qli.mmioResponse.data;
                                    out.parValid = True;
                                    out.par = oddParity32P1(qli.mmioResponse.data);
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
                    if (!timedOut()) begin
                        out.mmioRequestValid = True;
                        out.mmioRequest = heldRequest();
                    end
                end
                QicWorkerResponse: begin
                    if (timedOut()) begin
                        out.mmioCancel = True;
                    end
                    else begin
                        out.mmioResponseReady = bus.dataStrobe;
                    end
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
                        if (workerAddressCycleP1(bus) && workerAddressValidP1(bus)) begin
                            heldAddress <= bus.ad;
                            heldBe <= bus.byteEnable;
                            heldWrite <= !bus.read;
                            heldWriteData <= 0;
                            waitCount <= 0;
                            if (bus.read)
                                state <= QicWorkerReadData;
                            else
                                state <= QicWorkerWriteData;
                        end
                    end
                    QicWorkerReadData: begin
                        if (timedOut()) begin
                            state <= QicIdle;
                            waitCount <= 0;
                        end
                        else if (bus.dataStrobe) begin
                            heldWrite <= False;
                            heldWriteData <= 0;
                            state <= QicWorkerOffer;
                        end
                        else begin
                            waitCount <= waitCount + 1;
                        end
                    end
                    QicWorkerWriteData: begin
                        if (timedOut()) begin
                            state <= QicIdle;
                            waitCount <= 0;
                        end
                        else if (bus.dataStrobe) begin
                            if (bus.adValid && bus.parValid
                                && ((oddParity32P1(bus.ad) & heldBe) == (bus.par & heldBe))) begin
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
                        else begin
                            waitCount <= waitCount + 1;
                        end
                    end
                    QicWorkerOffer: begin
                        if (timedOut()) begin
                            state <= QicIdle;
                            waitCount <= 0;
                        end
                        else if (qli.mmioReady) begin
                            state <= QicWorkerResponse;
                            // Deliberately retain waitCount: QLI acceptance does
                            // not restart the outstanding PLIO data timeout.
                        end
                        else begin
                            waitCount <= waitCount + 1;
                        end
                    end
                    QicWorkerResponse: begin
                        if (timedOut()) begin
                            state <= QicIdle;
                            waitCount <= 0;
                        end
                        else if (bus.dataStrobe && qli.mmioResponseValid) begin
                            state <= QicIdle;
                            waitCount <= 0;
                        end
                        else begin
                            waitCount <= waitCount + 1;
                        end
                    end
                endcase
            end
        endaction
    endmethod

    method QicPhase2State debugState = state;
    method Bit#(9) debugWait = waitCount;
endmodule

endpackage
