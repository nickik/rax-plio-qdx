package TbNakedCardProtocolPhysical;

import QLITypes::*;
import QICInterfaces::*;
import PLIOQIC::*;
import PLIOQICPhase1::*;
import QLI16Codec::*;
import PLIOTx::*;
import PLIOTxCardHarness::*;

typedef enum { ModeD2H, ModeH2D, ModeNotify, ModeDone } ProbeMode deriving (Bits, Eq, FShow);
typedef enum { PeerIdle, PeerGrant, PeerDmaAddress, PeerDmaData, PeerNotificationAddress, PeerNotificationData } PeerState deriving (Bits, Eq, FShow);

function BurstWords burstFor(Bit#(2) i);
    case (i)
        0: return BurstOne;
        1: return BurstFour;
        2: return BurstEight;
        default: return BurstSixteen;
    endcase
endfunction

function Bit#(5) wordCountFor(Bit#(2) i);
    return burstWordCount(burstFor(i));
endfunction

module mkTbNakedCardProtocolPhysical(Empty);
    PLIOQICIfc qic <- mkPLIOQIC;
    QLI16CodecIfc local <- mkQLI16Codec;
    PLIOTxCardHarnessIfc phy <- mkPLIOTxCardHarness;

    Reg#(ProbeMode) mode <- mkReg(ModeD2H);
    Reg#(Bit#(2)) burstIndex <- mkReg(0);
    Reg#(Bool) requestPending <- mkReg(True);
    Reg#(Bit#(5)) deviceIndex <- mkReg(0);

    Reg#(PeerState) peer <- mkReg(PeerIdle);
    Reg#(Bool) peerRead <- mkReg(False);
    Reg#(Bit#(5)) peerTotal <- mkReg(0);
    Reg#(Bit#(5)) peerBeat <- mkReg(0);

    Reg#(Bit#(4)) phase <- mkReg(0);
    Reg#(PlioIn) sampledBus <- mkReg(plioInDefault());
    Reg#(QliIn) heldQli <- mkReg(qliInDefault());

    function DmaRequest currentRequest(ProbeMode m, Bit#(2) bi);
        return DmaRequest {
            direction:(m==ModeD2H ? DeviceToHost : HostToDevice),
            address:32'h1234_5000,
            words:burstFor(bi)
        };
    endfunction

    function PlioIn peerBus(PeerState p, Bool read, Bit#(5) beat);
        PlioIn b=plioInDefault();
        case (p)
            PeerGrant: b.grant=True;
            PeerDmaAddress: begin b.grant=True; b.ack=True; end
            PeerDmaData: begin
                b.grant=True; b.ack=True;
                if (read) begin
                    Bit#(32) data=32'h7000_0000 + zeroExtend(beat)*4;
                    b.adValid=True; b.ad=data; b.parValid=True; b.par=oddParity32P1(data);
                end
            end
            PeerNotificationAddress: begin b.grant=True; b.ack=True; end
            PeerNotificationData: begin b.grant=True; b.ack=True; end
            default: begin end
        endcase
        return b;
    endfunction

    rule resetAll (phase==0);
        PlioIn b=plioInDefault(); b.reset=True;
        qic.advance(b,qliInDefault());
        local.resetCodec; phy.step(True);
        mode<=ModeD2H; burstIndex<=0; requestPending<=True; deviceIndex<=0;
        peer<=PeerIdle; peerBeat<=0;
        phase<=1;
    endrule

    rule startReceive (phase==1 && phy.ready && mode!=ModeDone);
        phy.startReceive(peerBus(peer,peerRead,peerBeat));
        phase<=2;
    endrule

    rule receiveSteps (phase==2 && !phy.receiveDone);
        phy.step(False);
    endrule

    rule beginLocal (phase==2 && phy.receiveDone);
        PlioIn b=phy.toQic;
        QliIn d=qliInDefault();
        QliIn preview=qliInDefault();
        d.dmaCompletionReady=True;

        if (mode==ModeD2H || mode==ModeH2D) begin
            DmaRequest r=currentRequest(mode,burstIndex);
            if (requestPending) begin
                d.dmaRequestValid=True; d.dmaRequest=r;
                preview.dmaRequestValid=True; preview.dmaRequest=r;
            end
            else if (mode==ModeD2H && deviceIndex < wordCountFor(burstIndex)) begin
                d.dmaWriteValid=True;
                d.dmaWrite=DmaWord { data:32'h4000_0000 + zeroExtend(deviceIndex)*4 };
            end
            if (mode==ModeH2D) d.dmaReadReady=True;
        end
        else if (mode==ModeNotify) begin
            NotificationRequest n=NotificationRequest { channel:2 };
            d.notificationValid=True; d.notification=n;
            preview.notificationValid=True; preview.notification=n;
        end

        QliOut qo=qic.driveQli(b,preview);
        local.load(qo,d);
        sampledBus<=b;
        phase<=3;
    endrule

    rule localSlot0 (phase==3);
        local.step; phase<=4;
    endrule

    rule localSlot1 (phase==4);
        local.step; phase<=5;
    endrule

    rule applyLocalAndTransmit (phase==5 && local.cycleComplete);
        QliIn qi=local.toQic;
        QliOut qo=local.toDevice;

        if (qo.dmaRequestReady) begin requestPending<=False; deviceIndex<=0; end
        if (qo.dmaWriteReady) deviceIndex<=deviceIndex+1;
        if (qo.dmaReadValid) begin
            Bit#(32) expect=32'h7000_0000 + zeroExtend(deviceIndex)*4;
            if (qo.dmaRead.data!=expect) begin $display("FAIL H2D QLI-16 data expected=%08x got=%08x",expect,qo.dmaRead.data); $finish(1); end
            deviceIndex<=deviceIndex+1;
        end

        if (qo.dmaCompletionValid) begin
            Bit#(5) expected=wordCountFor(burstIndex);
            if (qo.dmaCompletion.status!=DmaOk || qo.dmaCompletion.wordsCompleted!=expected) begin
                $display("FAIL DMA completion mode=%0d burst=%0d status=%0d count=%0d",pack(mode),burstIndex,pack(qo.dmaCompletion.status),qo.dmaCompletion.wordsCompleted);
                $finish(1);
            end
            if (mode==ModeD2H)
                $display("NAKEDTRACE|v1|case=d2h|words=%0d|status=0",expected);
            else
                $display("NAKEDTRACE|v1|case=h2d|words=%0d|status=0",expected);
            if (burstIndex==3) begin
                if (mode==ModeD2H) begin mode<=ModeH2D; burstIndex<=0; end
                else begin mode<=ModeNotify; burstIndex<=0; end
            end
            else burstIndex<=burstIndex+1;
            requestPending<=True; deviceIndex<=0;
        end

        if (mode==ModeNotify && qo.notificationReady) begin
            $display("NAKEDTRACE|v1|case=notification|channel=2|ready=1");
            mode<=ModeDone;
        end

        PlioOut po=qic.drivePlio(sampledBus,qi);
        phy.startTransmit(po);
        heldQli<=qi;
        phase<=6;
    endrule

    rule transmitSteps (phase==6 && !phy.transmitDone);
        phy.step(False);
    endrule

    rule finishLogicalCycle (phase==6 && phy.transmitDone);
        BackplaneDrive bp=phy.backplane;
        PeerState next=peer;

        if (phy.protocolFault || local.protocolFault) begin
            $display("FAIL protocol fault in physical probe"); $finish(1);
        end

        case (peer)
            PeerIdle: begin
                if (bp.request) next=PeerGrant;
            end
            PeerGrant: begin
                if (bp.controlValid && bp.control.addressStrobe) begin
                    if (bp.control.space==1) begin
                        peerRead<=bp.control.read;
                        case (bp.control.burstLen)
                            0: peerTotal<=1;
                            1: peerTotal<=4;
                            2: peerTotal<=8;
                            default: peerTotal<=16;
                        endcase
                        peerBeat<=0;
                        next=PeerDmaAddress;
                    end
                    else if (bp.control.space==2) begin
                        if (bp.ad!=8) begin $display("FAIL notification address %08x",bp.ad); $finish(1); end
                        next=PeerNotificationAddress;
                    end
                end
            end
            PeerDmaAddress: begin
                if (bp.controlValid && bp.control.addressStrobe) next=PeerDmaData;
            end
            PeerDmaData: begin
                if (bp.controlValid && bp.control.dataStrobe) begin
                    if (!peerRead) begin
                        Bit#(32) expect=32'h4000_0000 + zeroExtend(peerBeat)*4;
                        if (!bp.adParValid || bp.ad!=expect || bp.par!=oddParity32P1(expect)) begin
                            $display("FAIL D2H PLIO data beat=%0d",peerBeat); $finish(1);
                        end
                    end
                    Bit#(5) n=peerBeat+1;
                    peerBeat<=n;
                    if (n==peerTotal) next=PeerIdle;
                end
            end
            PeerNotificationAddress: begin
                if (bp.controlValid && bp.control.addressStrobe) next=PeerNotificationData;
            end
            PeerNotificationData: begin
                if (bp.controlValid && bp.control.dataStrobe) begin
                    if (!bp.adParValid || bp.ad!=0) begin $display("FAIL notification data"); $finish(1); end
                    next=PeerIdle;
                end
            end
        endcase

        qic.advance(sampledBus,heldQli);
        peer<=next;
        phy.finishCycle;
        phase<=1;
    endrule

    rule finish (phase==1 && mode==ModeDone);
        $display("PASS NakedCard physical DMA/Notification probe all burst sizes");
        $finish(0);
    endrule
endmodule

endpackage
