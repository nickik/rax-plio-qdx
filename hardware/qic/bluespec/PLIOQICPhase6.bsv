package PLIOQICPhase6;

import QLITypes::*;
import QICInterfaces::*;
import PLIOQICPhase1::*;

typedef enum {
    QicIdle,
    QicRequestBusNotification,
    QicNotificationAddress,
    QicNotificationData,
    QicRequestBusDmaPlaceholder,
    QicActiveDmaPlaceholder
} QicPhase6State deriving (Bits, Eq, FShow);

interface PLIOQICPhase6Ifc;
    method PlioOut drivePlio(PlioIn bus, QliIn qli);
    method QliOut driveQli(PlioIn bus, QliIn qli);
    method Action advance(PlioIn bus, QliIn qli);
    method QicPhase6State debugState;
    method Bit#(9) debugWait;
endinterface

module mkPLIOQICPhase6(PLIOQICPhase6Ifc);
    Reg#(QicPhase6State) state <- mkReg(QicIdle);
    Reg#(NotificationRequest) request <- mkReg(NotificationRequest { channel: 0 });
    Reg#(Bit#(9)) waitCount <- mkReg(0);

    function Bool timedOut();
        return waitCount >= 255;
    endfunction

    function Bool validNotification(NotificationRequest r);
        return r.channel < 4;
    endfunction

    function Bit#(32) notificationAddress(NotificationRequest r);
        return zeroExtend(r.channel) << 2;
    endfunction

    method PlioOut drivePlio(PlioIn bus, QliIn qli);
        PlioOut out = plioOutDefault();
        if (!bus.reset) begin
            case (state)
                QicRequestBusNotification: out.request = True;
                QicNotificationAddress: begin
                    out.request = True;
                    if (bus.grant && !timedOut()) begin
                        Bit#(32) address = notificationAddress(request);
                        out.adValid = True;
                        out.ad = address;
                        out.parValid = True;
                        out.par = oddParity32P1(address);
                        out.spaceValid = True;
                        out.space = PlioController;
                        out.addressStrobe = True;
                        out.read = False;
                        out.byteEnable = 4'hf;
                        out.burst = BurstOne;
                    end
                end
                QicNotificationData: begin
                    out.request = True;
                    if (bus.grant && !timedOut()) begin
                        out.adValid = True;
                        out.ad = 0;
                        out.parValid = True;
                        out.par = oddParity32P1(0);
                        out.dataStrobe = True;
                    end
                end
                QicRequestBusDmaPlaceholder: out.request = True;
                default: noAction;
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
                    if (!qli.notificationValid && qli.dmaRequestValid && qli.dmaRequest.address[1:0] == 0)
                        out.dmaRequestReady = True;
                end
                QicNotificationData: begin
                    if (bus.grant && !timedOut() && bus.ack
                        && qli.notificationValid && qli.notification == request)
                        out.notificationReady = True;
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
                waitCount <= 0;
            end
            else begin
                case (state)
                    QicIdle: begin
                        waitCount <= 0;
                        if (qli.notificationValid) begin
                            if (validNotification(qli.notification)) begin
                                request <= qli.notification;
                                state <= QicRequestBusNotification;
                            end
                        end
                        else if (qli.dmaRequestValid && qli.dmaRequest.address[1:0] == 0) begin
                            // Placeholder preserves the Phase-3 idle priority rule:
                            // Notification wins only at an idle scheduling boundary.
                            state <= QicRequestBusDmaPlaceholder;
                        end
                    end
                    QicRequestBusNotification: begin
                        if (bus.grant) begin
                            waitCount <= 0;
                            state <= QicNotificationAddress;
                        end
                    end
                    QicNotificationAddress: begin
                        if (!bus.grant || timedOut() || bus.err) begin
                            waitCount <= 0;
                            state <= QicIdle;
                        end
                        else if (bus.ack) begin
                            waitCount <= 0;
                            state <= QicNotificationData;
                        end
                        else waitCount <= waitCount + 1;
                    end
                    QicNotificationData: begin
                        if (!bus.grant || timedOut() || bus.err || bus.ack) begin
                            // Notification completion is intentionally not latched.
                            // The producer must hold the request until notificationReady;
                            // any fault returns to Idle and the same request is retried.
                            waitCount <= 0;
                            state <= QicIdle;
                        end
                        else waitCount <= waitCount + 1;
                    end
                    QicRequestBusDmaPlaceholder: begin
                        if (bus.grant)
                            state <= QicActiveDmaPlaceholder;
                    end
                    QicActiveDmaPlaceholder: begin
                        // Phase 6 does not reimplement DMA. This state exists only
                        // to prove a later-arriving Notification cannot preempt it.
                        if (!qli.dmaRequestValid)
                            state <= QicIdle;
                    end
                endcase
            end
        endaction
    endmethod

    method QicPhase6State debugState = state;
    method Bit#(9) debugWait = waitCount;
endmodule

endpackage
