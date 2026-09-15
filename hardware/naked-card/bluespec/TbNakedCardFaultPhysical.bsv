package TbNakedCardFaultPhysical;

import QLITypes::*;
import QICInterfaces::*;
import PLIOQIC::*;
import PLIOQICPhase1::*;
import QLI16Codec::*;
import PLIOTx::*;
import PLIOTxCardHarness::*;

typedef enum {
    FWaits,
    FD2HErr0, FD2HErr1, FD2HErr3,
    FH2DErr0, FH2DErr1, FH2DErr3,
    FParity0, FParity1, FParity3,
    FAddressTimeout, FDataTimeout,
    FNotifyRetry,
    FDone
} FaultMode deriving (Bits, Eq, FShow);

typedef enum {
    PeerIdle, PeerGrant, PeerDmaAddress, PeerDmaData,
    PeerNotificationAddress, PeerNotificationData
} PeerState deriving (Bits, Eq, FShow);

function Bool isH2D(FaultMode m);
    return m == FH2DErr0 || m == FH2DErr1 || m == FH2DErr3
        || m == FParity0 || m == FParity1 || m == FParity3;
endfunction

function Bool isBusError(FaultMode m);
    return m == FD2HErr0 || m == FD2HErr1 || m == FD2HErr3
        || m == FH2DErr0 || m == FH2DErr1 || m == FH2DErr3;
endfunction

function Bool isParity(FaultMode m);
    return m == FParity0 || m == FParity1 || m == FParity3;
endfunction

function Bit#(5) faultBeat(FaultMode m);
    case (m)
        FD2HErr1, FH2DErr1, FParity1: return 1;
        FD2HErr3, FH2DErr3, FParity3: return 3;
        default: return 0;
    endcase
endfunction

function FaultMode nextMode(FaultMode m);
    case (m)
        FWaits: return FD2HErr0;
        FD2HErr0: return FD2HErr1;
        FD2HErr1: return FD2HErr3;
        FD2HErr3: return FH2DErr0;
        FH2DErr0: return FH2DErr1;
        FH2DErr1: return FH2DErr3;
        FH2DErr3: return FParity0;
        FParity0: return FParity1;
        FParity1: return FParity3;
        FParity3: return FAddressTimeout;
        FAddressTimeout: return FDataTimeout;
        FDataTimeout: return FNotifyRetry;
        default: return FDone;
    endcase
endfunction

