package BlockRamBackend;

import BRAMCore::*;

// Synthesizable FPGA block-RAM backend for MemoryController.
// The backend contract deliberately matches the request/response shape used by
// the simulation/reference backend without exposing simulation-only hooks.
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

Integer defaultBlockRamBytes = 1024 * 1024;
Integer smallBlockRamBytes = 64 * 1024;
Integer mediumBlockRamBytes = 128 * 1024;

// The integrated backend supports capacities up to 1 MiB.  A 1 MiB store has
// 262144 32-bit words, so the physical BRAM uses an 18-bit word address.  Range
// checking is performed on the original 32-bit byte address before it reaches
// the primitive, allowing smaller elaboration-time configurations to use the
// same interface safely.
module mkBlockRamBackend#(Integer bytes)(BlockRamBackendIfc);
    Integer words = bytes / 4;
    BRAM_PORT#(Bit#(18), Bit#(32)) ram <- mkBRAMCore1(words, False);

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
            Bit#(18) wordAddress = address[19:2];
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

// System and simulation default: one MiB of integrated FPGA RAM.
(* synthesize *)
module mkDefaultBlockRamBackend(BlockRamBackendIfc);
    let backend <- mkBlockRamBackend(defaultBlockRamBytes);
    return backend;
endmodule

(* synthesize *)
module mkBlockRamBackend64KiB(BlockRamBackendIfc);
    let backend <- mkBlockRamBackend(smallBlockRamBytes);
    return backend;
endmodule

(* synthesize *)
module mkBlockRamBackend128KiB(BlockRamBackendIfc);
    let backend <- mkBlockRamBackend(mediumBlockRamBytes);
    return backend;
endmodule

(* synthesize *)
module mkBlockRamBackend1MiB(BlockRamBackendIfc);
    let backend <- mkBlockRamBackend(1024 * 1024);
    return backend;
endmodule

endpackage
