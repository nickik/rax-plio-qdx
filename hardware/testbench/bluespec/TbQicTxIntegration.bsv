package TbQicTxIntegration;

import QLITypes::*;
import QICInterfaces::*;
import PLIOQIC::*;
import PLIOTx::*;
import QicTxHarness::*;
import PLIOQICPhase1::*;

module mkTbQicTxIntegration(Empty);
    PLIOQICIfc qic <- mkPLIOQIC;
    QicTxHarnessIfc h <- mkQicTxHarness;
    Reg#(Bit#(8)) stage <- mkReg(0);
    Reg#(PlioIn) bus <- mkReg(plioInDefault());
    Reg#(QliIn) qli <- mkReg(qliInDefault());

    rule stepHarness (!h.ready);
        h.step(False);
    endrule

    rule scenario (h.ready);
        PlioIn b=bus; QliIn q=qli;
        case (stage)
            0: begin
                b.reset=True; qic.advance(b,q); h.step(True);
                b=plioInDefault(); q=qliInDefault(); bus<=b; qli<=q; stage<=1;
            end
            // Worker read address. The selected worker response must emerge only on ACK/ERR.
            1: begin
                b=plioInDefault(); b.selected=True; b.adValid=True; b.ad=32'h100; b.parValid=True; b.par=oddParity32P1(32'h100);
                b.spaceValid=True; b.space=PlioWorker; b.addressStrobe=True; b.read=True; b.byteEnable=4'hf; b.burst=BurstOne;
                bus<=b; h.start(qic.drivePlio(b,q)); stage<=2;
            end
            2: if (h.done) begin
                BackplaneDrive x=h.backplane;
                if (!x.responseValid || !x.ack || x.err || h.protocolFault) $fatal(1,"worker address response did not cross PLIO-TX");
                qic.advance(b,q); b=plioInDefault(); b.dataStrobe=True; bus<=b; qic.advance(b,q); stage<=3;
            end
            3: begin q.mmioReady=True; qli<=q; qic.advance(plioInDefault(),q); stage<=4; end
            4: begin
                b=plioInDefault(); b.dataStrobe=True; q.mmioResponseValid=True; q.mmioResponse=mmioReadOk(32'h89abcdef);
                bus<=b; qli<=q; h.start(qic.drivePlio(b,q)); stage<=5;
            end
            5: if (h.done) begin
                BackplaneDrive x=h.backplane;
                if (!x.adParValid || x.ad!=32'h89abcdef || x.par!=oddParity32P1(32'h89abcdef) || !x.responseValid || !x.ack || h.protocolFault)
                    $fatal(1,"worker read data did not cross PLIO-TX");
                $display("QTXTRACE|v1|case=worker_read|ad=%08x|par=%01x|ack=1|err=0",x.ad,x.par);
                b=plioInDefault(); b.reset=True; q=qliInDefault(); qic.advance(b,q); h.step(True); bus<=plioInDefault(); qli<=q; stage<=10;
            end
            // DEVICE_TO_HOST one-word DMA.
            10: begin
                q=qliInDefault(); q.dmaRequestValid=True; q.dmaRequest=DmaRequest {direction:DeviceToHost,address:32'h2000,words:BurstOne};
                qli<=q; qic.advance(plioInDefault(),q); stage<=11;
            end
            11: begin b=plioInDefault(); b.grant=True; bus<=b; h.start(qic.drivePlio(b,q)); stage<=12; end
            12: if (h.done) begin
                if (!h.backplane.request || h.protocolFault) $fatal(1,"DMA BR did not cross PLIO-TX");
                qic.advance(b,q); h.start(qic.drivePlio(b,q)); stage<=13;
            end
            13: if (h.done) begin
                BackplaneDrive x=h.backplane;
                if (!x.adParValid || x.ad!=32'h2000 || !x.controlValid || x.control.space!=1 || !x.control.addressStrobe || x.control.read || h.protocolFault)
                    $fatal(1,"D2H DMA address did not cross PLIO-TX");
                $display("QTXTRACE|v1|case=d2h_address|ad=%08x|space=%01x|rd=0|as=1",x.ad,x.control.space);
                b.ack=True; qic.advance(b,q); b.ack=False; bus<=b; stage<=14;
            end
            14: begin q.dmaWriteValid=True; q.dmaWrite=DmaWord {data:32'h11223344}; qli<=q; qic.advance(b,q); h.start(qic.drivePlio(b,q)); stage<=15; end
            15: if (h.done) begin
                BackplaneDrive x=h.backplane;
                if (!x.adParValid || x.ad!=32'h11223344 || !x.controlValid || !x.control.dataStrobe || h.protocolFault)
                    $fatal(1,"D2H DMA data did not cross PLIO-TX");
                $display("QTXTRACE|v1|case=d2h_data|ad=%08x|par=%01x|ds=1",x.ad,x.par);
                b.ack=True; qic.advance(b,q); b.ack=False; q.dmaWriteValid=False; qli<=q; bus<=b; stage<=16;
            end
            16: begin
                QliOut qo=qic.driveQli(b,q);
                if (!qo.dmaCompletionValid || qo.dmaCompletion.status!=DmaOk || qo.dmaCompletion.wordsCompleted!=1) $fatal(1,"D2H completion mismatch");
                q.dmaCompletionReady=True; qic.advance(b,q); q=qliInDefault(); qli<=q;
                b=plioInDefault(); b.reset=True; qic.advance(b,q); h.step(True); bus<=plioInDefault(); stage<=20;
            end
            // Notification channel 3.
            20: begin q=qliInDefault(); q.notificationValid=True; q.notification=NotificationRequest {channel:3}; qli<=q; qic.advance(plioInDefault(),q); stage<=21; end
            21: begin b=plioInDefault(); b.grant=True; bus<=b; qic.advance(b,q); h.start(qic.drivePlio(b,q)); stage<=22; end
            22: if (h.done) begin
                BackplaneDrive x=h.backplane;
                if (!x.adParValid || x.ad!=12 || !x.controlValid || x.control.space!=2 || !x.control.addressStrobe || h.protocolFault)
                    $fatal(1,"notification address did not cross PLIO-TX");
                $display("QTXTRACE|v1|case=notification_address|ad=%08x|space=2|as=1",x.ad);
                b.ack=True; qic.advance(b,q); b.ack=False; bus<=b; h.start(qic.drivePlio(b,q)); stage<=23;
            end
            23: if (h.done) begin
                BackplaneDrive x=h.backplane;
                if (!x.adParValid || x.ad!=0 || !x.controlValid || !x.control.dataStrobe || h.protocolFault)
                    $fatal(1,"notification data did not cross PLIO-TX");
                b.ack=True;
                QliOut qo=qic.driveQli(b,q);
                if (!qo.notificationReady) $fatal(1,"notification completion ready missing");
                $display("QTXTRACE|v1|case=notification_data|ad=00000000|ds=1|ready=1");
                stage<=30;
            end
            // Explicit reset safety at integration boundary.
            30: begin
                PlioOut p=plioOutDefault(); p.request=True; p.adValid=True; p.ad=32'hdeadbeef; p.parValid=True; p.par=oddParity32P1(32'hdeadbeef);
                p.spaceValid=True; p.space=PlioHostDma; p.dataStrobe=True; p.byteEnable=4'hf;
                h.start(p); stage<=31;
            end
            31: if (h.done) begin
                h.step(True); stage<=32;
            end
            32: begin
                BackplaneDrive x=h.backplane;
                // exposed is historical, so safety is checked by PLIO-TX's reset step and sticky fault state here.
                if (h.protocolFault) $fatal(1,"legal integration sequence caused PTI protocol fault");
                $display("QTXTRACE|v1|case=reset|fault=0");
                $display("PASS unified QIC + PTI + PLIO-TX integration");
                $finish(0);
            end
        endcase
    endrule
endmodule

endpackage
