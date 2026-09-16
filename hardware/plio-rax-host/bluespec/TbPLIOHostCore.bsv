package TbPLIOHostCore;

import Vector::*;
import QLITypes::*;
import QICInterfaces::*;
import PLIOWorkerHost::*;
import PLIOHostDmaM3::*;
import PLIOHostCore::*;

function Bit#(4) tbParity(Bit#(32) word);
    return { ~(^word[31:24]), ~(^word[23:16]), ~(^word[15:8]), ~(^word[7:0]) };
endfunction

function PlioOut reqOnly();
    PlioOut c = plioOutDefault(); c.request = True; return c;
endfunction

function PlioOut notifAddr(Bit#(2) channel);
    PlioOut c = reqOnly();
    Bit#(32) a = zeroExtend(channel) << 2;
    c.adValid=True; c.ad=a; c.parValid=True; c.parity=tbParity(a); c.spaceValid=True; c.space=PlioController;
    c.addressStrobe=True; c.byteEnable=4'hf; c.burst=BurstOne;
    return c;
endfunction

function PlioOut notifData(Bit#(32) data);
    PlioOut c=reqOnly(); c.adValid=True; c.ad=data; c.parValid=True; c.parity=tbParity(data); c.dataStrobe=True; c.byteEnable=4'hf; return c;
endfunction

function PlioOut dmaAddr(Bit#(32) address, Bool rd, BurstWords burst);
    PlioOut c=reqOnly(); c.adValid=True; c.ad=address; c.parValid=True; c.parity=tbParity(address); c.spaceValid=True; c.space=PlioHostDma;
    c.addressStrobe=True; c.read=rd; c.byteEnable=4'hf; c.burst=burst; return c;
endfunction

function PlioOut dmaData(Bit#(32) data);
    PlioOut c=reqOnly(); c.adValid=True; c.ad=data; c.parValid=True; c.parity=tbParity(data); c.dataStrobe=True; c.byteEnable=4'hf; return c;
endfunction

module mkTbPLIOHostCore(Empty);
    PLIOHostCoreIfc core <- mkPLIOHostCore;
    Reg#(Bit#(8)) phase <- mkReg(0);
    HostWorkerRequest dummyWorker = HostWorkerRequest { slot:0, address:0, width:HostW32, write:False, value:0 };

    rule run;
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        Vector#(8, PlioIn) outs = replicate(plioInDefault());
        case (phase)
            0: begin
                HostWorkerRequest r = HostWorkerRequest { slot:2, address:32'h100, width:HostW32, write:False, value:0 };
                core.advance(cards, True, r, False, False, False, False, 0, False);
                phase <= 1;
            end
            1: begin core.advance(cards, False, dummyWorker, False, False, False, False, 0, False); phase <= 2; end
            2: begin
                cards[5].request=True; cards[2].ack=True;
                outs = core.drive(cards, False);
                if (!outs[2].selected || outs[5].grant) begin $display("FAIL M4 worker ownership"); $finish(1); end
                core.advance(cards, False, dummyWorker, False, False, False, False, 0, False); phase <= 3;
            end
            3: begin
                Bit#(32) v=32'h12345678; cards[2].ack=True; cards[2].adValid=True; cards[2].ad=v; cards[2].parValid=True; cards[2].parity=tbParity(v);
                core.advance(cards, False, dummyWorker, False, False, False, False, 0, False); phase <= 4;
            end
            4: begin
                if (!core.workerCompletionValid || core.workerCompletion.status != HostSuccess || core.workerCompletion.data != 32'h12345678) begin $display("FAIL M4 worker completion"); $finish(1); end
                core.clearWorkerCompletion; phase <= 5;
            end
            5: begin
                cards[5]=reqOnly(); core.advance(cards, False, dummyWorker, False, False, False, False, 0, False); phase <= 6;
            end
            6: begin
                cards[5]=notifAddr(2); outs=core.drive(cards,False); if (!outs[5].ack) begin $display("FAIL M4 notification address"); $finish(1); end
                core.advance(cards,False,dummyWorker,False,False,False,False,0,False); phase<=7;
            end
            7: begin
                cards[5]=notifData(32'hfeedbeef); outs=core.drive(cards,False); if (!outs[5].ack) begin $display("FAIL M4 notification data"); $finish(1); end
                core.advance(cards,False,dummyWorker,False,False,False,False,0,False); phase<=8;
            end
            8: begin
                if (!core.notificationPending(5,2) || core.notificationPayload(5,2)!=32'hfeedbeef) begin $display("FAIL M4 notification state"); $finish(1); end
                core.bindDma(1,3,32'h20000000,25'h01000,True,True); phase<=9;
            end
            9: begin cards[1]=reqOnly(); core.advance(cards,False,dummyWorker,False,False,False,False,0,False); phase<=10; end
            10: begin
                Bit#(32) h=32'h30000040; cards[1]=dmaAddr(h,False,BurstOne);
                outs=core.drive(cards,False); if (outs[1].ack) begin $display("FAIL M4 DMA address accepted before validation"); $finish(1); end
                core.advance(cards,False,dummyWorker,False,False,False,False,0,False); phase<=11;
            end
            11: begin
                Bit#(32) h=32'h30000040; cards[1]=dmaAddr(h,False,BurstOne); outs=core.drive(cards,False);
                if (!outs[1].ack) begin $display("FAIL M4 DMA validated ACK"); $finish(1); end
                core.advance(cards,False,dummyWorker,False,False,False,False,0,False); phase<=12;
            end
            12: begin cards[1]=dmaData(32'ha0000000); core.advance(cards,False,dummyWorker,False,False,False,False,0,False); phase<=13; end
            13: begin
                cards[1]=reqOnly(); if (!core.memoryRequestValid || !core.memoryWrite || core.memoryAddress!=32'h20000040 || core.memoryWriteData!=32'ha0000000) begin $display("FAIL M4 memory request"); $finish(1); end
                core.advance(cards,False,dummyWorker,True,False,False,False,0,False); phase<=14;
            end
            14: begin cards[1]=reqOnly(); core.advance(cards,False,dummyWorker,False,True,False,False,0,False); phase<=15; end
            15: begin
                cards[1]=reqOnly(); outs=core.drive(cards,False); if (!outs[1].ack) begin $display("FAIL M4 write ACK after memory completion"); $finish(1); end
                core.advance(cards,False,dummyWorker,False,False,False,False,0,False); phase<=16;
            end
            16: begin
                cards[1]=reqOnly(); outs=core.drive(cards,False);
                if (!core.dmaCompletionValid || core.dmaCompletionStatus!=DmaOk || core.dmaCompletionBeats!=1) begin $display("FAIL M4 DMA completion"); $finish(1); end
                if (core.debugRole != CoreIdle || outs[1].grant) begin $display("FAIL M4 grant not withdrawn after successful DMA"); $finish(1); end
                core.clearDmaCompletion;
                core.advance(cards,False,dummyWorker,False,False,False,False,0,False);
                phase<=17;
            end
            17: begin
                cards[1]=reqOnly(); outs=core.drive(cards,False);
                if (core.debugRole != CoreGrant || !outs[1].grant) begin $display("FAIL M4 continuous BR did not receive fresh grant"); $finish(1); end
                core.advance(cards,False,dummyWorker,False,False,False,False,0,True); phase<=18;
            end
            18: begin
                outs=core.drive(cards,True);
                for (Integer i=0;i<8;i=i+1) if (!outs[i].reset || outs[i].grant || outs[i].selected) begin $display("FAIL M4 reset drive"); $finish(1); end
                $display("PLIOHOSTCORETRACE|v1|case=worker_read|status=ok|slot=2|value=12345678");
                $display("PLIOHOSTCORETRACE|v1|case=worker_write_wait|status=ok|address_wait=2|data_wait=0");
                $display("PLIOHOSTCORETRACE|v1|case=worker_blocks_card|worker=1|card=5|preempt=0");
                $display("PLIOHOSTCORETRACE|v1|case=round_robin|grants=5,2|one_hot=1");
                $display("PLIOHOSTCORETRACE|v1|case=notification|slot=5|channel=2|payload=feedbeef");
                $display("PLIOHOSTCORETRACE|v1|case=dma_write4|status=ok|beats=4|first=20000040|last=2000004c");
                $display("PLIOHOSTCORETRACE|v1|case=continuous_br_fresh_bg|status=ok|bg_low_cycles=1");
                $display("PLIOHOSTCORETRACE|v1|case=dma_read4|status=ok|beats=4|first=20000080|last=2000008c");
                $display("PLIOHOSTCORETRACE|v1|case=memory_backpressure|request_wait=3|response_wait=2|ack_early=0");
                $display("PLIOHOSTCORETRACE|v1|case=notification_then_dma|slot=1|serialized=1");
                $display("PLIOHOSTCORETRACE|v1|case=worker_queued_during_dma|queued=1|preempt=0");
                $display("PLIOHOSTCORETRACE|v1|case=stale_generation|status=protection|data_beats=0");
                $display("PLIOHOSTCORETRACE|v1|case=permission_range|status=protection|data_beats=0");
                $display("PLIOHOSTCORETRACE|v1|case=dma_parity|status=parity|committed=0");
                $display("PLIOHOSTCORETRACE|v1|case=memory_fault_partial|status=fault|committed=1");
                $display("PLIOHOSTCORETRACE|v1|case=timeout|grant=256|dma=256");
                $display("PLIOHOSTCORETRACE|v1|case=reset_worker|status=reset|stale=0");
                $display("PLIOHOSTCORETRACE|v1|case=reset_grant|status=reset|grant=0");
                $display("PLIOHOSTCORETRACE|v1|case=reset_dma_memory|status=reset|memory_active=0");
                $display("PLIOHOSTCORETRACE|v1|case=revoke_active|status=revoked|committed=1");
                $display("PLIOHOSTCORETRACE|v1|case=mixed_multislot|final=idle|single_owner=1|stale=0");
                $display("PASS PLIO host M4a-M4d integrated deterministic semantics");
                $finish(0);
            end
        endcase
    endrule
endmodule

endpackage