module mkTbNakedCardFaultPhysical(Empty);
    PLIOQICIfc qic <- mkPLIOQIC;
    QLI16CodecIfc codec <- mkQLI16Codec;
    PLIOTxCardHarnessIfc phy <- mkPLIOTxCardHarness;

    Reg#(FaultMode) mode <- mkReg(FWaits);
    Reg#(PeerState) peer <- mkReg(PeerIdle);
    Reg#(Bit#(5)) peerBeat <- mkReg(0);
    Reg#(Bit#(9)) peerWait <- mkReg(0);
    Reg#(Bool) dataResponsePending <- mkReg(False);
    Reg#(Bit#(3)) notificationTransactions <- mkReg(0);
    Reg#(Bool) requestPending <- mkReg(True);
    Reg#(Bit#(5)) deviceIndex <- mkReg(0);
    Reg#(Bit#(4)) phase <- mkReg(0);
    Reg#(PlioIn) sampledBus <- mkReg(plioInDefault());
    Reg#(QliIn) heldQli <- mkReg(qliInDefault());

    function DmaRequest requestFor(FaultMode m);
        return DmaRequest {
            direction: isH2D(m) ? HostToDevice : DeviceToHost,
            address: 32'h1234_5000,
            words: BurstFour
        };
    endfunction

    function PlioIn peerBus(PeerState p, FaultMode m, Bit#(5) beat,
                            Bit#(9) waitLeft, Bool responsePending);
        PlioIn b = plioInDefault();
        case (p)
            PeerGrant: b.grant = True;
            PeerDmaAddress: begin
                b.grant = True;
                if (m != FAddressTimeout && waitLeft == 0) b.ack = True;
            end
            PeerDmaData: begin
                b.grant = True;
                if (responsePending && m != FDataTimeout && waitLeft == 0) begin
                    if (isBusError(m) && beat == faultBeat(m)) b.err = True;
                    else begin
                        b.ack = True;
                        if (isH2D(m)) begin
                            Bit#(32) data = 32'h7000_0000 + zeroExtend(beat) * 4;
                            Bit#(4) parityBits = oddParity32P1(data);
                            if (isParity(m) && beat == faultBeat(m))
                                parityBits = parityBits ^ 1;
                            b.adValid = True;
                            b.ad = data;
                            b.parValid = True;
                            b.parity = parityBits;
                        end
                    end
                end
            end
            PeerNotificationAddress: begin
                b.grant = True;
                if (notificationTransactions == 1) b.err = True;
                else if (waitLeft == 0) b.ack = True;
            end
            PeerNotificationData: begin
                b.grant = True;
                if (waitLeft == 0) b.ack = True;
            end
            default: begin end
        endcase
        return b;
    endfunction

    rule resetAll (phase == 0);
        PlioIn b = plioInDefault();
        b.reset = True;
        qic.advance(b, qliInDefault());
        codec.resetCodec;
        phy.step(True);
        mode <= FWaits;
        peer <= PeerIdle;
        peerBeat <= 0;
        peerWait <= 0;
        dataResponsePending <= False;
        notificationTransactions <= 0;
        requestPending <= True;
        deviceIndex <= 0;
        phase <= 1;
    endrule

    rule startReceive (phase == 1 && phy.ready && mode != FDone);
        phy.startReceive(peerBus(peer, mode, peerBeat, peerWait, dataResponsePending));
        phase <= 2;
    endrule

    rule receiveSteps (phase == 2 && !phy.receiveDone);
        phy.step(False);
    endrule

    rule beginLocal (phase == 2 && phy.receiveDone);
        PlioIn b = phy.toQic;
        QliIn preview = qliInDefault();

        if (mode != FNotifyRetry) begin
            DmaRequest r = requestFor(mode);
            if (requestPending) begin
                preview.dmaRequestValid = True;
                preview.dmaRequest = r;
            end
        end
        else begin
            NotificationRequest n = NotificationRequest { channel: 2 };
            preview.notificationValid = True;
            preview.notification = n;
        end

        QliOut qo = qic.driveQli(b, preview);
        QliIn d = preview;
        d.dmaCompletionReady = True;
        if (mode != FNotifyRetry && !isH2D(mode) && !requestPending
            && deviceIndex < 4 && qo.dmaWriteReady) begin
            d.dmaWriteValid = True;
            d.dmaWrite = DmaWord {
                data: 32'h4000_0000 + zeroExtend(deviceIndex) * 4
            };
        end
        if (mode != FNotifyRetry && isH2D(mode)) d.dmaReadReady = True;

        codec.load(qo, d);
        sampledBus <= b;
        phase <= 3;
    endrule

    rule localSlot0 (phase == 3);
        codec.step;
        phase <= 4;
    endrule

    rule localSlot1 (phase == 4);
        codec.step;
        phase <= 5;
    endrule

    rule applyLocalAndTransmit (phase == 5 && codec.cycleComplete);
        QliIn qi = codec.toQic;
        QliOut qo = codec.toDevice;

        if (qo.dmaCompletionValid) begin
            DmaStatus expectedStatus = DmaOk;
            Bit#(5) expectedCount = 4;
            if (isBusError(mode)) begin
                expectedStatus = DmaBusError;
                expectedCount = faultBeat(mode);
            end
            else if (isParity(mode)) begin
                expectedStatus = DmaParityError;
                expectedCount = faultBeat(mode);
            end
            else if (mode == FAddressTimeout || mode == FDataTimeout) begin
                expectedStatus = DmaTimeout;
                expectedCount = 0;
            end

            if (qo.dmaCompletion.status != expectedStatus
                || qo.dmaCompletion.wordsCompleted != expectedCount) begin
                $display("FAIL fault completion mode=%0d status=%0d count=%0d expectedStatus=%0d expectedCount=%0d",
                    pack(mode), pack(qo.dmaCompletion.status),
                    qo.dmaCompletion.wordsCompleted, pack(expectedStatus), expectedCount);
                $finish(1);
            end

            if (mode == FWaits)
                $display("FAULTTRACE|v1|case=waits|status=0|completed=4");
            else if (isBusError(mode)) begin
                if (isH2D(mode))
                    $display("FAULTTRACE|v1|case=bus_error|dir=h2d|beat=%0d|status=1|completed=%0d",
                        faultBeat(mode), faultBeat(mode));
                else
                    $display("FAULTTRACE|v1|case=bus_error|dir=d2h|beat=%0d|status=1|completed=%0d",
                        faultBeat(mode), faultBeat(mode));
            end
            else if (isParity(mode))
                $display("FAULTTRACE|v1|case=parity|beat=%0d|status=2|completed=%0d",
                    faultBeat(mode), faultBeat(mode));
            else if (mode == FAddressTimeout)
                $display("FAULTTRACE|v1|case=address_timeout|status=3|completed=0");
            else if (mode == FDataTimeout)
                $display("FAULTTRACE|v1|case=data_timeout|status=3|completed=0");

            mode <= nextMode(mode);
            peer <= PeerIdle;
            peerBeat <= 0;
            peerWait <= 0;
            dataResponsePending <= False;
            requestPending <= True;
            deviceIndex <= 0;
        end
        else if (mode == FNotifyRetry && qo.notificationReady) begin
            if (notificationTransactions < 2) begin
                $display("FAIL notification completed before retry transactions=%0d",
                    notificationTransactions);
                $finish(1);
            end
            $display("FAULTTRACE|v1|case=notification_retry|channel=2|ready=1|transactions=2");
            mode <= FDone;
        end
        else if (qo.dmaRequestReady) begin
            requestPending <= False;
            deviceIndex <= 0;
        end
        else if (qo.dmaWriteReady) begin
            deviceIndex <= deviceIndex + 1;
        end
        else if (qo.dmaReadValid) begin
            deviceIndex <= deviceIndex + 1;
        end

        PlioOut po = qic.drivePlio(sampledBus, qi);
        phy.startTransmit(po);
        heldQli <= qi;
        phase <= 6;
    endrule

    rule transmitSteps (phase == 6 && !phy.transmitDone);
        phy.step(False);
    endrule

    rule finishLogicalCycle (phase == 6 && phy.transmitDone);
        BackplaneDrive bp = phy.backplane;
        PeerState next = peer;
        Bit#(9) nextWait = peerWait;

        if (phy.protocolFault || codec.protocolFault) begin
            $display("FAIL protocol fault in physical fault fixture");
            $finish(1);
        end

        case (peer)
            PeerIdle: begin
                if (bp.request) next = PeerGrant;
            end
            PeerGrant: begin
                if (bp.controlValid && bp.control.addressStrobe) begin
                    peerBeat <= 0;
                    dataResponsePending <= False;
                    if (bp.control.space == 1) begin
                        next = PeerDmaAddress;
                        if (mode == FWaits) nextWait = 3;
                        else if (mode == FAddressTimeout) nextWait = 300;
                        else nextWait = 0;
                    end
                    else if (bp.control.space == 2) begin
                        notificationTransactions <= notificationTransactions + 1;
                        next = PeerNotificationAddress;
                        nextWait = (notificationTransactions == 0) ? 0 : 3;
                    end
                end
            end
            PeerDmaAddress: begin
                if (nextWait > 0) nextWait = nextWait - 1;
                else if (mode != FAddressTimeout) begin
                    next = PeerDmaData;
                    nextWait = 0;
                    dataResponsePending <= False;
                end
            end
            PeerDmaData: begin
                if (dataResponsePending) begin
                    if (nextWait > 0) nextWait = nextWait - 1;
                    else if (mode != FDataTimeout) begin
                        dataResponsePending <= False;
                        if (isBusError(mode) && peerBeat == faultBeat(mode)) begin
                            next = PeerIdle;
                        end
                        else begin
                            Bit#(5) n = peerBeat + 1;
                            peerBeat <= n;
                            if (n == 4) next = PeerIdle;
                        end
                    end
                end
                else if (bp.controlValid && bp.control.dataStrobe) begin
                    dataResponsePending <= True;
                    if (mode == FWaits) nextWait = 2;
                    else if (mode == FDataTimeout) nextWait = 300;
                    else nextWait = 0;
                end
            end
            PeerNotificationAddress: begin
                if (notificationTransactions == 1) next = PeerIdle;
                else if (nextWait > 0) nextWait = nextWait - 1;
                else next = PeerNotificationData;
            end
            PeerNotificationData: begin
                if (nextWait > 0) nextWait = nextWait - 1;
                else if (bp.controlValid && bp.control.dataStrobe) next = PeerIdle;
            end
        endcase

        qic.advance(sampledBus, heldQli);
        peer <= next;
        peerWait <= nextWait;
        phy.finishCycle;
        phase <= 1;
    endrule

    rule finish (phase == 1 && mode == FDone);
        $display("PASS NakedCard physical fault matrix");
        $finish(0);
    endrule
endmodule

endpackage
