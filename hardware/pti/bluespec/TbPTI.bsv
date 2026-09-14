package TbPTI;

import PTIEncoding::*;

function Action showToken(PtiToken t);
    action
        $write(" %0h:%05h", pack(t.kind), t.ptd);
    endaction
endfunction

module mkTbPTI(Empty);
    Reg#(Bool) done <- mkReg(False);

    rule run (!done);
        $write("VECTOR PTI_DATA");
        showToken(dataLo(32'h89ab_cdef, 4'b1010));
        showToken(dataHi(32'h89ab_cdef, 4'b1010));
        $display("");

        $write("VECTOR PTI_DATA_ZERO");
        showToken(dataLo(0, 0));
        showToken(dataHi(0, 0));
        $display("");

        PtiControlImage control = PtiControlImage {
            space: 2,
            addressStrobe: True,
            read: True,
            byteEnable: 4'hf,
            burstLen: 3,
            dataStrobe: True,
            driveAdPar: True,
            driveControl: False
        };
        $write("VECTOR PTI_CONTROL");
        showToken(controlToken(control));
        $display("");

        $display("PASS PTI conformance vectors");
        done <= True;
    endrule

    rule finish (done);
        $finish(0);
    endrule
endmodule

endpackage
