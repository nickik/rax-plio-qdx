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

function PtiToken controlToken(PtiControlImage image);
    return ptiToken(PtiControl, packControl(image), 0);
endfunction

endpackage
