package TbQDXBSg;

import Vector::*;
import QLITypes::*;
import QDXAEndpointIfc::*;
import QDXAProfileDma::*;
import QDXBFakeMedia::*;
import QDXBEndpoint::*;

typedef enum { SWrite, SWriteRun, SWriteAck, SRead, SReadRun, SReadAck, SDone } SgTestState deriving (Bits,Eq,FShow);

function QdxACommand mkSgCmd(Bit#(8) op, Bit#(32) tag, Bit#(32) sgAddr);
    QdxACommand c=replicate(0);
    c[0]={16'd1,8'h00,op}; c[1]=tag; c[2]=7; c[3]={8'h00,8'd2,16'd1}; c[5]=sgAddr;
    return c;
endfunction

function Bit#(32) hostReadWord(SgTestState s, Bit#(32) a);
    if (s==SWriteRun) begin
        case (a)
            32'h8000:return 32'h9000;
            32'h8004:return 256;
            32'h8008:return 32'ha000;
            32'h800c:return 256;
            default:begin
                if (a>=32'h9000 && a<32'h9100) return 32'h6600_0000+(a-32'h9000);
                if (a>=32'ha000 && a<32'ha100) return 32'h7700_0000+(a-32'ha000);
                return 0;
            end
        endcase
    end
    else begin
        case (a)
            32'h8100:return 32'hb000;
            32'h8104:return 128;
            32'h8108:return 32'hc000;
            32'h810c:return 384;
            default:return 0;
        endcase
    end
endfunction

function Bit#(32) expectedRead(Bit#(32) a);
    Bit#(32) logicalWord=0;
    if (a>=32'hb000 && a<32'hb080) logicalWord=(a-32'hb000)>>2;
    else logicalWord=32+((a-32'hc000)>>2);
    if (logicalWord<64) return 32'h6600_0000+(logicalWord<<2);
    return 32'h7700_0000+((logicalWord-64)<<2);
endfunction

module mkTbQDXBSg(Empty);
    QDXBMediaIfc media <- mkQDXBFakeMedia;
    QDXBEndpointIfc ep <- mkQDXBEndpoint(media);
    Reg#(SgTestState) ts <- mkReg(SWrite);
    Reg#(Bool) hostActive <- mkReg(False);
    Reg#(DmaRequest) hostReq <- mkReg(DmaRequest {direction:HostToDevice,address:0,words:BurstOne});
    Reg#(Bit#(5)) hostMoved <- mkReg(0);
    Reg#(Bit#(16)) readWords <- mkReg(0);

    rule step;
        QdxAEndpointOut q=qdxAEndpointOutDefault();
        if (ts==SWrite) begin q.commandValid=True; q.command=mkSgCmd(OP_WRITE,32'h21,32'h8000); end
        if (ts==SRead) begin q.commandValid=True; q.command=mkSgCmd(OP_READ,32'h22,32'h8100); end
        if (ts==SWriteAck || ts==SReadAck) q.completionReady=True;

        QdxAEndpointIn e=ep.endpointDrive(q);
        QdxAProfileDmaIn p=ep.dmaDrive;
        QdxAProfileDmaOut d=qdxAProfileDmaOutDefault();

        if (!hostActive && p.requestValid) begin
            d.requestReady=True; hostActive<=True; hostReq<=p.request; hostMoved<=0;
        end
        else if (hostActive) begin
            Bit#(5) total=burstCount(hostReq.words);
            if (hostMoved<total) begin
                Bit#(32) a=hostReq.address+(zeroExtend(hostMoved)<<2);
                if (hostReq.direction==HostToDevice && p.readReady) begin
                    d.readValid=True; d.readWord=DmaWord {data:hostReadWord(ts,a)}; hostMoved<=hostMoved+1;
                end
                else if (hostReq.direction==DeviceToHost && p.writeValid) begin
                    Bit#(32) expect=expectedRead(a);
                    if (p.writeWord.data!=expect) begin $display("FAIL SG READ a=%08x expect=%08x got=%08x",a,expect,p.writeWord.data); $finish(1); end
                    d.writeReady=True; hostMoved<=hostMoved+1; readWords<=readWords+1;
                end
            end
            else if (p.completionReady) begin
                d.completionValid=True; d.completion=DmaCompletion {status:DmaOk,wordsCompleted:total}; hostActive<=False; hostMoved<=0;
            end
        end

        case (ts)
            SWrite:if (e.commandReady) ts<=SWriteRun;
            SWriteRun:if (e.completionValid) begin
                if (e.completion[1][15:0]!=ST_SUCCESS || e.completion[2]!=1) begin $display("FAIL SG WRITE completion"); $finish(1); end
                ts<=SWriteAck;
            end
            SWriteAck:ts<=SRead;
            SRead:if (e.commandReady) begin readWords<=0; ts<=SReadRun; end
            SReadRun:if (e.completionValid) begin
                if (e.completion[1][15:0]!=ST_SUCCESS || e.completion[2]!=1 || readWords!=128) begin $display("FAIL SG READ completion/word count"); $finish(1); end
                ts<=SReadAck;
            end
            SReadAck:ts<=SDone;
            default:noAction;
        endcase

        ep.advance(q,d);
    endrule

    rule done (ts==SDone);
        $display("QDXBTRACE|v1|case=sg|entries=2|write_words=128|read_words=128|status=0");
        $display("PASS QDX-B scatter/gather write/read across segment boundaries");
        $finish(0);
    endrule
endmodule

endpackage
