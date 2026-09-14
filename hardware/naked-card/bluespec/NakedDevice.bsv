package NakedDevice;

import QLITypes::*;

Bit#(32) plioId = 32'h504c_494f;
Bit#(16) testVendorId = 16'hffff;
Bit#(16) testDeviceId = 16'h0001;
Bit#(16) testRevision = 16'h0001;

Bit#(32) cfgId = 32'h0000_0000;
Bit#(32) cfgVendorDevice = 32'h0000_0004;
Bit#(32) cfgRevClassFlags = 32'h0000_0008;
Bit#(32) cfgQdx = 32'h0000_000c;
Bit#(32) cfgMmioLength = 32'h0000_0010;
Bit#(32) cfgDeviceStatus = 32'h0000_0014;
Bit#(32) cfgDeviceControl = 32'h0000_0018;

function MmioResponse nakedMmio(MmioRequest req);
    MmioResponse result = mmioError();
    Bit#(32) aligned = req.address & 32'hffff_fffc;

    if (validMmioRequest(req)) begin
        if (req.write) begin
            if (aligned == cfgDeviceControl) begin
                result = mmioWriteOk();
            end
        end
        else begin
            Bit#(32) data = 0;
            Bool found = True;

            case (aligned)
                32'h0000_0000: data = plioId;
                32'h0000_0004: data = { testDeviceId, testVendorId };
                32'h0000_0008: data = { 8'h01, 8'h00, testRevision };
                32'h0000_000c: data = 0;
                32'h0000_0010: data = 32'h0000_0100;
                32'h0000_0014: data = 0;
                32'h0000_0018: data = 0;
                default: found = False;
            endcase

            if (found) begin
                result = mmioReadOk(data);
            end
        end
    end

    return result;
endfunction

interface NakedDeviceIfc;
    method Bool requestReady;
    method Action request(MmioRequest req);
    method Bool responseValid;
    method MmioResponse response;
    method Action responseTaken;
    method Action cancelRequest;
    method Action resetDevice;
endinterface

module mkNakedDevice(NakedDeviceIfc);
    Reg#(Maybe#(MmioResponse)) pending <- mkReg(tagged Invalid);

    method Bool requestReady = !isValid(pending);

    method Action request(MmioRequest req) if (!isValid(pending));
        pending <= tagged Valid nakedMmio(req);
    endmethod

    method Bool responseValid = isValid(pending);

    method MmioResponse response if (isValid(pending));
        return fromMaybe(mmioError(), pending);
    endmethod

    method Action responseTaken if (isValid(pending));
        pending <= tagged Invalid;
    endmethod

    method Action cancelRequest;
        pending <= tagged Invalid;
    endmethod

    method Action resetDevice;
        pending <= tagged Invalid;
    endmethod
endmodule

endpackage
