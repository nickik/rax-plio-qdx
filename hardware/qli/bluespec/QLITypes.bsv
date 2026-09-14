package QLITypes;

typedef enum {
    BurstOne,
    BurstFour,
    BurstEight,
    BurstSixteen
} BurstWords deriving (Bits, Eq, FShow);

typedef struct {
    Bit#(32) address;
    Bool write;
    Bit#(4) byteEnable;
    Bit#(32) writeData;
} MmioRequest deriving (Bits, Eq, FShow);

typedef enum {
    MmioReadOk,
    MmioWriteOk,
    MmioError
} MmioStatus deriving (Bits, Eq, FShow);

typedef struct {
    MmioStatus status;
    Bit#(32) data;
} MmioResponse deriving (Bits, Eq, FShow);

typedef enum {
    HostToDevice,
    DeviceToHost
} DmaDirection deriving (Bits, Eq, FShow);

typedef struct {
    DmaDirection direction;
    Bit#(32) address;
    BurstWords words;
} DmaRequest deriving (Bits, Eq, FShow);

typedef struct {
    Bit#(32) data;
} DmaWord deriving (Bits, Eq, FShow);

typedef enum {
    DmaOk,
    DmaBusError,
    DmaParityError,
    DmaTimeout,
    DmaProtocolError
} DmaStatus deriving (Bits, Eq, FShow);

typedef struct {
    DmaStatus status;
    Bit#(5) wordsCompleted;
} DmaCompletion deriving (Bits, Eq, FShow);

typedef struct {
    Bit#(8) channel;
} NotificationRequest deriving (Bits, Eq, FShow);

function Bit#(5) burstWordCount(BurstWords burst);
    case (burst)
        BurstOne: return 1;
        BurstFour: return 4;
        BurstEight: return 8;
        BurstSixteen: return 16;
    endcase
endfunction

function Bool validWorkerAddress(Bit#(32) address);
    return address[31:25] == 0;
endfunction

function Bool validWorkerByteEnable(Bit#(32) address, Bit#(4) be);
    Bool result = False;
    case (be)
        4'b0001: result = (address[1:0] == 2'b00);
        4'b0010: result = (address[1:0] == 2'b01);
        4'b0100: result = (address[1:0] == 2'b10);
        4'b1000: result = (address[1:0] == 2'b11);
        4'b0011: result = (address[1:0] == 2'b00);
        4'b1100: result = (address[1:0] == 2'b10);
        4'b1111: result = (address[1:0] == 2'b00);
        default: result = False;
    endcase
    return result;
endfunction

function Bool validMmioRequest(MmioRequest req);
    return validWorkerAddress(req.address)
        && validWorkerByteEnable(req.address, req.byteEnable);
endfunction

function Bool validDmaRequest(DmaRequest req);
    return req.address[1:0] == 0;
endfunction

function Bool validDmaCompletion(DmaCompletion completion, BurstWords requested);
    Bit#(5) requestedWords = burstWordCount(requested);
    Bool countOk = completion.wordsCompleted <= requestedWords;
    Bool successOk = (completion.status != DmaOk)
        || (completion.wordsCompleted == requestedWords);
    return countOk && successOk;
endfunction

function Bool validNotificationRequest(NotificationRequest req);
    return req.channel < 4;
endfunction

function MmioResponse mmioReadOk(Bit#(32) data);
    return MmioResponse { status: MmioReadOk, data: data };
endfunction

function MmioResponse mmioWriteOk();
    return MmioResponse { status: MmioWriteOk, data: 0 };
endfunction

function MmioResponse mmioError();
    return MmioResponse { status: MmioError, data: 0 };
endfunction

endpackage
