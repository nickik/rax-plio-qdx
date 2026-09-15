package QDXATestEndpoint;

import Vector::*;
import QDXAEndpointIfc::*;

interface QDXATestEndpointIfc;
    method QdxAEndpointIn drive(QdxAEndpointOut fromQdx);
    method Action advance(QdxAEndpointOut fromQdx);
    method Bool debugPending;
    method Bit#(32) debugLastCommand0;
endinterface

module mkQDXATestEndpoint(QDXATestEndpointIfc);
    Reg#(Bool) pending <- mkReg(False);
    Reg#(QdxACompletion) completion <- mkReg(replicate(0));
    Reg#(Bit#(32)) lastCommand0 <- mkReg(0);

    function QdxACompletion makeCompletion(QdxACommand cmd);
        QdxACompletion c = replicate(0);
        // Deterministic validation-only completion. Keep enough command data
        // visible to prove the opaque descriptor crossed the complete card.
        c[0] = 32'hc001_0000 | (cmd[0] & 32'h0000_ffff);
        c[1] = cmd[1];
        c[2] = cmd[6];
        c[3] = cmd[7];
        return c;
    endfunction

    method QdxAEndpointIn drive(QdxAEndpointOut fromQdx);
        QdxAEndpointIn e = qdxAEndpointInDefault();
        e.commandReady = !pending && !fromQdx.reset;
        e.completionValid = pending;
        e.completion = completion;
        return e;
    endmethod

    method Action advance(QdxAEndpointOut fromQdx);
        action
            if (fromQdx.reset) begin
                pending <= False;
                completion <= replicate(0);
                lastCommand0 <= 0;
            end
            else begin
                if (fromQdx.commandValid && !pending) begin
                    completion <= makeCompletion(fromQdx.command);
                    lastCommand0 <= fromQdx.command[0];
                    pending <= True;
                end
                if (fromQdx.completionReady && pending)
                    pending <= False;
            end
        endaction
    endmethod

    method Bool debugPending = pending;
    method Bit#(32) debugLastCommand0 = lastCommand0;
endmodule

endpackage
