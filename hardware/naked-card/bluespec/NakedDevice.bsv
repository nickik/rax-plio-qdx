package NakedDevice;

import QLITypes::*;
import QICInterfaces::*;

Bit#(32) plioId = 32'h504c_494f;
Bit#(16) testVendorId = 16'hffff;
Bit#(16) testDeviceId = 16'h0001;
Bit#(16) testRevision = 16'h0001;
Bit#(32) cfgDeviceControl = 32'h18;

function MmioResponse nakedMmio(MmioRequest req);
    MmioResponse result = mmioError();
    Bit#(32) aligned = req.address & 32'hffff_fffc;
    if (validMmioRequest(req)) begin
        if (req.write) begin
            if (aligned == cfgDeviceControl) result = mmioWriteOk();
        end
        else begin
            Bit#(32) data = 0;
            Bool found = True;
            case (aligned)
                32'h00: data = plioId;
                32'h04: data = { testDeviceId, testVendorId };
                32'h08: data = { 8'h01, 8'h00, testRevision };
                32'h0c: data = 0;
                32'h10: data = 32'h100;
                32'h14: data = 0;
                32'h18: data = 0;
                default: found = False;
            endcase
            if (found) result = mmioReadOk(data);
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
    method Action applyQli(QliOut qli);
endinterface

module mkNakedDevice(NakedDeviceIfc);
    Reg#(Maybe#(MmioResponse)) pending <- mkReg(tagged Invalid);

    method Bool requestReady = !isValid(pending);

    method Action request(MmioRequest req);
        if (!isValid(pending)) pending <= tagged Valid nakedMmio(req);
    endmethod

    method Bool responseValid = isValid(pending);

    method MmioResponse response;
        return fromMaybe(mmioError(), pending);
    endmethod

    method Action responseTaken;
        if (isValid(pending)) pending <= tagged Invalid;
    endmethod

    method Action cancelRequest;
        pending <= tagged Invalid;
    endmethod

    method Action resetDevice;
        pending <= tagged Invalid;
    endmethod

    // Apply the QLI response atomically so a fixture never schedules several
    // methods that all write the single pending-response register.
    method Action applyQli(QliOut qli);
        if (qli.reset || qli.mmioCancel
            || (qli.mmioResponseReady && isValid(pending))) begin
            pending <= tagged Invalid;
        end
        else if (qli.mmioRequestValid && !isValid(pending)) begin
            pending <= tagged Valid nakedMmio(qli.mmioRequest);
        end
    endmethod
endmodule

endpackage
