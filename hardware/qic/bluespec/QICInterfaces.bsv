package QICInterfaces;

import QLITypes::*;

typedef enum {
    PlioWorker,
    PlioHostDma,
    PlioController,
    PlioReserved
} PlioSpace deriving (Bits, Eq, FShow);

typedef struct {
    Bool reset;
    Bool selected;
    Bool grant;
    Bool adValid;
    Bit#(32) ad;
    Bool parValid;
    Bit#(4) parity;
    Bool spaceValid;
    PlioSpace space;
    Bool addressStrobe;
    Bool read;
    Bit#(4) byteEnable;
    BurstWords burst;
    Bool dataStrobe;
    Bool ack;
    Bool err;
} PlioIn deriving (Bits, Eq, FShow);

typedef struct {
    Bool request;
    Bool adValid;
    Bit#(32) ad;
    Bool parValid;
    Bit#(4) parity;
    Bool spaceValid;
    PlioSpace space;
    Bool addressStrobe;
    Bool read;
    Bit#(4) byteEnable;
    BurstWords burst;
    Bool dataStrobe;
    Bool ack;
    Bool err;
} PlioOut deriving (Bits, Eq, FShow);

typedef struct {
    Bool mmioReady;
    Bool mmioResponseValid;
    MmioResponse mmioResponse;
    Bool dmaRequestValid;
    DmaRequest dmaRequest;
    Bool dmaReadReady;
    Bool dmaWriteValid;
    DmaWord dmaWrite;
    Bool dmaCompletionReady;
    Bool notificationValid;
    NotificationRequest notification;
} QliIn deriving (Bits, Eq, FShow);

typedef struct {
    Bool reset;
    Bool mmioRequestValid;
    MmioRequest mmioRequest;
    Bool mmioResponseReady;
    Bool mmioCancel;
    Bool dmaRequestReady;
    Bool dmaReadValid;
    DmaWord dmaRead;
    Bool dmaWriteReady;
    Bool dmaCompletionValid;
    DmaCompletion dmaCompletion;
    Bool notificationReady;
} QliOut deriving (Bits, Eq, FShow);

function PlioIn plioInDefault();
    return PlioIn {
        reset: False,
        selected: False,
        grant: False,
        adValid: False,
        ad: 0,
        parValid: False,
        parity: 0,
        spaceValid: False,
        space: PlioWorker,
        addressStrobe: False,
        read: False,
        byteEnable: 0,
        burst: BurstOne,
        dataStrobe: False,
        ack: False,
        err: False
    };
endfunction

function PlioOut plioOutDefault();
    return PlioOut {
        request: False,
        adValid: False,
        ad: 0,
        parValid: False,
        parity: 0,
        spaceValid: False,
        space: PlioWorker,
        addressStrobe: False,
        read: False,
        byteEnable: 0,
        burst: BurstOne,
        dataStrobe: False,
        ack: False,
        err: False
    };
endfunction

function QliIn qliInDefault();
    return QliIn {
        mmioReady: False,
        mmioResponseValid: False,
        mmioResponse: mmioError(),
        dmaRequestValid: False,
        dmaRequest: DmaRequest { direction: HostToDevice, address: 0, words: BurstOne },
        dmaReadReady: False,
        dmaWriteValid: False,
        dmaWrite: DmaWord { data: 0 },
        dmaCompletionReady: False,
        notificationValid: False,
        notification: NotificationRequest { channel: 0 }
    };
endfunction

function QliOut qliOutDefault();
    return QliOut {
        reset: False,
        mmioRequestValid: False,
        mmioRequest: MmioRequest { address: 0, write: False, byteEnable: 0, writeData: 0 },
        mmioResponseReady: False,
        mmioCancel: False,
        dmaRequestReady: False,
        dmaReadValid: False,
        dmaRead: DmaWord { data: 0 },
        dmaWriteReady: False,
        dmaCompletionValid: False,
        dmaCompletion: DmaCompletion { status: DmaOk, wordsCompleted: 0 },
        notificationReady: False
    };
endfunction

endpackage
