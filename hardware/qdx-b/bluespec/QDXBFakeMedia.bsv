package QDXBFakeMedia;

import RegFile::*;

interface QDXBMediaIfc;
    method Bool validNamespace(Bit#(16) ns);
    method Bit#(32) blockSize(Bit#(16) ns);
    method Bit#(32) totalBlocks(Bit#(16) ns);
    method Bit#(32) readWord(Bit#(16) ns, Bit#(32) lba, Bit#(8) wordIndex);
    method Action writeWord(Bit#(16) ns, Bit#(32) lba, Bit#(8) wordIndex, Bit#(32) data);
    method Action flush(Bit#(16) ns);
    method Bit#(32) flushCount;
endinterface

function Bit#(15) mediaKey(Bit#(16) ns, Bit#(32) lba, Bit#(8) wordIndex);
    Bit#(15) k = 0;
    Bit#(15) lbaPart = truncate(lba);
    Bit#(15) wordPart = zeroExtend(wordIndex);
    if (ns == 1)
        k = (lbaPart << 7) + wordPart;
    else
        k = 15'd8192 + (lbaPart << 8) + wordPart;
    return k;
endfunction

module mkQDXBFakeMedia(QDXBMediaIfc);
    RegFile#(Bit#(15),Bit#(32)) mem <- mkRegFileFull;
    Reg#(Bit#(32)) flushes <- mkReg(0);

    method Bool validNamespace(Bit#(16) ns) = ns == 1 || ns == 2;
    method Bit#(32) blockSize(Bit#(16) ns) = (ns == 1) ? 512 : ((ns == 2) ? 1024 : 0);
    method Bit#(32) totalBlocks(Bit#(16) ns) = (ns == 1 || ns == 2) ? 64 : 0;

    method Bit#(32) readWord(Bit#(16) ns, Bit#(32) lba, Bit#(8) wordIndex);
        return mem.sub(mediaKey(ns,lba,wordIndex));
    endmethod

    method Action writeWord(Bit#(16) ns, Bit#(32) lba, Bit#(8) wordIndex, Bit#(32) data);
        mem.upd(mediaKey(ns,lba,wordIndex),data);
    endmethod

    method Action flush(Bit#(16) ns);
        if (ns == 1 || ns == 2) flushes <= flushes + 1;
    endmethod

    method Bit#(32) flushCount = flushes;
endmodule

endpackage
