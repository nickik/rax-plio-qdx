package QDXACard;

import QLITypes::*;
import QICInterfaces::*;
import PLIOQIC::*;
import QLI16Codec::*;
import PLIOTx::*;
import PLIOTxCardHarness::*;
import QDXA::*;
import QDXAEndpointIfc::*;
import QDXATestEndpoint::*;

typedef enum {
    CardIdle,
    CardRx,
    CardLocalLoad,
    CardLocalPreview,
    CardLocal0,
    CardLocal1,
    CardApply,
    CardTx,
    CardExpose
} QdxACardPhase deriving (Bits, Eq, FShow);

interface QDXACardIfc;
    method Bool ready;
    method Action startCycle(PlioIn image);
    method Bool cycleDone;
    method BackplaneDrive backplane;
    method Action finishCycle;

    method Bool protocolFault;
    method QdxAState qdxState;
    method QdxAError qdxError;
    method Bit#(16) sqHead;
    method Bit#(16) sqTail;
    method Bit#(16) cqHead;
    method Bit#(16) cqTail;
    method Bit#(32) endpointLastCommand0;
endinterface

module mkQDXACard(QDXACardIfc);
    PLIOQICIfc qic <- mkPLIOQIC;
    QLI16CodecIfc qliCodec <- mkQLI16Codec;
    QDXAIfc qdx <- mkQDXA;
    QDXATestEndpointIfc endpoint <- mkQDXATestEndpoint;
    PLIOTxCardHarnessIfc phy <- mkPLIOTxCardHarness;

    Reg#(QdxACardPhase) phase <- mkReg(CardIdle);
    Reg#(PlioIn) sampledBus <- mkReg(plioInDefault());
    Reg#(QliOut) heldQicSemantic <- mkReg(qliOutDefault());
    Reg#(QliIn) heldQli <- mkReg(qliInDefault());
    Reg#(BackplaneDrive) exposed <- mkReg(backplaneDriveDefault());
    Reg#(Bool) fault <- mkReg(False);

    rule rxStep (phase == CardRx && !phy.receiveDone);
        phy.step(False);
    endrule

    rule rxDone (phase == CardRx && phy.receiveDone);
        sampledBus <= phy.toQic;
        phase <= CardLocalLoad;
    endrule

    rule loadLocal (phase == CardLocalLoad);
        PlioIn b = sampledBus;

        // QIC needs only a request-valid/ready preview while idle. Keep this
        // preview in its own phase so the same combinational QDX-A method is
        // not called both to produce the preview and consume its result.
        // No transfer is accepted here and no payload bypasses QLI-16.
        QliOut emptyQic = qliOutDefault();
        emptyQic.reset = b.reset;
        QliIn devicePreview = qdx.qicPort(emptyQic);
        QliOut qicSemantic = qic.driveQli(b, devicePreview);

        heldQicSemantic <= qicSemantic;
        phase <= CardLocalPreview;
    endrule

    rule loadPhysicalLocal (phase == CardLocalPreview);
        QliOut qicSemantic = heldQicSemantic;
        QliIn qdxSemantic = qdx.qicPort(qicSemantic);
        qliCodec.load(qicSemantic, qdxSemantic);
        phase <= CardLocal0;
    endrule

    rule local0 (phase == CardLocal0);
        qliCodec.step;
        phase <= CardLocal1;
    endrule

    rule local1 (phase == CardLocal1);
        qliCodec.step;
        phase <= CardApply;
    endrule

    rule applyLocal (phase == CardApply && qliCodec.cycleComplete);
        QliIn toQic = qliCodec.toQic;
        QliOut toQdx = qliCodec.toDevice;

        QdxAEndpointOut eo = qdx.endpointPort(toQdx);
        QdxAEndpointIn ei = endpoint.drive(eo);
        qdx.advance(toQdx, ei);
        endpoint.advance(eo);

        PlioOut po = qic.drivePlio(sampledBus, toQic);
        phy.startTransmit(po);
        heldQli <= toQic;
        phase <= CardTx;
    endrule

    rule txStep (phase == CardTx && !phy.transmitDone);
        phy.step(False);
    endrule

    rule txDone (phase == CardTx && phy.transmitDone);
        BackplaneDrive bp = phy.backplane;
        qic.advance(sampledBus, heldQli);
        exposed <= bp;
        if (phy.protocolFault || qliCodec.protocolFault)
            fault <= True;
        phy.finishCycle;
        phase <= CardExpose;
    endrule

    method Bool ready = phase == CardIdle && phy.ready;

    method Action startCycle(PlioIn image) if (phase == CardIdle && phy.ready);
        action
            if (image.reset) begin
                QliOut qr = qliOutDefault();
                qr.reset = True;
                QdxAEndpointOut eo = qdx.endpointPort(qr);
                QdxAEndpointIn ei = endpoint.drive(eo);

                qic.advance(image, qliInDefault());
                qliCodec.resetCodec;
                qdx.advance(qr, ei);
                endpoint.advance(eo);
                phy.step(True);
                exposed <= backplaneDriveDefault();
                fault <= False;
                phase <= CardExpose;
            end
            else begin
                phy.startReceive(image);
                phase <= CardRx;
            end
        endaction
    endmethod

    method Bool cycleDone = phase == CardExpose;
    method BackplaneDrive backplane if (phase == CardExpose) = exposed;

    method Action finishCycle if (phase == CardExpose);
        phase <= CardIdle;
    endmethod

    method Bool protocolFault = fault || phy.protocolFault || qliCodec.protocolFault;
    method QdxAState qdxState = qdx.debugState;
    method QdxAError qdxError = qdx.debugError;
    method Bit#(16) sqHead = qdx.debugSqHead;
    method Bit#(16) sqTail = qdx.debugSqTail;
    method Bit#(16) cqHead = qdx.debugCqHead;
    method Bit#(16) cqTail = qdx.debugCqTail;
    method Bit#(32) endpointLastCommand0 = endpoint.debugLastCommand0;
endmodule

endpackage
