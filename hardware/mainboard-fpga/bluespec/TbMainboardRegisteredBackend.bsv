package TbMainboardRegisteredBackend;

import Vector::*;
import QLITypes::*;
import QICInterfaces::*;
import PLIOTx::*;
import PLIOWorkerHost::*;
import PLIOHostDmaM3::*;
import MemoryController::*;
import LightingMemoryBusCompat::*;
import MainboardFPGA::*;

function Vector#(8, BackplaneDrive) idleCards();
    return replicate(backplaneDriveDefault());
endfunction

function HostWorkerRequest noWorkerRequest();
    return HostWorkerRequest {
        slot: 0,
        address: 0,
        width: HostW32,
        write: False,
        value: 0
    };
endfunction

function LightingBusMasterDrive cpuBusRequest();
    LightingBusMasterDrive d = lightingBusMasterDriveDefault();
    d.busRequest = True;
    return d;
endfunction

function LightingBusMasterDrive cpuRequest(Bit#(32) address, Bool write,
    Bit#(32) writeData);
    LightingBusMasterDrive d = cpuBusRequest();
    d.request = True;
    d.payload.addr = address;
    d.payload.write = write;
    d.payload.writeData = writeData;
    d.payload.byteEnable = 4'hf;
    return d;
endfunction

typedef enum {
    RbResetSubmit,
    RbResetDrain,
    RbSetup,
    RbWriteBusReq,
    RbWriteActive,
    RbWriteWait,
    RbWriteRetire,
    RbWriteRetireDrain,
    RbReadBusReq,
    RbReadActive,
    RbReadWait,
    RbReadRetire,
    RbReadRetireDrain,
    RbDone
} RbStage deriving (Bits, Eq, FShow);

module mkTbMainboardRegisteredBackend(Empty);
    MainboardFPGAIfc board <- mkMainboardFPGA;
    FakeMemoryBackendIfc ram <- mkFakeMemoryBackend(8'd2);

    Reg#(RbStage) stage <- mkReg(RbResetSubmit);
    Reg#(Bit#(8)) watchdog <- mkReg(0);

    function Action traceWait(String op, LightingBusInputs bus);
        action
            $display("DBG|registered-backend|op=%s|cycle=%0d|grant=%0d|ready=%0d|error=%0d|owner=%0d|mc=%0d|backend_req=%0d|backend_resp_ready=%0d|ram_req_ready=%0d|ram_resp_valid=%0d|cpu_resp=%0d",
                op, watchdog, pack(bus.busGrant), pack(bus.ready), pack(bus.error),
                pack(board.debugMemoryOwner), pack(board.debugMemoryControllerState),
                pack(board.memoryBackendRequestValid),
                pack(board.memoryBackendResponseReady), pack(ram.requestReady),
                pack(ram.responseValid), pack(board.debugCpuResponsePending));
        endaction
    endfunction

    rule resetSubmit (stage == RbResetSubmit);
        board.advance(idleCards(), lightingBusMasterDriveDefault(),
            False, noWorkerRequest(),
            False, False, False, False, 0, True);
        ram.resetBackend;
        stage <= RbResetDrain;
    endrule

    rule resetDrain (stage == RbResetDrain);
        stage <= RbSetup;
    endrule

    rule setup (stage == RbSetup);
        // Force several cycles in MemBackendRequest. This is the boundary that
        // the old monolithic test modeled incorrectly by sampling requestReady
        // independently from accepting the request.
        ram.setRequestHoldoff(8'd6);
        stage <= RbWriteBusReq;
    endrule

    rule writeBusReq (stage == RbWriteBusReq);
        LightingBusMasterDrive cpu = cpuBusRequest();
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL|registered-backend|write-bus-req|grant=%0d|ready=%0d|error=%0d",
                pack(bus.busGrant), pack(bus.ready), pack(bus.error));
            $finish(1);
        end
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= RbWriteActive;
    endrule

    rule writeActive (stage == RbWriteActive);
        LightingBusMasterDrive cpu = cpuRequest(32'h0000_0100, True,
            32'h1122_3344);
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL|registered-backend|write-active|grant=%0d|ready=%0d|error=%0d",
                pack(bus.busGrant), pack(bus.ready), pack(bus.error));
            $finish(1);
        end
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            False, False, False, False, 0, False);
        watchdog <= 0;
        stage <= RbWriteWait;
    endrule

    // Request acceptance is atomic at the external registered-cycle boundary:
    // the fake backend accepts the request in the same testbench rule that
    // queues backendRequestReady=True into MainboardFPGA.
    rule writeAcceptRequest (stage == RbWriteWait
        && board.memoryBackendRequestValid && ram.requestReady);
        LightingBusMasterDrive cpu = cpuRequest(32'h0000_0100, True,
            32'h1122_3344);
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        traceWait("write-request", bus);
        if (!board.memoryBackendWrite
            || board.memoryBackendAddress != 32'h0000_0100
            || board.memoryBackendWriteData != 32'h1122_3344) begin
            $display("FAIL|registered-backend|write-request-shape|write=%0d|addr=%08x|data=%08x",
                pack(board.memoryBackendWrite), board.memoryBackendAddress,
                board.memoryBackendWriteData);
            $finish(1);
        end
        ram.acceptRequest(board.memoryBackendWrite,
            board.memoryBackendAddress, board.memoryBackendWriteData);
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            True, False, False, False, 0, False);
        watchdog <= watchdog + 1;
    endrule

    rule writeReturnResponse (stage == RbWriteWait
        && board.memoryBackendResponseReady && ram.responseValid);
        LightingBusMasterDrive cpu = cpuRequest(32'h0000_0100, True,
            32'h1122_3344);
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        traceWait("write-response", bus);
        Bool fault = ram.responseFault;
        Bool readValid = ram.responseReadDataValid;
        Bit#(32) readData = ram.responseReadData;
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            False, True, fault, readValid, readData, False);
        ram.responseConsumed;
        watchdog <= watchdog + 1;
    endrule

    rule writeWait (stage == RbWriteWait
        && !(board.memoryBackendRequestValid && ram.requestReady)
        && !(board.memoryBackendResponseReady && ram.responseValid));
        LightingBusMasterDrive cpu = cpuRequest(32'h0000_0100, True,
            32'h1122_3344);
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        traceWait("write-wait", bus);
        if (!bus.busGrant || bus.error) begin
            $display("FAIL|registered-backend|write-wait|grant=%0d|error=%0d",
                pack(bus.busGrant), pack(bus.error));
            $finish(1);
        end
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            False, False, False, False, 0, False);
        if (bus.ready) begin
            if (ram.peek(32'h0000_0100) != 32'h1122_3344) begin
                $display("FAIL|registered-backend|write-data");
                $finish(1);
            end
            stage <= RbWriteRetire;
            watchdog <= 0;
        end
        else begin
            watchdog <= watchdog + 1;
            if (watchdog == 80) begin
                $display("FAIL|registered-backend|write-watchdog|owner=%0d|mc=%0d|backend_req=%0d|backend_resp_ready=%0d|ram_req_ready=%0d|ram_resp_valid=%0d",
                    pack(board.debugMemoryOwner), pack(board.debugMemoryControllerState),
                    pack(board.memoryBackendRequestValid),
                    pack(board.memoryBackendResponseReady), pack(ram.requestReady),
                    pack(ram.responseValid));
                $finish(1);
            end
        end
    endrule

    // READY/ERROR is deliberately sticky until the CPU drops request. Queue an
    // explicit request-low board cycle and do not start the next transaction
    // until retireCpuResponse has consumed it.
    rule writeRetire (stage == RbWriteRetire);
        LightingBusMasterDrive cpu = lightingBusMasterDriveDefault();
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        $display("DBG|registered-backend|op=write-retire-submit|ready=%0d|cpu_resp=%0d|cycle_pending=%0d",
            pack(bus.ready), pack(board.debugCpuResponsePending),
            pack(board.debugCyclePending));
        if (!board.debugCpuResponsePending || !bus.ready) begin
            $display("FAIL|registered-backend|write-response-not-latched");
            $finish(1);
        end
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= RbWriteRetireDrain;
    endrule

    rule writeRetireDrain (stage == RbWriteRetireDrain
        && !board.debugCpuResponsePending && board.debugAdvanceReady);
        $display("DBG|registered-backend|op=write-retired|cpu_resp=0");
        stage <= RbReadBusReq;
    endrule

    rule readBusReq (stage == RbReadBusReq);
        LightingBusMasterDrive cpu = cpuBusRequest();
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL|registered-backend|read-bus-req|grant=%0d|ready=%0d|error=%0d|cpu_resp=%0d",
                pack(bus.busGrant), pack(bus.ready), pack(bus.error),
                pack(board.debugCpuResponsePending));
            $finish(1);
        end
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= RbReadActive;
    endrule

    rule readActive (stage == RbReadActive);
        LightingBusMasterDrive cpu = cpuRequest(32'h0000_0100, False, 0);
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL|registered-backend|read-active|grant=%0d|ready=%0d|error=%0d",
                pack(bus.busGrant), pack(bus.ready), pack(bus.error));
            $finish(1);
        end
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            False, False, False, False, 0, False);
        watchdog <= 0;
        stage <= RbReadWait;
    endrule

    rule readAcceptRequest (stage == RbReadWait
        && board.memoryBackendRequestValid && ram.requestReady);
        LightingBusMasterDrive cpu = cpuRequest(32'h0000_0100, False, 0);
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        traceWait("read-request", bus);
        if (board.memoryBackendWrite
            || board.memoryBackendAddress != 32'h0000_0100) begin
            $display("FAIL|registered-backend|read-request-shape|write=%0d|addr=%08x",
                pack(board.memoryBackendWrite), board.memoryBackendAddress);
            $finish(1);
        end
        ram.acceptRequest(board.memoryBackendWrite,
            board.memoryBackendAddress, board.memoryBackendWriteData);
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            True, False, False, False, 0, False);
        watchdog <= watchdog + 1;
    endrule

    rule readReturnResponse (stage == RbReadWait
        && board.memoryBackendResponseReady && ram.responseValid);
        LightingBusMasterDrive cpu = cpuRequest(32'h0000_0100, False, 0);
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        traceWait("read-response", bus);
        Bool fault = ram.responseFault;
        Bool readValid = ram.responseReadDataValid;
        Bit#(32) readData = ram.responseReadData;
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            False, True, fault, readValid, readData, False);
        ram.responseConsumed;
        watchdog <= watchdog + 1;
    endrule

    rule readWait (stage == RbReadWait
        && !(board.memoryBackendRequestValid && ram.requestReady)
        && !(board.memoryBackendResponseReady && ram.responseValid));
        LightingBusMasterDrive cpu = cpuRequest(32'h0000_0100, False, 0);
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        traceWait("read-wait", bus);
        if (!bus.busGrant || bus.error) begin
            $display("FAIL|registered-backend|read-wait|grant=%0d|error=%0d",
                pack(bus.busGrant), pack(bus.error));
            $finish(1);
        end
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            False, False, False, False, 0, False);
        if (bus.ready) begin
            if (bus.readData != 32'h1122_3344) begin
                $display("FAIL|registered-backend|read-data|got=%08x", bus.readData);
                $finish(1);
            end
            stage <= RbReadRetire;
            watchdog <= 0;
        end
        else begin
            watchdog <= watchdog + 1;
            if (watchdog == 80) begin
                $display("FAIL|registered-backend|read-watchdog|owner=%0d|mc=%0d|backend_req=%0d|backend_resp_ready=%0d|ram_req_ready=%0d|ram_resp_valid=%0d",
                    pack(board.debugMemoryOwner), pack(board.debugMemoryControllerState),
                    pack(board.memoryBackendRequestValid),
                    pack(board.memoryBackendResponseReady), pack(ram.requestReady),
                    pack(ram.responseValid));
                $finish(1);
            end
        end
    endrule

    rule readRetire (stage == RbReadRetire);
        LightingBusMasterDrive cpu = lightingBusMasterDriveDefault();
        LightingBusInputs bus = board.lightingMemory(idleCards(), cpu, False);
        $display("DBG|registered-backend|op=read-retire-submit|ready=%0d|data=%08x|cpu_resp=%0d",
            pack(bus.ready), bus.readData, pack(board.debugCpuResponsePending));
        if (!board.debugCpuResponsePending || !bus.ready
            || bus.readData != 32'h1122_3344) begin
            $display("FAIL|registered-backend|read-response-not-latched");
            $finish(1);
        end
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= RbReadRetireDrain;
    endrule

    rule readRetireDrain (stage == RbReadRetireDrain
        && !board.debugCpuResponsePending && board.debugAdvanceReady);
        $display("DBG|registered-backend|op=read-retired|cpu_resp=0");
        stage <= RbDone;
    endrule

    rule done (stage == RbDone);
        $display("MAINBOARDREGISTEREDBACKENDTRACE|v2|write=ok|read=ok|wait_states=ok|response_retire=ok|registered_cycle=atomic_backend_handshake");
        $display("PASS|registered-backend|mainboard queued cycle matches fake backend handshake");
        $finish(0);
    endrule
endmodule

endpackage
