package QDXAProfileDma;

import QLITypes::*;
import QICInterfaces::*;
import QDXA::*;

typedef struct {
    Bool requestValid;
    DmaRequest request;
    Bool readReady;
    Bool writeValid;
    DmaWord writeWord;
    Bool completionReady;
} QdxAProfileDmaIn deriving (Bits, Eq, FShow);

typedef struct {
    Bool requestReady;
    Bool readValid;
    DmaWord readWord;
    Bool writeReady;
    Bool completionValid;
    DmaCompletion completion;
} QdxAProfileDmaOut deriving (Bits, Eq, FShow);

function QdxAProfileDmaIn qdxAProfileDmaInDefault();
    return QdxAProfileDmaIn {
        requestValid: False,
        request: DmaRequest { direction: HostToDevice, address: 0, words: BurstOne },
        readReady: False,
        writeValid: False,
        writeWord: DmaWord { data: 0 },
        completionReady: False
    };
endfunction

function QdxAProfileDmaOut qdxAProfileDmaOutDefault();
    return QdxAProfileDmaOut {
        requestReady: False,
        readValid: False,
        readWord: DmaWord { data: 0 },
        writeReady: False,
        completionValid: False,
        completion: DmaCompletion { status: DmaOk, wordsCompleted: 0 }
    };
endfunction

// Profile payload DMA is legal only while QDX-A has handed one command to its
// profile endpoint and is waiting for that endpoint's completion.  In that
// state the queue core itself never issues a QLI DMA transaction.
function QliIn mergeProfileDma(QdxAState state, QliIn core, QdxAProfileDmaIn p);
    QliIn d = core;
    if (state == AEndpointCompletion) begin
        if (p.requestValid) begin d.dmaRequestValid=True; d.dmaRequest=p.request; end
        d.dmaReadReady = p.readReady;
        if (p.writeValid) begin d.dmaWriteValid=True; d.dmaWrite=p.writeWord; end
        d.dmaCompletionReady = p.completionReady;
    end
    return d;
endfunction

function QdxAProfileDmaOut profileDmaResponse(QdxAState state, QliOut qic);
    QdxAProfileDmaOut o = qdxAProfileDmaOutDefault();
    if (state == AEndpointCompletion) begin
        o.requestReady = qic.dmaRequestReady;
        o.readValid = qic.dmaReadValid;
        o.readWord = qic.dmaRead;
        o.writeReady = qic.dmaWriteReady;
        o.completionValid = qic.dmaCompletionValid;
        o.completion = qic.dmaCompletion;
    end
    return o;
endfunction

endpackage
