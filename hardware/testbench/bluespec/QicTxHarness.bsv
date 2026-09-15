package QicTxHarness;

import QLITypes::*;
import QICInterfaces::*;
import PTIEncoding::*;
import PLIOTx::*;

typedef enum { HIdle, HControl, HDataLo, HDataHi, HTurn, HExpose } HarnessState deriving (Bits, Eq, FShow);

interface QicTxHarnessIfc;
    method Bool ready;
    method Action start(PlioOut image);
    method Action step(Bool reset);
    method Bool done;
    method BackplaneDrive backplane;
    method Bool protocolFault;
endinterface

module mkQicTxHarness(QicTxHarnessIfc);
    PLIOTxIfc tx <- mkPLIOTx;
    Reg#(HarnessState) state <- mkReg(HIdle);
    Reg#(PlioOut) held <- mkReg(plioOutDefault());
    Reg#(BackplaneDrive) exposed <- mkReg(backplaneDriveDefault());
    Reg#(Bool) donePulse <- mkReg(False);

    function Bool hasControl(PlioOut x);
        return x.spaceValid || x.addressStrobe || x.dataStrobe;
    endfunction
    function Bool hasData(PlioOut x); return x.adValid && x.parValid; endfunction
    function QicPtiDrive baseDrive(PtiToken t);
        QicPtiDrive q=qicPtiDriveDefault(); q.token=t; return q;
    endfunction
    function PtiControlImage controlImage(PlioOut x);
        return PtiControlImage { space:pack(x.space), addressStrobe:x.addressStrobe, read:x.read,
            byteEnable:x.byteEnable, burstLen:pack(x.burst), dataStrobe:x.dataStrobe,
            driveAdPar:hasData(x), driveControl:hasControl(x) };
    endfunction

    method Bool ready = state==HIdle;
    method Action start(PlioOut image) if (state==HIdle);
        action
            held<=image; donePulse<=False;
            if (hasControl(image)) state<=HControl;
            else if (hasData(image)) state<=HDataLo;
            else state<=HTurn;
        endaction
    endmethod

    method Action step(Bool reset);
        action
            QicPtiDrive q=qicPtiDriveDefault();
            BackplaneSample b=backplaneSampleDefault();
            donePulse<=False;
            case (state)
                HIdle: begin q.token=ptiToken(PtiIdle,0,0); tx.advance(reset,q,b); end
                HControl: begin
                    q=baseDrive(controlToken(controlImage(held))); tx.advance(reset,q,b);
                    state <= hasData(held) ? HDataLo : HTurn;
                end
                HDataLo: begin q=baseDrive(dataLo(held.ad,held.par)); tx.advance(reset,q,b); state<=HDataHi; end
                HDataHi: begin q=baseDrive(dataHi(held.ad,held.par)); tx.advance(reset,q,b); state<=HTurn; end
                HTurn: begin q=baseDrive(ptiToken(PtiIdle,0,0)); tx.advance(reset,q,b); state<=HExpose; end
                HExpose: begin
                    q=baseDrive(ptiToken(PtiIdle,0,0));
                    q.driveEnable=hasControl(held); q.responseEnable=held.ack||held.err;
                    q.responseAck=held.ack; q.responseErr=held.err; q.busRequest=held.request;
                    exposed<=tx.driveBackplane(reset,q,b); tx.advance(reset,q,b);
                    donePulse<=True; state<=HIdle;
                end
            endcase
        endaction
    endmethod
    method Bool done=donePulse;
    method BackplaneDrive backplane=exposed;
    method Bool protocolFault=tx.debugProtocolFault;
endmodule

endpackage
