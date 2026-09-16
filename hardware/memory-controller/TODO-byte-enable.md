# Memory Controller Byte-Enable Milestone TODO

## Goal

Make `hardware/memory-controller` the authoritative byte-enable-aware memory subsystem shared by CPU and PLIO paths, and make `hardware/mainboard-fpga` pass CPU byte enables through unchanged.

This milestone is entirely upstream in `rax-plio-qdx`. Do **not** modify `LightingSimulation` as part of this work. `LightingSimulation` should only consume and verify the finished upstream behavior later.

## Target architecture

```text
SoftwareCpuBoard / future LightingComputeBoard
                 |
       ADDR + WRITE_DATA + BE[3:0]
                 |
                 v
          MainboardFPGA
                 |
                 v
          MemoryController
     write/address/data/byteEnable
                 |
                 v
        pluggable memory backend
        |- FPGA BRAM
        |- simulator RAM
        |- SRAM/SDRAM/DDR
        `- file-backed simulation
```

## Acceptance contract

The authoritative host request contract should carry byte enable explicitly:

```text
hostRequest(
    Bool write,
    Bit#(32) address,
    Bit#(4) byteEnable,
    Bit#(32) writeData
)
```

The memory controller must retain and expose the request mask to the active backend:

```text
backendWrite
backendAddress
backendByteEnable
backendWriteData
```

CPU requests preserve their original `BE[3:0]` value. PLIO DMA remains full-word only and must enter the shared controller with `byteEnable = 4'hf`.

## 1. Rust memory-controller request model

- [ ] Stop using `plio_host_dma_model::MemoryRequest` as the internal general memory-controller request type.
- [ ] Define a memory-controller-owned request type carrying at least:
  - [ ] `physical_address: u32`
  - [ ] `write: bool`
  - [ ] `byte_enable: u8`
  - [ ] `write_data: u32`
- [ ] Keep the byte enable constrained to the low four bits.
- [ ] Define and document read semantics for `byte_enable` so Rust and Bluespec agree exactly.
- [ ] Adapt the CPU-facing path to pass the real byte enable unchanged.
- [ ] Adapt the PLIO DMA path to generate `byte_enable = 0x0f` without changing the PLIO DMA protocol itself.
- [ ] Preserve existing alignment/full-beat validation for PLIO DMA.
- [ ] Add unit tests for request construction and PLIO-to-memory-controller adaptation.

## 2. Rust reference backend masked-write semantics

- [ ] Implement one canonical masked-write helper in the memory-controller model.
- [ ] Verify byte-lane mapping:
  - [ ] `BE[0]` updates bits `[7:0]`
  - [ ] `BE[1]` updates bits `[15:8]`
  - [ ] `BE[2]` updates bits `[23:16]`
  - [ ] `BE[3]` updates bits `[31:24]`
- [ ] Verify `BE = 0000` leaves memory unchanged.
- [ ] Verify `BE = 1111` exactly matches current whole-word behavior.
- [ ] Test every single-byte mask.
- [ ] Test every two-byte mask, including non-contiguous masks such as `0101` and `1010`.
- [ ] Test three-byte masks.
- [ ] Test all 16 mask values exhaustively.
- [ ] Test consecutive masked writes to the same word.
- [ ] Test masked write followed by full-word read.
- [ ] Test full-word write followed by masked overwrite.
- [ ] Test multiple addresses so lane merging cannot leak across words.
- [ ] Retain existing backend backpressure/fault/reset tests with byte-enable requests included.

Example required behavior:

```text
old word  = 11 22 33 44
writeData = AA BB CC DD
BE        = 0101
```

Only lanes 0 and 2 are updated.

## 3. Bluespec MemoryController interface

- [ ] Change `MemoryControllerIfc.hostRequest()` to accept `Bit#(4) byteEnable`.
- [ ] Add storage for the byte enable alongside pending write/address/data state.
- [ ] Expose the current mask to the backend as `backendByteEnable` or an equivalent typed request field.
- [ ] Ensure byte enable remains stable for the full lifetime of an outstanding backend request.
- [ ] Ensure reset clears any pending request/mask state and cannot leak a stale masked write afterward.
- [ ] Preserve current ready/valid/backpressure behavior.
- [ ] Preserve current fault propagation behavior.
- [ ] Update all direct users/testbenches of `hostRequest()`.

## 4. Bluespec backend contract

- [ ] Extend the backend request contract from `(write, address, writeData)` to also carry `byteEnable`.
- [ ] Update simulator/fake RAM backends to merge selected byte lanes only.
- [ ] Keep read behavior unchanged unless the existing interface requires otherwise.
- [ ] Document that backends lacking native byte strobes may use an internal RMW operation.
- [ ] Keep any such RMW entirely inside the backend adapter; it must not be visible to `MainboardFPGA`, the CPU board, or `LightingSimulation`.

## 5. FPGA BlockRamBackend

Preferred implementation: four independent 8-bit RAM lanes.

```text
BE[0] -> RAM byte lane 0
BE[1] -> RAM byte lane 1
BE[2] -> RAM byte lane 2
BE[3] -> RAM byte lane 3
```

