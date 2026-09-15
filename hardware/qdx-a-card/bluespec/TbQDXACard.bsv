package TbQDXACard;

import QLITypes::*;
import QICInterfaces::*;
import PLIOQICPhase1::*;
import PLIOTx::*;
import QDXA::*;
import QDXACard::*;

typedef enum {
    WReset,
    WSqBase, WSqSize, WCqBase, WCqSize, WControl, WSqTail,
    WIdle, WDone
} Work deriving (Bits, Eq, FShow);

typedef enum { WAddr, WData } WorkerPhase deriving (Bits, Eq, FShow);
typedef enum {
    PeerIdle, PeerGrant, PeerDmaAddress, PeerDmaData,
    PeerNotificationAddress, PeerNotificationData
} PeerState deriving (Bits, Eq, FShow);

function Bool isProgramming(Work w);
    case (w)
        WSqBase, WSqSize, WCqBase, WCqSize, WControl, WSqTail: return True;
        default: return False;
    endcase
endfunction

function Bit#(32) workAddress(Work w);
    case (w)
        WSqBase: return regSqBase;
        WSqSize: return regSqSize;
        WCqBase: return regCqBase;
        WCqSize: return regCqSize;
        WControl: return regQdxControl;
        WSqTail: return regSqTail;
        default: return 0;
    endcase
endfunction

function Bit#(32) workData(Work w);
    case (w)
        WSqBase: return 32'h1200_1000;
        WSqSize: return 4;
        WCqBase: return 32'h2300_2000;
        WCqSize: return 4;
        WControl: return 32'h0000_0005;
        WSqTail: return 1;
        default: return 0;
    endcase
endfunction

function Bit#(4) workBe(Work w);
    case (w)
        WSqSize, WCqSize, WSqTail: return 4'h3;
        default: return 4'hf;
    endcase
endfunction

function Work nextWork(Work w);
    case (w)
        WSqBase: return WSqSize;
        WSqSize: return WCqBase;
        WCqBase: return WCqSize;
        WCqSize: return WControl;
        WControl: return WSqTail;
        WSqTail: return WIdle;
        default: return w;
    endcase
endfunction

function PlioIn workerBus(Work w, WorkerPhase p);
    PlioIn b = plioInDefault();
    Bit#(32) a = workAddress(w);
    Bit#(32) d = workData(w);
    Bit#(4) be = workBe(w);
    b.selected = True;
    b.read = False;
    b.byteEnable = be;
    b.burst = BurstOne;
    if (p == WAddr) begin
        b.adValid = True;
        b.ad = a;
        b.parValid = True;
        b.parity = oddParity32P1(a);
        b.spaceValid = True;
        b.space = PlioWorker;
        b.addressStrobe = True;
    end
    else begin
        b.adValid = True;
        b.ad = d;
        b.parValid = True;
        b.parity = oddParity32P1(d);
        b.dataStrobe = True;
    end
    return b;
endfunction

