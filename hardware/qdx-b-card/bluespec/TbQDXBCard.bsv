package TbQDXBCard;

import QLITypes::*;
import QICInterfaces::*;
import PLIOQICPhase1::*;
import PLIOTx::*;
import QDXA::*;
import QDXBEndpoint::*;
import QDXBCard::*;

typedef enum { WReset, WSqBase, WSqSize, WCqBase, WCqSize, WControl, WSqTail, WRun, WDone } Work deriving (Bits,Eq,FShow);
typedef enum { WAddr, WData } WorkerPhase deriving (Bits,Eq,FShow);
typedef enum { PeerIdle, PeerGrant, PeerDmaAddress, PeerDmaData, PeerNotificationAddress, PeerNotificationData } PeerState deriving (Bits,Eq,FShow);

function Bool isProgramming(Work w);
    case (w) WSqBase,WSqSize,WCqBase,WCqSize,WControl,WSqTail:return True; default:return False; endcase
endfunction
function Bit#(32) workAddress(Work w);
    case (w) WSqBase:return REG_SQ_BASE; WSqSize:return REG_SQ_SIZE; WCqBase:return REG_CQ_BASE; WCqSize:return REG_CQ_SIZE; WControl:return REG_QDX_CONTROL; WSqTail:return REG_SQ_TAIL; default:return 0; endcase
endfunction
function Bit#(32) workData(Work w);
    case (w) WSqBase:return 32'h1200_1000; WSqSize:return 4; WCqBase:return 32'h2300_2000; WCqSize:return 4; WControl:return 5; WSqTail:return 1; default:return 0; endcase
endfunction
function Bit#(4) workBe(Work w); return (w==WSqSize || w==WCqSize || w==WSqTail)?4'h3:4'hf; endfunction
function Work nextWork(Work w);
    case (w) WSqBase:return WSqSize; WSqSize:return WCqBase; WCqBase:return WCqSize; WCqSize:return WControl; WControl:return WSqTail; WSqTail:return WRun; default:return w; endcase
endfunction

function PlioIn workerBus(Work w, WorkerPhase p);
    PlioIn b=plioInDefault(); Bit#(32) a=workAddress(w); Bit#(32) d=workData(w); Bit#(4) be=workBe(w);
    b.selected=True; b.read=False; b.byteEnable=be; b.burst=BurstOne;
    if (p==WAddr) begin b.adValid=True;b.ad=a;b.parValid=True;b.par=oddParity32P1(a);b.spaceValid=True;b.space=PlioWorker;b.addressStrobe=True; end
    else begin b.adValid=True;b.ad=d;b.parValid=True;b.par=oddParity32P1(d);b.dataStrobe=True; end
    return b;
endfunction

function Bit#(32) sqWord(Bit#(3) i);
    case (i)
        0:return 32'h0001_0014;
        1:return 32'h0000_beef;
        2:return 3;
        3:return 1;
        4:return 32'h0000_3000;
        default:return 0;
    endcase
endfunction

