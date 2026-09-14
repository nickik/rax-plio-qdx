package TbTraceFormat;

module mkTbTraceFormat(Empty);
    Reg#(Bool) done <- mkReg(False);

    rule emit (!done);
        $display("TRACE|v1|c=0000002a|pi=0.1.0.1.00000100.1.7.1.0.1.1.f.0.0.0.0|qi=1.0.0.00000000.0.0.00000000.0.1.0.00000000.1.0.0|po=0.0.00000000.0.0.0.0.0.0.0.0.0.0.0|qo=0.0.00000000.0.0.00000000.0.0.0.0.00000000.0.0.0.00.0|ev=worker_address");
        done <= True;
    endrule

    rule finish (done);
        $finish(0);
    endrule
endmodule

endpackage
