# RAX Memory Controller

## Scope

The memory controller is the boundary between the RAX PLIO host and physical memory.
It deliberately does **not** embed a particular RAM implementation.

```text
PLIOHostCore
    |
    | Host memory request/response
    v
MemoryController
    |
    | Backend request/response
    +---- FakeMemoryBackend       (simulation/reference)
    +---- BlockRamBackend         (synthesizable FPGA BRAM; default hardware backend)
    +---- SRAM backend            (later)
    +---- SDR/SDRAM backend       (later)
    +---- DDR3/DDR4 adapter       (later)
```

## Host-side contract

The controller accepts one 32-bit request at a time:

- `Read32 { physical_address }`
- `Write32 { physical_address, value }`

Requirements:

- addresses are 32-bit and 4-byte aligned;
- at most one transaction is outstanding;
- a request remains stable until the backend accepts it;
- a response remains stable until the host consumes it;
- malformed/mismatched backend responses become a memory fault;
- controller reset isolates any stale backend response;
- coordinated controller/backend reset cancels an in-flight hardware transaction;
- memory-range and device-specific errors are backend policy and return `Fault`.

The controller itself contains no memory array and must synthesize without inferred RAM.

## Backend-side contract

All physical backends use the same semantic handshake:

- `request_ready`
- request `{ write, address, write_data }`
- response `{ fault, read_data_valid, read_data }`
- `response_consumed`
- backend reset

The backend owns latency, capacity, physical-device timing and range faults. `MemoryController` does not change when the physical memory implementation changes.

## FPGA block RAM backend

`BlockRamBackend.bsv` is the first real synthesizable memory backend.

- 32-bit words;
- synchronous one-cycle BRAM read latency;
- one outstanding transaction with real ready/response backpressure;
- aligned in-range accesses only; out-of-range requests return `Fault`;
- reset cancels protocol state but does not erase RAM contents;
- uses BSC `BRAMCore`, whose generated `BRAM1` storage is mapped by Yosys to native FPGA block-RAM cells.

Hardware sizing is an elaboration-time choice:

- `mkDefaultBlockRamBackend` — **64 KiB** (default);
- `mkBlockRamBackend64KiB` — explicit 64 KiB;
- `mkBlockRamBackend128KiB` — 128 KiB;
- `mkBlockRamBackend(bytes)` — underlying constructor, currently intended for capacities up to 128 KiB.

The default is deliberately a hardware build choice rather than a runtime mux: only the selected memory implementation should consume FPGA resources.

## External-memory path

SRAM, SDR/SDRAM and DDR3/DDR4 should be separate backend modules implementing the same request/response contract. Their PHY/device-specific state machines remain below this boundary; PLIO and `MemoryController` must not learn device timing details.

## Acceptance

1. Rust controller + fake backend unit tests.
2. Bluespec controller + fake backend tests.
3. Exact Rust/Bluesim controller and backend-sequence equivalence.
4. Real `PLIOHostCore` DMA read/write/fault integration through the controller.
5. Generated `mkMemoryController` Verilog passes Yosys with zero inferred memories.
6. FPGA BRAM backend passes write/read, RAW, multiple-address, reset/recovery and range-fault tests.
7. 64 KiB and 128 KiB configurations elaborate to the expected memory capacity.
8. Yosys maps the default backend to native FPGA BRAM cells while the standalone controller remains memory-free.
