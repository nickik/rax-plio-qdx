package TbNakedDevice;

import QLITypes::*;
import NakedDevice::*;

function MmioRequest vectorRequest(Bit#(4) index);
    case (index)
        0: return MmioRequest { address: 32'h0000_0000, write: False, byteEnable: 4'hf, writeData: 0 };
        1: return MmioRequest { address: 32'h0000_0004, write: False, byteEnable: 4'hf, writeData: 0 };
        2: return MmioRequest { address: 32'h0000_0004, write: False, byteEnable: 4'h3, writeData: 0 };
        3: return MmioRequest { address: 32'h0000_0006, write: False, byteEnable: 4'hc, writeData: 0 };
        4: return MmioRequest { address: 32'h0000_000b, write: False, byteEnable: 4'h8, writeData: 0 };
        5: return MmioRequest { address: 32'h0000_0010, write: False, byteEnable: 4'hf, writeData: 0 };
        6: return MmioRequest { address: 32'h0000_0005, write: False, byteEnable: 4'h3, writeData: 0 };
        7: return MmioRequest { address: 32'h0000_0080, write: False, byteEnable: 4'hf, writeData: 0 };
        8: return MmioRequest { address: 32'h0000_0018, write: True, byteEnable: 4'hf, writeData: 32'h1234_5678 };
        default: return MmioRequest { address: 0, write: False, byteEnable: 0, writeData: 0 };
    endcase
endfunction

function MmioResponse expectedResponse(Bit#(4) index);
    case (index)
        0: return mmioReadOk(32'h504c_494f);
        1: return mmioReadOk(32'h0001_ffff);
        2: return mmioReadOk(32'h0001_ffff);
        3: return mmioReadOk(32'h0001_ffff);
        4: return mmioReadOk(32'h0100_0001);
        5: return mmioReadOk(32'h0000_0100);
        6: return mmioError();
        7: return mmioError();
        8: return mmioWriteOk();
        default: return mmioError();
    endcase
endfunction

module mkTbNakedDevice(Empty);
    NakedDeviceIfc dut <- mkNakedDevice;
    Reg#(Bit#(4)) index <- mkReg(0);
    Reg#(Bool) waiting <- mkReg(False);

    rule issue (index < 9 && !waiting && dut.requestReady);
        dut.request(vectorRequest(index));
        waiting <= True;
    endrule

    rule check (index < 9 && waiting && dut.responseValid);
        MmioRequest req = vectorRequest(index);
        MmioResponse got = dut.response;
        MmioResponse expected = expectedResponse(index);

        if (got != expected) begin
            $display("FAIL vector %0d got=", index, fshow(got), " expected=", fshow(expected));
            $finish(1);
        end

        case (index)
            0: $display("VECTOR READ32 %08h R %08h", req.address, got.data);
            1: $display("VECTOR READ32 %08h R %08h", req.address, got.data);
            2: $display("VECTOR READ16 %08h R %08h", req.address, got.data);
            3: $display("VECTOR READ16 %08h R %08h", req.address, got.data);
            4: $display("VECTOR READ8 %08h R %08h", req.address, got.data);
            5: $display("VECTOR READ32 %08h R %08h", req.address, got.data);
            6: $display("VECTOR BADALIGN %08h E 00000000", req.address);
            7: $display("VECTOR UNKNOWN %08h E 00000000", req.address);
            8: $display("VECTOR WRITE32 %08h W 00000000", req.address);
        endcase

        dut.responseTaken;
        waiting <= False;
        index <= index + 1;
    endrule

    rule finish (index == 9 && !waiting);
        $display("PASS NakedDevice conformance");
        $finish(0);
    endrule
endmodule

endpackage
