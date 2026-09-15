package PLIOQICPhase3;

import QLITypes::*;
import QICInterfaces::*;
import PLIOQICPhase1::*;

typedef enum {
    QicIdle,
    QicRequestBusDma,
    QicRequestBusNotification,
    QicDmaAddress,
    QicNotificationAddress,
    QicDmaComplete,
    QicDmaDataPlaceholder,
    QicNotificationDataPlaceholder
} QicPhase3State deriving (Bits, Eq, FShow);

interface PLIOQICPhase3Ifc;
    method PlioOut drivePlio(PlioIn bus, QliIn qli);
    method QliOut driveQli(PlioIn bus, QliIn qli);
    method Action advance(PlioIn bus, QliIn qli);
    method QicPhase3State debugState;
    method Bit#(9) debugWait;
endinterface

module mkPLIOQICPhase3(PLIOQICPhase3Ifc);
    Reg#(QicPhase3State) state <- mkReg(QicIdle);
    Reg#(DmaRequest) heldDma <- mkReg(DmaRequest { direction: HostToDevice, address: 0, words: BurstOne });
    Reg#(NotificationRequest) heldNotification <- mkReg(NotificationRequest { channel: 0 });
    Reg#(DmaCompletion) heldCompletion <- mkReg(DmaCompletion { status: DmaOk, wordsCompleted: 0 });
    Reg#(Bit#(9)) waitCount <- mkReg(0);

    function Bool timedOutP3();
        return waitCount >= 255;
    endfunction

    function Bool validDmaP3(DmaRequest r);
        return r.address[1:0] == 0;
    endfunction

    function Bool validNotificationP3(NotificationRequest r);
        return r.channel < 4;
    endfunction

    method PlioOut drivePlio(PlioIn bus, QliIn qli);
        PlioOut out = plioOutDefault();
        if (!bus.reset) begin
            case (state)
                QicRequestBusDma, QicRequestBusNotification: begin
                    out.request = True;
                end
                QicDmaAddress: begin
                    out.request = True;
                    if (bus.grant && !timedOutP3()) begin
                        out.adValid = True;
                        out.ad = heldDma.address;
                        out.parValid = True;
                        out.parity = oddParity32P1(heldDma.address);
                        out.spaceValid = True;
                        out.space = PlioHostDma;
                        out.addressStrobe = True;
                        out.read = heldDma.direction == HostToDevice;
                        out.byteEnable = 4'hf;
                        out.burst = heldDma.words;
                    end
                end
                QicNotificationAddress: begin
                    out.request = True;
                    if (bus.grant && !timedOutP3()) begin
                        Bit#(32) address = zeroExtend(heldNotification.channel) << 2;
                        out.adValid = True;
                        out.ad = address;
                        out.parValid = True;
                        out.parity = oddParity32P1(address);
                        out.spaceValid = True;
                        out.space = PlioController;
                        out.addressStrobe = True;
                        out.read = False;
                        out.byteEnable = 4'hf;
                        out.burst = BurstOne;
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
                    if (!qli.notificationValid && qli.dmaRequestValid && validDmaP3(qli.dmaRequest))
                        out.dmaRequestReady = True;
                end
                QicDmaComplete: begin
                    out.dmaCompletionValid = True;
                    out.dmaCompletion = heldCompletion;
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
                waitCount <= 0;
            end
            else begin
                case (state)
                    QicIdle: begin
                        waitCount <= 0;
                        // Match the Rust oracle literally: presence of a
                        // Notification is considered before DMA, even when the
                        // Notification itself is invalid.
                        if (qli.notificationValid) begin
                            if (validNotificationP3(qli.notification)) begin
                                heldNotification <= qli.notification;
                                state <= QicRequestBusNotification;
                            end
                        end
                        else if (qli.dmaRequestValid && validDmaP3(qli.dmaRequest)) begin
                            heldDma <= qli.dmaRequest;
                            state <= QicRequestBusDma;
                        end
                    end
                    QicRequestBusDma: begin
                        if (bus.grant) begin
                            waitCount <= 0;
                            state <= QicDmaAddress;
                        end
                    end
                    QicRequestBusNotification: begin
                        if (bus.grant) begin
                            waitCount <= 0;
                            state <= QicNotificationAddress;
                        end
                    end
                    QicDmaAddress: begin
                        if (!bus.grant) begin
                            heldCompletion <= DmaCompletion { status: DmaProtocolError, wordsCompleted: 0 };
                            waitCount <= 0;
                            state <= QicDmaComplete;
                        end
                        else if (timedOutP3()) begin
                            heldCompletion <= DmaCompletion { status: DmaTimeout, wordsCompleted: 0 };
                            waitCount <= 0;
                            state <= QicDmaComplete;
                        end
                        else if (bus.err) begin
                            heldCompletion <= DmaCompletion { status: DmaBusError, wordsCompleted: 0 };
                            waitCount <= 0;
                            state <= QicDmaComplete;
                        end
                        else if (bus.ack) begin
                            waitCount <= 0;
                            state <= QicDmaDataPlaceholder;
                        end
                        else begin
                            waitCount <= waitCount + 1;
                        end
                    end
                    QicNotificationAddress: begin
                        if (!bus.grant || timedOutP3() || bus.err) begin
                            waitCount <= 0;
                            state <= QicIdle;
                        end
                        else if (bus.ack) begin
                            waitCount <= 0;
                            state <= QicNotificationDataPlaceholder;
                        end
                        else begin
                            waitCount <= waitCount + 1;
                        end
                    end
                    QicDmaComplete: begin
                        if (qli.dmaCompletionReady)
                            state <= QicIdle;
                    end
                    // Phase 3 deliberately stops once an address has been ACKed.
                    // Phase 4/5/6 replace these placeholders with data machinery.
                    QicDmaDataPlaceholder: noAction;
                    QicNotificationDataPlaceholder: noAction;
                endcase
            end
        endaction
    endmethod

    method QicPhase3State debugState = state;
    method Bit#(9) debugWait = waitCount;
endmodule

endpackage
