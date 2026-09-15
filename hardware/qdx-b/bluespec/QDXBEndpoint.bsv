package QDXBEndpoint;

import Vector::*;
import RegFile::*;
import QLITypes::*;
import QDXAEndpointIfc::*;
import QDXAProfileDma::*;
import QDXBFakeMedia::*;

typedef struct { Bit#(8) opcode; Bit#(8) flags; Bit#(16) namespaceId; Bit#(32) tag; Bit#(32) lba; Bit#(16) blockCount; Bit#(8) sgCount; Bit#(8) reserved0; Bit#(32) dataAddr; Bit#(32) sgAddr; Bit#(32) commandArg; Bit#(32) reserved1; } QdxBCommand deriving (Bits, Eq, FShow);
typedef struct { Bit#(32) address; Bit#(32) lengthBytes; } QdxBSgEntry deriving (Bits, Eq, FShow);
typedef enum { BIdle, BFetchSg, BTransfer, BMediaCommit, BComplete } QdxBState deriving (Bits, Eq, FShow);
typedef enum { BDmaIdle, BDmaRequest, BDmaTransfer, BDmaCompletion } QdxBDmaPhase deriving (Bits, Eq, FShow);
typedef enum { BDmaNone, BDmaSgAddress, BDmaSgLength, BDmaPayload } QdxBDmaKind deriving (Bits, Eq, FShow);
typedef enum { BOpNone, BOpIdentifyController, BOpIdentifyNamespace, BOpHealth, BOpRead, BOpWrite, BOpWriteDurable } QdxBOpKind deriving (Bits, Eq, FShow);

Bit#(8) opNop=8'h00;
Bit#(8) opFlush=8'h12;
Bit#(16) stSuccess=16'h0000;
Bit#(16) stInvalidOpcode=16'h0001;
Bit#(16) stInvalidNamespace=16'h0002;
Bit#(16) stInvalidField=16'h0003;
Bit#(16) stLbaRange=16'h0004;
Bit#(16) stDmaFault=16'h0005;
Bit#(16) cfWriteDurableDone=16'h0008;

function QdxBCommand decodeCommand(QdxACommand c);
 return QdxBCommand { opcode:c[0][7:0], flags:c[0][15:8], namespaceId:c[0][31:16], tag:c[1], lba:c[2], blockCount:c[3][15:0], sgCount:c[3][23:16], reserved0:c[3][31:24], dataAddr:c[4], sgAddr:c[5], commandArg:c[6], reserved1:c[7] };
endfunction
function Bool validNs(Bit#(16) ns); return ns==1 || ns==2; endfunction
function Bit#(16) blockWords(Bit#(16) ns); return (ns==1) ? 128 : ((ns==2) ? 256 : 0); endfunction
function Bool handleRangeOk(Bit#(32) h, Bit#(32) bytes); Bit#(32) off=zeroExtend(h[23:0]); return h[1:0]==0 && bytes!=0 && bytes<=32'h0100_0000 && off<=32'h0100_0000-bytes; endfunction
function Bit#(32) handleAdd(Bit#(32) h, Bit#(32) delta); Bit#(24) off=h[23:0]+truncate(delta); return {h[31:24],off}; endfunction
function Bool bufferHeaderValid(QdxBCommand c, Bit#(32) bytes); Bool ok=False; if (c.sgCount==0) ok=handleRangeOk(c.dataAddr,bytes); else begin Bit#(32) listBytes=zeroExtend(c.sgCount)<<3; ok=c.sgCount<=16 && handleRangeOk(c.sgAddr,listBytes); end return ok; endfunction
function BurstWords chooseBurst(Bit#(16) words); BurstWords b=BurstOne; if (words>=16) b=BurstSixteen; else if (words>=8) b=BurstEight; else if (words>=4) b=BurstFour; return b; endfunction
function Bit#(5) burstCount(BurstWords b); case (b) BurstOne:return 1; BurstFour:return 4; BurstEight:return 8; default:return 16; endcase endfunction
function QdxACompletion makeCompletion(QdxBCommand c, Bit#(16) status, Bit#(16) flags, Bit#(32) blocksDone); QdxACompletion x=replicate(0); x[0]=c.tag; x[1]={flags,status}; x[2]=blocksDone; x[3]=0; return x; endfunction
function Bit#(32) identifyControllerWord(Bit#(8) i); case (i) 0:return 32'h0002_0005; 1:return 32'h0000_0010; 2:return 1; 3:return 0; 4:return 32'h20434544; 5:return 32'h2d584451; 6:return 32'h41422042; 7:return 32'h20204553; 8:return 32'h304d4953; 9:return 32'h30303030; 10:return 32'h30303030; 11:return 32'h31303030; default:return 0; endcase endfunction
function Bit#(32) identifyNamespaceWord(Bit#(16) ns, Bit#(8) i); case (i) 0:return zeroExtend(ns); 1:return ns==1 ? 512 : 1024; 2:return 64; 3:return ns==1 ? 512 : 1024; 4:return 32'h454b4146; 5:return ns==1 ? 32'h3231352d : 32'h3230312d; 6:return ns==1 ? 32'h20202020 : 32'h20202034; 7:return 32'h20202020; 8:return 32'h3030534e; 9:return 32'h30303030; 10:return 32'h30303030; 11:return ns==1 ? 32'h31303030 : 32'h32303030; default:return 0; endcase endfunction
function Bit#(32) selectPayloadWord(QdxBOpKind op, QdxBCommand c, Bit#(16) index, Bit#(32) mediaWord, Bit#(32) stagedWord); Bit#(8) i=truncate(index); case (op) BOpIdentifyController:return identifyControllerWord(i); BOpIdentifyNamespace:return identifyNamespaceWord(c.namespaceId,i); BOpHealth:return i==0 ? 1 : 0; BOpRead:return mediaWord; default:return stagedWord; endcase endfunction
function Bool sgValid(Vector#(16,QdxBSgEntry) v, QdxBCommand c, QdxBOpKind op); Bit#(32) total=0; Bool ok=True; for (Integer i=0;i<16;i=i+1) begin if (fromInteger(i)<c.sgCount) begin QdxBSgEntry e=v[i]; if (e.lengthBytes==0 || e.lengthBytes[1:0]!=0 || !handleRangeOk(e.address,e.lengthBytes)) ok=False; total=total+e.lengthBytes; end end Bit#(32) need=(op==BOpIdentifyController || op==BOpIdentifyNamespace || op==BOpHealth) ? 64 : (zeroExtend(blockWords(c.namespaceId))<<2); return ok && total>=need; endfunction

interface QDXBEndpointIfc;
 method QdxAEndpointIn endpointDrive(QdxAEndpointOut qdx);
 method QdxAProfileDmaIn dmaDrive;
 method Action advance(QdxAEndpointOut qdx, QdxAProfileDmaOut dma);
 method QdxBState debugState;
 method Bit#(16) debugLastStatus;
 method Bit#(32) debugFlushCount;
endinterface

module mkQDXBEndpoint#(QDXBMediaIfc media)(QDXBEndpointIfc);
 Reg#(QdxBState) state <- mkReg(BIdle); Reg#(QdxBCommand) cmd <- mkReg(unpack(0)); Reg#(QdxACompletion) completion <- mkReg(replicate(0)); Reg#(Bit#(16)) lastStatus <- mkReg(0); Reg#(Vector#(16,QdxBSgEntry)) sg <- mkReg(replicate(QdxBSgEntry {address:0,lengthBytes:0})); Reg#(Bit#(5)) sgEntry <- mkReg(0); Reg#(Bit#(1)) sgPart <- mkReg(0); Reg#(Bit#(5)) segmentIndex <- mkReg(0); Reg#(Bit#(16)) segmentWordOffset <- mkReg(0); Reg#(Bit#(16)) transferWords <- mkReg(0); Reg#(Bit#(16)) transferIndex <- mkReg(0); Reg#(Bit#(8)) commitIndex <- mkReg(0); Reg#(QdxBOpKind) opKind <- mkReg(BOpNone); RegFile#(Bit#(8),Bit#(32)) stage <- mkRegFileFull; Reg#(QdxBDmaPhase) dmaPhase <- mkReg(BDmaIdle); Reg#(QdxBDmaKind) dmaKind <- mkReg(BDmaNone); Reg#(DmaRequest) dmaReq <- mkReg(DmaRequest {direction:HostToDevice,address:0,words:BurstOne}); Reg#(Bit#(5)) dmaMoved <- mkReg(0);
 method QdxAEndpointIn endpointDrive(QdxAEndpointOut qdx); QdxAEndpointIn e=qdxAEndpointInDefault(); e.commandReady=(state==BIdle && !qdx.reset); if (state==BComplete) begin e.completionValid=True; e.completion=completion; end return e; endmethod
 method QdxAProfileDmaIn dmaDrive; QdxAProfileDmaIn p=qdxAProfileDmaInDefault(); Bit#(16) payloadIndex=transferIndex+zeroExtend(dmaMoved); Bit#(8) pi=truncate(payloadIndex); Bit#(32) mediaWord=media.readWord(cmd.namespaceId,cmd.lba,pi); Bit#(32) stagedWord=stage.sub(pi); Bit#(32) outWord=selectPayloadWord(opKind,cmd,payloadIndex,mediaWord,stagedWord); case (dmaPhase) BDmaRequest: begin p.requestValid=True; p.request=dmaReq; end BDmaTransfer: begin if (dmaReq.direction==HostToDevice) p.readReady=True; else begin p.writeValid=True; p.writeWord=DmaWord {data:outWord}; end end BDmaCompletion:p.completionReady=True; default:begin end endcase return p; endmethod
 method Action advance(QdxAEndpointOut qdx, QdxAProfileDmaOut dma); action
  if (qdx.reset) begin state<=BIdle; dmaPhase<=BDmaIdle; dmaKind<=BDmaNone; lastStatus<=0; sgEntry<=0; sgPart<=0; segmentIndex<=0; segmentWordOffset<=0; transferIndex<=0; transferWords<=0; end
  else if (state==BComplete) begin if (qdx.completionReady) state<=BIdle; end
  else if (state==BIdle) begin if (qdx.commandValid) begin QdxBCommand c=decodeCommand(qdx.command); cmd<=c; lastStatus<=0; sgEntry<=0; sgPart<=0; segmentIndex<=0; segmentWordOffset<=0; transferIndex<=0; Bool genericOk=(c.flags==0 && c.reserved0==0 && c.reserved1==0 && c.commandArg==0 && c.sgCount<=16); Bit#(16) st=stSuccess; QdxBOpKind nextOp=BOpNone; Bool needsBuffer=False; Bit#(32) blockBytes=zeroExtend(blockWords(c.namespaceId))<<2; if (!genericOk) st=stInvalidField; else case (c.opcode) 8'h00: if (c.namespaceId!=0 || c.blockCount!=0 || c.sgCount!=0 || c.dataAddr!=0 || c.sgAddr!=0) st=stInvalidField; 8'h01: begin nextOp=BOpIdentifyController; needsBuffer=True; if (c.namespaceId!=0 || c.blockCount!=0 || !bufferHeaderValid(c,64)) st=stInvalidField; end 8'h02: begin nextOp=BOpIdentifyNamespace; needsBuffer=True; if (!validNs(c.namespaceId)) st=stInvalidNamespace; else if (c.blockCount!=0 || !bufferHeaderValid(c,64)) st=stInvalidField; end 8'h03: st=stInvalidOpcode; 8'h10,8'h11,8'h14: begin nextOp=(c.opcode==8'h10)?BOpRead:((c.opcode==8'h11)?BOpWrite:BOpWriteDurable); needsBuffer=True; if (!validNs(c.namespaceId)) st=stInvalidNamespace; else if (c.blockCount!=1 || !bufferHeaderValid(c,blockBytes)) st=stInvalidField; else if (c.lba>=64) st=stLbaRange; end 8'h12: begin if (!validNs(c.namespaceId)) st=stInvalidNamespace; else if (c.blockCount!=0 || c.sgCount!=0 || c.dataAddr!=0 || c.sgAddr!=0) st=stInvalidField; end 8'h13: begin nextOp=BOpHealth; needsBuffer=True; if (c.namespaceId>2) st=stInvalidNamespace; else if (c.blockCount!=0 || !bufferHeaderValid(c,64)) st=stInvalidField; end default:st=stInvalidOpcode; endcase
   if (st!=stSuccess) begin completion<=makeCompletion(c,st,0,0); lastStatus<=st; state<=BComplete; end else if (c.opcode==opNop) begin completion<=makeCompletion(c,stSuccess,0,0); lastStatus<=stSuccess; state<=BComplete; end else if (c.opcode==opFlush) begin media.flush(c.namespaceId); completion<=makeCompletion(c,stSuccess,0,0); lastStatus<=stSuccess; state<=BComplete; end else begin opKind<=nextOp; transferWords <= (nextOp==BOpIdentifyController || nextOp==BOpIdentifyNamespace || nextOp==BOpHealth) ? 16 : blockWords(c.namespaceId); if (needsBuffer && c.sgCount>0) state<=BFetchSg; else state<=BTransfer; end end end
  else begin
   if (dmaPhase==BDmaIdle) begin
    if (state==BFetchSg) begin if (sgEntry>=truncate(cmd.sgCount)) begin Vector#(16,QdxBSgEntry) currentSg=sg; if (!sgValid(currentSg,cmd,opKind)) begin completion<=makeCompletion(cmd,stInvalidField,0,0); lastStatus<=stInvalidField; state<=BComplete; end else begin transferIndex<=0; segmentIndex<=0; segmentWordOffset<=0; state<=BTransfer; end end else begin Bit#(32) sgEntry32=zeroExtend(sgEntry); Bit#(32) sgPart32=zeroExtend(sgPart); Bit#(32) delta=(sgEntry32<<3)+(sgPart32<<2); Bit#(32) a=handleAdd(cmd.sgAddr,delta); dmaReq<=DmaRequest {direction:HostToDevice,address:a,words:BurstOne}; dmaKind<=sgPart==0 ? BDmaSgAddress : BDmaSgLength; dmaMoved<=0; dmaPhase<=BDmaRequest; end end
    else if (state==BTransfer) begin if (transferIndex>=transferWords) begin if (opKind==BOpWrite || opKind==BOpWriteDurable) begin commitIndex<=0; state<=BMediaCommit; end else begin Bit#(32) blocks=(opKind==BOpRead)?1:0; completion<=makeCompletion(cmd,stSuccess,0,blocks); lastStatus<=stSuccess; state<=BComplete; end end else if (cmd.sgCount==0) begin Bit#(16) remain=transferWords-transferIndex; BurstWords b=chooseBurst(remain); Bit#(32) transferOffset=zeroExtend(transferIndex); Bit#(32) a=handleAdd(cmd.dataAddr,transferOffset<<2); dmaReq<=DmaRequest {direction:(opKind==BOpWrite || opKind==BOpWriteDurable)?HostToDevice:DeviceToHost,address:a,words:b}; dmaKind<=BDmaPayload; dmaMoved<=0; dmaPhase<=BDmaRequest; end else if (segmentIndex>=truncate(cmd.sgCount)) begin completion<=makeCompletion(cmd,stInvalidField,0,0); lastStatus<=stInvalidField; state<=BComplete; end else begin Vector#(16,QdxBSgEntry) currentSg=sg; QdxBSgEntry e=currentSg[segmentIndex[3:0]]; Bit#(16) segWords=truncate(e.lengthBytes>>2); if (segmentWordOffset>=segWords) begin segmentIndex<=segmentIndex+1; segmentWordOffset<=0; end else begin Bit#(16) remain=transferWords-transferIndex; Bit#(16) segRemain=segWords-segmentWordOffset; Bit#(16) possible=(remain<segRemain)?remain:segRemain; BurstWords b=chooseBurst(possible); Bit#(32) segmentOffset=zeroExtend(segmentWordOffset); Bit#(32) a=handleAdd(e.address,segmentOffset<<2); dmaReq<=DmaRequest {direction:(opKind==BOpWrite || opKind==BOpWriteDurable)?HostToDevice:DeviceToHost,address:a,words:b}; dmaKind<=BDmaPayload; dmaMoved<=0; dmaPhase<=BDmaRequest; end end end
    else if (state==BMediaCommit) begin Bit#(32) staged=stage.sub(commitIndex); media.writeWord(cmd.namespaceId,cmd.lba,commitIndex,staged); Bit#(16) nextCommit=zeroExtend(commitIndex)+16'd1; if (nextCommit>=transferWords) begin Bit#(16) f=(opKind==BOpWriteDurable)?cfWriteDurableDone:0; completion<=makeCompletion(cmd,stSuccess,f,1); lastStatus<=stSuccess; state<=BComplete; end else commitIndex<=commitIndex+1; end
   end
   else begin
    case (dmaPhase)
     BDmaRequest: if (dma.requestReady) begin dmaMoved<=0; dmaPhase<=BDmaTransfer; end
     BDmaTransfer: begin if (dmaReq.direction==HostToDevice && dma.readValid) begin if (dmaKind==BDmaSgAddress) begin Vector#(16,QdxBSgEntry) v=sg; QdxBSgEntry e=v[sgEntry[3:0]]; e.address=dma.readWord.data; v[sgEntry[3:0]]=e; sg<=v; end else if (dmaKind==BDmaSgLength) begin Vector#(16,QdxBSgEntry) v=sg; QdxBSgEntry e=v[sgEntry[3:0]]; e.lengthBytes=dma.readWord.data; v[sgEntry[3:0]]=e; sg<=v; end else if (dmaKind==BDmaPayload) stage.upd(truncate(transferIndex+zeroExtend(dmaMoved)),dma.readWord.data); Bit#(5) n=dmaMoved+1; dmaMoved<=n; if (n==burstCount(dmaReq.words)) dmaPhase<=BDmaCompletion; end else if (dmaReq.direction==DeviceToHost && dma.writeReady) begin Bit#(5) n=dmaMoved+1; dmaMoved<=n; if (n==burstCount(dmaReq.words)) dmaPhase<=BDmaCompletion; end end
     BDmaCompletion: if (dma.completionValid) begin if (dma.completion.status!=DmaOk || dma.completion.wordsCompleted!=burstCount(dmaReq.words)) begin completion<=makeCompletion(cmd,stDmaFault,0,0); lastStatus<=stDmaFault; dmaPhase<=BDmaIdle; state<=BComplete; end else begin Bit#(16) moved=zeroExtend(burstCount(dmaReq.words)); if (dmaKind==BDmaSgAddress) sgPart<=1; else if (dmaKind==BDmaSgLength) begin sgPart<=0; sgEntry<=sgEntry+1; end else if (dmaKind==BDmaPayload) begin transferIndex<=transferIndex+moved; if (cmd.sgCount>0) segmentWordOffset<=segmentWordOffset+moved; end dmaPhase<=BDmaIdle; end end
     default:begin end
    endcase
   end
  end
 endaction endmethod
 method QdxBState debugState=state; method Bit#(16) debugLastStatus=lastStatus; method Bit#(32) debugFlushCount=media.flushCount;
endmodule
endpackage