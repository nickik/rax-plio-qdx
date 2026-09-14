package TbQLITypes;

import QLITypes::*;

module mkTbQLITypes(Empty);
    Reg#(Bool) ran <- mkReg(False);

    rule runTests (!ran);
        MmioRequest byte0 = MmioRequest {
            address: 32'h0000_0100,
            write: False,
            byteEnable: 4'b0001,
            writeData: 0
        };
        MmioRequest byte3 = MmioRequest {
            address: 32'h0000_0103,
            write: False,
            byteEnable: 4'b1000,
            writeData: 0
        };
        MmioRequest half2 = MmioRequest {
            address: 32'h0000_0102,
            write: False,
            byteEnable: 4'b1100,
            writeData: 0
        };
        MmioRequest word = MmioRequest {
            address: 32'h0000_0100,
            write: True,
            byteEnable: 4'b1111,
            writeData: 32'h1234_5678
        };
        MmioRequest badAlign = MmioRequest {
            address: 32'h0000_0101,
            write: False,
            byteEnable: 4'b0011,
            writeData: 0
        };
        MmioRequest badMask = MmioRequest {
            address: 32'h0000_0100,
            write: False,
            byteEnable: 4'b0101,
            writeData: 0
        };
        MmioRequest badRange = MmioRequest {
            address: 32'h0200_0000,
            write: False,
            byteEnable: 4'b0001,
            writeData: 0
        };

        if (!validMmioRequest(byte0)) begin
            $display("FAIL byte0");
            $finish(1);
        end
        if (!validMmioRequest(byte3)) begin
            $display("FAIL byte3");
            $finish(1);
        end
        if (!validMmioRequest(half2)) begin
            $display("FAIL half2");
            $finish(1);
        end
        if (!validMmioRequest(word)) begin
            $display("FAIL word");
            $finish(1);
        end
        if (validMmioRequest(badAlign)) begin
            $display("FAIL badAlign accepted");
            $finish(1);
        end
        if (validMmioRequest(badMask)) begin
            $display("FAIL badMask accepted");
            $finish(1);
        end
        if (validMmioRequest(badRange)) begin
            $display("FAIL badRange accepted");
            $finish(1);
        end

        DmaRequest alignedDma = DmaRequest {
            direction: HostToDevice,
            address: 32'h1200_1000,
            words: BurstFour
        };
        DmaRequest unalignedDma = DmaRequest {
            direction: HostToDevice,
            address: 32'h1200_1002,
            words: BurstFour
        };
        if (!validDmaRequest(alignedDma) || validDmaRequest(unalignedDma)) begin
            $display("FAIL DMA alignment");
            $finish(1);
        end

        DmaCompletion fullOk = DmaCompletion { status: DmaOk, wordsCompleted: 4 };
        DmaCompletion shortOk = DmaCompletion { status: DmaOk, wordsCompleted: 3 };
        DmaCompletion partialError = DmaCompletion { status: DmaBusError, wordsCompleted: 3 };
        if (!validDmaCompletion(fullOk, BurstFour)) begin
            $display("FAIL full completion");
            $finish(1);
        end
        if (validDmaCompletion(shortOk, BurstFour)) begin
            $display("FAIL short success accepted");
            $finish(1);
        end
        if (!validDmaCompletion(partialError, BurstFour)) begin
            $display("FAIL partial error rejected");
            $finish(1);
        end

        if (!validNotificationRequest(NotificationRequest { channel: 3 })) begin
            $display("FAIL notification 3");
            $finish(1);
        end
        if (validNotificationRequest(NotificationRequest { channel: 4 })) begin
            $display("FAIL notification 4 accepted");
            $finish(1);
        end

        if (burstWordCount(BurstOne) != 1
            || burstWordCount(BurstFour) != 4
            || burstWordCount(BurstEight) != 8
            || burstWordCount(BurstSixteen) != 16) begin
            $display("FAIL burst counts");
            $finish(1);
        end

        $display("PASS QLI types");
        ran <= True;
    endrule

    rule finish (ran);
        $finish(0);
    endrule
endmodule

endpackage
