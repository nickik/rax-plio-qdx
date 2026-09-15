package QDXBCard;

import QLITypes::*;
import QICInterfaces::*;
import PLIOQIC::*;
import QLI16Codec::*;
import PLIOTx::*;
import PLIOTxCardHarness::*;
import QDXA::*;
import QDXAEndpointIfc::*;
import QDXAProfileDma::*;
import QDXBFakeMedia::*;
import QDXBEndpoint::*;

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
} QdxBCardPhase deriving (Bits,Eq,FShow);

interface QDXBCardIfc;
    method Bool ready;
    method Action startCycle(PlioIn image);
    method Bool cycleDone;
    method BackplaneDrive backplane;
    method Action finishCycle;
    method Bool protocolFault;
    method UnifiedQicState qicState;
    method QdxAState qdxState;
    method QdxAError qdxError;
    method Bit#(16) sqHead;
    method Bit#(16) sqTail;
    method Bit#(16) cqHead;
    method Bit#(16) cqTail;
    method QdxBState qdxbState;
    method Bit#(16) qdxbLastStatus;
    method Bit#(32) fakeFlushCount;
endinterface

module mkQDXBCard(QDXBCardIfc);
    PLIOQICIfc qic <- mkPLIOQIC;
    QLI16CodecIfc codec <- mkQLI16Codec;
    QDXAIfc qdx <- mkQDXA;
    QDXBMediaIfc media <- mkQDXBFakeMedia;
    QDXBEndpointIfc qdxb <- mkQDXBEndpoint(media);
    PLIOTxCardHarnessIfc phy <- mkPLIOTxCardHarness;

    Reg#(QdxBCardPhase) phase <- mkReg(CardIdle);
    Reg#(PlioIn) sampledBus <- mkReg(plioInDefault());
    Reg#(QliOut) heldQicSemantic <- mkReg(qliOutDefault());
    Reg#(QliIn) heldQli <- mkReg(qliInDefault());
    Reg#(BackplaneDrive) exposed <- mkReg(backplaneDriveDefault());
    Reg#(Bool) fault <- mkReg(False);

    method Bool ready = phase==CardIdle && phy.ready;

    method Action startCycle(PlioIn image) if (phase==CardIdle && phy.ready);
        action
            if (image.reset) begin
                qic.advance(image,qliInDefault());
                codec.resetCodec;
                QliOut qr=qliOutDefault(); qr.reset=True;
                QdxAEndpointOut eo=qdx.endpointPort(qr);
                QdxAEndpointIn ei=qdxb.endpointDrive(eo);
                qdx.advance(qr,ei);
                qdxb.advance(eo,qdxAProfileDmaOutDefault());
                phy.step(True);
                exposed<=backplaneDriveDefault(); fault<=False; phase<=CardExpose;
            end else begin
                phy.startReceive(image); phase<=CardRx;
            end
        endaction
    endmethod

    rule rxStep (phase==CardRx && !phy.receiveDone); phy.step(False); endrule
    rule rxDone (phase==CardRx && phy.receiveDone); sampledBus<=phy.toQic; phase<=CardLocalLoad; endrule

    rule loadLocal (phase==CardLocalLoad);
        PlioIn b=sampledBus;
        QliOut emptyQic=qliOutDefault();
        emptyQic.reset=b.reset;
        QliIn corePreview=qdx.qicPort(emptyQic);
        QliIn mergedPreview=mergeProfileDma(qdx.debugState,corePreview,qdxb.dmaDrive);
        QliOut qicSemantic=qic.driveQli(b,mergedPreview);
        heldQicSemantic<=qicSemantic;
        phase<=CardLocalPreview;
    endrule

    rule loadPhysicalLocal (phase==CardLocalPreview);
        QliOut qicSemantic=heldQicSemantic;
        QliIn coreSemantic=qdx.qicPort(qicSemantic);
        QliIn mergedSemantic=mergeProfileDma(qdx.debugState,coreSemantic,qdxb.dmaDrive);
        codec.load(qicSemantic,mergedSemantic);
        phase<=CardLocal0;
    endrule

    rule local0 (phase==CardLocal0); codec.step; phase<=CardLocal1; endrule
    rule local1 (phase==CardLocal1); codec.step; phase<=CardApply; endrule

    rule applyLocal (phase==CardApply && codec.cycleComplete);
        QliIn toQic=codec.toQic;
        QliOut toDevice=codec.toDevice;
        QdxAEndpointOut eo=qdx.endpointPort(toDevice);
        QdxAEndpointIn ei=qdxb.endpointDrive(eo);
        QdxAProfileDmaOut pd=profileDmaResponse(qdx.debugState,toDevice);
        qdx.advance(toDevice,ei);
        qdxb.advance(eo,pd);
        PlioOut po=qic.drivePlio(sampledBus,toQic);
        phy.startTransmit(po); heldQli<=toQic; phase<=CardTx;
    endrule

    rule txStep (phase==CardTx && !phy.transmitDone); phy.step(False); endrule
    rule txDone (phase==CardTx && phy.transmitDone);
        BackplaneDrive bp=phy.backplane;
        qic.advance(sampledBus,heldQli);
        exposed<=bp;
        if (phy.protocolFault || codec.protocolFault) fault<=True;
        phy.finishCycle; phase<=CardExpose;
    endrule

    method Bool cycleDone=phase==CardExpose;
    method BackplaneDrive backplane if (phase==CardExpose)=exposed;
    method Action finishCycle if (phase==CardExpose); phase<=CardIdle; endmethod
    method Bool protocolFault=fault || phy.protocolFault || codec.protocolFault;
    method UnifiedQicState qicState=qic.debugState;
    method QdxAState qdxState=qdx.debugState;
    method QdxAError qdxError=qdx.debugError;
    method Bit#(16) sqHead=qdx.debugSqHead;
    method Bit#(16) sqTail=qdx.debugSqTail;
    method Bit#(16) cqHead=qdx.debugCqHead;
    method Bit#(16) cqTail=qdx.debugCqTail;
    method QdxBState qdxbState=qdxb.debugState;
    method Bit#(16) qdxbLastStatus=qdxb.debugLastStatus;
    method Bit#(32) fakeFlushCount=qdxb.debugFlushCount;
endmodule

endpackage
