package TbQICPhase4Bursts;

import QLITypes::*;
import QICInterfaces::*;
import PLIOQICPhase1::*;
import PLIOQICPhase4::*;

function BurstWords burstFor(Bit#(3) scenario);
    case (scenario)
        0: return BurstOne;
        1: return BurstFour;
        2: return BurstEight;
        default: return BurstSixteen;
    endcase
endfunction

module mkTbQICPhase4Bursts(Empty);
    PLIOQICPhase4Ifc dut <- mkPLIOQICPhase4;
    Reg#(Bit#(3)) scenario <- mkReg(0);
    Reg#(Bool) start <- mkReg(True);
    Reg#(Bit#(32)) nextWord <- mkReg(32'h1000_0000);

    rule run;
        PlioIn pi = plioInDefault();
        QliIn qi = qliInDefault();
        BurstWords burst = burstFor(scenario);

        if (start) begin
            pi.reset = True;
        end
        else begin
            case (dut.debugState)
                QicIdle: begin
                    qi.dmaRequestValid = True;
                    qi.dmaRequest = DmaRequest {
                        direction: HostToDevice,
                        address: 32'h3000_1000,
                        words: burst
                    };
                end
                QicRequestBus: begin
                    pi.grant = True;
                end
                QicDmaAddress: begin
                    pi.grant = True;
                    pi.ack = True;
                end
                QicDmaData: begin
                    if (dut.debugBuffered) begin
                        qi.dmaReadReady = True;
                        // The final buffered word no longer requires BG.
                        pi.grant = dut.debugCompleted != burstWordCount(burst);
                    end
                    else begin
                        pi.grant = True;
                        pi.ack = True;
                        pi.adValid = True;
                        pi.ad = nextWord;
                        pi.parValid = True;
                        pi.par = oddParity32P1(nextWord);
                    end
                end
                QicDmaComplete: begin
                    if (!qi.dmaCompletionValid) noAction;
                    qi.dmaCompletionReady = True;
                end
            endcase
        end

        PlioOut po = dut.drivePlio(pi, qi);
        QliOut qo = dut.driveQli(pi, qi);

        if (dut.debugState == QicDmaData && !dut.debugBuffered && pi.ack)
            nextWord <= nextWord + 1;

        if (dut.debugState == QicDmaComplete) begin
            if (!qo.dmaCompletionValid || qo.dmaCompletion.status != DmaOk
                || qo.dmaCompletion.wordsCompleted != burstWordCount(burst)) begin
                $display("FAIL Phase4 burst scenario=%0d completed=%0d", scenario, qo.dmaCompletion.wordsCompleted);
                $finish(1);
            end
            if (scenario == 3) begin
                $display("PASS QIC Phase4 1/4/8/16 successful bursts");
                $finish(0);
            end
            else begin
                scenario <= scenario + 1;
                start <= True;
                nextWord <= 32'h1000_0000 + zeroExtend(scenario + 1) * 32'h100;
            end
        end
        else if (start) begin
            start <= False;
        end

        dut.advance(pi, qi);
    endrule
endmodule

endpackage
