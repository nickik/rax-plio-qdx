package LightingMemoryBusCompat;

// Compatibility copy of the LightingChips logical memory-bus boundary.
// Keep this package small and replace it with a shared dependency once the
// cross-repository hardware dependency is stable.

typedef struct {
    Bit#(32) addr;
    Bit#(32) writeData;
    Bit#(4)  byteEnable;
    Bool     write;
} LightingBusPayload deriving (Bits, Eq, FShow);

typedef struct {
    Bool     busGrant;
    Bool     ready;
    Bool     error;
    Bit#(32) readData;
} LightingBusInputs deriving (Bits, Eq, FShow);

// Aggregate of the signals driven by LightingMemoryBusMaster.  The real
// LightingChips interface exposes these as methods; this aggregate is useful
// at the mainboard FPGA composition boundary.
typedef struct {
    Bool busRequest;
    Bool request;
    LightingBusPayload payload;
} LightingBusMasterDrive deriving (Bits, Eq, FShow);

typedef struct {
    Bool plioIrq;
    Bool timerIrq;
    Bool machineFault;
} LightingModuleInterrupts deriving (Bits, Eq, FShow);

function LightingBusPayload lightingBusPayloadDefault();
    return LightingBusPayload {
        addr: 0,
        writeData: 0,
        byteEnable: 0,
        write: False
    };
endfunction

function LightingBusInputs lightingBusInputsDefault();
    return LightingBusInputs {
        busGrant: False,
        ready: False,
        error: False,
        readData: 0
    };
endfunction

function LightingBusMasterDrive lightingBusMasterDriveDefault();
    return LightingBusMasterDrive {
        busRequest: False,
        request: False,
        payload: lightingBusPayloadDefault()
    };
endfunction

function LightingModuleInterrupts lightingModuleInterruptsDefault();
    return LightingModuleInterrupts {
        plioIrq: False,
        timerIrq: False,
        machineFault: False
    };
endfunction

endpackage
