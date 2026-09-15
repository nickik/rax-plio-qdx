package QDXA;

import Vector::*;
import QLITypes::*;
import QICInterfaces::*;
import QDXAQicPort::*;
import QDXAEndpointIfc::*;

typedef enum {
    ADisabled,
    AReadyIdle,
    ASqRequest,
    ASqReceive,
    ASqCompletion,
    AEndpointOffer,
    AEndpointCompletion,
    ACqRequest,
    ACqSend,
    ACqCompletion,
    ANotify,
    AFault
} QdxAState deriving (Bits, Eq, FShow);

typedef enum {
    QdxErrNone,
    QdxErrBadConfig,
    QdxErrSqDma,
    QdxErrCqDma,
    QdxErrQueueProtocol,
    QdxErrEndpointProtocol
} QdxAError deriving (Bits, Eq, FShow);

Bit#(32) qdxCapValue = 32'h0032_4501;

Bit#(32) regQdxCap     = 32'h0000_1000;
Bit#(32) regQdxStatus  = 32'h0000_1004;
Bit#(32) regQdxControl = 32'h0000_1008;
Bit#(32) regSqBase     = 32'h0000_1010;
Bit#(32) regSqSize     = 32'h0000_1014;
Bit#(32) regSqTail     = 32'h0000_1018;
Bit#(32) regCqBase     = 32'h0000_1020;
Bit#(32) regCqSize     = 32'h0000_1024;
Bit#(32) regCqHead     = 32'h0000_1028;
Bit#(32) regSqHead     = 32'h0000_1030;
Bit#(32) regCqTail     = 32'h0000_1034;
Bit#(32) regQdxError   = 32'h0000_1038;

function Bit#(32) sqEntryAddress(Bit#(32) base, Bit#(16) position);
    Bit#(24) delta = zeroExtend(position[1:0]) << 5;
    Bit#(24) offset = base[23:0] + delta;
    return { base[31:24], offset };
endfunction

function Bit#(32) cqEntryAddress(Bit#(32) base, Bit#(16) position);
    Bit#(24) delta = zeroExtend(position[1:0]) << 4;
    Bit#(24) offset = base[23:0] + delta;
    return { base[31:24], offset };
endfunction

