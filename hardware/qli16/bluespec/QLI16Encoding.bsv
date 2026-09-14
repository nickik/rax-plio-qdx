package QLI16Encoding;

import QLITypes::*;

typedef enum {
    Q16Idle,
    Q16MmioHeader,
    Q16MmioData,
    Q16MmioResponse,
    Q16DmaHeader,
    Q16DmaData,
    Q16DmaCompletion,
    Q16Notification
} Qli16Type deriving (Bits, Eq, FShow);

typedef struct {
    Bit#(1) direction; // 0 = QIC->device, 1 = device->QIC
    Qli16Type kind;
    Bit#(16) payload;
} Qli16Token deriving (Bits, Eq, FShow);

function Qli16Token q16Token(Bit#(1) direction, Qli16Type kind, Bit#(16) payload);
    return Qli16Token { direction: direction, kind: kind, payload: payload };
endfunction

function Qli16Token mmioHeader0(MmioRequest req);
    return q16Token(0, Q16MmioHeader, req.address[15:0]);
endfunction

function Qli16Token mmioHeader1(MmioRequest req);
    Bit#(16) payload = { 2'b00, req.byteEnable, pack(req.write), req.address[24:16] };
    return q16Token(0, Q16MmioHeader, payload);
endfunction

function Qli16Token mmioDataLo(Bit#(1) direction, Bit#(32) data);
    return q16Token(direction, Q16MmioData, data[15:0]);
endfunction

function Qli16Token mmioDataHi(Bit#(1) direction, Bit#(32) data);
    return q16Token(direction, Q16MmioData, data[31:16]);
endfunction

function Qli16Token mmioResponseStatus(MmioResponse resp);
    return q16Token(1, Q16MmioResponse, zeroExtend(pack(resp.status)));
endfunction

function Bit#(2) burstCode(BurstWords words);
    case (words)
        BurstOne: return 0;
        BurstFour: return 1;
        BurstEight: return 2;
        BurstSixteen: return 3;
    endcase
endfunction

function Qli16Token dmaHeader0(DmaRequest req);
    return q16Token(1, Q16DmaHeader, req.address[15:0]);
endfunction

function Qli16Token dmaHeader1(DmaRequest req);
    return q16Token(1, Q16DmaHeader, req.address[31:16]);
endfunction

function Qli16Token dmaHeader2(DmaRequest req);
    Bit#(1) dir = pack(req.direction == DeviceToHost);
    Bit#(16) payload = { 13'b0, burstCode(req.words), dir };
    return q16Token(1, Q16DmaHeader, payload);
endfunction

function Qli16Token dmaDataLo(Bit#(1) direction, DmaWord word);
    return q16Token(direction, Q16DmaData, word.data[15:0]);
endfunction

function Qli16Token dmaDataHi(Bit#(1) direction, DmaWord word);
    return q16Token(direction, Q16DmaData, word.data[31:16]);
endfunction

function Qli16Token dmaCompletionToken(DmaCompletion completion);
    Bit#(16) payload = { 8'b0, completion.wordsCompleted, pack(completion.status) };
    return q16Token(0, Q16DmaCompletion, payload);
endfunction

function Qli16Token notificationToken(NotificationRequest req);
    return q16Token(1, Q16Notification, { 14'b0, req.channel[1:0] });
endfunction

endpackage
