package PLIOQICPhase5;

import QLITypes::*;
import QICInterfaces::*;
import PLIOQICPhase1::*;

typedef enum {
    QicIdle,
    QicRequestBus,
    QicDmaAddress,
    QicDmaData,
    QicDmaComplete
} QicPhase5State deriving (Bits, Eq, FShow);

interface PLIOQICPhase5Ifc;
    method PlioOut drivePlio(PlioIn bus, QliIn qli);
    method QliOut driveQli(PlioIn bus, QliIn qli);
    method Action advance(PlioIn bus, QliIn qli);
    method QicPhase5State debugState;
    method Bit#(5) debugCompleted;
    method Bool debugBuffered;
    method Bit#(9) debugWait;
endinterface

module mkPLIOQICPhase5(PLIOQICPhase5Ifc);
    Reg#(QicPhase5State) state <- mkReg(QicIdle);
    Reg#(DmaRequest) request <- mkReg(DmaRequest { direction: DeviceToHost, address: 0, words: BurstOne });
    Reg#(DmaCompletion) completion <- mkReg(DmaCompletion { status: DmaOk, wordsCompleted: 0 });
    Reg#(Bit#(5)) completed <- mkReg(0);
    Reg#(Bool) bufferValid <- mkReg(False);
    Reg#(Bit#(32)) bufferData <- mkReg(0);
    Reg#(Bit#(9)) waitCount <- mkReg(0);

    function Bool timedOut();
        return waitCount >= 255;
    endfunction

    function Bool validWriteRequest(DmaRequest r);
        return r.direction == DeviceToHost && r.address[1:0] == 0;
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
                        out.read = False;
                        out.byteEnable = 4'hf;
                        out.burst = request.words;
                    end
                end
                QicDmaData: begin
                    out.request = True;
                    if (!timedOut() && bus.grant && bufferValid) begin
                        out.adValid = True;
                        out.ad = bufferData;
                        out.parValid = True;
                        out.parity = oddParity32P1(bufferData);
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
                    if (qli.dmaRequestValid && validWriteRequest(qli.dmaRequest))
                        out.dmaRequestReady = True;
                end
                QicDmaData: begin
                    if (!timedOut() && bus.grant && !bufferValid
                        && completed < burstWordCount(request.words))
                        out.dmaWriteReady = True;
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
                        if (qli.dmaRequestValid && validWriteRequest(qli.dmaRequest)) begin
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
                        if (!bus.grant) begin
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
                            if (bus.err) begin
                                completion <= DmaCompletion { status: DmaBusError, wordsCompleted: completed };
                                state <= QicDmaComplete;
                                waitCount <= 0;
                            end
                            else if (bus.ack) begin
                                Bit#(5) next = completed + 1;
                                completed <= next;
                                bufferValid <= False;
                                waitCount <= 0;
                                if (next == burstWordCount(request.words)) begin
                                    completion <= DmaCompletion { status: DmaOk, wordsCompleted: next };
                                    state <= QicDmaComplete;
                                end
                            end
                            else waitCount <= waitCount + 1;
                        end
                        else begin
                            if (qli.dmaWriteValid) begin
                                bufferData <= qli.dmaWrite.data;
                                bufferValid <= True;
                                waitCount <= 0;
                            end
                            else waitCount <= waitCount + 1;
                        end
                    end
                    QicDmaComplete: begin
                        if (qli.dmaCompletionReady)
                            state <= QicIdle;
                    end
                endcase
            end
        endaction
    endmethod

    method QicPhase5State debugState = state;
    method Bit#(5) debugCompleted = completed;
    method Bool debugBuffered = bufferValid;
    method Bit#(9) debugWait = waitCount;
endmodule

endpackage
