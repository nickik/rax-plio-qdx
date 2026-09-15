package PLIOQICPhase4;

import QLITypes::*;
import QICInterfaces::*;
import PLIOQICPhase1::*;

typedef enum {
    QicIdle,
    QicRequestBus,
    QicDmaAddress,
    QicDmaData,
    QicDmaComplete
} QicPhase4State deriving (Bits, Eq, FShow);

interface PLIOQICPhase4Ifc;
    method PlioOut drivePlio(PlioIn bus, QliIn qli);
    method QliOut driveQli(PlioIn bus, QliIn qli);
    method Action advance(PlioIn bus, QliIn qli);
    method QicPhase4State debugState;
    method Bit#(5) debugCompleted;
    method Bool debugBuffered;
    method Bit#(9) debugWait;
endinterface

module mkPLIOQICPhase4(PLIOQICPhase4Ifc);
    Reg#(QicPhase4State) state <- mkReg(QicIdle);
    Reg#(DmaRequest) request <- mkReg(DmaRequest { direction: HostToDevice, address: 0, words: BurstOne });
    Reg#(DmaCompletion) completion <- mkReg(DmaCompletion { status: DmaOk, wordsCompleted: 0 });
    Reg#(Bit#(5)) completed <- mkReg(0);
    Reg#(Bool) bufferValid <- mkReg(False);
    Reg#(Bit#(32)) bufferData <- mkReg(0);
    Reg#(Bit#(9)) waitCount <- mkReg(0);

    function Bool timedOut();
        return waitCount >= 255;
    endfunction

    function Bool validReadRequest(DmaRequest r);
        return r.direction == HostToDevice && r.address[1:0] == 0;
    endfunction

    function Bool finalBuffered();
        return bufferValid && completed == burstWordCount(request.words);
    endfunction

    method PlioOut drivePlio(PlioIn bus, QliIn qli);
        PlioOut out = plioOutDefault();
        if (!bus.reset) begin
            case (state)
                QicRequestBus: out.request = True;
                QicDmaAddress: begin
                    out.request = True;
                    if (bus.grant && !timedOut()) begin
                        out.adValid = True;
                        out.ad = request.address;
                        out.parValid = True;
                        out.parity = oddParity32P1(request.address);
                        out.spaceValid = True;
                        out.space = PlioHostDma;
                        out.addressStrobe = True;
                        out.read = True;
                        out.byteEnable = 4'hf;
                        out.burst = request.words;
                    end
                end
                QicDmaData: begin
                    out.request = !finalBuffered();
                    if (!timedOut() && (finalBuffered() || bus.grant)) begin
                        if (!bufferValid && completed < burstWordCount(request.words))
                            out.dataStrobe = True;
                    end
                end
                default: begin end
            endcase
        end
        return out;
    endmethod

    method QliOut driveQli(PlioIn bus, QliIn qli);
        QliOut out = qliOutDefault();
        out.reset = bus.reset;
        if (!bus.reset) begin
            case (state)
                QicIdle: begin
                    if (qli.dmaRequestValid && validReadRequest(qli.dmaRequest))
                        out.dmaRequestReady = True;
                end
                QicDmaData: begin
                    if (!timedOut() && bufferValid && (finalBuffered() || bus.grant)) begin
                        out.dmaReadValid = True;
                        out.dmaRead = DmaWord { data: bufferData };
                    end
                end
                QicDmaComplete: begin
                    out.dmaCompletionValid = True;
                    out.dmaCompletion = completion;
                end
                default: begin end
            endcase
        end
        return out;
    endmethod

    method Action advance(PlioIn bus, QliIn qli);
        action
            if (bus.reset) begin
                state <= QicIdle;
                completed <= 0;
                bufferValid <= False;
                bufferData <= 0;
                waitCount <= 0;
            end
            else begin
                case (state)
                    QicIdle: begin
                        completed <= 0;
                        bufferValid <= False;
                        waitCount <= 0;
                        if (qli.dmaRequestValid && validReadRequest(qli.dmaRequest)) begin
                            request <= qli.dmaRequest;
                            state <= QicRequestBus;
                        end
                    end
                    QicRequestBus: begin
                        if (bus.grant) begin
                            waitCount <= 0;
                            state <= QicDmaAddress;
                        end
                    end
                    QicDmaAddress: begin
                        if (!bus.grant) begin
                            completion <= DmaCompletion { status: DmaProtocolError, wordsCompleted: 0 };
                            state <= QicDmaComplete;
                            waitCount <= 0;
                        end
                        else if (timedOut()) begin
                            completion <= DmaCompletion { status: DmaTimeout, wordsCompleted: 0 };
                            state <= QicDmaComplete;
                            waitCount <= 0;
                        end
                        else if (bus.err) begin
                            completion <= DmaCompletion { status: DmaBusError, wordsCompleted: 0 };
                            state <= QicDmaComplete;
                            waitCount <= 0;
                        end
                        else if (bus.ack) begin
                            completed <= 0;
                            bufferValid <= False;
                            waitCount <= 0;
                            state <= QicDmaData;
                        end
                        else waitCount <= waitCount + 1;
                    end
                    QicDmaData: begin
                        Bool finalBuf = finalBuffered();
                        if (!finalBuf && !bus.grant) begin
                            completion <= DmaCompletion { status: DmaProtocolError, wordsCompleted: completed };
                            state <= QicDmaComplete;
                            waitCount <= 0;
                        end
                        else if (timedOut()) begin
                            completion <= DmaCompletion { status: DmaTimeout, wordsCompleted: completed };
                            state <= QicDmaComplete;
                            waitCount <= 0;
                        end
                        else if (bufferValid) begin
                            if (qli.dmaReadReady) begin
                                if (completed == burstWordCount(request.words)) begin
                                    completion <= DmaCompletion { status: DmaOk, wordsCompleted: completed };
                                    bufferValid <= False;
                                    state <= QicDmaComplete;
                                end
                                else begin
                                    bufferValid <= False;
                                    waitCount <= 0;
                                end
                            end
                            else waitCount <= waitCount + 1;
                        end
                        else if (bus.err) begin
                            completion <= DmaCompletion { status: DmaBusError, wordsCompleted: completed };
                            state <= QicDmaComplete;
                            waitCount <= 0;
                        end
                        else if (bus.ack) begin
                            if (bus.adValid && bus.parValid && oddParity32P1(bus.ad) == bus.parity) begin
                                bufferData <= bus.ad;
                                bufferValid <= True;
                                completed <= completed + 1;
                                waitCount <= 0;
                            end
                            else begin
                                completion <= DmaCompletion { status: DmaParityError, wordsCompleted: completed };
                                state <= QicDmaComplete;
                                waitCount <= 0;
                            end
                        end
                        else waitCount <= waitCount + 1;
                    end
                    QicDmaComplete: begin
                        if (qli.dmaCompletionReady)
                            state <= QicIdle;
                    end
                endcase
            end
        endaction
    endmethod

    method QicPhase4State debugState = state;
    method Bit#(5) debugCompleted = completed;
    method Bool debugBuffered = bufferValid;
    method Bit#(9) debugWait = waitCount;
endmodule

endpackage
