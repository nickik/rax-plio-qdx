package TbPLIOHostCoreStress;

import Vector::*;
import QLITypes::*;
import QICInterfaces::*;
import PLIOWorkerHost::*;
import PLIOHostDmaM3::*;
import PLIOHostCore::*;

function Bit#(4) stressParity(Bit#(32) word);
    return { ~(^word[31:24]), ~(^word[23:16]), ~(^word[15:8]), ~(^word[7:0]) };
endfunction

function Bit#(32) nextSeed(Bit#(32) x);
    Bit#(32) y = x;
    y = y ^ (y << 13);
    y = y ^ (y >> 17);
    y = y ^ (y << 5);
    return y;
endfunction

function PlioOut requestOnly();
    PlioOut c = plioOutDefault(); c.request = True; return c;
endfunction

function PlioOut notificationAddress(Bit#(2) channel);
    PlioOut c = requestOnly();
    Bit#(32) a = zeroExtend(channel) << 2;
    c.adValid=True; c.ad=a; c.parValid=True; c.parity=stressParity(a);
    c.spaceValid=True; c.space=PlioController; c.addressStrobe=True;
    c.byteEnable=4'hf; c.burst=BurstOne;
    return c;
endfunction

function PlioOut notificationData(Bit#(32) data);
    PlioOut c=requestOnly(); c.adValid=True; c.ad=data; c.parValid=True;
    c.parity=stressParity(data); c.dataStrobe=True; c.byteEnable=4'hf; return c;
endfunction

function PlioOut dmaAddress(Bit#(32) address, Bool rd);
    PlioOut c=requestOnly(); c.adValid=True; c.ad=address; c.parValid=True;
    c.parity=stressParity(address); c.spaceValid=True; c.space=PlioHostDma;
    c.addressStrobe=True; c.read=rd; c.byteEnable=4'hf; c.burst=BurstOne; return c;
endfunction

function PlioOut dmaWriteData(Bit#(32) data);
    PlioOut c=requestOnly(); c.adValid=True; c.ad=data; c.parValid=True;
    c.parity=stressParity(data); c.dataStrobe=True; c.byteEnable=4'hf; return c;
endfunction

module mkTbPLIOHostCoreStress(Empty);
    PLIOHostCoreIfc core <- mkPLIOHostCore;
    Reg#(Bit#(8)) phase <- mkReg(0);
    Reg#(Bit#(7)) epoch <- mkReg(0);
    Reg#(Bit#(32)) seed <- mkReg(32'h4d34e5a1);
    Reg#(Bit#(32)) current <- mkReg(0);
    Reg#(Bit#(3)) slot <- mkReg(0);
    Reg#(Bit#(2)) channel <- mkReg(0);
    Reg#(Bit#(3)) awLeft <- mkReg(0);
    Reg#(Bit#(3)) dwLeft <- mkReg(0);
    Reg#(Bit#(3)) mwLeft <- mkReg(0);
    Reg#(Bit#(3)) rwLeft <- mkReg(0);
    Reg#(Bool) dmaRead <- mkReg(False);

    HostWorkerRequest dummyWorker = HostWorkerRequest { slot:0, address:0, width:HostW32, write:False, value:0 };

    rule run;
        Vector#(8, PlioOut) cards = replicate(plioOutDefault());
        Vector#(8, PlioIn) outs = replicate(plioInDefault());

        case (phase)
            0: begin
                core.bindDma(1,3,32'h20000000,25'h01000,True,True);
                phase <= 1;
            end
            1: begin
                if (epoch == 64) begin
                    $display("PASS PLIO host M4e seeded stress seed=4d34e5a1 epochs=64");
                    $finish(0);
                end
                else begin
                    Bit#(32) n = nextSeed(seed);
                    seed <= n; current <= n;
                    case (n[1:0])
                        0, 1: begin
                            Bit#(3) s = n[7:5];
                            Bit#(2) aw = n[9:8]; Bit#(2) dw = n[11:10];
                            Bool wr = n[1:0] == 1;
                            Bit#(32) v = n ^ 32'ha55a5aa5;
                            HostWorkerRequest r = HostWorkerRequest { slot:s, address:32'h100, width:HostW32, write:wr, value:v };
                            slot <= s; awLeft <= zeroExtend(aw); dwLeft <= zeroExtend(dw);
                            core.advance(cards,True,r,False,False,False,False,0,False);
                            phase <= 10;
                        end
                        2: begin
                            Bit#(3) s=n[7:5]; Bit#(2) ch=n[9:8];
                            slot<=s; channel<=ch; awLeft<=zeroExtend(n[11:10]); dwLeft<=zeroExtend(n[13:12]);
                            cards[s]=requestOnly();
                            core.advance(cards,False,dummyWorker,False,False,False,False,0,False);
                            phase<=20;
                        end
                        3: begin
                            slot<=1; dmaRead<=unpack(n[2]); awLeft<=zeroExtend(n[9:8]); dwLeft<=zeroExtend(n[11:10]);
                            mwLeft<=zeroExtend(n[13:12]); rwLeft<=zeroExtend(n[15:14]);
                            cards[1]=requestOnly();
                            core.advance(cards,False,dummyWorker,False,False,False,False,0,False);
                            phase<=30;
                        end
                    endcase
                end
            end

            // Worker: one queue-to-active cycle, then randomized address/data stalls.
            10: begin
                core.advance(cards,False,dummyWorker,False,False,False,False,0,False);
                phase<=11;
            end
            11: begin
                if (awLeft != 0) begin
                    core.advance(cards,False,dummyWorker,False,False,False,False,0,False);
                    awLeft<=awLeft-1;
                end
                else begin
                    cards[slot].ack=True;
                    core.advance(cards,False,dummyWorker,False,False,False,False,0,False);
                    phase<=12;
                end
            end
            12: begin
                if (dwLeft != 0) begin
                    core.advance(cards,False,dummyWorker,False,False,False,False,0,False);
                    dwLeft<=dwLeft-1;
                end
                else begin
                    Bit#(32) v=current ^ 32'ha55a5aa5;
                    Bool wr=current[1:0]==1;
                    cards[slot].ack=True;
                    if (!wr) begin cards[slot].adValid=True; cards[slot].ad=v; cards[slot].parValid=True; cards[slot].parity=stressParity(v); end
                    core.advance(cards,False,dummyWorker,False,False,False,False,0,False);
                    phase<=13;
                end
            end
            13: begin
                Bit#(32) v=current ^ 32'ha55a5aa5;
                Bool wr=current[1:0]==1;
                if (!core.workerCompletionValid || core.workerCompletion.status != HostSuccess || (!wr && core.workerCompletion.data != v) || (wr && core.workerCompletion.data != 0)) begin
                    $display("FAIL M4e worker seed=4d34e5a1 epoch=%0d",epoch); $finish(1);
                end
                if (wr)
                    $display("PLIOHOSTSTRESS|v1|seed=4d34e5a1|epoch=%0d|kind=worker_write|slot=%0d|aw=%0d|dw=%0d|cursor=%0d|ok=1",epoch,slot,current[9:8],current[11:10],core.debugCursor);
                else
                    $display("PLIOHOSTSTRESS|v1|seed=4d34e5a1|epoch=%0d|kind=worker_read|slot=%0d|aw=%0d|dw=%0d|cursor=%0d|ok=1",epoch,slot,current[9:8],current[11:10],core.debugCursor);
                core.clearWorkerCompletion; epoch<=epoch+1; phase<=1;
            end

            // Notification transaction with randomized address and data waits.
            20: begin
                if (awLeft != 0) begin
                    cards[slot]=requestOnly(); core.advance(cards,False,dummyWorker,False,False,False,False,0,False); awLeft<=awLeft-1;
                end
                else begin
                    cards[slot]=notificationAddress(channel); outs=core.drive(cards,False);
                    if (!outs[slot].ack) begin $display("FAIL M4e notification address seed=4d34e5a1 epoch=%0d",epoch); $finish(1); end
                    core.advance(cards,False,dummyWorker,False,False,False,False,0,False); phase<=21;
                end
            end
            21: begin
                if (dwLeft != 0) begin
                    cards[slot]=requestOnly(); core.advance(cards,False,dummyWorker,False,False,False,False,0,False); dwLeft<=dwLeft-1;
                end
                else begin
                    Bit#(32) payload=current ^ 32'hfeedbeef;
                    cards[slot]=notificationData(payload); outs=core.drive(cards,False);
                    if (!outs[slot].ack) begin $display("FAIL M4e notification data seed=4d34e5a1 epoch=%0d",epoch); $finish(1); end
                    core.advance(cards,False,dummyWorker,False,False,False,False,0,False); phase<=22;
                end
            end
            22: begin
                Bit#(32) payload=current ^ 32'hfeedbeef;
                if (!core.notificationPending(slot,channel) || core.notificationPayload(slot,channel)!=payload || !core.claimValid || core.claimSlot!=slot || core.claimChannel!=channel || core.claimPayload!=payload) begin
                    $display("FAIL M4e notification state seed=4d34e5a1 epoch=%0d",epoch); $finish(1);
                end
                $display("PLIOHOSTSTRESS|v1|seed=4d34e5a1|epoch=%0d|kind=notification|slot=%0d|ch=%0d|aw=%0d|dw=%0d|cursor=%0d|ok=1",epoch,slot,channel,current[11:10],current[13:12],core.debugCursor);
                core.claimFirst; epoch<=epoch+1; phase<=1;
            end

            // DMA address phase: the first presentation must not ACK until capability validation completes.
            30: begin
                if (awLeft != 0) begin
                    cards[1]=requestOnly(); core.advance(cards,False,dummyWorker,False,False,False,False,0,False); awLeft<=awLeft-1;
                end
                else begin
                    cards[1]=dmaAddress(32'h30000040,dmaRead); outs=core.drive(cards,False);
                    if (outs[1].ack) begin $display("FAIL M4e premature DMA ACK seed=4d34e5a1 epoch=%0d",epoch); $finish(1); end
                    core.advance(cards,False,dummyWorker,False,False,False,False,0,False); phase<=31;
                end
            end
            31: begin
                cards[1]=dmaAddress(32'h30000040,dmaRead); outs=core.drive(cards,False);
                if (!outs[1].ack) begin $display("FAIL M4e validated DMA ACK seed=4d34e5a1 epoch=%0d",epoch); $finish(1); end
                core.advance(cards,False,dummyWorker,False,False,False,False,0,False);
                phase<=32;
            end
            32: begin
                if (!dmaRead) begin
                    if (dwLeft != 0) begin
                        cards[1]=requestOnly(); core.advance(cards,False,dummyWorker,False,False,False,False,0,False); dwLeft<=dwLeft-1;
                    end
                    else begin
                        Bit#(32) payload=current ^ 32'h13579bdf;
                        cards[1]=dmaWriteData(payload); core.advance(cards,False,dummyWorker,False,False,False,False,0,False); phase<=33;
                    end
                end
                else phase<=33;
            end
            33: begin
                cards[1]=requestOnly();
                if (!core.memoryRequestValid) begin $display("FAIL M4e missing memory request seed=4d34e5a1 epoch=%0d",epoch); $finish(1); end
                if (mwLeft != 0) begin
                    outs=core.drive(cards,False); if (outs[1].ack) begin $display("FAIL M4e ACK before memory completion seed=4d34e5a1 epoch=%0d",epoch); $finish(1); end
                    core.advance(cards,False,dummyWorker,False,False,False,False,0,False); mwLeft<=mwLeft-1;
                end
                else begin
                    core.advance(cards,False,dummyWorker,True,False,False,False,0,False); phase<=34;
                end
            end
            34: begin
                cards[1]=requestOnly();
                if (rwLeft != 0) begin
                    core.advance(cards,False,dummyWorker,False,False,False,False,0,False); rwLeft<=rwLeft-1;
                end
                else begin
                    Bit#(32) payload=current ^ 32'h13579bdf;
                    core.advance(cards,False,dummyWorker,False,True,False,dmaRead,payload,False);
                    phase<=35;
                end
            end
            35: begin
                if (dmaRead) begin
                    if (dwLeft != 0) begin
                        cards[1]=requestOnly(); core.advance(cards,False,dummyWorker,False,False,False,False,0,False); dwLeft<=dwLeft-1;
                    end
                    else begin
                        Bit#(32) payload=current ^ 32'h13579bdf;
                        cards[1]=requestOnly(); cards[1].dataStrobe=True; outs=core.drive(cards,False);
                        if (!outs[1].ack || !outs[1].adValid || outs[1].ad!=payload) begin $display("FAIL M4e DMA read data seed=4d34e5a1 epoch=%0d",epoch); $finish(1); end
                        core.advance(cards,False,dummyWorker,False,False,False,False,0,False); phase<=37;
                    end
                end
                else begin
                    cards[1]=requestOnly(); outs=core.drive(cards,False);
                    if (!outs[1].ack) begin $display("FAIL M4e DMA write ACK seed=4d34e5a1 epoch=%0d",epoch); $finish(1); end
                    core.advance(cards,False,dummyWorker,False,False,False,False,0,False); phase<=37;
                end
            end
            37: begin
                if (!core.dmaCompletionValid || core.dmaCompletionStatus!=DmaOk || core.dmaCompletionBeats!=1 || core.debugRole!=CoreIdle) begin
                    $display("FAIL M4e DMA completion seed=4d34e5a1 epoch=%0d",epoch); $finish(1);
                end
                if (dmaRead)
                    $display("PLIOHOSTSTRESS|v1|seed=4d34e5a1|epoch=%0d|kind=dma_read|slot=1|aw=%0d|dw=%0d|mw=%0d|rw=%0d|cursor=%0d|ok=1",epoch,current[9:8],current[11:10],current[13:12],current[15:14],core.debugCursor);
                else
                    $display("PLIOHOSTSTRESS|v1|seed=4d34e5a1|epoch=%0d|kind=dma_write|slot=1|aw=%0d|dw=%0d|mw=%0d|rw=%0d|cursor=%0d|ok=1",epoch,current[9:8],current[11:10],current[13:12],current[15:14],core.debugCursor);
                core.clearDmaCompletion; epoch<=epoch+1; phase<=1;
            end
        endcase
    endrule
endmodule

endpackage
