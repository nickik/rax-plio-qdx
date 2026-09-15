package TbNakedCardPhysical;

import QLITypes::*;
import QICInterfaces::*;
import PLIOQIC::*;
import PLIOQICPhase1::*;
import QLI16Codec::*;
import NakedDevice::*;
import PLIOTx::*;
import PLIOTxCardHarness::*;

typedef enum {
    HReadAddress, HReadData,
    HWriteAddress, HWriteData,
    HErrorAddress, HErrorData,
    HDone
} HostState deriving (Bits, Eq, FShow);

function PlioIn hostBus(HostState h);
    PlioIn b=plioInDefault();
    case (h)
        HReadAddress: begin
            b.selected=True; b.adValid=True; b.ad=32'h0000_0000; b.parValid=True; b.par=oddParity32P1(32'h0000_0000);
            b.spaceValid=True; b.space=PlioWorker; b.addressStrobe=True; b.read=True; b.byteEnable=4'hf; b.burst=BurstOne;
        end
        HReadData: begin b.selected=True; b.dataStrobe=True; b.read=True; b.byteEnable=4'hf; end
        HWriteAddress: begin
            b.selected=True; b.adValid=True; b.ad=32'h0000_0018; b.parValid=True; b.par=oddParity32P1(32'h0000_0018);
            b.spaceValid=True; b.space=PlioWorker; b.addressStrobe=True; b.read=False; b.byteEnable=4'hf; b.burst=BurstOne;
        end
        HWriteData: begin
            b.selected=True; b.dataStrobe=True; b.read=False; b.byteEnable=4'hf;
            b.adValid=True; b.ad=32'h1234_5678; b.parValid=True; b.par=oddParity32P1(32'h1234_5678);
        end
        HErrorAddress: begin
            b.selected=True; b.adValid=True; b.ad=32'h0000_0080; b.parValid=True; b.par=oddParity32P1(32'h0000_0080);
            b.spaceValid=True; b.space=PlioWorker; b.addressStrobe=True; b.read=True; b.byteEnable=4'hf; b.burst=BurstOne;
        end
        HErrorData: begin b.selected=True; b.dataStrobe=True; b.read=True; b.byteEnable=4'hf; end
        default: noAction;
    endcase
    return b;
endfunction

module mkTbNakedCardPhysical(Empty);
    PLIOQICIfc qic <- mkPLIOQIC;
    QLI16CodecIfc local <- mkQLI16Codec;
    NakedDeviceIfc dev <- mkNakedDevice;
    PLIOTxCardHarnessIfc phy <- mkPLIOTxCardHarness;

    Reg#(HostState) host <- mkReg(HReadAddress);
    Reg#(Bit#(4)) phase <- mkReg(0);
    Reg#(PlioIn) sampledBus <- mkReg(plioInDefault());
    Reg#(QliIn) heldQli <- mkReg(qliInDefault());

    rule resetAll (phase==0);
        PlioIn b=plioInDefault(); b.reset=True;
        qic.advance(b,qliInDefault());
        local.resetCodec;
        dev.resetDevice;
        phy.step(True);
        host<=HReadAddress;
        phase<=1;
    endrule

    rule startReceive (phase==1 && phy.ready && host!=HDone);
        phy.startReceive(hostBus(host));
        phase<=2;
    endrule

    rule receiveSteps (phase==2 && !phy.receiveDone);
        phy.step(False);
    endrule

    rule beginLocal (phase==2 && phy.receiveDone);
        PlioIn b=phy.toQic;
        QliIn d=qliInDefault();
        d.mmioReady=dev.requestReady;
        d.dmaCompletionReady=True;
        if (dev.responseValid) begin d.mmioResponseValid=True; d.mmioResponse=dev.response; end

        QliOut qo=qic.driveQli(b,qliInDefault());
        local.load(qo,d);
        sampledBus<=b;
        phase<=3;
    endrule

    rule localSlot0 (phase==3);
        local.step;
        phase<=4;
    endrule

    rule localSlot1 (phase==4);
        local.step;
        phase<=5;
    endrule

    rule applyLocalAndTransmit (phase==5 && local.cycleComplete);
        QliIn qi=local.toQic;
        QliOut qo=local.toDevice;

        if (qo.reset) dev.resetDevice;
        else begin
            if (qo.mmioCancel) dev.cancelRequest;
            if (qo.mmioRequestValid && dev.requestReady) dev.request(qo.mmioRequest);
            if (qo.mmioResponseReady && dev.responseValid) dev.responseTaken;
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
        HostState next=host;

        if (phy.protocolFault || local.protocolFault) begin
            $display("FAIL physical interface fault host=%0d",pack(host));
            $finish(1);
        end

        case (host)
            HReadAddress: begin
                if (bp.responseValid && bp.ack && !bp.err) next=HReadData;
            end
            HReadData: begin
                if (bp.responseValid && bp.err) begin $display("FAIL config read returned ERR"); $finish(1); end
                if (bp.responseValid && bp.ack) begin
                    if (!bp.adParValid || bp.ad!=32'h504c_494f || bp.par!=oddParity32P1(32'h504c_494f)) begin
                        $display("FAIL config read data/parity"); $finish(1);
                    end
                    $display("NAKEDTRACE|v1|case=worker_read|ad=%08x|ack=1|err=0",bp.ad);
                    next=HWriteAddress;
                end
            end
            HWriteAddress: if (bp.responseValid && bp.ack && !bp.err) next=HWriteData;
            HWriteData: begin
                if (bp.responseValid && bp.err) begin $display("FAIL DEVICE_CONTROL write ERR"); $finish(1); end
                if (bp.responseValid && bp.ack) begin
                    $display("NAKEDTRACE|v1|case=worker_write|ack=1|err=0");
                    next=HErrorAddress;
                end
            end
            HErrorAddress: if (bp.responseValid && bp.ack && !bp.err) next=HErrorData;
            HErrorData: begin
                if (bp.responseValid && bp.ack) begin $display("FAIL unsupported read ACKed"); $finish(1); end
                if (bp.responseValid && bp.err) begin
                    $display("NAKEDTRACE|v1|case=unsupported|ack=0|err=1");
                    next=HDone;
                end
            end
            default: noAction;
        endcase

        qic.advance(sampledBus,heldQli);
        phy.finishCycle;
        host<=next;
        phase<=1;
    endrule

    rule finish (phase==1 && host==HDone);
        $display("PASS NakedCard PLIO -> PLIO-TX -> PTI -> QIC -> QLI-16 -> NakedDevice");
        $finish(0);
    endrule
endmodule

endpackage
