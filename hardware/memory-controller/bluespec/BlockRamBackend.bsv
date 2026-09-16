package BlockRamBackend;

import BRAMCore::*;

// Synthesizable FPGA block-RAM backend for MemoryController.
// Four independent byte-wide RAM lanes map directly to BE[3:0], so masked
// writes never require an externally visible read-modify-write transaction.
interface BlockRamBackendIfc;
    method Bool requestReady;
    method Action acceptRequest(Bool write, Bit#(32) address, Bit#(4) byteEnable, Bit#(32) writeData);
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

module mkBlockRamBackend#(Integer bytes)(BlockRamBackendIfc);
    Integer words = bytes / 4;
    BRAM_PORT#(Bit#(18), Bit#(8)) lane0 <- mkBRAMCore1(words, False);
    BRAM_PORT#(Bit#(18), Bit#(8)) lane1 <- mkBRAMCore1(words, False);
    BRAM_PORT#(Bit#(18), Bit#(8)) lane2 <- mkBRAMCore1(words, False);
    BRAM_PORT#(Bit#(18), Bit#(8)) lane3 <- mkBRAMCore1(words, False);

    Reg#(Bool) readPending <- mkReg(False);
    Reg#(Bool) responsePending <- mkReg(False);
    Reg#(Bool) responseFaultReg <- mkReg(False);

    function Bool addressValid(Bit#(32) address);
        Bit#(32) limit = fromInteger(bytes);
        return address[1:0] == 0 && address < limit;
    endfunction

    method Bool requestReady = !readPending && !responsePending;

    method Action acceptRequest(Bool write, Bit#(32) address, Bit#(4) byteEnable, Bit#(32) writeData)
        if (!readPending && !responsePending);
        Bool valid = addressValid(address);
        if (!valid) begin
            responsePending <= True;
            responseFaultReg <= True;
        end
        else begin
            Bit#(18) wordAddress = address[19:2];
            lane0.put(write && byteEnable[0] == 1'b1, wordAddress, writeData[7:0]);
            lane1.put(write && byteEnable[1] == 1'b1, wordAddress, writeData[15:8]);
            lane2.put(write && byteEnable[2] == 1'b1, wordAddress, writeData[23:16]);
            lane3.put(write && byteEnable[3] == 1'b1, wordAddress, writeData[31:24]);
            responseFaultReg <= False;
            if (write) begin
                responsePending <= True;
            end
            else begin
                readPending <= True;
            end
        end
    endmethod

    method Bool responseValid = readPending || responsePending;
    method Bool responseFault = responsePending && responseFaultReg;
    method Bool responseReadDataValid = readPending;
    method Bit#(32) responseReadData = readPending ? { lane3.read, lane2.read, lane1.read, lane0.read } : 0;

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
