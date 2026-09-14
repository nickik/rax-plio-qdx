package QLI16CancelProbe;

import QLI16Encoding::*;

interface QLI16CancelProbeIfc;
    method Bit#(1) direction;
    method Bit#(3) kind;
    method Bit#(16) payload;
endinterface

(* synthesize *)
module mkQLI16CancelProbe(QLI16CancelProbeIfc);
    Qli16Token cancel = mmioCancelToken();

    method Bit#(1) direction = cancel.direction;
    method Bit#(3) kind = pack(cancel.kind);
    method Bit#(16) payload = cancel.payload;
endmodule

endpackage
