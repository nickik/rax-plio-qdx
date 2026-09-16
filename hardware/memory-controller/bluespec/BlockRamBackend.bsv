package BlockRamBackend;

import BRAMCore::*;

// Synthesizable FPGA block-RAM backend for MemoryController.
// The backend contract deliberately matches the request/response shape used by
// the simulation backend without exposing simulation-only preload/peek hooks.
interface BlockRamBackendIfc;
    method Bool requestReady;
    method Action acceptRequest(Bool write, Bit#(32) address, Bit#(32) writeData);
    method Bool responseValid;
    method Bool responseFault;
    method Bool responseReadDataValid;
    method Bit#(32) responseReadData;
    method Action responseConsumed;
    method Action resetBackend;
endinterface

Integer defaultBlockRamBytes = 64 * 1024;
Integer largeBlockRamBytes = 128 * 1024;

// Supported hardware sizes are currently <= 128 KiB.  The physical BRAM uses
// a 15-bit word address (32 Ki x 32 bits maximum); range checking happens on
// the original 32-bit byte address before it reaches the primitive.
module mkBlockRamBackend#(Integer bytes)(BlockRamBackendIfc);
    Integer words = bytes / 4;
    BRAM_PORT#(Bit#(15), Bit#(32)) ram <- mkBRAMCore1(words, False);

    // A read becomes visible exactly one cycle after the BRAM request.  The
    // BRAM primitive's read method is the registered synchronous output, so no
    // extra data register is inserted here.
    Reg#(Bool) readPending <- mkReg(False);
    Reg#(Bool) responsePending <- mkReg(False);
    Reg#(Bool) responseFaultReg <- mkReg(False);

    function Bool addressValid(Bit#(32) address);
        Bit#(32) limit = fromInteger(bytes);
        return address[1:0] == 0 && address < limit;
    endfunction

    method Bool requestReady = !readPending && !responsePending;

    method Action acceptRequest(Bool write, Bit#(32) address, Bit#(32) writeData)
        if (!readPending && !responsePending);
        Bool valid = addressValid(address);
        if (!valid) begin
            responsePending <= True;
            responseFaultReg <= True;
        end
        else begin
            Bit#(15) wordAddress = address[16:2];
            ram.put(write, wordAddress, writeData);
            responseFaultReg <= False;
            if (write) begin
                // The write is committed at this clock edge.  A normal
                // write-complete response is visible in the following cycle.
                responsePending <= True;
            end
            else begin
                // BRAMCore's non-pipelined output is synchronous, one cycle.
                readPending <= True;
            end
        end
    endmethod

    method Bool responseValid = readPending || responsePending;
    method Bool responseFault = responsePending && responseFaultReg;
    method Bool responseReadDataValid = readPending;
    method Bit#(32) responseReadData = readPending ? ram.read : 0;

    method Action responseConsumed if (readPending || responsePending);
        readPending <= False;
        responsePending <= False;
        responseFaultReg <= False;
    endmethod

    // Reset cancels protocol state but deliberately does not clear BRAM data.
    method Action resetBackend;
        readPending <= False;
        responsePending <= False;
        responseFaultReg <= False;
    endmethod
endmodule

(* synthesize *)
module mkDefaultBlockRamBackend(BlockRamBackendIfc);
    let backend <- mkBlockRamBackend(defaultBlockRamBytes);
    return backend;
endmodule

(* synthesize *)
module mkBlockRamBackend64KiB(BlockRamBackendIfc);
    let backend <- mkBlockRamBackend(64 * 1024);
    return backend;
endmodule

(* synthesize *)
module mkBlockRamBackend128KiB(BlockRamBackendIfc);
    let backend <- mkBlockRamBackend(128 * 1024);
    return backend;
endmodule

endpackage
