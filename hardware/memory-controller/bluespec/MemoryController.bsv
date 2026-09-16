package MemoryController;

import RegFile::*;

typedef enum { MemIdle, MemBackendRequest, MemBackendResponse, MemHostResponse } MemoryControllerState deriving (Bits, Eq, FShow);

function Bit#(32) mergeMaskedWrite(Bit#(32) oldValue, Bit#(32) newValue, Bit#(4) byteEnable);
    Bit#(32) merged = oldValue;
    if (byteEnable[0] == 1'b1) merged[7:0] = newValue[7:0];
    if (byteEnable[1] == 1'b1) merged[15:8] = newValue[15:8];
    if (byteEnable[2] == 1'b1) merged[23:16] = newValue[23:16];
    if (byteEnable[3] == 1'b1) merged[31:24] = newValue[31:24];
    return merged;
endfunction

interface MemoryControllerIfc;
    method Bool hostRequestReady;
    method Action hostRequest(Bool write, Bit#(32) address, Bit#(4) byteEnable, Bit#(32) writeData);
    method Bool hostResponseValid;
    method Bool hostResponseFault;
    method Bool hostReadDataValid;
    method Bit#(32) hostReadData;
    method Action hostResponseConsumed;

    method Bool backendRequestValid;
    method Bool backendWrite;
    method Bit#(32) backendAddress;
    method Bit#(4) backendByteEnable;
    method Bit#(32) backendWriteData;
    method Action backendRequestAccepted;
    method Bool backendResponseReady;
    method Action backendRespond(Bool fault, Bool readDataValid, Bit#(32) readData);

    method Action resetController;
    method MemoryControllerState debugState;
endinterface

module mkMemoryController(MemoryControllerIfc);
    Reg#(MemoryControllerState) state <- mkReg(MemIdle);
    Reg#(Bool) requestWrite <- mkReg(False);
    Reg#(Bit#(32)) requestAddress <- mkReg(0);
    Reg#(Bit#(4)) requestByteEnable <- mkReg(0);
    Reg#(Bit#(32)) requestWriteData <- mkReg(0);
    Reg#(Bool) responseFault <- mkReg(False);
    Reg#(Bool) responseReadDataValid <- mkReg(False);
    Reg#(Bit#(32)) responseReadData <- mkReg(0);

    method Bool hostRequestReady = state == MemIdle;

    method Action hostRequest(Bool write, Bit#(32) address, Bit#(4) byteEnable, Bit#(32) writeData) if (state == MemIdle);
        Bool misaligned = address[1:0] != 0;
        requestWrite <= write;
        requestAddress <= address;
        requestByteEnable <= byteEnable;
        requestWriteData <= writeData;
        responseFault <= misaligned;
        responseReadDataValid <= False;
        responseReadData <= 0;
        state <= misaligned ? MemHostResponse : MemBackendRequest;
    endmethod

    method Bool hostResponseValid = state == MemHostResponse;
    method Bool hostResponseFault = responseFault;
    method Bool hostReadDataValid = responseReadDataValid;
    method Bit#(32) hostReadData = responseReadData;

    method Action hostResponseConsumed if (state == MemHostResponse);
        state <= MemIdle;
        responseFault <= False;
        responseReadDataValid <= False;
        responseReadData <= 0;
    endmethod

    method Bool backendRequestValid = state == MemBackendRequest;
    method Bool backendWrite = requestWrite;
    method Bit#(32) backendAddress = requestAddress;
    method Bit#(4) backendByteEnable = requestByteEnable;
    method Bit#(32) backendWriteData = requestWriteData;

    method Action backendRequestAccepted if (state == MemBackendRequest);
        state <= MemBackendResponse;
    endmethod

    method Bool backendResponseReady = state == MemBackendResponse;

    method Action backendRespond(Bool fault, Bool readDataValid, Bit#(32) readData) if (state == MemBackendResponse);
        Bool shapeFault = (!fault) && ((requestWrite && readDataValid) || (!requestWrite && !readDataValid));
        responseFault <= fault || shapeFault;
        responseReadDataValid <= (!fault) && (!shapeFault) && (!requestWrite) && readDataValid;
        responseReadData <= readData;
        state <= MemHostResponse;
    endmethod

    method Action resetController;
        state <= MemIdle;
        requestWrite <= False;
        requestAddress <= 0;
        requestByteEnable <= 0;
        requestWriteData <= 0;
        responseFault <= False;
        responseReadDataValid <= False;
        responseReadData <= 0;
    endmethod

    method MemoryControllerState debugState = state;
endmodule

interface FakeMemoryBackendIfc;
    method Bool requestReady;
    method Action acceptRequest(Bool write, Bit#(32) address, Bit#(4) byteEnable, Bit#(32) writeData);
    method Bool responseValid;
    method Bool responseFault;
    method Bool responseReadDataValid;
    method Bit#(32) responseReadData;
    method Action responseConsumed;
    method Action preload(Bit#(32) address, Bit#(32) value);
    method Bit#(32) peek(Bit#(32) address);
    method Action setRequestHoldoff(Bit#(8) cycles);
    method Action resetBackend;
endinterface

module mkFakeMemoryBackend#(Bit#(8) latency)(FakeMemoryBackendIfc);
    RegFile#(Bit#(10), Bit#(32)) memory <- mkRegFileFull;
    Reg#(Bit#(8)) holdoff <- mkReg(0);
    Reg#(Bool) pending <- mkReg(False);
    Reg#(Bool) pendingWrite <- mkReg(False);
    Reg#(Bit#(32)) pendingAddress <- mkReg(0);
    Reg#(Bit#(4)) pendingByteEnable <- mkReg(0);
    Reg#(Bit#(32)) pendingWriteData <- mkReg(0);
    Reg#(Bit#(8)) pendingWait <- mkReg(0);
    Reg#(Bool) responsePending <- mkReg(False);
    Reg#(Bool) responseFaultReg <- mkReg(False);
    Reg#(Bool) responseReadValidReg <- mkReg(False);
    Reg#(Bit#(32)) responseReadDataReg <- mkReg(0);

    function Bool addressValid(Bit#(32) address);
        return address[1:0] == 0 && address[31:12] == 0;
    endfunction

    rule countHoldoff (holdoff != 0);
        holdoff <= holdoff - 1;
    endrule

    rule progressRequest (pending && !responsePending);
        if (pendingWait != 0) begin
            pendingWait <= pendingWait - 1;
        end
        else begin
            Bool valid = addressValid(pendingAddress);
            responseFaultReg <= !valid;
            responseReadValidReg <= valid && !pendingWrite;
            if (valid) begin
                Bit#(10) index = pendingAddress[11:2];
                if (pendingWrite) begin
                    Bit#(32) oldValue = memory.sub(index);
                    memory.upd(index, mergeMaskedWrite(oldValue, pendingWriteData, pendingByteEnable));
                    responseReadDataReg <= 0;
                end
                else begin
                    responseReadDataReg <= memory.sub(index);
                end
            end
            else begin
                responseReadDataReg <= 0;
            end
            pending <= False;
            responsePending <= True;
        end
    endrule

    method Bool requestReady = holdoff == 0 && !pending && !responsePending;

    method Action acceptRequest(Bool write, Bit#(32) address, Bit#(4) byteEnable, Bit#(32) writeData)
        if (holdoff == 0 && !pending && !responsePending);
        pending <= True;
        pendingWrite <= write;
        pendingAddress <= address;
        pendingByteEnable <= byteEnable;
        pendingWriteData <= writeData;
        pendingWait <= latency;
    endmethod

    method Bool responseValid = responsePending;
    method Bool responseFault = responseFaultReg;
    method Bool responseReadDataValid = responseReadValidReg;
    method Bit#(32) responseReadData = responseReadDataReg;

    method Action responseConsumed if (responsePending);
        responsePending <= False;
        responseFaultReg <= False;
        responseReadValidReg <= False;
        responseReadDataReg <= 0;
    endmethod

    method Action preload(Bit#(32) address, Bit#(32) value);
        if (addressValid(address)) begin
            memory.upd(address[11:2], value);
        end
    endmethod

    method Bit#(32) peek(Bit#(32) address);
        if (addressValid(address)) return memory.sub(address[11:2]);
        else return 0;
    endmethod

    method Action setRequestHoldoff(Bit#(8) cycles);
        holdoff <= cycles;
    endmethod

    method Action resetBackend;
        holdoff <= 0;
        pending <= False;
        pendingWrite <= False;
        pendingAddress <= 0;
        pendingByteEnable <= 0;
        pendingWriteData <= 0;
        pendingWait <= 0;
        responsePending <= False;
        responseFaultReg <= False;
        responseReadValidReg <= False;
        responseReadDataReg <= 0;
    endmethod
endmodule

endpackage
