package TbMainboardValidation;
import Vector::*;
import QLITypes::*;
import QICInterfaces::*;
import PLIOTx::*;
import PLIOWorkerHost::*;
import MainboardFPGA::*;
import LightingMemoryBusCompat::*;

(* synthesize *)
module mkTbMainboardValidation(Empty);
    MainboardFPGAIfc dut <- mkMainboardFPGA;
    Reg#(Bit#(4)) test <- mkReg(0);
    Reg#(Bit#(3)) phase <- mkReg(0);
    Reg#(Bit#(32)) watchdog <- mkReg(0);
    Reg#(Bit#(32)) sentinel <- mkReg(32'h12345678);
    rule noWorkerSideEffects;
        let slots=dut.plioSlots(replicate(backplaneDriveDefault()),False);
        for(Integer i=0;i<8;i=i+1) if(slots[i].selected || slots[i].addressStrobe || slots[i].dataStrobe) begin $display("FAIL validation touched worker");$finish(1);end
        if(dut.dmaGeneration(0,0)!=0) begin $display("FAIL validation changed DMA CSR");$finish(1);end
    endrule
    rule tick;
        watchdog <= watchdog+1;
        if(watchdog==20000) begin $display("FAIL validation watchdog test=%0d phase=%0d",test,phase); $finish(1); end
    endrule
    rule run (dut.debugAdvanceReady);
        Vector#(8,BackplaneDrive) cards=replicate(backplaneDriveDefault());
        HostWorkerRequest worker=HostWorkerRequest{slot:0,address:0,width:HostW32,write:False,value:0};
        LightingBusMasterDrive cpu=lightingBusMasterDriveDefault();
        Bit#(32) addr = test==2 ? 32'h1001 : (test==4 || test==10) ? lightingPlio0Base : test==5 ? lightingPlio0Base+lightingPlio0WorkerBase : test==6 ? 32'hfffffffC : 32'h1000;
        Bool reject = test>=2;
        Bool accept=False; Bool respond=False;
        if(phase!=4) begin
            cpu.busRequest=True; cpu.request=True;
            cpu.payload.addr=addr;cpu.payload.byteEnable=test==3 ? 3 : 15;
            cpu.payload.write=(test!=0 && test!=9 && test!=10);cpu.payload.writeData=32'hdeadbeef;cpu.payload.validate=(test<=6 || test==8);
            cpu.payload.accessKind=test==9 ? 3 : test>=7 ? 1 : 0;
        end
        let response=dut.lightingMemory(cards,cpu,False);
        if(phase==0) phase<=1;
        else if(phase==1 && dut.memoryBackendRequestValid) begin
            if((test>=2 && test<=5) || test>=7) begin $display("FAIL malformed/MMIO validation reached backend");$finish(1);end
            if(!dut.memoryBackendValidate || dut.memoryBackendAddress!=addr || dut.memoryBackendByteEnable!=15 || dut.memoryBackendWriteData!=0 || dut.memoryBackendWrite!=(test!=0)) begin
                $display("FAIL validation payload");$finish(1);
            end
            // Ordinary backend writes would mutate this sentinel. Validation skips them.
            if(!dut.memoryBackendValidate && dut.memoryBackendWrite) sentinel<=dut.memoryBackendWriteData;
            accept=True;phase<=2;
        end
        else if(phase==2 && dut.memoryBackendResponseReady) begin respond=True;phase<=3;end

        else if((phase==1 || phase==3) && response.ready) begin
            if(response.error!=reject || response.readData!=0 || sentinel!=32'h12345678) begin $display("FAIL validation response/nonmutation");$finish(1);end
            phase<=4;
        end
        else if(phase==4) begin
            if(test==10) begin $display("PASS validation read/write, alignment, BE, MMIO/range and qualified-write/validate/reserved/MMIO rejection; no mutation");$finish(0);end
            test<=test+1;phase<=0;
        end
        dut.advance(cards,cpu,False,worker,accept,respond,test==6,test==0,0,False);
    endrule
endmodule
endpackage
