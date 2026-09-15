package QDXAEndpointIfc;

import Vector::*;

typedef Vector#(8, Bit#(32)) QdxACommand;
typedef Vector#(4, Bit#(32)) QdxACompletion;

typedef struct {
    Bool commandReady;
    Bool completionValid;
    QdxACompletion completion;
} QdxAEndpointIn deriving (Bits, Eq, FShow);

typedef struct {
    Bool reset;
    Bool commandValid;
    QdxACommand command;
    Bool completionReady;
} QdxAEndpointOut deriving (Bits, Eq, FShow);

function QdxAEndpointIn qdxAEndpointInDefault();
    return QdxAEndpointIn {
        commandReady: False,
        completionValid: False,
        completion: replicate(0)
    };
endfunction

function QdxAEndpointOut qdxAEndpointOutDefault();
    return QdxAEndpointOut {
        reset: False,
        commandValid: False,
        command: replicate(0),
        completionReady: False
    };
endfunction

endpackage
