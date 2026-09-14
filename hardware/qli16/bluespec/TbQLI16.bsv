package TbQLI16;

import QLITypes::*;
import QLI16Encoding::*;

function Action showToken(Qli16Token t);
    action
        $write(" %0h:%0h:%04h", t.direction, pack(t.kind), t.payload);
    endaction
endfunction

module mkTbQLI16(Empty);
    Reg#(Bool) done <- mkReg(False);

    rule run (!done);
        MmioRequest mr = MmioRequest { address: 32'h0000_0101, write: False, byteEnable: 4'h2, writeData: 0 };
        $write("VECTOR MMIO_READ8"); showToken(mmioHeader0(mr)); showToken(mmioHeader1(mr)); $display("");

        MmioRequest mw = MmioRequest { address: 32'h0000_0104, write: True, byteEnable: 4'hf, writeData: 32'h89ab_cdef };
        $write("VECTOR MMIO_WRITE32"); showToken(mmioHeader0(mw)); showToken(mmioHeader1(mw)); showToken(mmioDataLo(0, mw.writeData)); showToken(mmioDataHi(0, mw.writeData)); $display("");

        MmioResponse rr = mmioReadOk(32'h1234_5678);
        $write("VECTOR MMIO_READ_OK"); showToken(mmioResponseStatus(rr)); showToken(mmioDataLo(1, rr.data)); showToken(mmioDataHi(1, rr.data)); $display("");

        $write("VECTOR MMIO_WRITE_OK"); showToken(mmioResponseStatus(mmioWriteOk())); $display("");
        $write("VECTOR MMIO_ERROR"); showToken(mmioResponseStatus(mmioError())); $display("");

        DmaRequest d1 = DmaRequest { direction: DeviceToHost, address: 32'h1234_5000, words: BurstOne };
        DmaRequest d4 = DmaRequest { direction: DeviceToHost, address: 32'h1234_5000, words: BurstFour };
        DmaRequest d8 = DmaRequest { direction: DeviceToHost, address: 32'h1234_5000, words: BurstEight };
        DmaRequest d16 = DmaRequest { direction: DeviceToHost, address: 32'h1234_5000, words: BurstSixteen };

        $write("VECTOR DMA1"); showToken(dmaHeader0(d1)); showToken(dmaHeader1(d1)); showToken(dmaHeader2(d1)); $display("");
        $write("VECTOR DMA4"); showToken(dmaHeader0(d4)); showToken(dmaHeader1(d4)); showToken(dmaHeader2(d4)); $display("");
        $write("VECTOR DMA8"); showToken(dmaHeader0(d8)); showToken(dmaHeader1(d8)); showToken(dmaHeader2(d8)); $display("");
        $write("VECTOR DMA16"); showToken(dmaHeader0(d16)); showToken(dmaHeader1(d16)); showToken(dmaHeader2(d16)); $display("");

        DmaWord word = DmaWord { data: 32'haabb_ccdd };
        $write("VECTOR DMA_DATA"); showToken(dmaDataLo(1, word)); showToken(dmaDataHi(1, word)); $display("");

        DmaCompletion cOk = DmaCompletion { status: DmaOk, wordsCompleted: 4 };
        DmaCompletion cBus = DmaCompletion { status: DmaBusError, wordsCompleted: 3 };
        DmaCompletion cPar = DmaCompletion { status: DmaParityError, wordsCompleted: 3 };
        DmaCompletion cTimeout = DmaCompletion { status: DmaTimeout, wordsCompleted: 3 };
        DmaCompletion cProto = DmaCompletion { status: DmaProtocolError, wordsCompleted: 3 };
        $write("VECTOR COMP_OK"); showToken(dmaCompletionToken(cOk)); $display("");
        $write("VECTOR COMP_BUS"); showToken(dmaCompletionToken(cBus)); $display("");
        $write("VECTOR COMP_PAR"); showToken(dmaCompletionToken(cPar)); $display("");
        $write("VECTOR COMP_TIMEOUT"); showToken(dmaCompletionToken(cTimeout)); $display("");
        $write("VECTOR COMP_PROTO"); showToken(dmaCompletionToken(cProto)); $display("");

        $write("VECTOR NOTIFY0"); showToken(notificationToken(NotificationRequest { channel: 0 })); $display("");
        $write("VECTOR NOTIFY1"); showToken(notificationToken(NotificationRequest { channel: 1 })); $display("");
        $write("VECTOR NOTIFY2"); showToken(notificationToken(NotificationRequest { channel: 2 })); $display("");
        $write("VECTOR NOTIFY3"); showToken(notificationToken(NotificationRequest { channel: 3 })); $display("");

        $display("PASS QLI-16 conformance vectors");
        done <= True;
    endrule

    rule finish (done);
        $finish(0);
    endrule
endmodule

endpackage
