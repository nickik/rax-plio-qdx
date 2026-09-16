package TbMainboardDiagnostics;

import Vector::*;
import QLITypes::*;
import QICInterfaces::*;
import PLIOTx::*;
import PLIOWorkerHost::*;
import PLIOHostDmaM3::*;
import LightingMemoryBusCompat::*;
import MainboardFPGA::*;

function Bit#(4) diagParity(Bit#(32) word);
    return { ~(^word[31:24]), ~(^word[23:16]), ~(^word[15:8]), ~(^word[7:0]) };
endfunction

function BackplaneDrive diagRequestOnly();
    BackplaneDrive d = backplaneDriveDefault();
    d.request = True;
    return d;
endfunction

function BackplaneDrive diagDmaAddress(Bit#(32) address, Bool readDirection);
    BackplaneDrive d = diagRequestOnly();
    BackplaneControl c = backplaneControlDefault();
    c.space = pack(PlioHostDma);
    c.addressStrobe = True;
    c.read = readDirection;
    c.byteEnable = 4'hf;
    c.burstLen = pack(BurstOne);
    d.controlValid = True;
    d.control = c;
    d.adParValid = True;
    d.ad = address;
    d.parity = diagParity(address);
    return d;
endfunction

function BackplaneDrive diagDmaReadBeat();
    BackplaneDrive d = diagRequestOnly();
    BackplaneControl c = backplaneControlDefault();
    c.dataStrobe = True;
    d.controlValid = True;
    d.control = c;
    return d;
endfunction

function LightingBusMasterDrive diagCpuBusRequest();
    LightingBusMasterDrive d = lightingBusMasterDriveDefault();
    d.busRequest = True;
    return d;
endfunction

function LightingBusMasterDrive diagCpuRequest(Bit#(32) address, Bool write,
    Bit#(32) writeData);
    LightingBusMasterDrive d = diagCpuBusRequest();
    d.request = True;
    d.payload.addr = address;
    d.payload.write = write;
    d.payload.writeData = writeData;
    d.payload.byteEnable = 4'hf;
    return d;
endfunction

function Vector#(8, BackplaneDrive) diagIdleCards();
    return replicate(backplaneDriveDefault());
endfunction

function HostWorkerRequest diagNoWorkerRequest();
    return HostWorkerRequest {
        slot: 0,
        address: 0,
        width: HostW32,
        write: False,
        value: 0
    };
endfunction

typedef enum {
    GrantResetSubmit,
    GrantResetDrain,
    GrantBusReq,
    GrantActive,
    GrantHeld
} GrantStage deriving (Bits, Eq, FShow);

module mkTbMainboardCpuGrant(Empty);
    MainboardFPGAIfc board <- mkMainboardFPGA;
    Reg#(GrantStage) stage <- mkReg(GrantResetSubmit);

    rule resetSubmit (stage == GrantResetSubmit);
        board.advance(diagIdleCards(), lightingBusMasterDriveDefault(),
            False, diagNoWorkerRequest(),
            False, False, False, False, 0, True);
        stage <= GrantResetDrain;
    endrule

    rule resetDrain (stage == GrantResetDrain);
        $display("DBG|cpu-grant|phase=reset-drain|owner=%0d|prefer_cpu=%0d|held=%0d",
            pack(board.debugMemoryOwner), pack(board.debugPreferCpu),
            pack(board.debugCpuGrantHeld));
        stage <= GrantBusReq;
    endrule

    rule busReq (stage == GrantBusReq);
        LightingBusMasterDrive cpu = diagCpuBusRequest();
        LightingBusInputs bus = board.lightingMemory(diagIdleCards(), cpu, False);
        $display("DBG|cpu-grant|phase=bus-req|grant=%0d|ready=%0d|error=%0d|owner=%0d|prefer_cpu=%0d|held=%0d",
            pack(bus.busGrant), pack(bus.ready), pack(bus.error),
            pack(board.debugMemoryOwner), pack(board.debugPreferCpu),
            pack(board.debugCpuGrantHeld));
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL|cpu-grant|phase=bus-req");
            $finish(1);
        end
        board.advance(diagIdleCards(), cpu, False, diagNoWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= GrantActive;
    endrule

    rule active (stage == GrantActive);
        LightingBusMasterDrive cpu = diagCpuRequest(32'h0000_0100, True,
            32'h1122_3344);
        LightingBusInputs bus = board.lightingMemory(diagIdleCards(), cpu, False);
        $display("DBG|cpu-grant|phase=active|grant=%0d|ready=%0d|error=%0d|owner=%0d|prefer_cpu=%0d|held=%0d",
            pack(bus.busGrant), pack(bus.ready), pack(bus.error),
            pack(board.debugMemoryOwner), pack(board.debugPreferCpu),
            pack(board.debugCpuGrantHeld));
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL|cpu-grant|phase=active");
            $finish(1);
        end
        board.advance(diagIdleCards(), cpu, False, diagNoWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= GrantHeld;
    endrule

    rule held (stage == GrantHeld);
        LightingBusMasterDrive cpu = diagCpuRequest(32'h0000_0100, True,
            32'h1122_3344);
        LightingBusInputs bus = board.lightingMemory(diagIdleCards(), cpu, False);
        $display("DBG|cpu-grant|phase=held|grant=%0d|owner=%0d|prefer_cpu=%0d|held=%0d|backend_req=%0d",
            pack(bus.busGrant), pack(board.debugMemoryOwner),
            pack(board.debugPreferCpu), pack(board.debugCpuGrantHeld),
            pack(board.memoryBackendRequestValid));
        if (!bus.busGrant || !board.debugCpuGrantHeld) begin
            $display("FAIL|cpu-grant|phase=held|grant=%0d|held=%0d",
                pack(bus.busGrant), pack(board.debugCpuGrantHeld));
            $finish(1);
        end
        $display("PASS|cpu-grant|registered BUS_REQ grant survives into active REQ");
        $finish(0);
    endrule
endmodule

typedef enum {
    WriteResetSubmit,
    WriteResetDrain,
    WriteBusReq,
    WriteActive,
    WriteWait
} WriteStage deriving (Bits, Eq, FShow);

module mkTbMainboardCpuWrite(Empty);
    MainboardFPGAIfc board <- mkMainboardFPGA;
    Reg#(WriteStage) stage <- mkReg(WriteResetSubmit);
    Reg#(Bit#(8)) cycles <- mkReg(0);
    Reg#(Bool) responseQueued <- mkReg(False);

    rule resetSubmit (stage == WriteResetSubmit);
        board.advance(diagIdleCards(), lightingBusMasterDriveDefault(),
            False, diagNoWorkerRequest(),
            False, False, False, False, 0, True);
        stage <= WriteResetDrain;
    endrule

    rule resetDrain (stage == WriteResetDrain);
        stage <= WriteBusReq;
    endrule

    rule busReq (stage == WriteBusReq);
        LightingBusMasterDrive cpu = diagCpuBusRequest();
        LightingBusInputs bus = board.lightingMemory(diagIdleCards(), cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL|cpu-write|phase=bus-req|grant=%0d|ready=%0d|error=%0d",
                pack(bus.busGrant), pack(bus.ready), pack(bus.error));
            $finish(1);
        end
        board.advance(diagIdleCards(), cpu, False, diagNoWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= WriteActive;
    endrule

    rule active (stage == WriteActive);
        LightingBusMasterDrive cpu = diagCpuRequest(32'h0000_0100, True,
            32'h1122_3344);
        LightingBusInputs bus = board.lightingMemory(diagIdleCards(), cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL|cpu-write|phase=active|grant=%0d|ready=%0d|error=%0d",
                pack(bus.busGrant), pack(bus.ready), pack(bus.error));
            $finish(1);
        end
        board.advance(diagIdleCards(), cpu, False, diagNoWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= WriteWait;
        cycles <= 0;
    endrule

    rule waitForWrite (stage == WriteWait);
        LightingBusMasterDrive cpu = diagCpuRequest(32'h0000_0100, True,
            32'h1122_3344);
        LightingBusInputs bus = board.lightingMemory(diagIdleCards(), cpu, False);
        Bool queueResponse = board.memoryBackendResponseReady && !responseQueued;

        $display("DBG|cpu-write|cycle=%0d|grant=%0d|ready=%0d|error=%0d|owner=%0d|held=%0d|backend_req=%0d|backend_wr=%0d|backend_addr=%08x|backend_resp_ready=%0d|resp_queue=%0d",
            cycles, pack(bus.busGrant), pack(bus.ready), pack(bus.error),
            pack(board.debugMemoryOwner), pack(board.debugCpuGrantHeld),
            pack(board.memoryBackendRequestValid), pack(board.memoryBackendWrite),
            board.memoryBackendAddress, pack(board.memoryBackendResponseReady),
            pack(queueResponse));

        if (!bus.busGrant || bus.error) begin
            $display("FAIL|cpu-write|phase=wait|grant=%0d|error=%0d",
                pack(bus.busGrant), pack(bus.error));
            $finish(1);
        end

        if (board.memoryBackendRequestValid
            && (!board.memoryBackendWrite
                || board.memoryBackendAddress != 32'h0000_0100
                || board.memoryBackendWriteData != 32'h1122_3344)) begin
            $display("FAIL|cpu-write|backend-request|write=%0d|addr=%08x|data=%08x",
                pack(board.memoryBackendWrite), board.memoryBackendAddress,
                board.memoryBackendWriteData);
            $finish(1);
        end

        board.advance(diagIdleCards(), cpu, False, diagNoWorkerRequest(),
            True, queueResponse, False, False, 0, False);
        if (queueResponse) responseQueued <= True;

        if (bus.ready) begin
            if (!responseQueued) begin
                $display("FAIL|cpu-write|ready-before-backend-response");
                $finish(1);
            end
            $display("PASS|cpu-write|backend handshake and CPU completion");
            $finish(0);
        end

        cycles <= cycles + 1;
        if (cycles == 40) begin
            $display("FAIL|cpu-write|watchdog|owner=%0d|backend_req=%0d|backend_resp_ready=%0d|plio_req=%0d",
                pack(board.debugMemoryOwner), pack(board.memoryBackendRequestValid),
                pack(board.memoryBackendResponseReady),
                pack(board.debugPlioMemoryRequestValid));
            $finish(1);
        end
    endrule
endmodule

typedef enum {
    ReadResetSubmit,
    ReadResetDrain,
    ReadBusReq,
    ReadActive,
    ReadWait
} ReadStage deriving (Bits, Eq, FShow);

module mkTbMainboardCpuRead(Empty);
    MainboardFPGAIfc board <- mkMainboardFPGA;
    Reg#(ReadStage) stage <- mkReg(ReadResetSubmit);
    Reg#(Bit#(8)) cycles <- mkReg(0);
    Reg#(Bool) responseQueued <- mkReg(False);

    rule resetSubmit (stage == ReadResetSubmit);
        board.advance(diagIdleCards(), lightingBusMasterDriveDefault(),
            False, diagNoWorkerRequest(),
            False, False, False, False, 0, True);
        stage <= ReadResetDrain;
    endrule

    rule resetDrain (stage == ReadResetDrain);
        stage <= ReadBusReq;
    endrule

    rule busReq (stage == ReadBusReq);
        LightingBusMasterDrive cpu = diagCpuBusRequest();
        LightingBusInputs bus = board.lightingMemory(diagIdleCards(), cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL|cpu-read|phase=bus-req");
            $finish(1);
        end
        board.advance(diagIdleCards(), cpu, False, diagNoWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= ReadActive;
    endrule

    rule active (stage == ReadActive);
        LightingBusMasterDrive cpu = diagCpuRequest(32'h0000_0200, False, 0);
        LightingBusInputs bus = board.lightingMemory(diagIdleCards(), cpu, False);
        if (!bus.busGrant || bus.ready || bus.error) begin
            $display("FAIL|cpu-read|phase=active|grant=%0d|ready=%0d|error=%0d",
                pack(bus.busGrant), pack(bus.ready), pack(bus.error));
            $finish(1);
        end
        board.advance(diagIdleCards(), cpu, False, diagNoWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= ReadWait;
        cycles <= 0;
    endrule

    rule waitForRead (stage == ReadWait);
        LightingBusMasterDrive cpu = diagCpuRequest(32'h0000_0200, False, 0);
        LightingBusInputs bus = board.lightingMemory(diagIdleCards(), cpu, False);
        Bool queueResponse = board.memoryBackendResponseReady && !responseQueued;

        $display("DBG|cpu-read|cycle=%0d|grant=%0d|ready=%0d|error=%0d|data=%08x|owner=%0d|held=%0d|backend_req=%0d|backend_wr=%0d|backend_addr=%08x|backend_resp_ready=%0d|resp_queue=%0d",
            cycles, pack(bus.busGrant), pack(bus.ready), pack(bus.error),
            bus.readData, pack(board.debugMemoryOwner),
            pack(board.debugCpuGrantHeld), pack(board.memoryBackendRequestValid),
            pack(board.memoryBackendWrite), board.memoryBackendAddress,
            pack(board.memoryBackendResponseReady), pack(queueResponse));

        if (!bus.busGrant || bus.error) begin
            $display("FAIL|cpu-read|phase=wait|grant=%0d|error=%0d",
                pack(bus.busGrant), pack(bus.error));
            $finish(1);
        end

        if (board.memoryBackendRequestValid
            && (board.memoryBackendWrite
                || board.memoryBackendAddress != 32'h0000_0200)) begin
            $display("FAIL|cpu-read|backend-request|write=%0d|addr=%08x",
                pack(board.memoryBackendWrite), board.memoryBackendAddress);
            $finish(1);
        end

        board.advance(diagIdleCards(), cpu, False, diagNoWorkerRequest(),
            True, queueResponse, False, queueResponse, 32'hcafe_babe, False);
        if (queueResponse) responseQueued <= True;

        if (bus.ready) begin
            if (bus.readData != 32'hcafe_babe) begin
                $display("FAIL|cpu-read|data|actual=%08x|expected=cafebabe",
                    bus.readData);
                $finish(1);
            end
            $display("PASS|cpu-read|backend read response reaches CPU");
            $finish(0);
        end

        cycles <= cycles + 1;
        if (cycles == 40) begin
            $display("FAIL|cpu-read|watchdog|owner=%0d|backend_req=%0d|backend_resp_ready=%0d",
                pack(board.debugMemoryOwner), pack(board.memoryBackendRequestValid),
                pack(board.memoryBackendResponseReady));
            $finish(1);
        end
    endrule
endmodule

typedef enum {
    ResetDiagInitialResetSubmit,
    ResetDiagInitialResetDrain,
    ResetDiagBusReq,
    ResetDiagActive,
    ResetDiagWaitOutstanding,
    ResetDiagWaitClear,
    ResetDiagStaleDrain,
    ResetDiagFreshBusReq,
    ResetDiagFreshActive,
    ResetDiagFreshWait
} ResetDiagStage deriving (Bits, Eq, FShow);

module mkTbMainboardResetRecovery(Empty);
    MainboardFPGAIfc board <- mkMainboardFPGA;
    Reg#(ResetDiagStage) stage <- mkReg(ResetDiagInitialResetSubmit);
    Reg#(Bit#(8)) cycles <- mkReg(0);
    Reg#(Bool) responseQueued <- mkReg(False);

    rule initialResetSubmit (stage == ResetDiagInitialResetSubmit);
        board.advance(diagIdleCards(), lightingBusMasterDriveDefault(),
            False, diagNoWorkerRequest(),
            False, False, False, False, 0, True);
        stage <= ResetDiagInitialResetDrain;
    endrule

    rule initialResetDrain (stage == ResetDiagInitialResetDrain);
        stage <= ResetDiagBusReq;
    endrule

    rule busReq (stage == ResetDiagBusReq);
        LightingBusMasterDrive cpu = diagCpuBusRequest();
        LightingBusInputs bus = board.lightingMemory(diagIdleCards(), cpu, False);
        if (!bus.busGrant) begin
            $display("FAIL|reset-recovery|phase=bus-req");
            $finish(1);
        end
        board.advance(diagIdleCards(), cpu, False, diagNoWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= ResetDiagActive;
    endrule

    rule active (stage == ResetDiagActive);
        LightingBusMasterDrive cpu = diagCpuRequest(32'h0000_0300, False, 0);
        LightingBusInputs bus = board.lightingMemory(diagIdleCards(), cpu, False);
        if (!bus.busGrant) begin
            $display("FAIL|reset-recovery|phase=active");
            $finish(1);
        end
        board.advance(diagIdleCards(), cpu, False, diagNoWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= ResetDiagWaitOutstanding;
        cycles <= 0;
    endrule

    rule waitOutstanding (stage == ResetDiagWaitOutstanding);
        LightingBusMasterDrive cpu = diagCpuRequest(32'h0000_0300, False, 0);
        LightingBusInputs bus = board.lightingMemory(diagIdleCards(), cpu, False);
        $display("DBG|reset-recovery|phase=wait-outstanding|cycle=%0d|grant=%0d|owner=%0d|held=%0d|backend_req=%0d|backend_resp_ready=%0d",
            cycles, pack(bus.busGrant), pack(board.debugMemoryOwner),
            pack(board.debugCpuGrantHeld), pack(board.memoryBackendRequestValid),
            pack(board.memoryBackendResponseReady));

        if (board.memoryBackendRequestValid
            && board.debugMemoryOwner == MainMemCpu) begin
            board.advance(diagIdleCards(), cpu, False, diagNoWorkerRequest(),
                False, False, False, False, 0, True);
            stage <= ResetDiagWaitClear;
            cycles <= 0;
        end
        else begin
            board.advance(diagIdleCards(), cpu, False, diagNoWorkerRequest(),
                False, False, False, False, 0, False);
            cycles <= cycles + 1;
            if (cycles == 20) begin
                $display("FAIL|reset-recovery|outstanding-request-watchdog");
                $finish(1);
            end
        end
    endrule

    rule waitClear (stage == ResetDiagWaitClear);
        $display("DBG|reset-recovery|phase=wait-clear|cycle=%0d|owner=%0d|held=%0d|backend_req=%0d|backend_resp_ready=%0d",
            cycles, pack(board.debugMemoryOwner), pack(board.debugCpuGrantHeld),
            pack(board.memoryBackendRequestValid),
            pack(board.memoryBackendResponseReady));

        if (board.debugMemoryOwner == MainMemNone
            && !board.debugCpuGrantHeld
            && !board.memoryBackendRequestValid
            && !board.memoryBackendResponseReady) begin
            board.advance(diagIdleCards(), lightingBusMasterDriveDefault(),
                False, diagNoWorkerRequest(),
                False, True, False, True, 32'hdead_beef, False);
            stage <= ResetDiagStaleDrain;
            cycles <= 0;
        end
        else begin
            cycles <= cycles + 1;
            if (cycles == 20) begin
                $display("FAIL|reset-recovery|reset-clear-watchdog");
                $finish(1);
            end
        end
    endrule

    rule staleDrain (stage == ResetDiagStaleDrain);
        LightingBusInputs bus = board.lightingMemory(diagIdleCards(),
            lightingBusMasterDriveDefault(), False);
        $display("DBG|reset-recovery|phase=stale-drain|owner=%0d|backend_req=%0d|backend_resp_ready=%0d|ready=%0d|error=%0d",
            pack(board.debugMemoryOwner), pack(board.memoryBackendRequestValid),
            pack(board.memoryBackendResponseReady), pack(bus.ready),
            pack(bus.error));
        if (board.debugMemoryOwner != MainMemNone
            || board.memoryBackendRequestValid
            || bus.ready || bus.error) begin
            $display("FAIL|reset-recovery|stale-response-resurrected-request");
            $finish(1);
        end
        stage <= ResetDiagFreshBusReq;
    endrule

    rule freshBusReq (stage == ResetDiagFreshBusReq);
        LightingBusMasterDrive cpu = diagCpuBusRequest();
        LightingBusInputs bus = board.lightingMemory(diagIdleCards(), cpu, False);
        if (!bus.busGrant) begin
            $display("FAIL|reset-recovery|phase=fresh-bus-req");
            $finish(1);
        end
        board.advance(diagIdleCards(), cpu, False, diagNoWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= ResetDiagFreshActive;
    endrule

    rule freshActive (stage == ResetDiagFreshActive);
        LightingBusMasterDrive cpu = diagCpuRequest(32'h0000_0304, False, 0);
        LightingBusInputs bus = board.lightingMemory(diagIdleCards(), cpu, False);
        if (!bus.busGrant) begin
            $display("FAIL|reset-recovery|phase=fresh-active");
            $finish(1);
        end
        board.advance(diagIdleCards(), cpu, False, diagNoWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= ResetDiagFreshWait;
        cycles <= 0;
        responseQueued <= False;
    endrule

    rule freshWait (stage == ResetDiagFreshWait);
        LightingBusMasterDrive cpu = diagCpuRequest(32'h0000_0304, False, 0);
        LightingBusInputs bus = board.lightingMemory(diagIdleCards(), cpu, False);
        Bool queueResponse = board.memoryBackendResponseReady && !responseQueued;

        $display("DBG|reset-recovery|phase=fresh-wait|cycle=%0d|grant=%0d|ready=%0d|error=%0d|owner=%0d|backend_req=%0d|backend_resp_ready=%0d|resp_queue=%0d",
            cycles, pack(bus.busGrant), pack(bus.ready), pack(bus.error),
            pack(board.debugMemoryOwner), pack(board.memoryBackendRequestValid),
            pack(board.memoryBackendResponseReady), pack(queueResponse));

        board.advance(diagIdleCards(), cpu, False, diagNoWorkerRequest(),
            True, queueResponse, False, queueResponse, 32'h1357_9bdf, False);
        if (queueResponse) responseQueued <= True;

        if (bus.error) begin
            $display("FAIL|reset-recovery|fresh-request-error");
            $finish(1);
        end
        if (bus.ready) begin
            if (bus.readData != 32'h1357_9bdf) begin
                $display("FAIL|reset-recovery|fresh-data|actual=%08x",
                    bus.readData);
                $finish(1);
            end
            $display("PASS|reset-recovery|outstanding reset, stale isolation, fresh recovery");
            $finish(0);
        end

        cycles <= cycles + 1;
        if (cycles == 40) begin
            $display("FAIL|reset-recovery|fresh-request-watchdog");
            $finish(1);
        end
    endrule
endmodule

typedef enum {
    DmaResetSubmit,
    DmaResetDrain,
    DmaBind,
    DmaRequest,
    DmaAddress0,
    DmaAddress1,
    DmaRead,
    DmaCompletion
} DmaDiagStage deriving (Bits, Eq, FShow);

module mkTbMainboardPlioDma(Empty);
    MainboardFPGAIfc board <- mkMainboardFPGA;
    Reg#(DmaDiagStage) stage <- mkReg(DmaResetSubmit);
    Reg#(Bit#(8)) cycles <- mkReg(0);
    Reg#(Bool) responseQueued <- mkReg(False);

    rule resetSubmit (stage == DmaResetSubmit);
        board.advance(diagIdleCards(), lightingBusMasterDriveDefault(),
            False, diagNoWorkerRequest(),
            False, False, False, False, 0, True);
        stage <= DmaResetDrain;
    endrule

    rule resetDrain (stage == DmaResetDrain);
        stage <= DmaBind;
    endrule

    rule bind (stage == DmaBind);
        board.bindDma(1, 3, 32'h0000_0100, 25'h00100, True, True);
        stage <= DmaRequest;
    endrule

    rule request (stage == DmaRequest);
        Vector#(8, BackplaneDrive) cards = diagIdleCards();
        cards[1] = diagRequestOnly();
        board.advance(cards, lightingBusMasterDriveDefault(),
            False, diagNoWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= DmaAddress0;
    endrule

    rule address0 (stage == DmaAddress0);
        Vector#(8, BackplaneDrive) cards = diagIdleCards();
        cards[1] = diagDmaAddress(32'h3000_0000, True);
        Vector#(8, PlioIn) slotInputs = board.plioSlots(cards, False);
        $display("DBG|plio-dma|phase=address0|ack=%0d|err=%0d|role=%0d|plio_mem_req=%0d",
            pack(slotInputs[1].ack), pack(slotInputs[1].err),
            pack(board.debugPlioRole), pack(board.debugPlioMemoryRequestValid));
        if (slotInputs[1].ack || slotInputs[1].err) begin
            $display("FAIL|plio-dma|phase=address0");
            $finish(1);
        end
        board.advance(cards, lightingBusMasterDriveDefault(),
            False, diagNoWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= DmaAddress1;
    endrule

    rule address1 (stage == DmaAddress1);
        Vector#(8, BackplaneDrive) cards = diagIdleCards();
        cards[1] = diagDmaAddress(32'h3000_0000, True);
        Vector#(8, PlioIn) slotInputs = board.plioSlots(cards, False);
        $display("DBG|plio-dma|phase=address1|ack=%0d|err=%0d|role=%0d|plio_mem_req=%0d",
            pack(slotInputs[1].ack), pack(slotInputs[1].err),
            pack(board.debugPlioRole), pack(board.debugPlioMemoryRequestValid));
        if (!slotInputs[1].ack || slotInputs[1].err) begin
            $display("FAIL|plio-dma|phase=address1");
            $finish(1);
        end
        board.advance(cards, lightingBusMasterDriveDefault(),
            False, diagNoWorkerRequest(),
            False, False, False, False, 0, False);
        stage <= DmaRead;
        cycles <= 0;
    endrule

    rule readBeat (stage == DmaRead);
        Vector#(8, BackplaneDrive) cards = diagIdleCards();
        cards[1] = diagDmaReadBeat();
        Vector#(8, PlioIn) slotInputs = board.plioSlots(cards, False);
        Bool queueResponse = board.memoryBackendResponseReady && !responseQueued;

        $display("DBG|plio-dma|phase=read|cycle=%0d|ack=%0d|err=%0d|ad_valid=%0d|ad=%08x|role=%0d|owner=%0d|plio_mem_req=%0d|backend_req=%0d|backend_wr=%0d|backend_addr=%08x|backend_resp_ready=%0d|resp_queue=%0d",
            cycles, pack(slotInputs[1].ack), pack(slotInputs[1].err),
            pack(slotInputs[1].adValid), slotInputs[1].ad,
            pack(board.debugPlioRole), pack(board.debugMemoryOwner),
            pack(board.debugPlioMemoryRequestValid),
            pack(board.memoryBackendRequestValid), pack(board.memoryBackendWrite),
            board.memoryBackendAddress, pack(board.memoryBackendResponseReady),
            pack(queueResponse));

        if (slotInputs[1].err) begin
            $display("FAIL|plio-dma|bus-error");
            $finish(1);
        end

        if (board.memoryBackendRequestValid
            && (board.memoryBackendWrite
                || board.memoryBackendAddress != 32'h0000_0100)) begin
            $display("FAIL|plio-dma|backend-request|write=%0d|addr=%08x",
                pack(board.memoryBackendWrite), board.memoryBackendAddress);
            $finish(1);
        end

        board.advance(cards, lightingBusMasterDriveDefault(),
            False, diagNoWorkerRequest(),
            True, queueResponse, False, queueResponse, 32'h1122_3344, False);
        if (queueResponse) responseQueued <= True;

        if (slotInputs[1].ack) begin
            if (!slotInputs[1].adValid || slotInputs[1].ad != 32'h1122_3344) begin
                $display("FAIL|plio-dma|read-data|valid=%0d|actual=%08x",
                    pack(slotInputs[1].adValid), slotInputs[1].ad);
                $finish(1);
            end
            stage <= DmaCompletion;
            cycles <= 0;
        end
        else begin
            cycles <= cycles + 1;
            if (cycles == 100) begin
                $display("FAIL|plio-dma|read-watchdog|role=%0d|owner=%0d|plio_mem_req=%0d|backend_req=%0d|backend_resp_ready=%0d",
                    pack(board.debugPlioRole), pack(board.debugMemoryOwner),
                    pack(board.debugPlioMemoryRequestValid),
                    pack(board.memoryBackendRequestValid),
                    pack(board.memoryBackendResponseReady));
                $finish(1);
            end
        end
    endrule

    rule completionWait (stage == DmaCompletion && !board.dmaCompletionValid);
        board.advance(diagIdleCards(), lightingBusMasterDriveDefault(),
            False, diagNoWorkerRequest(),
            False, False, False, False, 0, False);
        cycles <= cycles + 1;
        if (cycles == 40) begin
            $display("FAIL|plio-dma|completion-watchdog|role=%0d",
                pack(board.debugPlioRole));
            $finish(1);
        end
    endrule

    rule completionDone (stage == DmaCompletion && board.dmaCompletionValid);
        if (board.dmaCompletionStatus != DmaOk || board.dmaCompletionBeats != 1) begin
            $display("FAIL|plio-dma|completion|status=%0d|beats=%0d",
                pack(board.dmaCompletionStatus), board.dmaCompletionBeats);
            $finish(1);
        end
        $display("PASS|plio-dma|one-beat PLIO DMA read through mainboard memory path");
        $finish(0);
    endrule
endmodule

endpackage
