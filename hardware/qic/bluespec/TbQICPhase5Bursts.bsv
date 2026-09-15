package TbQICPhase5Bursts;

import QLITypes::*;
import QICInterfaces::*;
import PLIOQICPhase1::*;
import PLIOQICPhase5::*;

function BurstWords burstFor(Bit#(2) idx);
    case (idx)
        0: return BurstOne;
        1: return BurstFour;
        2: return BurstEight;
        default: return BurstSixteen;
    endcase
endfunction

function Bit#(32) dataFor(Bit#(2) idx, Bit#(5) n);
    return 32'h5100_0000 | (zeroExtend(idx) << 16) | zeroExtend(n);
endfunction

module mkTbQICPhase5Bursts(Empty);
    PLIOQICPhase5Ifc dut <- mkPLIOQICPhase5;
    Reg#(Bit#(3)) phase <- mkReg(0);
    Reg#(Bit#(2)) burstIndex <- mkReg(0);
    Reg#(Bit#(5)) supplied <- mkReg(0);
    Reg#(Bit#(5)) acked <- mkReg(0);

    rule run;
        BurstWords burst = burstFor(burstIndex);
        Bit#(5) count = burstWordCount(burst);
        PlioIn pi = plioInDefault();
        QliIn qi = qliInDefault();

        case (phase)
            0: begin
                qi.dmaRequestValid = True;
                qi.dmaRequest = DmaRequest { direction: DeviceToHost, address: 32'h4400_0000, words: burst };
            end
            1: pi.grant = True;
            2: begin pi.grant = True; pi.ack = True; end
            3: begin
                pi.grant = True;
                pi.ack = True;
                qi.dmaWriteValid = supplied < count;
                qi.dmaWrite = DmaWord { data: dataFor(burstIndex, supplied) };
            end
            4: qi.dmaCompletionReady = True;
        endcase

        PlioOut po = dut.drivePlio(pi, qi);
        QliOut qo = dut.driveQli(pi, qi);

        case (phase)
            0: begin
                if (!qo.dmaRequestReady) begin $display("FAIL burst request not ready idx=%0d", burstIndex); $finish(1); end
                phase <= 1;
            end
            1: phase <= 2;
            2: begin
                if (!po.addressStrobe || po.read || po.burst != burst) begin $display("FAIL burst address idx=%0d", burstIndex); $finish(1); end
                phase <= 3;
            end
            3: begin
                if (qo.dmaWriteReady && supplied < count)
                    supplied <= supplied + 1;

                if (po.dataStrobe) begin
                    Bit#(32) expected = dataFor(burstIndex, acked);
                    if (!po.adValid || po.ad != expected || !po.parValid || po.par != oddParity32P1(expected)) begin
                        $display("FAIL D2H data/parity idx=%0d beat=%0d", burstIndex, acked);
                        $finish(1);
                    end
                    if (acked >= count) begin
                        $display("FAIL extra D2H beat idx=%0d", burstIndex);
                        $finish(1);
                    end
                    acked <= acked + 1;
                end

                if (qo.dmaCompletionValid) begin
                    if (qo.dmaCompletion.status != DmaOk || qo.dmaCompletion.wordsCompleted != count || acked != count) begin
                        $display("FAIL burst completion idx=%0d got=%0d expected=%0d acked=%0d", burstIndex, qo.dmaCompletion.wordsCompleted, count, acked);
                        $finish(1);
                    end
                    phase <= 4;
                end
            end
            4: begin
                if (burstIndex == 3) begin
                    $display("PASS QIC Phase5 D2H bursts 1/4/8/16");
                    $finish(0);
                end
                else begin
                    burstIndex <= burstIndex + 1;
                    supplied <= 0;
                    acked <= 0;
                    phase <= 0;
                end
            end
        endcase

        dut.advance(pi, qi);
    endrule
endmodule

endpackage