function PlioIn peerBus(PeerState p, Bool rd, Bit#(32) base, Bit#(5) beat);
    PlioIn b=plioInDefault();
    case (p)
        PeerGrant:b.grant=True;
        PeerDmaAddress:begin b.grant=True;b.ack=True; end
        PeerDmaData:begin
            b.grant=True;b.ack=True;
            if (rd) begin
                Bit#(32) a=base+(zeroExtend(beat)<<2); Bit#(32) data=0;
                if (base==32'h1200_1000) data=sqWord(truncate(beat));
                else data=32'h9900_0000+(a-32'h3000);
                b.adValid=True;b.ad=data;b.parValid=True;b.par=oddParity32P1(data);
            end
        end
        PeerNotificationAddress:begin b.grant=True;b.ack=True; end
        PeerNotificationData:begin b.grant=True;b.ack=True; end
        default:begin end
    endcase
    return b;
endfunction

module mkTbQDXBCard(Empty);
    QDXBCardIfc card <- mkQDXBCard;
    Reg#(Work) work <- mkReg(WReset);
    Reg#(WorkerPhase) wp <- mkReg(WAddr);
    Reg#(PeerState) peer <- mkReg(PeerIdle);
    Reg#(Bool) peerRead <- mkReg(False);
    Reg#(Bit#(32)) peerBase <- mkReg(0);
    Reg#(Bit#(5)) peerBeat <- mkReg(0);
    Reg#(Bit#(5)) peerTotal <- mkReg(0);
    Reg#(Bool) notificationSeen <- mkReg(False);
    Reg#(Bool) sawPayload <- mkReg(False);
    Reg#(Bool) sawCq <- mkReg(False);
    Reg#(Bit#(16)) idleCycles <- mkReg(0);

    function PlioIn currentBus();
        PlioIn b=plioInDefault();
        if (work==WReset) begin b.reset=True; return b; end
        if (isProgramming(work)) return workerBus(work,wp);
        return peerBus(peer,peerRead,peerBase,peerBeat);
    endfunction

    rule launch (card.ready && work!=WDone); card.startCycle(currentBus()); endrule

    rule consume (card.cycleDone && work!=WDone);
        BackplaneDrive bp=card.backplane; Work next=work; WorkerPhase nextWp=wp; PeerState nextPeer=peer;
        if (card.protocolFault) begin $display("FAIL QDX-B card protocol fault"); $finish(1); end

        if (work==WReset) begin
            if (bp.adParValid || bp.controlValid || bp.responseValid || bp.request) begin $display("FAIL drive during reset"); $finish(1); end
            $display("QDXBCARDTRACE|v1|event=reset|drive=0"); next=WSqBase; nextWp=WAddr;
        end
        else if (isProgramming(work)) begin
            if (bp.responseValid && bp.err) begin $display("FAIL QDX-B config ERR"); $finish(1); end
            if (bp.responseValid && bp.ack) begin
                if (wp==WAddr) nextWp=WData;
                else begin
                    if (work==WSqTail) $display("QDXBCARDTRACE|v1|event=submitted|opcode=14|tag=0000beef");
                    next=nextWork(work); nextWp=WAddr;
                end
            end
        end
        else begin
            case (peer)
                PeerIdle:if (bp.request) nextPeer=PeerGrant;
                PeerGrant:if (bp.controlValid && bp.control.addressStrobe) begin
                    if (bp.control.space==1) begin
                        BurstWords bw=unpack(bp.control.burstLen);
                        Bit#(5) total=burstWordCount(bw);
                        if (!bp.adParValid) begin $display("FAIL DMA address not driven"); $finish(1); end
                        if (bp.control.read) begin
                            if (bp.ad==32'h1200_1000) begin if (total!=8) begin $display("FAIL SQ burst");$finish(1);end end
                            else if (bp.ad>=32'h3000 && bp.ad<32'h3200) begin if (total!=16) begin $display("FAIL payload burst");$finish(1);end sawPayload<=True; end
                            else begin $display("FAIL unexpected H2D addr=%08x",bp.ad);$finish(1); end
                        end
                        else begin
                            if (bp.ad!=32'h2300_2000 || total!=4) begin $display("FAIL CQ DMA addr/burst");$finish(1); end
                            sawCq<=True;
                        end
                        peerRead<=bp.control.read; peerBase<=bp.ad; peerBeat<=0; peerTotal<=total; nextPeer=PeerDmaAddress;
                    end
                    else if (bp.control.space==2) begin
                        if (!bp.adParValid || bp.ad!=0) begin $display("FAIL notification address");$finish(1); end
                        nextPeer=PeerNotificationAddress;
                    end
                    else begin $display("FAIL unexpected manager space");$finish(1); end
                end
                PeerDmaAddress:if (bp.controlValid && bp.control.addressStrobe) nextPeer=PeerDmaData;
                PeerDmaData:if (bp.controlValid && bp.control.dataStrobe) begin
                    if (!peerRead && peerBase==32'h2300_2000) begin
                        Bit#(32) expect=0;
                        case (peerBeat) 0:expect=32'h0000_beef; 1:expect=32'h0008_0000; 2:expect=1; default:expect=0; endcase
                        if (!bp.adParValid || bp.ad!=expect || bp.par!=oddParity32P1(expect)) begin $display("FAIL CQ beat=%0d expect=%08x got=%08x",peerBeat,expect,bp.ad);$finish(1); end
                    end
                    Bit#(5) n=peerBeat+1; peerBeat<=n; if (n==peerTotal) nextPeer=PeerIdle;
                end
                PeerNotificationAddress:if (bp.controlValid && bp.control.addressStrobe) nextPeer=PeerNotificationData;
                PeerNotificationData:if (bp.controlValid && bp.control.dataStrobe) begin
                    if (!bp.adParValid || bp.ad!=0) begin $display("FAIL notification data");$finish(1);end
                    notificationSeen<=True; $display("QDXBCARDTRACE|v1|event=notification|channel=0|ack=1"); nextPeer=PeerIdle;
                end
            endcase

            if (notificationSeen && nextPeer==PeerIdle) begin
                idleCycles<=idleCycles+1;
                if (card.qdxState==AReadyIdle) begin
                    if (!sawPayload || !sawCq || card.qdxError!=QdxErrNone || card.qdxbLastStatus!=ST_SUCCESS
                        || card.sqHead!=1 || card.sqTail!=1 || card.cqHead!=0 || card.cqTail!=1) begin
                        $display("FAIL final QDX-B card state");$finish(1);
                    end
                    $display("QDXBCARDTRACE|v1|event=done|write_durable=1|payload=512|blocks=1|status=0"); next=WDone;
                end else if (idleCycles>128) begin $display("FAIL QDX-B never returned ready");$finish(1); end
            end
        end

        work<=next; wp<=nextWp; peer<=nextPeer; card.finishCycle;
    endrule

    rule done (work==WDone && card.ready);
        $display("PASS QDX-B physical card WRITE_DURABLE through PLIO-TX/PTI/QIC/QLI-16/QDX-A");
        $finish(0);
    endrule
endmodule

endpackage
