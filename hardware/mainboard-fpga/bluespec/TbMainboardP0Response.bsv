package TbMainboardP0Response;

import Vector::*;
import QLITypes::*;
import QICInterfaces::*;
import PLIOTx::*;
import PLIOWorkerHost::*;
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

function LightingBusMasterDrive cpuWriteRequest();
    LightingBusMasterDrive d = cpuBusRequest();
    d.request = True;
    d.payload.addr = 32'h0000_0100;
    d.payload.write = True;
    d.payload.writeData = 32'h1122_3344;
    d.payload.byteEnable = 4'hf;
    return d;
endfunction

typedef enum {
    P0ResetSubmit,
    P0ResetDrain,
    P0BusRequest,
    P0ActiveRequest,
    P0WaitResponse
} P0CpuResponseStage deriving (Bits, Eq, FShow);

module mkTbP0CpuResponse(Empty);
    MainboardFPGAIfc board <- mkMainboardFPGA;
    Reg#(P0CpuResponseStage) stage <- mkReg(P0ResetSubmit);
    Reg#(Bit#(8)) cycle <- mkReg(0);
    Reg#(Bool) backendResponseSubmitted <- mkReg(False);

    rule resetSubmit (stage == P0ResetSubmit);
        board.advance(idleCards(), lightingBusMasterDriveDefault(),
            False, noWorkerRequest(),
            False, False, False, False, 0, True);
        stage <= P0ResetDrain;
    endrule

    rule resetDrain (stage == P0ResetDrain);
        stage <= P0BusRequest;
    endrule

    rule busRequest (stage == P0BusRequest);
        let cpu = cpuBusRequest();
        let bus = board.lightingMemory(idleCards(), cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL|p0-cpu-response|phase=bus-request");
            $finish(1);
        end
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= P0ActiveRequest;
    endrule

    rule activeRequest (stage == P0ActiveRequest);
        let cpu = cpuWriteRequest();
        let bus = board.lightingMemory(idleCards(), cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL|p0-cpu-response|phase=active");
            $finish(1);
        end
        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= P0WaitResponse;
        cycle <= 0;
    endrule

    rule waitResponse (stage == P0WaitResponse);
        let cpu = cpuWriteRequest();
        let bus = board.lightingMemory(idleCards(), cpu, False);
        Bool submitResponse = board.memoryBackendResponseReady
            && !backendResponseSubmitted;

        $display("TRACE|p0-cpu-response|cycle=%0d|grant=%0d|ready=%0d|error=%0d|owner=%0d|held=%0d|seen=%0d|cpu_resp=%0d|plio_resp=%0d|mc_state=%0d|mc_host_resp=%0d|cycle_pending=%0d|advance_ready=%0d|backend_req=%0d|backend_resp_ready=%0d|submit_resp=%0d|response_submitted=%0d",
            cycle, pack(bus.busGrant), pack(bus.ready), pack(bus.error),
            pack(board.debugMemoryOwner), pack(board.debugCpuGrantHeld),
            pack(board.debugCpuRequestSeen), pack(board.debugCpuResponsePending),
            pack(board.debugPlioResponsePending), pack(board.debugMemoryControllerState),
            pack(board.debugMemoryHostResponseValid), pack(board.debugCyclePending),
            pack(board.debugAdvanceReady), pack(board.memoryBackendRequestValid),
            pack(board.memoryBackendResponseReady), pack(submitResponse),
            pack(backendResponseSubmitted));

        if (bus.error) begin
            $display("FAIL|p0-cpu-response|unexpected-error");
            $finish(1);
        end
        if (bus.ready) begin
            $display("PASS|p0-cpu-response|CPU observes stable captured backend completion");
            $finish(0);
        end

        board.advance(idleCards(), cpu, False, noWorkerRequest(),
            True, submitResponse, False, False, 0, False);
        if (submitResponse) backendResponseSubmitted <= True;

        cycle <= cycle + 1;
        if (cycle == 12) begin
            $display("FAIL|p0-cpu-response|short-watchdog|owner=%0d|cpu_resp=%0d|mc_state=%0d|mc_host_resp=%0d|backend_req=%0d|backend_resp_ready=%0d",
                pack(board.debugMemoryOwner), pack(board.debugCpuResponsePending),
                pack(board.debugMemoryControllerState),
                pack(board.debugMemoryHostResponseValid),
                pack(board.memoryBackendRequestValid),
                pack(board.memoryBackendResponseReady));
            $finish(1);
        end
    endrule
endmodule

endpackage