- [ ] Replace the current whole-word-only BRAM write implementation with four byte-wide banks or an equivalent synthesis-friendly masked-write implementation.
- [ ] Read all four lanes and combine them into one 32-bit word.
- [ ] Independently assert each lane's write enable from `BE[3:0]`.
- [ ] Verify no externally visible read-modify-write transaction is introduced.
- [ ] Run synthesis/elaboration checks and confirm the implementation still infers RAM rather than registers.
- [ ] Record inferred memory resources in the test/CI output if practical.

## 6. MainboardFPGA integration

- [ ] Pass `cpu.payload.byteEnable` unchanged into `MemoryController.hostRequest()`.
- [ ] Pass `4'hf` for PLIO DMA requests entering the memory controller.
- [ ] Remove `rejectPartialCpu`.
- [ ] Remove the `byteEnable == 4'hf` qualification from `startCpuMemoryTransaction`.
- [ ] Remove the temporary partial-access error from `lightingMemory()`.
- [ ] Keep CPU-vs-PLIO memory arbitration semantics unchanged apart from carrying the mask.
- [ ] Verify CPU byte enables are not transformed, widened, or discarded.
- [ ] Verify PLIO cannot accidentally create partial writes.

## 7. Mainboard specification

- [ ] Update `hardware/mainboard-fpga/SPEC.md` to state that CPU memory requests support masked byte writes through `BE[3:0]`.
- [ ] State explicitly that PLIO DMA uses aligned full 32-bit beats and supplies `BE = 1111` internally.
- [ ] Document byte-lane ordering.
- [ ] Document backend responsibility for native masks versus internal RMW.
- [ ] Remove any statement that partial CPU accesses are unsupported.

## 8. Rust <-> Bluespec conformance

- [ ] Add an exact Rust/Bluespec request trace format including byte enable.
- [ ] Compare Rust and Bluespec behavior for all 16 masks.
- [ ] Compare resulting memory contents after mixed masked/full writes.
- [ ] Include multiple addresses.
- [ ] Include read-after-write cases.
- [ ] Include consecutive writes without idle gaps where permitted by the interface.
- [ ] Include backend backpressure.
- [ ] Include backend fault propagation.
- [ ] Include reset while idle.
- [ ] Include reset while a request is outstanding.
- [ ] Prove no stale response or stale masked write appears after reset.

## 9. Mainboard integration tests

- [ ] CPU full-word write/read through `MainboardFPGA`.
- [ ] CPU byte write for each lane through `MainboardFPGA`.
- [ ] CPU halfword-style masks for low/high halves.
- [ ] CPU non-contiguous masks to prove the interface is truly mask-based rather than size-based.
- [ ] CPU masked write followed by readback.
- [ ] CPU masked writes interleaved with PLIO DMA full-word operations.
- [ ] PLIO DMA regression proving all existing full-word behavior remains unchanged.
- [ ] Arbitration regression proving byte-enable support does not alter CPU/PLIO ownership or completion sequencing.
- [ ] Fault and reset regressions through the full mainboard path.

## 10. Compatibility and cleanup

- [ ] Search the repository for every `hostRequest` call and backend request implementation and migrate them together.
- [ ] Search for every assumption that memory writes are necessarily full-word.
- [ ] Remove obsolete partial-access rejection code rather than retaining dead compatibility branches.
- [ ] Keep PLIO protocol models full-word where that is their actual contract; do not generalize PLIO just because the shared memory controller is byte-aware.
- [ ] Do not add a workaround to `SoftwareCpuBoard` or any future hardware CPU board.
- [ ] Do not add a workaround or implementation change to `LightingSimulation`.

## 11. Validation gate

Before this milestone is considered complete, require one exact commit SHA where all of the following pass:

- [ ] Rust memory-controller unit tests.
- [ ] Exhaustive Rust masked-write tests.
- [ ] Bluespec `MemoryController` compile/elaboration.
- [ ] Bluespec fake/simulator backend tests.
- [ ] FPGA BRAM backend masked-write tests.
- [ ] Rust <-> Bluespec exact differential tests.
- [ ] Mainboard CPU byte/halfword/word integration tests.
- [ ] Mainboard CPU/PLIO arbitration regressions.
- [ ] PLIO DMA regressions.
- [ ] Fault propagation tests.
- [ ] Reset/outstanding-request tests.
- [ ] Synthesis/inference check for the BRAM backend.
- [ ] Existing repository regression suite relevant to memory-controller and mainboard-fpga.

Do not mark the milestone complete based on isolated unit tests if the shared `MainboardFPGA -> MemoryController -> backend` path has not passed.

## Explicit non-goals for this branch

- Changing `LightingSimulation`.
- Changing CPU architecture or teaching the CPU board to emulate partial writes.
- Making PLIO DMA byte-granular.
- Moving backend-specific RMW behavior into the shared memory controller unless the backend contract itself requires that implementation.
- Implementing full `SoftwareCpuBoard -> MainboardFPGA` program execution in `LightingSimulation`; that comes only after this upstream milestone is merged and consumed.
