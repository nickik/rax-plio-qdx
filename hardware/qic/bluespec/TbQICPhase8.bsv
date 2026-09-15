package TbQICPhase8;

import QLITypes::*;
import QICInterfaces::*;
import PLIOQIC::*;
import PLIOQICPhase1::*;
import PLIOQICPhase2::*;

function PlioIn resetPi(); PlioIn x=plioInDefault(); x.reset=True; return x; endfunction
function PlioIn grantPi(Bool ack, Bool err); PlioIn x=plioInDefault(); x.grant=True; x.ack=ack; x.err=err; return x; endfunction
function PlioIn workerAddr(Bit#(32) a, Bool rd, Bit#(4) be); PlioIn x=plioInDefault(); x.selected=True; x.adValid=True; x.ad=a; x.parValid=True; x.parity=oddParity32P2(a); x.spaceValid=True; x.space=PlioWorker; x.addressStrobe=True; x.read=rd; x.byteEnable=be; x.burst=BurstOne; return x; endfunction
function PlioIn workerData(Bit#(32) d); PlioIn x=plioInDefault(); x.dataStrobe=True; x.adValid=True; x.ad=d; x.parValid=True; x.parity=oddParity32P2(d); return x; endfunction
function QliIn dmaReq(DmaDirection dir, Bit#(32) addr, BurstWords words); QliIn q=qliInDefault(); q.dmaRequestValid=True; q.dmaRequest=DmaRequest{direction:dir,address:addr,words:words}; return q; endfunction
function QliIn notifReq(Bit#(8) ch); QliIn q=qliInDefault(); q.notificationValid=True; q.notification=NotificationRequest{channel:ch}; return q; endfunction

function PlioIn workerPi(Bit#(16) l, Bool write, Bit#(32) addr, Bit#(4) be, Bit#(32) data);
    PlioIn x=plioInDefault();
    if(l==0) x=resetPi();
    else if(l==1) x=workerAddr(addr,!write,be);
    else if(l==2) begin if(write) x=workerData(data); else x.dataStrobe=True; end
    else if(l==4) x.dataStrobe=True;
    return x;
endfunction
function QliIn workerQi(Bit#(16) l, Bool write, Bit#(32) responseData);
    QliIn q=qliInDefault();
    if(l==3) q.mmioReady=True;
    else if(l==4) begin q.mmioResponseValid=True; q.mmioResponse=write ? mmioWriteOk() : mmioReadOk(responseData); end
    return q;
endfunction

function PlioIn notificationPi(Bit#(16) l);
    PlioIn x=plioInDefault();
    if(l==0) x=resetPi();
    else if(l==2) x=grantPi(False,False);
    else if(l==3 || l==4) x=grantPi(True,False);
    return x;
endfunction
function QliIn notificationQi(Bit#(16) l, Bit#(8) ch);
    QliIn q=qliInDefault();
    if(l>=1 && l<=4) q=notifReq(ch);
    return q;
endfunction

function PlioIn h2dPi(Bit#(16) l, Bit#(16) n);
    PlioIn x=plioInDefault();
    Bit#(16) twice=n<<1;
    if(l==0) x=resetPi();
    else if(l==2) x=grantPi(False,False);
    else if(l==3) x=grantPi(True,False);
    else if(l>=4 && l<4+twice) begin
        if(l[0]==0) begin
            Bit#(16) idx=(l-4)>>1;
            Bit#(32) d=32'h1100_0000+zeroExtend(idx);
            x=grantPi(True,False); x.adValid=True; x.ad=d; x.parValid=True; x.parity=oddParity32P1(d);
        end
        else if(l != 3+twice) x=grantPi(False,False);
    end
    return x;
endfunction
function QliIn h2dQi(Bit#(16) l, Bit#(16) n, Bit#(32) addr, BurstWords words);
    QliIn q=qliInDefault();
    Bit#(16) twice=n<<1;
    if(l==1) q=dmaReq(HostToDevice,addr,words);
    else if(l>=5 && l<=3+twice && l[0]==1) q.dmaReadReady=True;
    else if(l==4+twice) q.dmaCompletionReady=True;
    return q;
endfunction

function PlioIn d2hPi(Bit#(16) l, Bit#(16) n);
    PlioIn x=plioInDefault();
    Bit#(16) twice=n<<1;
    if(l==0) x=resetPi();
    else if(l==2) x=grantPi(False,False);
    else if(l==3) x=grantPi(True,False);
    else if(l>=4 && l<4+twice) begin
        if(l[0]==0) x=grantPi(False,False);
        else x=grantPi(True,False);
    end
    return x;
endfunction
function QliIn d2hQi(Bit#(16) l, Bit#(16) n, Bit#(32) addr, BurstWords words);
    QliIn q=qliInDefault();
    Bit#(16) twice=n<<1;
    if(l==1) q=dmaReq(DeviceToHost,addr,words);
    else if(l>=4 && l<4+twice && l[0]==0) begin
        Bit#(16) idx=(l-4)>>1;
        q.dmaWriteValid=True; q.dmaWrite=DmaWord{data:32'h2200_0000+zeroExtend(idx)};
    end
    else if(l==4+twice) q.dmaCompletionReady=True;
    return q;
endfunction

function PlioIn piFor(Bit#(16) c);
    PlioIn x=plioInDefault();
    if(c<5) x=workerPi(c,False,32'h100,4'h1,0);
    else if(c<10) x=workerPi(c-5,False,32'h102,4'h3,0);
    else if(c<15) x=workerPi(c-10,False,32'h104,4'hf,0);
    else if(c<20) x=workerPi(c-15,True,32'h108,4'h1,32'h0000_005a);
    else if(c<25) x=workerPi(c-20,True,32'h10a,4'h3,32'h0000_a55a);
    else if(c<30) x=workerPi(c-25,True,32'h10c,4'hf,32'ha55a_5aa5);
    else if(c<36) x=notificationPi(c-30);
    else if(c<42) x=notificationPi(c-36);
    else if(c<48) x=notificationPi(c-42);
    else if(c<54) x=notificationPi(c-48);
    else if(c==54) x=resetPi();
    else if(c==56 || c==59 || c==61) x=grantPi(False,False);
    else if(c==57 || c==58) x=grantPi(True,False);
    else if(c==62) x=resetPi();
    else if(c<70) x=h2dPi(c-63,1);
    else if(c<83) x=h2dPi(c-70,4);
    else if(c<104) x=h2dPi(c-83,8);
    else if(c<141) x=h2dPi(c-104,16);
    else if(c<148) x=d2hPi(c-141,1);
    else if(c<161) x=d2hPi(c-148,4);
    else if(c<182) x=d2hPi(c-161,8);
    else if(c<219) x=d2hPi(c-182,16);
    else begin
        case(c)
            219,224,229,235,496,757,1016: x=resetPi();
            221,226,231,237,1018,1021,1025: x=grantPi(False,False);
            222: x=grantPi(False,True);
            227: x=plioInDefault();
            232,1022,1026: x=grantPi(True,False);
            233: begin Bit#(32) d=32'hdead_beef; x=grantPi(True,False); x.adValid=True; x.ad=d; x.parValid=True; x.parity=oddParity32P1(d)^4'h1; end
            238: x=grantPi(True,False);
            239,240,241,242,243,244,245,246,247,248,249,250,251,252,253,254,
            255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,270,
            271,272,273,274,275,276,277,278,279,280,281,282,283,284,285,286,
            287,288,289,290,291,292,293,294,295,296,297,298,299,300,301,302,
            303,304,305,306,307,308,309,310,311,312,313,314,315,316,317,318,
            319,320,321,322,323,324,325,326,327,328,329,330,331,332,333,334,
            335,336,337,338,339,340,341,342,343,344,345,346,347,348,349,350,
            351,352,353,354,355,356,357,358,359,360,361,362,363,364,365,366,
            367,368,369,370,371,372,373,374,375,376,377,378,379,380,381,382,
            383,384,385,386,387,388,389,390,391,392,393,394,395,396,397,398,
            399,400,401,402,403,404,405,406,407,408,409,410,411,412,413,414,
            415,416,417,418,419,420,421,422,423,424,425,426,427,428,429,430,
            431,432,433,434,435,436,437,438,439,440,441,442,443,444,445,446,
            447,448,449,450,451,452,453,454,455,456,457,458,459,460,461,462,
            463,464,465,466,467,468,469,470,471,472,473,474,475,476,477,478,
            479,480,481,482,483,484,485,486,487,488,489,490,491,492,493,494: x=grantPi(False,False);
            497: x=workerAddr(32'h180,True,4'hf);
            498: x.dataStrobe=True;
            499: x=plioInDefault();
            500,501,502,503,504,505,506,507,508,509,510,511,512,513,514,515,
            516,517,518,519,520,521,522,523,524,525,526,527,528,529,530,531,
            532,533,534,535,536,537,538,539,540,541,542,543,544,545,546,547,
            548,549,550,551,552,553,554,555,556,557,558,559,560,561,562,563,
            564,565,566,567,568,569,570,571,572,573,574,575,576,577,578,579,
            580,581,582,583,584,585,586,587,588,589,590,591,592,593,594,595,
            596,597,598,599,600,601,602,603,604,605,606,607,608,609,610,611,
            612,613,614,615,616,617,618,619,620,621,622,623,624,625,626,627,
            628,629,630,631,632,633,634,635,636,637,638,639,640,641,642,643,
            644,645,646,647,648,649,650,651,652,653,654,655,656,657,658,659,
            660,661,662,663,664,665,666,667,668,669,670,671,672,673,674,675,
            676,677,678,679,680,681,682,683,684,685,686,687,688,689,690,691,
            692,693,694,695,696,697,698,699,700,701,702,703,704,705,706,707,
            708,709,710,711,712,713,714,715,716,717,718,719,720,721,722,723,
            724,725,726,727,728,729,730,731,732,733,734,735,736,737,738,739,
            740,741,742,743,744,745,746,747,748,749,750,751,752,753,754,755: x.dataStrobe=True;
            758: x=workerAddr(32'h184,True,4'hf);
            759: x.dataStrobe=True;
            1019: x=grantPi(False,True);
            1020: x=plioInDefault();
            1023: x=grantPi(False,True);
            1024: x=plioInDefault();
            1027: x=grantPi(True,False);
            default: x=plioInDefault();
        endcase
    end
    return x;
endfunction

function QliIn qiFor(Bit#(16) c);
    QliIn q=qliInDefault();
    if(c<5) q=workerQi(c,False,32'h0000_0011);
    else if(c<10) q=workerQi(c-5,False,32'h0000_2233);
    else if(c<15) q=workerQi(c-10,False,32'h4455_6677);
    else if(c<20) q=workerQi(c-15,True,0);
    else if(c<25) q=workerQi(c-20,True,0);
    else if(c<30) q=workerQi(c-25,True,0);
    else if(c<36) q=notificationQi(c-30,0);
    else if(c<42) q=notificationQi(c-36,1);
    else if(c<48) q=notificationQi(c-42,2);
    else if(c<54) q=notificationQi(c-48,3);
    else if(c==55 || c==56 || c==57 || c==58) begin q=notifReq(2); q.dmaRequestValid=True; q.dmaRequest=DmaRequest{direction:HostToDevice,address:32'h3300_0000,words:BurstOne}; end
    else if(c==59 || c==60 || c==61) q=dmaReq(HostToDevice,32'h3300_0000,BurstOne);
    else if(c<70) q=h2dQi(c-63,1,32'h4000_1000,BurstOne);
    else if(c<83) q=h2dQi(c-70,4,32'h4000_2000,BurstFour);
    else if(c<104) q=h2dQi(c-83,8,32'h4000_3000,BurstEight);
    else if(c<141) q=h2dQi(c-104,16,32'h4000_4000,BurstSixteen);
    else if(c<148) q=d2hQi(c-141,1,32'h5000_1000,BurstOne);
    else if(c<161) q=d2hQi(c-148,4,32'h5000_2000,BurstFour);
    else if(c<182) q=d2hQi(c-161,8,32'h5000_3000,BurstEight);
    else if(c<219) q=d2hQi(c-182,16,32'h5000_4000,BurstSixteen);
    else begin
        case(c)
            220,221,222,223: q=dmaReq(HostToDevice,32'h6000_1000,BurstOne);
            223: q.dmaCompletionReady=True;
            225,226,227,228: q=dmaReq(HostToDevice,32'h6000_2000,BurstOne);
            228: q.dmaCompletionReady=True;
            230,231,232,233,234: q=dmaReq(HostToDevice,32'h6000_3000,BurstOne);
            234: q.dmaCompletionReady=True;
            236,237,238,239,240,241,242,243,244,245,246,247,248,249,250,251,
            252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,
            268,269,270,271,272,273,274,275,276,277,278,279,280,281,282,283,
            284,285,286,287,288,289,290,291,292,293,294,295,296,297,298,299,
            300,301,302,303,304,305,306,307,308,309,310,311,312,313,314,315,
            316,317,318,319,320,321,322,323,324,325,326,327,328,329,330,331,
            332,333,334,335,336,337,338,339,340,341,342,343,344,345,346,347,
            348,349,350,351,352,353,354,355,356,357,358,359,360,361,362,363,
            364,365,366,367,368,369,370,371,372,373,374,375,376,377,378,379,
            380,381,382,383,384,385,386,387,388,389,390,391,392,393,394,395,
            396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,411,
            412,413,414,415,416,417,418,419,420,421,422,423,424,425,426,427,
            428,429,430,431,432,433,434,435,436,437,438,439,440,441,442,443,
            444,445,446,447,448,449,450,451,452,453,454,455,456,457,458,459,
            460,461,462,463,464,465,466,467,468,469,470,471,472,473,474,475,
            476,477,478,479,480,481,482,483,484,485,486,487,488,489,490,491,
            492,493,494,495: begin q=dmaReq(DeviceToHost,32'h6000_4000,BurstOne); if(c==495) q.dmaCompletionReady=True; end
            499: q.mmioReady=True;
            760,761,762,763,764,765,766,767,768,769,770,771,772,773,774,775,
            776,777,778,779,780,781,782,783,784,785,786,787,788,789,790,791,
            792,793,794,795,796,797,798,799,800,801,802,803,804,805,806,807,
            808,809,810,811,812,813,814,815,816,817,818,819,820,821,822,823,
            824,825,826,827,828,829,830,831,832,833,834,835,836,837,838,839,
            840,841,842,843,844,845,846,847,848,849,850,851,852,853,854,855,
            856,857,858,859,860,861,862,863,864,865,866,867,868,869,870,871,
            872,873,874,875,876,877,878,879,880,881,882,883,884,885,886,887,
            888,889,890,891,892,893,894,895,896,897,898,899,900,901,902,903,
            904,905,906,907,908,909,910,911,912,913,914,915,916,917,918,919,
            920,921,922,923,924,925,926,927,928,929,930,931,932,933,934,935,
            936,937,938,939,940,941,942,943,944,945,946,947,948,949,950,951,
            952,953,954,955,956,957,958,959,960,961,962,963,964,965,966,967,
            968,969,970,971,972,973,974,975,976,977,978,979,980,981,982,983,
            984,985,986,987,988,989,990,991,992,993,994,995,996,997,998,999,
            1000,1001,1002,1003,1004,1005,1006,1007,1008,1009,1010,1011,1012,
            1013,1014,1015: q=qliInDefault();
            1017,1018,1019,1020,1021,1022,1023,1024,1025,1026,1027: q=notifReq(3);
            default: begin end
        endcase
    end
    return q;
endfunction

function Bit#(2) mmioKind(QliIn q);
    Bit#(2) k=0;
    if(q.mmioResponseValid) begin
        case(q.mmioResponse.status)
            MmioReadOk: k=1;
            MmioWriteOk: k=2;
            MmioError: k=3;
        endcase
    end
    return k;
endfunction
function Bit#(32) mmioData(QliIn q); return q.mmioResponseValid ? q.mmioResponse.data : 0; endfunction
function Bit#(2) dmaDir(DmaDirection d); return d==HostToDevice ? 0 : 1; endfunction
function Bit#(8) dmaStatus(DmaStatus s);
    Bit#(8) r=0;
    case(s) DmaOk:r=0; DmaBusError:r=1; DmaParityError:r=2; DmaTimeout:r=3; DmaProtocolError:r=4; endcase
    return r;
endfunction

function Action emitTrace(Bit#(16) c, PlioIn pi, QliIn qi, PlioOut po, QliOut qo);
 action
    Bit#(32) cc=zeroExtend(c);
    Bit#(32) pia=pi.adValid ? pi.ad : 0; Bit#(4) pip=pi.parValid ? pi.parity : 0;
    Bit#(32) poa=po.adValid ? po.ad : 0; Bit#(4) pop=po.parValid ? po.parity : 0;
    $display("TRACE|v2|c=%08x|pi=%0d.%0d.%0d.%0d.%08x.%0d.%01x.%0d.%01x.%0d.%0d.%01x.%01x.%0d.%0d.%0d|qi=%0d.%0d.%0d.%08x.%0d.%0d.%08x.%0d.%0d.%0d.%08x.%0d.%0d.%02x|po=%0d.%0d.%08x.%0d.%01x.%0d.%01x.%0d.%0d.%01x.%01x.%0d.%0d.%0d|qo=%0d.%0d.%08x.%0d.%01x.%08x.%0d.%0d.%0d.%0d.%08x.%0d.%0d.%02x.%01x.%0d|ev=phase8",
      cc,
      pack(pi.reset),pack(pi.selected),pack(pi.grant),pack(pi.adValid),pia,pack(pi.parValid),pip,pack(pi.spaceValid),pack(pi.space),pack(pi.addressStrobe),pack(pi.read),pi.byteEnable,pack(pi.burst),pack(pi.dataStrobe),pack(pi.ack),pack(pi.err),
      pack(qi.mmioReady),pack(qi.mmioResponseValid),mmioKind(qi),mmioData(qi),pack(qi.dmaRequestValid),dmaDir(qi.dmaRequest.direction),qi.dmaRequest.address,pack(qi.dmaRequest.words),pack(qi.dmaReadReady),pack(qi.dmaWriteValid),qi.dmaWrite.data,pack(qi.dmaCompletionReady),pack(qi.notificationValid),qi.notification.channel,
      pack(po.request),pack(po.adValid),poa,pack(po.parValid),pop,pack(po.spaceValid),pack(po.space),pack(po.addressStrobe),pack(po.read),po.byteEnable,pack(po.burst),pack(po.dataStrobe),pack(po.ack),pack(po.err),
      pack(qo.reset),pack(qo.mmioRequestValid),qo.mmioRequest.address,pack(qo.mmioRequest.write),qo.mmioRequest.byteEnable,qo.mmioRequest.writeData,pack(qo.mmioResponseReady),pack(qo.mmioCancel),pack(qo.dmaRequestReady),pack(qo.dmaReadValid),qo.dmaRead.data,pack(qo.dmaWriteReady),pack(qo.dmaCompletionValid),dmaStatus(qo.dmaCompletion.status),qo.dmaCompletion.wordsCompleted,pack(qo.notificationReady));
 endaction
endfunction

module mkTbQICPhase8(Empty);
    PLIOQICIfc dut <- mkPLIOQIC;
    Reg#(Bit#(16)) c <- mkReg(0);
    rule run;
        PlioIn pi=piFor(c); QliIn qi=qiFor(c); PlioOut po=dut.drivePlio(pi,qi); QliOut qo=dut.driveQli(pi,qi);
        emitTrace(c,pi,qi,po,qo);
        dut.advance(pi,qi);
        if(c==1027) begin $display("PASS QIC Phase8 unified conformance fixture"); $finish(0); end
        else c<=c+1;
    endrule
endmodule

endpackage