function PlioIn peerBus(PeerState p, Bool dmaRead, Bit#(5) beat);
    PlioIn b = plioInDefault();
    case (p)
        PeerGrant: b.grant = True;
        PeerDmaAddress: begin b.grant=True; b.ack=True; end
        PeerDmaData: begin
            b.grant=True; b.ack=True;
            if (dmaRead) begin
                Bit#(32) data = 32'ha000_0000 + zeroExtend(beat)*4;
                b.adValid=True; b.ad=data;
                b.parValid=True; b.parity=oddParity32P1(data);
            end
        end
        PeerNotificationAddress: begin b.grant=True; b.ack=True; end
        PeerNotificationData: begin b.grant=True; b.ack=True; end
        default: begin end
    endcase
    return b;
endfunction

module mkTbQDXACard(Empty);
    QDXACardIfc card <- mkQDXACard;

    Reg#(Work) work <- mkReg(WReset);
    Reg#(WorkerPhase) workerPhase <- mkReg(WAddr);
    Reg#(PeerState) peer <- mkReg(PeerIdle);
    Reg#(Bool) peerRead <- mkReg(False);
    Reg#(Bit#(5)) peerBeat <- mkReg(0);
    Reg#(Bit#(5)) peerTotal <- mkReg(0);
    Reg#(Bool) notificationSeen <- mkReg(False);
    Reg#(Bit#(16)) idleCycles <- mkReg(0);

    function PlioIn currentBus();
        PlioIn b = plioInDefault();
        if (work == WReset) begin
            b.reset = True;
        end
        else if (isProgramming(work)) begin
            b = workerBus(work, workerPhase);
        end
        else begin
            b = peerBus(peer, peerRead, peerBeat);
        end
        return b;
    endfunction

    rule launch (card.ready && work != WDone);
        card.startCycle(currentBus());
    endrule

    rule consume (card.cycleDone && work != WDone);
        BackplaneDrive bp = card.backplane;
        Work next = work;
        WorkerPhase nextWp = workerPhase;
        PeerState nextPeer = peer;

        if (card.protocolFault) begin
            $display("FAIL QDX-A card physical protocol fault");
            $finish(1);
        end

        if (work == WReset) begin
            if (bp.adParValid || bp.controlValid || bp.responseValid || bp.request) begin
                $display("FAIL QDX-A card drives during reset");
                $finish(1);
            end
            $display("QDXACARDTRACE|v1|event=reset|drive=0");
            next = WSqBase;
            nextWp = WAddr;
        end
        else if (isProgramming(work)) begin
            if (bp.responseValid && bp.err) begin
                $display("FAIL worker programming ERR work=%0d phase=%0d",pack(work),pack(workerPhase));
                $finish(1);
            end
            if (bp.responseValid && bp.ack) begin
                if (workerPhase == WAddr) begin
                    nextWp = WData;
                end
                else begin
                    if (work == WSqTail)
                        $display("QDXACARDTRACE|v1|event=configured|sqh=0|sqt=1|cqh=0|cqt=0");
                    next = nextWork(work);
                    nextWp = WAddr;
                end
            end
        end
        else begin
            case (peer)
                PeerIdle: begin
                    if (bp.request) nextPeer = PeerGrant;
                end

                PeerGrant: begin
                    if (bp.controlValid && bp.control.addressStrobe) begin
                        if (bp.control.space == 1) begin
                            Bool rd = bp.control.read;
                            Bit#(5) total = 0;
                            case (bp.control.burstLen)
                                0: total=1;
                                1: total=4;
                                2: total=8;
                                default: total=16;
                            endcase
                            if (rd) begin
                                if (!bp.adParValid || bp.ad != 32'h1200_1000 || total != 8) begin
                                    $display("FAIL SQ DMA address/burst ad=%08x total=%0d",bp.ad,total);
                                    $finish(1);
                                end
                                $display("QDXACARDTRACE|v1|event=sq_dma|addr=%08x|words=8",bp.ad);
                            end
                            else begin
                                if (!bp.adParValid || bp.ad != 32'h2300_2000 || total != 4) begin
                                    $display("FAIL CQ DMA address/burst ad=%08x total=%0d",bp.ad,total);
                                    $finish(1);
                                end
                                if (card.endpointLastCommand0 != 32'ha000_0000) begin
                                    $display("FAIL endpoint never received exact command0 %08x",card.endpointLastCommand0);
                                    $finish(1);
                                end
                                $display("QDXACARDTRACE|v1|event=cq_dma|addr=%08x|words=4",bp.ad);
                            end
                            peerRead <= rd;
                            peerTotal <= total;
                            peerBeat <= 0;
                            nextPeer = PeerDmaAddress;
                        end
                        else if (bp.control.space == 2) begin
                            if (!bp.adParValid || bp.ad != 0) begin
                                $display("FAIL Notification channel-0 address %08x",bp.ad);
                                $finish(1);
                            end
                            nextPeer = PeerNotificationAddress;
                        end
                        else begin
                            $display("FAIL unexpected manager SPACE %0d",bp.control.space);
                            $finish(1);
                        end
                    end
                end

                PeerDmaAddress: begin
                    if (bp.controlValid && bp.control.addressStrobe)
                        nextPeer = PeerDmaData;
                end

                PeerDmaData: begin
                    if (bp.controlValid && bp.control.dataStrobe) begin
                        if (!peerRead) begin
                            Bit#(32) expected = 0;
                            case (peerBeat)
                                0: expected=32'hc001_0000;
                                1: expected=32'ha000_0004;
                                2: expected=32'ha000_0018;
                                default: expected=32'ha000_001c;
                            endcase
                            if (!bp.adParValid || bp.ad != expected || bp.parity != oddParity32P1(expected)) begin
                                $display("FAIL CQ data beat=%0d expected=%08x got=%08x",peerBeat,expected,bp.ad);
                                $finish(1);
                            end
                        end
                        Bit#(5) n = peerBeat + 1;
                        peerBeat <= n;
                        if (n == peerTotal) begin
                            if (!peerRead)
                                $display("QDXACARDTRACE|v1|event=cq_data|words=4|exact=1");
                            nextPeer = PeerIdle;
                        end
                    end
                end

                PeerNotificationAddress: begin
                    if (bp.controlValid && bp.control.addressStrobe)
                        nextPeer = PeerNotificationData;
                end

                PeerNotificationData: begin
                    if (bp.controlValid && bp.control.dataStrobe) begin
                        if (!bp.adParValid || bp.ad != 0) begin
                            $display("FAIL Notification data %08x",bp.ad);
                            $finish(1);
                        end
                        notificationSeen <= True;
                        $display("QDXACARDTRACE|v1|event=notification|channel=0|ack=1");
                        nextPeer = PeerIdle;
                    end
                end
            endcase

            if (notificationSeen && nextPeer == PeerIdle) begin
                idleCycles <= idleCycles + 1;
                if (card.qdxState == AReadyIdle) begin
                    if (card.qdxError != QdxErrNone
                        || card.sqHead != 1 || card.sqTail != 1
                        || card.cqHead != 0 || card.cqTail != 1) begin
                        $display("FAIL final QDX-A card state/error/rings");
                        $finish(1);
                    end
                    $display("QDXACARDTRACE|v1|event=done|sqh=1|sqt=1|cqh=0|cqt=1|error=0");
                    next = WDone;
                end
                else if (idleCycles > 64) begin
                    $display("FAIL Notification completed but QDX-A did not return READY");
                    $finish(1);
                end
            end
        end

        work <= next;
        workerPhase <= nextWp;
        peer <= nextPeer;
        card.finishCycle;
    endrule

    rule finish (work == WDone && card.ready);
        $display("PASS QDX-A physical card PLIO-TX -> PTI -> QIC -> QLI-16 -> QDX-A");
        $finish(0);
    endrule
endmodule

endpackage
