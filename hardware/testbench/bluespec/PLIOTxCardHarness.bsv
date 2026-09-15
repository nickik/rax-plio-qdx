package PLIOTxCardHarness;

import QLITypes::*;
import QICInterfaces::*;
import PTIEncoding::*;
import PLIOTx::*;

typedef enum {
    CIdle,
    CRxTurn, CRxControl, CRxDataLo, CRxDataHi, CRxDone,
    CTxTurn, CTxControl, CTxDataLo, CTxDataHi, CTxExpose, CTxDone
} CardHarnessState deriving (Bits, Eq, FShow);

interface PLIOTxCardHarnessIfc;
    method Bool ready;
    method Action startReceive(PlioIn image);
    method Bool receiveDone;
    method PlioIn toQic;
    method Action startTransmit(PlioOut image);
    method Bool transmitDone;
    method BackplaneDrive backplane;
    method Action finishCycle;
    method Action step(Bool reset);
    method Bool protocolFault;
endinterface

module mkPLIOTxCardHarness(PLIOTxCardHarnessIfc);
    PLIOTxIfc tx <- mkPLIOTx;
    Reg#(CardHarnessState) state <- mkReg(CIdle);
    Reg#(PlioIn) heldIn <- mkReg(plioInDefault());
    Reg#(PlioOut) heldOut <- mkReg(plioOutDefault());
    Reg#(PlioIn) sampled <- mkReg(plioInDefault());
    Reg#(Bit#(16)) rxLow <- mkReg(0);
    Reg#(Bit#(2)) rxLowPar <- mkReg(0);
    Reg#(BackplaneDrive) exposed <- mkReg(backplaneDriveDefault());

    function BackplaneSample sampleImage(PlioIn x);
        BackplaneSample b=backplaneSampleDefault();
        b.ad=x.ad; b.par=x.par;
        b.control=BackplaneControl {
            space:pack(x.space), addressStrobe:x.addressStrobe, read:x.read,
            byteEnable:x.byteEnable, burstLen:pack(x.burst), dataStrobe:x.dataStrobe
        };
        b.ack=x.ack; b.err=x.err; b.selected=x.selected; b.grant=x.grant;
        return b;
    endfunction

    function Bool inHasControl(PlioIn x);
        return x.spaceValid || x.addressStrobe || x.dataStrobe;
    endfunction
    function Bool inHasData(PlioIn x); return x.adValid && x.parValid; endfunction
    function Bool outHasControl(PlioOut x);
        return x.spaceValid || x.addressStrobe || x.dataStrobe;
    endfunction
    function Bool outHasData(PlioOut x); return x.adValid && x.parValid; endfunction
    function Bool needsOutDrive(PlioOut x); return outHasControl(x) || outHasData(x); endfunction

    function QicPtiDrive rxSelect(PtiTokenKind kind);
        QicPtiDrive q=qicPtiDriveDefault();
        q.direction=PtiTxToQic; q.token=ptiToken(kind,0,0); return q;
    endfunction

    function QicPtiDrive txToken(PtiToken token);
        QicPtiDrive q=qicPtiDriveDefault(); q.direction=PtiQicToTx; q.token=token; return q;
    endfunction

    function PtiControlImage outControl(PlioOut x);
        return PtiControlImage {
            space:pack(x.space), addressStrobe:x.addressStrobe, read:x.read,
            byteEnable:x.byteEnable, burstLen:pack(x.burst), dataStrobe:x.dataStrobe,
            driveAdPar:outHasData(x), driveControl:outHasControl(x)
        };
    endfunction

    method Bool ready = state==CIdle;

    method Action startReceive(PlioIn image) if (state==CIdle);
        action
            heldIn<=image;
            sampled<=plioInDefault();
            state<=CRxTurn;
        endaction
    endmethod

    method Bool receiveDone = state==CRxDone;
    method PlioIn toQic if (state==CRxDone) = sampled;

    method Action startTransmit(PlioOut image) if (state==CRxDone);
        action
            heldOut<=image;
            state<=CTxTurn;
        endaction
    endmethod

    method Bool transmitDone = state==CTxDone;
    method BackplaneDrive backplane if (state==CTxDone) = exposed;

    method Action finishCycle if (state==CTxDone);
        state<=CIdle;
    endmethod

    method Action step(Bool reset);
        action
            BackplaneSample b=sampleImage(heldIn);
            QicPtiDrive q=qicPtiDriveDefault();
            PtiObserve obs=ptiObserveDefault();

            if (reset) begin
                q=txToken(ptiToken(PtiIdle,0,0));
                tx.advance(True,q,b);
                sampled<=plioInDefault(); exposed<=backplaneDriveDefault(); state<=CIdle;
            end
            else case (state)
                CIdle: begin
                    q=txToken(ptiToken(PtiIdle,0,0));
                    tx.advance(False,q,b);
                end
                CRxTurn: begin
                    q=rxSelect(PtiIdle);
                    obs=tx.observeQic(False,q,b);
                    PlioIn s=sampled;
                    s.reset=heldIn.reset; s.selected=obs.sampleSelected; s.grant=obs.sampleGrant;
                    s.ack=obs.sampleAck; s.err=obs.sampleErr;
                    sampled<=s;
                    tx.advance(False,q,b);
                    if (inHasControl(heldIn)) state<=CRxControl;
                    else if (inHasData(heldIn)) state<=CRxDataLo;
                    else state<=CRxDone;
                end
                CRxControl: begin
                    q=rxSelect(PtiControl);
                    obs=tx.observeQic(False,q,b);
                    if (obs.rxValid) begin
                        PtiControlImage c=unpackControl(ptiData(obs.rxToken));
                        PlioIn s=sampled;
                        s.spaceValid=heldIn.spaceValid; s.space=unpack(c.space);
                        s.addressStrobe=c.addressStrobe; s.read=c.read; s.byteEnable=c.byteEnable;
                        s.burst=unpack(c.burstLen); s.dataStrobe=c.dataStrobe;
                        sampled<=s;
                    end
                    tx.advance(False,q,b);
                    state <= inHasData(heldIn) ? CRxDataLo : CRxDone;
                end
                CRxDataLo: begin
                    q=rxSelect(PtiDataLo);
                    obs=tx.observeQic(False,q,b);
                    if (obs.rxValid) begin rxLow<=ptiData(obs.rxToken); rxLowPar<=ptiParity(obs.rxToken); end
                    tx.advance(False,q,b); state<=CRxDataHi;
                end
                CRxDataHi: begin
                    q=rxSelect(PtiDataHi);
                    obs=tx.observeQic(False,q,b);
                    if (obs.rxValid) begin
                        PlioIn s=sampled;
                        s.adValid=True; s.ad={ptiData(obs.rxToken),rxLow};
                        s.parValid=True; s.par={ptiParity(obs.rxToken),rxLowPar};
                        sampled<=s;
                    end
                    tx.advance(False,q,b); state<=CRxDone;
                end
                CRxDone: noAction;

                CTxTurn: begin
                    q=txToken(ptiToken(PtiIdle,0,0)); tx.advance(False,q,b);
                    if (needsOutDrive(heldOut)) state<=CTxControl;
                    else state<=CTxExpose;
                end
                CTxControl: begin
                    q=txToken(controlToken(outControl(heldOut))); tx.advance(False,q,b);
                    state <= outHasData(heldOut) ? CTxDataLo : CTxExpose;
                end
                CTxDataLo: begin q=txToken(dataLo(heldOut.ad,heldOut.par)); tx.advance(False,q,b); state<=CTxDataHi; end
                CTxDataHi: begin q=txToken(dataHi(heldOut.ad,heldOut.par)); tx.advance(False,q,b); state<=CTxExpose; end
                CTxExpose: begin
                    q=txToken(ptiToken(PtiIdle,0,0));
                    q.driveEnable=needsOutDrive(heldOut);
                    q.responseEnable=heldOut.ack||heldOut.err; q.responseAck=heldOut.ack; q.responseErr=heldOut.err;
                    q.busRequest=heldOut.request;
                    exposed<=tx.driveBackplane(False,q,b);
                    tx.advance(False,q,b); state<=CTxDone;
                end
                CTxDone: noAction;
            endcase
        endaction
    endmethod

    method Bool protocolFault = tx.debugProtocolFault;
endmodule

endpackage
