package PTIEncoding;

typedef enum {
    PtiIdle,
    PtiDataLo,
    PtiDataHi,
    PtiControl
} PtiTokenKind deriving (Bits, Eq, FShow);

typedef struct {
    PtiTokenKind kind;
    Bit#(18) ptd;
} PtiToken deriving (Bits, Eq, FShow);

typedef struct {
    Bit#(2) space;
    Bool addressStrobe;
    Bool read;
    Bit#(4) byteEnable;
    Bit#(2) burstLen;
    Bool dataStrobe;
    Bool driveAdPar;
    Bool driveControl;
} PtiControlImage deriving (Bits, Eq, FShow);

function PtiToken ptiToken(PtiTokenKind kind, Bit#(16) data, Bit#(2) parity);
    return PtiToken { kind: kind, ptd: { parity, data } };
endfunction

function Bit#(16) ptiData(PtiToken t);
    return t.ptd[15:0];
endfunction

function Bit#(2) ptiParity(PtiToken t);
    return t.ptd[17:16];
endfunction

function PtiToken dataLo(Bit#(32) data, Bit#(4) parity);
    return ptiToken(PtiDataLo, data[15:0], parity[1:0]);
endfunction

function PtiToken dataHi(Bit#(32) data, Bit#(4) parity);
    return ptiToken(PtiDataHi, data[31:16], parity[3:2]);
endfunction

function Bit#(16) packControl(PtiControlImage image);
    return {
        3'b000,
        pack(image.driveControl),
        pack(image.driveAdPar),
        pack(image.dataStrobe),
        image.burstLen,
        image.byteEnable,
        pack(image.read),
        pack(image.addressStrobe),
        image.space
    };
endfunction

function PtiControlImage unpackControl(Bit#(16) bits);
    return PtiControlImage {
        space: bits[1:0],
        addressStrobe: unpack(bits[2]),
        read: unpack(bits[3]),
        byteEnable: bits[7:4],
        burstLen: bits[9:8],
        dataStrobe: unpack(bits[10]),
        driveAdPar: unpack(bits[11]),
        driveControl: unpack(bits[12])
    };
endfunction

function Bool validControlBits(Bit#(16) bits);
    return bits[15:13] == 0;
endfunction

function Bool validControlToken(PtiToken t);
    return t.kind == PtiControl
        && ptiParity(t) == 0
        && validControlBits(ptiData(t));
endfunction

function PtiToken controlToken(PtiControlImage image);
    return ptiToken(PtiControl, packControl(image), 0);
endfunction

endpackage
