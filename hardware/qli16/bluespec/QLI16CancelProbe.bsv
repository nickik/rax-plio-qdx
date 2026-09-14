package QLI16CancelProbe;

import QLI16Encoding::*;

interface QLI16CancelProbeIfc;
    method Bit#(1) direction;
    method Bit#(3) kind;
    method Bit#(16) payload;
    method Bit#(8) heartbeat;
endinterface

(* synthesize *)
module mkQLI16CancelProbe(QLI16CancelProbeIfc);
    // Keep a small real sequential path in the smoke target so BSC -> Verilog
    // -> Yosys -> nextpnr exercises clocked logic and a 5 MHz timing target,
    // instead of allowing an all-constant probe to optimize the clock away.
    Reg#(Bit#(8)) heartbeatReg <- mkReg(0);

    rule tick;
        heartbeatReg <= heartbeatReg + 1;
    endrule

    method Bit#(1) direction;
        Qli16Token cancel = mmioCancelToken();
        return cancel.direction;
    endmethod

    method Bit#(3) kind;
        Qli16Token cancel = mmioCancelToken();
        return pack(cancel.kind);
    endmethod

    method Bit#(16) payload;
        Qli16Token cancel = mmioCancelToken();
        return cancel.payload;
    endmethod

    method Bit#(8) heartbeat = heartbeatReg;
endmodule

endpackage
