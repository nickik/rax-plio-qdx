package PLIOTx;

import PTIEncoding::*;

typedef enum {
    PtiQicToTx,
    PtiTxToQic
} PtiDirection deriving (Bits, Eq, FShow);

typedef struct {
    Bit#(2) space;
    Bool addressStrobe;
    Bool read;
    Bit#(4) byteEnable;
    Bit#(2) burstLen;
    Bool dataStrobe;
} BackplaneControl deriving (Bits, Eq, FShow);

typedef struct {
    Bit#(32) ad;
    Bit#(4) par;
    BackplaneControl control;
    Bool ack;
    Bool err;
    Bool selected;
    Bool grant;
    Bool externalAdParDrive;
    Bool externalControlDrive;
    Bool externalResponseDrive;
} BackplaneSample deriving (Bits, Eq, FShow);

typedef struct {
    PtiDirection direction;
    PtiToken token;
    Bool driveEnable;
    Bool responseEnable;
    Bool responseAck;
    Bool responseErr;
    Bool busRequest;
} QicPtiDrive deriving (Bits, Eq, FShow);

typedef struct {
    Bool adParValid;
    Bit#(32) ad;
    Bit#(4) par;
    Bool controlValid;
    BackplaneControl control;
    Bool responseValid;
    Bool ack;
    Bool err;
    Bool request;
} BackplaneDrive deriving (Bits, Eq, FShow);

typedef struct {
    Bool rxValid;
    PtiToken rxToken;
    Bool sampleAck;
    Bool sampleErr;
    Bool sampleSelected;
    Bool sampleGrant;
    Bool protocolFault;
    Bool contention;
} PtiObserve deriving (Bits, Eq, FShow);

function BackplaneControl backplaneControlDefault();
    return BackplaneControl {
        space: 0,
        addressStrobe: False,
        read: False,
        byteEnable: 0,
        burstLen: 0,
        dataStrobe: False
    };
endfunction

function BackplaneSample backplaneSampleDefault();
    return BackplaneSample {
        ad: 0,
        par: 0,
        control: backplaneControlDefault(),
        ack: False,
        err: False,
        selected: False,
        grant: False,
        externalAdParDrive: False,
        externalControlDrive: False,
        externalResponseDrive: False
    };
endfunction

function QicPtiDrive qicPtiDriveDefault();
    return QicPtiDrive {
        direction: PtiQicToTx,
        token: ptiToken(PtiIdle, 0, 0),
        driveEnable: False,
        responseEnable: False,
        responseAck: False,
        responseErr: False,
        busRequest: False
    };
endfunction

function BackplaneDrive backplaneDriveDefault();
    return BackplaneDrive {
        adParValid: False,
        ad: 0,
        par: 0,
        controlValid: False,
        control: backplaneControlDefault(),
        responseValid: False,
        ack: False,
        err: False,
        request: False
    };
endfunction

function PtiObserve ptiObserveDefault();
    return PtiObserve {
        rxValid: False,
        rxToken: ptiToken(PtiIdle, 0, 0),
        sampleAck: False,
        sampleErr: False,
        sampleSelected: False,
        sampleGrant: False,
        protocolFault: False,
        contention: False
    };
endfunction

function BackplaneControl driveControlImage(PtiControlImage c);
    return BackplaneControl {
        space: c.space,
        addressStrobe: c.addressStrobe,
        read: c.read,
        byteEnable: c.byteEnable,
        burstLen: c.burstLen,
        dataStrobe: c.dataStrobe
    };
endfunction

function PtiControlImage receiveControlImage(BackplaneControl c);
    return PtiControlImage {
        space: c.space,
        addressStrobe: c.addressStrobe,
        read: c.read,
        byteEnable: c.byteEnable,
        burstLen: c.burstLen,
        dataStrobe: c.dataStrobe,
        driveAdPar: False,
        driveControl: False
    };
endfunction

interface PLIOTxIfc;
    method BackplaneDrive driveBackplane(Bool reset, QicPtiDrive qic, BackplaneSample bus);
    method PtiObserve observeQic(Bool reset, QicPtiDrive qic, BackplaneSample bus);
    method Action advance(Bool reset, QicPtiDrive qic, BackplaneSample bus);
    method Bool debugControlValid;
    method PtiControlImage debugControl;
    method Bool debugDataValid;
    method Bit#(32) debugAd;
    method Bit#(4) debugPar;
    method Bool debugProtocolFault;
    method Bool debugContention;
endinterface

