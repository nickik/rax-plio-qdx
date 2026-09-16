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
    +---- FakeMemoryBackend (simulation / Rust)
    +---- FPGA external-memory backend (later)
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
- reset discards every in-flight request/response;
- memory-range and device-specific errors are backend policy and return `Fault`.

The controller itself contains no memory array and must synthesize without inferred RAM.

## Backend-side contract

The backend sees the same semantic operation but has independent backpressure:

- `request_ready`
- request `{ write, address, write_data }`
- response `{ fault, read_data_valid, read_data }`

This is intentionally small enough to bind to:

- the Rust fake-memory model;
- a Bluespec fake-memory model for Bluesim;
- an FPGA SRAM/SDRAM/DDR controller later;
- a board-specific bridge without changing PLIOHostCore or the memory controller.

## Acceptance

1. Rust controller + fake backend unit tests.
2. Bluespec controller + fake backend tests.
3. Exact Rust/Bluesim controller trace equivalence.
4. Real PLIOHostCore DMA read and write through the controller into fake RAM in both Rust and Bluespec.
5. Generated `mkMemoryController` Verilog passes Yosys and reports zero inferred memories.
