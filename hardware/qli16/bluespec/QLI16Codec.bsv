package QLI16Codec;

import QLITypes::*;
import QICInterfaces::*;
import QLI16Encoding::*;

typedef enum {
    QTxNone, QTxMmioRead, QTxMmioWrite, QTxCancel,
    QTxDmaRead, QTxDmaCompletion, QTxNotificationCompletion
} QTxKind deriving (Bits, Eq, FShow);

typedef enum {
    DTxNone, DTxMmioReadResponse, DTxMmioSimpleResponse,
    DTxDmaRequest, DTxDmaWrite, DTxNotificationRequest
} DTxKind deriving (Bits, Eq, FShow);

typedef struct {
    Bool valid;
    Bool ack;
    Qli16Token token;
} Qli16Slot deriving (Bits, Eq, FShow);

function Qli16Slot idleSlot();
    return Qli16Slot { valid: False, ack: False, token: q16Token(0, Q16Idle, 0) };
endfunction

function Qli16Token notificationCompletionToken(NotificationRequest req);
    return q16Token(0, Q16Notification, { 14'b0, req.channel[1:0] });
endfunction

interface QLI16CodecIfc;
    method Action load(QliOut qic, QliIn device);
    method Qli16Slot currentSlot;
    method Action step;
    method QliIn toQic;
    method QliOut toDevice;
    method Bool cycleComplete;
    method Bool protocolFault;
    method Action injectRaw(Qli16Token token);
    method Action resetCodec;
endinterface

module mkQLI16Codec(QLI16CodecIfc);
    Reg#(QliOut) qicReg <- mkReg(qliOutDefault());
    Reg#(QliIn) devReg <- mkReg(qliInDefault());
    Reg#(QliIn) toQicReg <- mkReg(qliInDefault());
    Reg#(QliOut) toDevReg <- mkReg(qliOutDefault());
    Reg#(Bool) loaded <- mkReg(False);
    Reg#(Bit#(2)) slotsLeft <- mkReg(0);

    Reg#(QTxKind) qKind <- mkReg(QTxNone);
    Reg#(Bit#(3)) qIndex <- mkReg(0);
    Reg#(MmioRequest) qMmio <- mkReg(MmioRequest { address:0, write:False, byteEnable:0, writeData:0 });
    Reg#(DmaWord) qWord <- mkReg(DmaWord { data:0 });
    Reg#(DmaCompletion) qCompletion <- mkReg(DmaCompletion { status:DmaOk, wordsCompleted:0 });
    Reg#(NotificationRequest) qNotification <- mkReg(NotificationRequest { channel:0 });

    Reg#(DTxKind) dKind <- mkReg(DTxNone);
    Reg#(Bit#(3)) dIndex <- mkReg(0);
    Reg#(MmioResponse) dResponse <- mkReg(mmioError());
    Reg#(DmaRequest) dRequest <- mkReg(DmaRequest { direction:HostToDevice, address:0, words:BurstOne });
    Reg#(DmaWord) dWord <- mkReg(DmaWord { data:0 });
    Reg#(NotificationRequest) dNotification <- mkReg(NotificationRequest { channel:0 });

    Reg#(Bool) lastDirValid <- mkReg(False);
    Reg#(Bit#(1)) lastDir <- mkReg(0);
    Reg#(Bool) notificationHeldValid <- mkReg(False);
    Reg#(NotificationRequest) notificationHeld <- mkReg(NotificationRequest { channel:0 });
    Reg#(Bool) notificationCompletionPending <- mkReg(False);
    Reg#(NotificationRequest) notificationCompletion <- mkReg(NotificationRequest { channel:0 });
    Reg#(Bool) fault <- mkReg(False);

    function Bit#(3) qLength(QTxKind k);
        Bit#(3) result = 0;
        case (k)
            QTxMmioRead: result = 2;
            QTxMmioWrite: result = 4;
            QTxCancel: result = 1;
            QTxDmaRead: result = 2;
            QTxDmaCompletion: result = 1;
            QTxNotificationCompletion: result = 1;
            default: result = 0;
        endcase
        return result;
    endfunction

    function Bit#(3) dLength(DTxKind k);
        Bit#(3) result = 0;
        case (k)
            DTxMmioReadResponse: result = 3;
            DTxMmioSimpleResponse: result = 1;
            DTxDmaRequest: result = 3;
            DTxDmaWrite: result = 2;
            DTxNotificationRequest: result = 1;
            default: result = 0;
        endcase
        return result;
    endfunction

    function Qli16Token qToken(QTxKind k, Bit#(3) i);
        Qli16Token t = q16Token(0, Q16Idle, 0);
        case (k)
            QTxMmioRead: t = (i==0) ? mmioHeader0(qMmio) : mmioHeader1(qMmio);
            QTxMmioWrite: begin
                case (i)
                    0: t=mmioHeader0(qMmio); 1: t=mmioHeader1(qMmio);
                    2: t=mmioDataLo(0,qMmio.writeData); default: t=mmioDataHi(0,qMmio.writeData);
                endcase
            end
            QTxCancel: t=mmioCancelToken();
            QTxDmaRead: t=(i==0) ? dmaDataLo(0,qWord) : dmaDataHi(0,qWord);
            QTxDmaCompletion: t=dmaCompletionToken(qCompletion);
            QTxNotificationCompletion: t=notificationCompletionToken(qNotification);
            default: begin end
        endcase
        return t;
    endfunction

    function Qli16Token dToken(DTxKind k, Bit#(3) i);
        Qli16Token t = q16Token(1, Q16Idle, 0);
        case (k)
            DTxMmioReadResponse: begin
                case (i)
                    0: t=mmioResponseStatus(dResponse); 1: t=mmioDataLo(1,dResponse.data);
                    default: t=mmioDataHi(1,dResponse.data);
                endcase
            end
            DTxMmioSimpleResponse: t=mmioResponseStatus(dResponse);
            DTxDmaRequest: begin
                case (i)
                    0: t=dmaHeader0(dRequest); 1: t=dmaHeader1(dRequest); default: t=dmaHeader2(dRequest);
                endcase
            end
            DTxDmaWrite: t=(i==0) ? dmaDataLo(1,dWord) : dmaDataHi(1,dWord);
            DTxNotificationRequest: t=notificationToken(dNotification);
            default: begin end
        endcase
        return t;
    endfunction

    function Bool qFinalReady(QTxKind k);
        Bool result = False;
        case (k)
            QTxMmioRead, QTxMmioWrite: result = devReg.mmioReady;
            QTxCancel: result = True;
            QTxDmaRead: result = devReg.dmaReadReady;
            QTxDmaCompletion: result = devReg.dmaCompletionReady;
            QTxNotificationCompletion: result = True;
            default: result = False;
        endcase
        return result;
    endfunction

    function Bool dFinalReady(DTxKind k);
        Bool result = False;
        case (k)
            DTxMmioReadResponse, DTxMmioSimpleResponse: result = qicReg.mmioResponseReady;
            DTxDmaRequest: result = qicReg.dmaRequestReady;
            DTxDmaWrite: result = qicReg.dmaWriteReady;
            DTxNotificationRequest: result = True;
            default: result = False;
        endcase
        return result;
    endfunction

    function Tuple2#(Bool,Bit#(1)) desiredDirection();
        Bool qActive = qKind != QTxNone;
        Bool dActive = dKind != DTxNone;
        Tuple2#(Bool,Bit#(1)) result = tuple2(False,0);
        if (lastDirValid && lastDir==0 && qActive) result = tuple2(True,0);
        else if (lastDirValid && lastDir==1 && dActive) result = tuple2(True,1);
        else if (qActive) result = tuple2(True,0);
        else if (dActive) result = tuple2(True,1);
        return result;
    endfunction

    method Action load(QliOut qic, QliIn device) if (!loaded);
        action
            qicReg <= qic; devReg <= device;
            QliIn qi = qliInDefault(); QliOut qo = qliOutDefault();
            if (notificationHeldValid) begin qi.notificationValid=True; qi.notification=notificationHeld; end
            if (qic.notificationReady && notificationHeldValid) begin
                notificationHeldValid<=False; notificationCompletionPending<=True;
                notificationCompletion<=notificationHeld; qi.notificationValid=False;
            end
            if (qKind==QTxNone) begin
                if (qic.mmioCancel) begin qKind<=QTxCancel; qIndex<=0; end
                else if (qic.mmioRequestValid) begin qMmio<=qic.mmioRequest; qKind<=qic.mmioRequest.write ? QTxMmioWrite : QTxMmioRead; qIndex<=0; end
                else if (qic.dmaReadValid) begin qWord<=qic.dmaRead; qKind<=QTxDmaRead; qIndex<=0; end
                else if (qic.dmaCompletionValid) begin qCompletion<=qic.dmaCompletion; qKind<=QTxDmaCompletion; qIndex<=0; end
                else if (notificationCompletionPending) begin qNotification<=notificationCompletion; qKind<=QTxNotificationCompletion; qIndex<=0; end
                else if (qic.notificationReady && notificationHeldValid) begin qNotification<=notificationHeld; qKind<=QTxNotificationCompletion; qIndex<=0; end
            end
            if (dKind==DTxNone) begin
                if (device.mmioResponseValid) begin
                    dResponse<=device.mmioResponse;
                    dKind <= (device.mmioResponse.status==MmioReadOk) ? DTxMmioReadResponse : DTxMmioSimpleResponse; dIndex<=0;
                end
                else if (device.dmaRequestValid) begin dRequest<=device.dmaRequest; dKind<=DTxDmaRequest; dIndex<=0; end
                else if (device.dmaWriteValid) begin dWord<=device.dmaWrite; dKind<=DTxDmaWrite; dIndex<=0; end
                else if (device.notificationValid && !notificationHeldValid && !notificationCompletionPending) begin dNotification<=device.notification; dKind<=DTxNotificationRequest; dIndex<=0; end
            end
            toQicReg<=qi; toDevReg<=qo; slotsLeft<=2; loaded<=True;
        endaction
    endmethod

    method Qli16Slot currentSlot if (loaded);
        match {.hasDir,.dir} = desiredDirection();
        Qli16Slot result = idleSlot();
        if (hasDir && !(lastDirValid && lastDir!=dir)) begin
            if (dir==0) begin
                Bit#(3) len=qLength(qKind); Bool finalToken=(qIndex+1)==len;
                result=Qli16Slot { valid:True, ack:(!finalToken || qFinalReady(qKind)), token:qToken(qKind,qIndex) };
            end
            else begin
                Bit#(3) len=dLength(dKind); Bool finalToken=(dIndex+1)==len;
                result=Qli16Slot { valid:True, ack:(!finalToken || dFinalReady(dKind)), token:dToken(dKind,dIndex) };
            end
        end
        return result;
    endmethod

    method Action step if (loaded);
        action
            match {.hasDir,.dir}=desiredDirection();
            Bool turnaround=hasDir && lastDirValid && lastDir!=dir;
            if (!hasDir) lastDirValid<=False;
            else if (turnaround) lastDirValid<=False;
            else if (dir==0) begin
                lastDirValid<=True; lastDir<=0;
                Bit#(3) len=qLength(qKind); Bool finalToken=(qIndex+1)==len; Bool ack=!finalToken || qFinalReady(qKind);
                if (ack) begin
                    if (!finalToken) qIndex<=qIndex+1;
                    else begin
                        QliIn qi=toQicReg; QliOut qo=toDevReg;
                        case (qKind)
                            QTxMmioRead, QTxMmioWrite: begin qo.mmioRequestValid=True; qo.mmioRequest=qMmio; qi.mmioReady=True; end
                            QTxCancel: qo.mmioCancel=True;
                            QTxDmaRead: begin qo.dmaReadValid=True; qo.dmaRead=qWord; qi.dmaReadReady=True; end
                            QTxDmaCompletion: begin qo.dmaCompletionValid=True; qo.dmaCompletion=qCompletion; qi.dmaCompletionReady=True; end
                            QTxNotificationCompletion: begin qo.notificationReady=True; notificationCompletionPending<=False; end
                            default: noAction;
                        endcase
                        toQicReg<=qi; toDevReg<=qo; qKind<=QTxNone; qIndex<=0;
                    end
                end
            end
            else begin
                lastDirValid<=True; lastDir<=1;
                Bit#(3) len=dLength(dKind); Bool finalToken=(dIndex+1)==len; Bool ack=!finalToken || dFinalReady(dKind);
                if (ack) begin
                    if (!finalToken) dIndex<=dIndex+1;
                    else begin
                        QliIn qi=toQicReg; QliOut qo=toDevReg;
                        case (dKind)
                            DTxMmioReadResponse, DTxMmioSimpleResponse: begin qi.mmioResponseValid=True; qi.mmioResponse=dResponse; qo.mmioResponseReady=True; end
                            DTxDmaRequest: begin qi.dmaRequestValid=True; qi.dmaRequest=dRequest; qo.dmaRequestReady=True; end
                            DTxDmaWrite: begin qi.dmaWriteValid=True; qi.dmaWrite=dWord; qo.dmaWriteReady=True; end
                            DTxNotificationRequest: begin notificationHeld<=dNotification; notificationHeldValid<=True; qi.notificationValid=True; qi.notification=dNotification; end
                            default: noAction;
                        endcase
                        toQicReg<=qi; toDevReg<=qo; dKind<=DTxNone; dIndex<=0;
                    end
                end
            end
            if (slotsLeft==1) begin slotsLeft<=0; loaded<=False; end else slotsLeft<=slotsLeft-1;
        endaction
    endmethod

    method QliIn toQic=toQicReg;
    method QliOut toDevice=toDevReg;
    method Bool cycleComplete=!loaded;
    method Bool protocolFault=fault;

    method Action injectRaw(Qli16Token token);
        action
            Bool malformed=False;
            case (token.kind)
                Q16Idle: malformed=token.payload!=0;
                Q16MmioResponse: begin if (token.direction==0) malformed=token.payload!=0; else malformed=(token.payload[15:2]!=0 || token.payload[1:0]==3); end
                Q16DmaHeader: malformed=token.direction!=1;
                Q16DmaCompletion: malformed=(token.direction!=0 || token.payload[15:8]!=0 || token.payload[2:0]>4);
                Q16Notification: malformed=token.payload[15:2]!=0;
                default: noAction;
            endcase
            if (malformed) fault<=True;
        endaction
    endmethod

    method Action resetCodec;
        action
            loaded<=False; slotsLeft<=0; qKind<=QTxNone; dKind<=DTxNone; qIndex<=0; dIndex<=0; lastDirValid<=False;
            notificationHeldValid<=False; notificationCompletionPending<=False;
            toQicReg<=qliInDefault(); toDevReg<=qliOutDefault(); fault<=False;
        endaction
    endmethod
endmodule

endpackage