module mkPLIOTx(PLIOTxIfc);
    Reg#(Bool) controlValid <- mkReg(False);
    Reg#(PtiControlImage) controlReg <- mkReg(unpackControl(0));
    Reg#(Bool) dataValid <- mkReg(False);
    Reg#(Bit#(32)) dataReg <- mkReg(0);
    Reg#(Bit#(4)) parReg <- mkReg(0);

    Reg#(Bool) outLowPending <- mkReg(False);
    Reg#(Bit#(16)) outLowData <- mkReg(0);
    Reg#(Bit#(2)) outLowPar <- mkReg(0);

    Reg#(Bool) inSampleValid <- mkReg(False);
    Reg#(Bit#(32)) inSampleAd <- mkReg(0);
    Reg#(Bit#(4)) inSamplePar <- mkReg(0);
    Reg#(Bool) inLowPending <- mkReg(False);

    Reg#(Bool) directionValid <- mkReg(False);
    Reg#(PtiDirection) directionReg <- mkReg(PtiQicToTx);
    Reg#(Bool) previousSlotIdle <- mkReg(True);
    Reg#(Bool) driveActive <- mkReg(False);
    Reg#(Bool) protocolFaultReg <- mkReg(False);
    Reg#(Bool) contentionReg <- mkReg(False);

    function Bool directionIllegal(QicPtiDrive qic);
        return directionValid
            && qic.token.kind != PtiIdle
            && directionReg != qic.direction;
    endfunction

    function Bool driveRiseIllegal(QicPtiDrive qic);
        return qic.driveEnable && !driveActive && !previousSlotIdle;
    endfunction

    function Bool responseIllegal(QicPtiDrive qic);
        return qic.responseEnable && qic.responseAck && qic.responseErr;
    endfunction

    function Bool tokenIllegal(QicPtiDrive qic);
        if (directionIllegal(qic)) return True;

        if (qic.token.kind == PtiIdle) begin
            return outLowPending
                || inLowPending
                || (qic.direction == PtiQicToTx && qic.token.ptd != 0);
        end

        if (qic.direction == PtiQicToTx) begin
            case (qic.token.kind)
                PtiControl: return outLowPending || !validControlToken(qic.token);
                PtiDataLo: return outLowPending;
                PtiDataHi: return !outLowPending;
                default: return False;
            endcase
        end
        else begin
            case (qic.token.kind)
                PtiControl: return inLowPending;
                PtiDataLo: return inLowPending;
                PtiDataHi: return !inLowPending || !inSampleValid;
                default: return False;
            endcase
        end
    endfunction

    function BackplaneDrive computeDrive(QicPtiDrive qic);
        BackplaneDrive out = backplaneDriveDefault();
        out.request = qic.busRequest;

        Bool effectiveDrive = qic.driveEnable && !driveRiseIllegal(qic);
        if (effectiveDrive && controlValid) begin
            if (controlReg.driveControl) begin
                out.controlValid = True;
                out.control = driveControlImage(controlReg);
            end
            if (controlReg.driveAdPar && dataValid) begin
                out.adParValid = True;
                out.ad = dataReg;
                out.par = parReg;
            end
        end

        if (qic.responseEnable && !responseIllegal(qic)) begin
            out.responseValid = True;
            out.ack = qic.responseAck;
            out.err = qic.responseErr;
        end
        return out;
    endfunction

    function Bool missingControl(QicPtiDrive qic);
        return qic.driveEnable && !driveRiseIllegal(qic) && !controlValid;
    endfunction

    function Bool missingData(QicPtiDrive qic);
        return qic.driveEnable
            && !driveRiseIllegal(qic)
            && controlValid
            && controlReg.driveAdPar
            && !dataValid;
    endfunction

    function Bool contentionNow(QicPtiDrive qic, BackplaneSample bus);
        BackplaneDrive out = computeDrive(qic);
        return (out.adParValid && bus.externalAdParDrive)
            || (out.controlValid && bus.externalControlDrive)
            || (out.responseValid && bus.externalResponseDrive);
    endfunction

    method BackplaneDrive driveBackplane(Bool reset, QicPtiDrive qic, BackplaneSample bus);
        if (reset) return backplaneDriveDefault();
        return computeDrive(qic);
    endmethod

    method PtiObserve observeQic(Bool reset, QicPtiDrive qic, BackplaneSample bus);
        PtiObserve out = ptiObserveDefault();
        if (!reset) begin
            Bool dirBad = directionIllegal(qic);
            Bool currentFault = dirBad
                || driveRiseIllegal(qic)
                || responseIllegal(qic)
                || tokenIllegal(qic)
                || missingControl(qic)
                || missingData(qic);

            out.sampleAck = qic.responseEnable ? False : bus.ack;
            out.sampleErr = qic.responseEnable ? False : bus.err;
            out.sampleSelected = bus.selected;
            out.sampleGrant = bus.grant;
            out.protocolFault = protocolFaultReg || currentFault;
            out.contention = contentionReg || contentionNow(qic, bus);

            if (!dirBad && qic.direction == PtiTxToQic) begin
                case (qic.token.kind)
                    PtiControl: begin
                        out.rxValid = True;
                        out.rxToken = controlToken(receiveControlImage(bus.control));
                    end
                    PtiDataLo: begin
                        out.rxValid = True;
                        out.rxToken = ptiToken(PtiDataLo, bus.ad[15:0], bus.par[1:0]);
                    end
                    PtiDataHi: begin
                        if (inLowPending && inSampleValid) begin
                            out.rxValid = True;
                            out.rxToken = ptiToken(PtiDataHi, inSampleAd[31:16], inSamplePar[3:2]);
                        end
                    end
                    default: begin end
                endcase
            end
        end
        return out;
    endmethod

    method Action advance(Bool reset, QicPtiDrive qic, BackplaneSample bus);
        action
            if (reset) begin
                controlValid <= False;
                controlReg <= unpackControl(0);
                dataValid <= False;
                dataReg <= 0;
                parReg <= 0;
                outLowPending <= False;
                outLowData <= 0;
                outLowPar <= 0;
                inSampleValid <= False;
                inSampleAd <= 0;
                inSamplePar <= 0;
                inLowPending <= False;
                directionValid <= False;
                directionReg <= PtiQicToTx;
                previousSlotIdle <= True;
                driveActive <= False;
                protocolFaultReg <= False;
                contentionReg <= False;
            end
            else begin
                Bool prevIdle = previousSlotIdle;
                Bool prevDrive = driveActive;
                Bool dirBad = directionIllegal(qic);
                Bool currentFault = dirBad
                    || driveRiseIllegal(qic)
                    || responseIllegal(qic)
                    || tokenIllegal(qic)
                    || missingControl(qic)
                    || missingData(qic);
                Bool faultNext = protocolFaultReg || currentFault;

                if (qic.token.kind == PtiIdle) begin
                    if (outLowPending || inLowPending) faultNext = True;
                    outLowPending <= False;
                    inLowPending <= False;
                    inSampleValid <= False;
                    directionValid <= True;
                    directionReg <= qic.direction;
                    if (qic.direction == PtiQicToTx && qic.token.ptd != 0)
                        faultNext = True;
                end
                else if (dirBad) begin
                    outLowPending <= False;
                    inLowPending <= False;
                    inSampleValid <= False;
                end
                else begin
                    if (!directionValid) begin
                        directionValid <= True;
                        directionReg <= qic.direction;
                    end

                    if (qic.direction == PtiQicToTx) begin
                        case (qic.token.kind)
                            PtiControl: begin
                                if (outLowPending) begin
                                    faultNext = True;
                                    outLowPending <= False;
                                end
                                if (validControlToken(qic.token)) begin
                                    controlReg <= unpackControl(ptiData(qic.token));
                                    controlValid <= True;
                                end
                                else faultNext = True;
                            end
                            PtiDataLo: begin
                                if (outLowPending) faultNext = True;
                                outLowData <= ptiData(qic.token);
                                outLowPar <= ptiParity(qic.token);
                                outLowPending <= True;
                            end
                            PtiDataHi: begin
                                if (outLowPending) begin
                                    dataReg <= { ptiData(qic.token), outLowData };
                                    parReg <= { ptiParity(qic.token), outLowPar };
                                    dataValid <= True;
                                    outLowPending <= False;
                                end
                                else faultNext = True;
                            end
                            default: begin end
                        endcase
                    end
                    else begin
                        case (qic.token.kind)
                            PtiControl: begin
                                if (inLowPending) begin
                                    faultNext = True;
                                    inLowPending <= False;
                                    inSampleValid <= False;
                                end
                            end
                            PtiDataLo: begin
                                if (inLowPending) faultNext = True;
                                inSampleAd <= bus.ad;
                                inSamplePar <= bus.par;
                                inSampleValid <= True;
                                inLowPending <= True;
                            end
                            PtiDataHi: begin
                                if (inLowPending && inSampleValid)
                                    inLowPending <= False;
                                else begin
                                    faultNext = True;
                                    inSampleValid <= False;
                                end
                            end
                            default: begin end
                        endcase
                    end
                end

                protocolFaultReg <= faultNext;
                contentionReg <= contentionReg || contentionNow(qic, bus);
                previousSlotIdle <= qic.token.kind == PtiIdle;

                if (!qic.driveEnable)
                    driveActive <= False;
                else if (prevDrive)
                    driveActive <= True;
                else
                    driveActive <= prevIdle;
            end
        endaction
    endmethod

    method Bool debugControlValid = controlValid;
    method PtiControlImage debugControl = controlReg;
    method Bool debugDataValid = dataValid;
    method Bit#(32) debugAd = dataReg;
    method Bit#(4) debugPar = parReg;
    method Bool debugProtocolFault = protocolFaultReg;
    method Bool debugContention = contentionReg;
endmodule

endpackage
