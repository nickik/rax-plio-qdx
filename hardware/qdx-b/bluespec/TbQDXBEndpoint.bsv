package TbQDXBEndpoint;

import Vector::*;
import QLITypes::*;
import QDXAEndpointIfc::*;
import QDXAProfileDma::*;
import QDXBFakeMedia::*;
import QDXBEndpoint::*;

typedef enum { TWrite, TWriteRun, TWriteAck, TRead, TReadRun, TReadAck, TIdentify, TIdentifyRun, TIdentifyAck, TDurable, TDurableRun, TDurableAck, TFlush, TFlushRun, TFlushAck, TDone } TestState deriving (Bits,Eq,FShow);

function QdxACommand mkCmd(Bit#(8) op, Bit#(16) ns, Bit#(32) tag, Bit#(32) lba, Bit#(16) count, Bit#(32) data);
    QdxACommand c=replicate(0);
    c[0]={ns,8'h00,op}; c[1]=tag; c[2]=lba; c[3]=zeroExtend(count); c[4]=data;
    return c;
endfunction

function Bit#(32) writePattern(Bit#(32) address);
    return 32'hd000_0000 + (address-32'h0000_3000);
endfunction

module mkTbQDXBEndpoint(Empty);
    QDXBMediaIfc media <- mkQDXBFakeMedia;
    QDXBEndpointIfc ep <- mkQDXBEndpoint(media);
    Reg#(TestState) ts <- mkReg(TWrite);
    Reg#(Bool) hostActive <- mkReg(False);
    Reg#(DmaRequest) hostReq <- mkReg(DmaRequest {direction:HostToDevice,address:0,words:BurstOne});
    Reg#(Bit#(5)) hostMoved <- mkReg(0);

    rule step;
        QdxAEndpointOut q=qdxAEndpointOutDefault();
        case (ts)
            TWrite:q.commandValid=True;
            TRead:q.commandValid=True;
            TIdentify:q.commandValid=True;
            TDurable:q.commandValid=True;
            TFlush:q.commandValid=True;
            TWriteAck,TReadAck,TIdentifyAck,TDurableAck,TFlushAck:q.completionReady=True;
            default:noAction;
        endcase
        case (ts)
            TWrite:q.command=mkCmd(8'h11,1,32'h11,3,1,32'h3000);
            TRead:q.command=mkCmd(8'h10,1,32'h12,3,1,32'h5000);
            TIdentify:q.command=mkCmd(8'h01,0,32'h13,0,0,32'h6000);
            TDurable:q.command=mkCmd(8'h14,1,32'h14,4,1,32'h3000);
            TFlush:q.command=mkCmd(8'h12,1,32'h15,0,0,0);
            default:noAction;
        endcase

        QdxAEndpointIn e=ep.endpointDrive(q);
        QdxAProfileDmaIn p=ep.dmaDrive;
        QdxAProfileDmaOut d=qdxAProfileDmaOutDefault();

        if (!hostActive && p.requestValid) begin
            d.requestReady=True; hostActive<=True; hostReq<=p.request; hostMoved<=0;
        end
        else if (hostActive) begin
            Bit#(5) total=burstCount(hostReq.words);
            if (hostMoved<total) begin
                if (hostReq.direction==HostToDevice && p.readReady) begin
                    Bit#(32) a=hostReq.address+(zeroExtend(hostMoved)<<2);
                    d.readValid=True; d.readWord=DmaWord {data:writePattern(a)};
                    hostMoved<=hostMoved+1;
                end
                else if (hostReq.direction==DeviceToHost && p.writeValid) begin
                    Bit#(32) a=hostReq.address+(zeroExtend(hostMoved)<<2);
                    if (ts==TReadRun && p.writeWord.data!=32'hd000_0000+(a-32'h5000)) begin
                        $display("FAIL QDX-B readback a=%08x data=%08x",a,p.writeWord.data); $finish(1);
                    end
                    if (ts==TIdentifyRun) begin
                        if (a==32'h6000 && p.writeWord.data!=32'h0002_0005) begin $display("FAIL identify word0"); $finish(1); end
                        if (a==32'h6004 && p.writeWord.data!=32'h0000_0010) begin $display("FAIL identify max SG"); $finish(1); end
                        if (a==32'h6008 && p.writeWord.data!=1) begin $display("FAIL identify max transfer"); $finish(1); end
                    end
                    d.writeReady=True; hostMoved<=hostMoved+1;
                end
            end
            else if (p.completionReady) begin
                d.completionValid=True; d.completion=DmaCompletion {status:DmaOk,wordsCompleted:total};
                hostActive<=False; hostMoved<=0;
            end
        end

        case (ts)
            TWrite:if (e.commandReady) ts<=TWriteRun;
            TWriteRun:if (e.completionValid) begin
                if (e.completion[0]!=32'h11 || e.completion[1][15:0]!=stSuccess || e.completion[2]!=1) begin $display("FAIL WRITE completion"); $finish(1); end
                ts<=TWriteAck;
            end
            TWriteAck:ts<=TRead;
            TRead:if (e.commandReady) ts<=TReadRun;
            TReadRun:if (e.completionValid) begin if (e.completion[1][15:0]!=stSuccess || e.completion[2]!=1) begin $display("FAIL READ completion"); $finish(1); end ts<=TReadAck; end
            TReadAck:ts<=TIdentify;
            TIdentify:if (e.commandReady) ts<=TIdentifyRun;
            TIdentifyRun:if (e.completionValid) begin if (e.completion[1][15:0]!=stSuccess) begin $display("FAIL IDENTIFY completion"); $finish(1); end ts<=TIdentifyAck; end
            TIdentifyAck:ts<=TDurable;
            TDurable:if (e.commandReady) ts<=TDurableRun;
            TDurableRun:if (e.completionValid) begin
                if (e.completion[1][15:0]!=stSuccess || e.completion[1][19]!=1) begin $display("FAIL WRITE_DURABLE completion"); $finish(1); end
                ts<=TDurableAck;
            end
            TDurableAck:ts<=TFlush;
            TFlush:if (e.commandReady) ts<=TFlushRun;
            TFlushRun:if (e.completionValid) begin if (e.completion[1][15:0]!=stSuccess) begin $display("FAIL FLUSH"); $finish(1); end ts<=TFlushAck; end
            TFlushAck:begin if (ep.debugFlushCount!=1) begin $display("FAIL flush count"); $finish(1); end ts<=TDone; end
            default:noAction;
        endcase

        ep.advance(q,d);
    endrule

    rule done (ts==TDone);
        $display("QDXBTRACE|v1|case=direct|write=1|read=1|identify=1|durable=1|flush=1");
        $display("PASS QDX-B mandatory direct-buffer profile operations");
        $finish(0);
    endrule
endmodule

endpackage