function Bool validConfiguration(Bit#(32) sqBase, Bit#(16) sqSize,
                                Bit#(32) cqBase, Bit#(16) cqSize);
    return sqSize == 4
        && cqSize == 4
        && sqBase[4:0] == 0
        && cqBase[3:0] == 0
        && sqBase[23:0] <= 24'hffff80
        && cqBase[23:0] <= 24'hffffc0;
endfunction

function Bool isReadyState(QdxAState s);
    return s != ADisabled && s != AFault;
endfunction

function Bit#(32) statusValue(QdxAState s);
    Bit#(32) value = 1;
    if (s == ADisabled) value = 0;
    else if (s == AFault) value = 2;
    return value;
endfunction

function Bit#(32) errorValue(QdxAError e);
    return zeroExtend(pack(e));
endfunction

interface QDXAIfc;
    method QdxAChipToQic qicPort(QdxAQicToChip qic);
    method QdxAEndpointOut endpointPort(QdxAQicToChip qic);
    method Action advance(QdxAQicToChip qic, QdxAEndpointIn endpoint);

    method QdxAState debugState;
    method QdxAError debugError;
    method Bit#(16) debugSqHead;
    method Bit#(16) debugSqTail;
    method Bit#(16) debugCqHead;
    method Bit#(16) debugCqTail;
endinterface

(* synthesize *)
module mkQDXA(QDXAIfc);
    Reg#(QdxAState) state <- mkReg(ADisabled);
    Reg#(QdxAError) errorReg <- mkReg(QdxErrNone);

    Reg#(Bool) enabled <- mkReg(False);
    Reg#(Bool) notifyEnable <- mkReg(False);

    Reg#(Bit#(32)) sqBase <- mkReg(0);
    Reg#(Bit#(16)) sqSize <- mkReg(0);
    Reg#(Bit#(16)) sqHead <- mkReg(0);
    Reg#(Bit#(16)) sqTail <- mkReg(0);

    Reg#(Bit#(32)) cqBase <- mkReg(0);
    Reg#(Bit#(16)) cqSize <- mkReg(0);
    Reg#(Bit#(16)) cqHead <- mkReg(0);
    Reg#(Bit#(16)) cqTail <- mkReg(0);

    Reg#(Bool) mmioResponsePending <- mkReg(False);
    Reg#(MmioResponse) mmioResponseReg <- mkReg(mmioError());

    Reg#(QdxACommand) commandBuffer <- mkReg(replicate(0));
    Reg#(QdxACompletion) completionBuffer <- mkReg(replicate(0));
    Reg#(Bit#(3)) sqWord <- mkReg(0);
    Reg#(Bit#(2)) cqWord <- mkReg(0);

    Reg#(Bool) endpointResetPulse <- mkReg(False);

    method QdxAChipToQic qicPort(QdxAQicToChip qic);
        QdxAChipToQic d = qdxAChipToQicDefault();

        d.mmioReady = !mmioResponsePending && !qic.reset;
        if (mmioResponsePending) begin
            d.mmioResponseValid = True;
            d.mmioResponse = mmioResponseReg;
        end

        case (state)
            ASqRequest: begin
                d.dmaRequestValid = True;
                d.dmaRequest = DmaRequest { direction: HostToDevice, address: sqEntryAddress(sqBase, sqHead), words: BurstEight };
            end
            ASqReceive: d.dmaReadReady = True;
            ASqCompletion: d.dmaCompletionReady = True;
            ACqRequest: begin
                d.dmaRequestValid = True;
                d.dmaRequest = DmaRequest { direction: DeviceToHost, address: cqEntryAddress(cqBase, cqTail), words: BurstFour };
            end
            ACqSend: begin
                d.dmaWriteValid = True;
                d.dmaWrite = DmaWord { data: completionBuffer[cqWord] };
            end
            ACqCompletion: d.dmaCompletionReady = True;
            ANotify: begin
                d.notificationValid = True;
                d.notification = NotificationRequest { channel: 0 };
            end
            default: begin end
        endcase
        return d;
    endmethod

    method QdxAEndpointOut endpointPort(QdxAQicToChip qic);
        QdxAEndpointOut e = qdxAEndpointOutDefault();
        e.reset = qic.reset || endpointResetPulse;
        if (state == AEndpointOffer) begin e.commandValid = True; e.command = commandBuffer; end
        if (state == AEndpointCompletion) begin
            Bit#(16) used = cqTail - cqHead;
            e.completionReady = used < 4;
        end
        return e;
    endmethod

    method Action advance(QdxAQicToChip qic, QdxAEndpointIn endpoint);
        action
            Bool canAcceptMmio = !mmioResponsePending && !qic.reset;
            Bool acceptsMmio = canAcceptMmio && qic.mmioRequestValid;
            MmioRequest req = qic.mmioRequest;
            Bool softReset = acceptsMmio && req.write && req.address == regQdxControl && req.byteEnable == 4'hf && req.writeData[1] == 1'b1;

            if (qic.reset) begin
                state <= ADisabled; errorReg <= QdxErrNone; enabled <= False; notifyEnable <= False;
                sqBase <= 0; sqSize <= 0; sqHead <= 0; sqTail <= 0;
                cqBase <= 0; cqSize <= 0; cqHead <= 0; cqTail <= 0;
                mmioResponsePending <= False; commandBuffer <= replicate(0); completionBuffer <= replicate(0);
                sqWord <= 0; cqWord <= 0; endpointResetPulse <= True;
            end
            else if (softReset) begin
                state <= ADisabled; errorReg <= QdxErrNone; enabled <= False; notifyEnable <= False;
                sqBase <= 0; sqSize <= 0; sqHead <= 0; sqTail <= 0;
                cqBase <= 0; cqSize <= 0; cqHead <= 0; cqTail <= 0;
                commandBuffer <= replicate(0); completionBuffer <= replicate(0); sqWord <= 0; cqWord <= 0;
                endpointResetPulse <= True; mmioResponseReg <= mmioWriteOk(); mmioResponsePending <= True;
            end
            else begin
                endpointResetPulse <= False;

                if (mmioResponsePending) begin
                    if (qic.mmioResponseReady || qic.mmioCancel)
                        mmioResponsePending <= False;
                end
                else if (acceptsMmio) begin
                    MmioResponse resp = mmioError();
                    Bool legal = False;
                    if (!req.write) begin
                        case (req.address)
                            regQdxCap: begin legal=req.byteEnable==4'hf; if (legal) resp=mmioReadOk(qdxCapValue); end
                            regQdxStatus: begin legal=req.byteEnable==4'hf; if (legal) resp=mmioReadOk(statusValue(state)); end
                            regQdxControl: begin legal=req.byteEnable==4'hf; if (legal) resp=mmioReadOk({29'b0,pack(notifyEnable),1'b0,pack(enabled)}); end
                            regSqBase: begin legal=req.byteEnable==4'hf; if (legal) resp=mmioReadOk(sqBase); end
                            regSqSize: begin legal=req.byteEnable==4'h3; if (legal) resp=mmioReadOk(zeroExtend(sqSize)); end
                            regSqTail: begin legal=req.byteEnable==4'h3; if (legal) resp=mmioReadOk(zeroExtend(sqTail)); end
                            regCqBase: begin legal=req.byteEnable==4'hf; if (legal) resp=mmioReadOk(cqBase); end
                            regCqSize: begin legal=req.byteEnable==4'h3; if (legal) resp=mmioReadOk(zeroExtend(cqSize)); end
                            regCqHead: begin legal=req.byteEnable==4'h3; if (legal) resp=mmioReadOk(zeroExtend(cqHead)); end
                            regSqHead: begin legal=req.byteEnable==4'h3; if (legal) resp=mmioReadOk(zeroExtend(sqHead)); end
                            regCqTail: begin legal=req.byteEnable==4'h3; if (legal) resp=mmioReadOk(zeroExtend(cqTail)); end
                            regQdxError: begin legal=req.byteEnable==4'hf; if (legal) resp=mmioReadOk(errorValue(errorReg)); end
                            default: begin end
                        endcase
                    end
                    else begin
                        case (req.address)
                            regQdxControl: begin
                                legal = req.byteEnable==4'hf && state==ADisabled;
                                if (legal) begin
                                    notifyEnable <= req.writeData[2]==1'b1;
                                    if (req.writeData[0]==1'b1) begin
                                        if (validConfiguration(sqBase,sqSize,cqBase,cqSize)) begin enabled<=True; errorReg<=QdxErrNone; state<=AReadyIdle; end
                                        else begin enabled<=True; errorReg<=QdxErrBadConfig; state<=AFault; end
                                    end else enabled<=False;
                                    resp=mmioWriteOk();
                                end
                            end
                            regSqBase: begin legal=req.byteEnable==4'hf && state==ADisabled; if (legal) begin sqBase<=req.writeData; resp=mmioWriteOk(); end end
                            regSqSize: begin legal=req.byteEnable==4'h3 && state==ADisabled; if (legal) begin sqSize<=req.writeData[15:0]; resp=mmioWriteOk(); end end
                            regCqBase: begin legal=req.byteEnable==4'hf && state==ADisabled; if (legal) begin cqBase<=req.writeData; resp=mmioWriteOk(); end end
                            regCqSize: begin legal=req.byteEnable==4'h3 && state==ADisabled; if (legal) begin cqSize<=req.writeData[15:0]; resp=mmioWriteOk(); end end
                            regSqTail: begin
                                legal=req.byteEnable==4'h3 && isReadyState(state);
                                if (legal) begin
                                    Bit#(16) newTail=req.writeData[15:0]; Bit#(16) occupancy=newTail-sqHead;
                                    if (occupancy<=4) begin sqTail<=newTail; resp=mmioWriteOk(); end
                                    else begin legal=False; errorReg<=QdxErrQueueProtocol; state<=AFault; end
                                end
                            end
                            regCqHead: begin
                                legal=req.byteEnable==4'h3 && isReadyState(state);
                                if (legal) begin
                                    Bit#(16) newHead=req.writeData[15:0]; Bit#(16) used=cqTail-cqHead; Bit#(16) consumed=newHead-cqHead;
                                    if (consumed<=used) begin cqHead<=newHead; resp=mmioWriteOk(); end
                                    else begin legal=False; errorReg<=QdxErrQueueProtocol; state<=AFault; end
                                end
                            end
                            default: begin end
                        endcase
                    end
                    mmioResponseReg <= legal ? resp : mmioError();
                    mmioResponsePending <= True;
                end
                else begin
                    case (state)
                        ADisabled: begin end
                        AReadyIdle: begin
                            Bit#(16) cqUsed=cqTail-cqHead;
                            if (sqHead!=sqTail && cqUsed<4) begin sqWord<=0; state<=ASqRequest; end
                        end
                        ASqRequest: if (qic.dmaRequestReady) begin sqWord<=0; state<=ASqReceive; end
                        ASqReceive: if (qic.dmaReadValid) begin
                            QdxACommand next=commandBuffer; next[sqWord]=qic.dmaRead.data; commandBuffer<=next;
                            if (sqWord==7) state<=ASqCompletion; else sqWord<=sqWord+1;
                        end
                        ASqCompletion: if (qic.dmaCompletionValid) begin
                            if (qic.dmaCompletion.status==DmaOk && qic.dmaCompletion.wordsCompleted==8) begin sqHead<=sqHead+1; state<=AEndpointOffer; end
                            else begin errorReg<=QdxErrSqDma; state<=AFault; end
                        end
                        AEndpointOffer: if (endpoint.commandReady) state<=AEndpointCompletion;
                        AEndpointCompletion: begin
                            Bit#(16) cqUsed=cqTail-cqHead;
                            if (endpoint.completionValid && cqUsed<4) begin completionBuffer<=endpoint.completion; cqWord<=0; state<=ACqRequest; end
                        end
                        ACqRequest: if (qic.dmaRequestReady) begin cqWord<=0; state<=ACqSend; end
                        ACqSend: if (qic.dmaWriteReady) begin if (cqWord==3) state<=ACqCompletion; else cqWord<=cqWord+1; end
                        ACqCompletion: if (qic.dmaCompletionValid) begin
                            if (qic.dmaCompletion.status==DmaOk && qic.dmaCompletion.wordsCompleted==4) begin
                                Bool wasEmpty=cqTail==cqHead; cqTail<=cqTail+1;
                                if (wasEmpty && notifyEnable) state<=ANotify; else state<=AReadyIdle;
                            end else begin errorReg<=QdxErrCqDma; state<=AFault; end
                        end
                        ANotify: if (qic.notificationReady) state<=AReadyIdle;
                        AFault: begin end
                    endcase
                end
            end
        endaction
    endmethod

    method QdxAState debugState = state;
    method QdxAError debugError = errorReg;
    method Bit#(16) debugSqHead = sqHead;
    method Bit#(16) debugSqTail = sqTail;
    method Bit#(16) debugCqHead = cqHead;
    method Bit#(16) debugCqTail = cqTail;
endmodule

endpackage