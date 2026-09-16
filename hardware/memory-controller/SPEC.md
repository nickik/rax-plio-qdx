# RAX Memory Controller

## Scope

The memory controller is the boundary between RAX host-side memory clients and physical memory. It deliberately does **not** embed a particular RAM implementation.

```text
CPU / other host                         PLIOHostCore
       |                                      |
       | address + write data + BE[3:0]       | full 32-bit DMA, BE=1111
       +------------------+-------------------+
                          v
                   MemoryController
                          |
                          | write + address + BE[3:0] + write_data
                          v
              pluggable memory backend
              +---- BlockRamBackend         (default system + simulation backend, 1 MiB)
              +---- FakeMemoryBackend       (reference/differential testing only)
              +---- SRAM backend            (later)
              +---- SDR/SDRAM backend       (later)
              +---- DDR3/DDR4 adapter       (later)
```

Mainboard/CPU wiring is outside this component's scope. This contract defines what such clients must supply to `MemoryController`.

## Host-side contract

The controller accepts one aligned 32-bit request at a time. A request contains `write`, 32-bit physical `address`, 4-bit `byteEnable` (`BE[3:0]`), and 32-bit `writeData`.

Byte lanes are little-endian and map directly:

- `BE[0]` -> `writeData[7:0]`;
- `BE[1]` -> `writeData[15:8]`;
- `BE[2]` -> `writeData[23:16]`;
- `BE[3]` -> `writeData[31:24]`.

Write semantics are `new_byte = enabled ? write_byte : old_byte`. Therefore `BE=0000` is a successful no-op, `BE=1111` is a full-word write, and non-contiguous masks such as `0101` and `1010` are valid. For example, old `0x11223344`, write data `0xAABBCCDD`, `BE=0101` produces `0x11BB33DD`.

Reads always return the complete aligned 32-bit word; the request BE does not mask read data. PLIO DMA remains a full-word interface and is adapted to `BE=1111` for every MemoryController request.

Protocol requirements:

- addresses are 32-bit and 4-byte aligned;
- at most one controller transaction is outstanding;
- address, write flag, byte enable and write data remain stable for the entire backend-backpressure interval until acceptance;
- a response remains stable until the host consumes it;
- malformed/mismatched backend responses become a memory fault;
- backend faults propagate to the host independent of BE value;
- controller reset clears controller-owned request/response state and does not expose a later stale backend completion as a host response;
- coordinated controller/backend reset cancels an in-flight hardware transaction;
- memory-range and device-specific errors are backend policy and return `Fault`.

The controller performs no read-modify-write to implement byte enables. A backend without native write strobes may implement RMW internally below the backend boundary. The controller itself contains no memory array and must synthesize without inferred RAM.

## Backend-side contract

All physical backends use the same semantic handshake:

- `request_ready`;
- request `{ write, address, byte_enable, write_data }`;
- response `{ fault, read_data_valid, read_data }`;
- `response_consumed`;
- backend reset.

The backend owns latency, capacity, physical-device timing, write-strobe implementation and range faults. `MemoryController` does not change when the physical memory implementation changes.

## FPGA block RAM backend

`BlockRamBackend.bsv` is the default system memory backend and the default Bluesim memory implementation.

- 32-bit logical words implemented as **four independent 8-bit BRAM lanes**;
- each `BE` bit directly controls the corresponding physical byte lane;
- `BE=0000` writes no lane;
- independent lane writes and non-contiguous `0101` / `1010` writes are supported without controller-visible RMW;
- **1 MiB default capacity** (262144 32-bit words);
- synchronous BRAM read latency;
- one outstanding transaction with real ready/response backpressure;
- aligned in-range accesses only; out-of-range requests return `Fault`;
- reset cancels protocol state but does not erase RAM contents;
- uses BSC `BRAMCore`; Yosys `memory_collect` must expose four 8-bit `$mem_v2` lane memories of the expected size, and the iCE40 synthesis gate must map storage to native `SB_RAM40_4K` cells.

Hardware sizing is an elaboration-time choice:

- `mkDefaultBlockRamBackend` — **1 MiB** (system and simulation default);
- `mkBlockRamBackend1MiB` — explicit 1 MiB;
- `mkBlockRamBackend128KiB` — explicit 128 KiB;
- `mkBlockRamBackend64KiB` — explicit 64 KiB;
- `mkBlockRamBackend(bytes)` — underlying constructor, intended for capacities up to 1 MiB with the current 18-bit word address.

The default is a build/elaboration choice rather than a runtime mux: only the selected memory implementation consumes FPGA resources. A physical FPGA selected for the 1 MiB configuration therefore needs at least 8 Mbit of usable embedded RAM. The CI iCE40 synthesis step proves native block-RAM mapping; it is not a device-capacity/place-and-route guarantee for a specific iCE40 part.

## Simulation policy

Normal Bluesim integration uses the same 1 MiB `BlockRamBackend` intended for FPGA hardware:

```text
PLIOHostCore -> MemoryController -> mkDefaultBlockRamBackend (1 MiB)
```

The Rust `FakeMemory` and Bluespec `FakeMemoryBackend` are independent semantic/reference implementations used for exact differential testing. They are not the default simulated machine memory.

## Reset and stale completions

Reset is a protocol boundary. Tests explicitly cover reset after a masked request has been accepted by the backend. If that old backend operation later completes while the reset controller is idle, the stale completion must not become a host response. A complete hardware reset should reset both controller and backend so the backend also cancels its protocol state.

## External-memory path

SRAM, SDR/SDRAM and DDR3/DDR4 are separate backend modules implementing the same request/response contract. Their PHY/device-specific state machines remain below this boundary; PLIO and `MemoryController` must not learn device timing details. A backend may use native byte strobes or internal RMW, but externally observed semantics must match this specification.

## Acceptance gate

The frozen MemoryController implementation is accepted only when one exact SHA passes the complete component gate:

1. Rust controller and fake-backend reference tests, including exhaustive all-16-mask masked-write semantics.
2. Bluespec controller tests and exact Rust/Bluesim controller differential.
3. Exact Rust/Bluesim backend differential, including request stability through backpressure.
4. Exhaustive 16-mask controller-to-backend semantic differential with full-word readback.
5. Arbitrary-BE backend fault propagation.
6. Reset after an accepted masked request and isolation of a deliberately delayed stale backend completion.
7. `PLIOHostCore -> MemoryController -> mkDefaultBlockRamBackend` DMA read/write/fault integration with explicit `BE=1111`.
8. Generated standalone `mkMemoryController` Verilog passes Yosys with zero inferred memories.
9. BRAM semantics cover `BE=0000`, each individual lane, non-contiguous `0101` and `1010`, read/write, reset/recovery and range faults.
10. Default 1 MiB and alternative 128 KiB BRAM configurations infer exactly four 8-bit `$mem_v2` lane memories with the expected per-lane size/capacity.
11. Dedicated iCE40 synthesis maps the integrated BRAM backend to native `SB_RAM40_4K` cells.

MainboardFPGA tests are intentionally not part of this component acceptance gate; Mainboard integration is a separate follow-on stage.
