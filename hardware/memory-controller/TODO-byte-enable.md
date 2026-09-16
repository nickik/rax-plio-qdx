# MemoryController byte-enable TODO

Scope: MemoryController and its backends/tests only. Do not modify `hardware/mainboard-fpga`.

## Implementation

- [x] Add a 4-bit byte-enable field to the Rust controller-owned request model.
- [x] Define exact little-endian lane semantics; reads still return the complete 32-bit word.
- [x] Keep PLIO DMA full-word by adapting PLIO requests to BE=1111.
- [x] Propagate BE through the Bluespec MemoryController/backend boundary.
- [x] Keep address, write data and BE stable until backend acceptance under backpressure.
- [x] Implement masked writes in the fake/reference backend, including BE=0000 and all 16 masks.
- [x] Propagate backend faults with arbitrary/non-contiguous BE.
- [x] Verify reset after an accepted masked request.
- [x] Verify a deliberately delayed stale backend completion after controller reset cannot become a host response.
- [x] Implement FPGA BRAM as four independently write-enabled 8-bit lanes, without controller-visible RMW.
- [x] Verify BRAM BE=0000 performs no lane write.
- [x] Verify each of the four BRAM lanes independently.
- [x] Verify non-contiguous BRAM strobes 0101 and 1010.

## Differential and integration proof

- [x] Exact Rust/Bluesim controller differential.
- [x] Exact Rust/Bluesim backend differential.
- [x] Exhaustive all-16-BE controller-to-backend differential with full-word readback.
- [x] PLIO -> MemoryController -> default BRAM integration with PLIO BE=1111.
- [x] Standalone MemoryController synthesis proves zero inferred RAM.
- [x] Default 1 MiB and alternative 128 KiB BRAM configurations infer four 8-bit `$mem_v2` lane memories with expected sizing.
- [x] Native iCE40 synthesis maps the BRAM backend to `SB_RAM40_4K` cells.

## Freeze / merge

- [x] Finalize `SPEC.md` to describe the contract proven by the tests.
- [x] Phase 1 backend propagation/backpressure gate green.
- [x] Phase 2 exhaustive semantics/fault/reset/stale-completion gate green.
- [x] Phase 3 physical BRAM semantics and synthesis gate green.
- [ ] Require the complete MemoryController gate green on the exact final documentation SHA.
- [ ] Mark PR #33 ready and merge to `main` only after that exact-head gate is green.
- [ ] Retire temporary MemoryController branches after merge.

`mainboard-fpga` byte-enable wiring and its currently independent regressions are explicitly deferred to the Mainboard integration stage and are not blockers for this component freeze.
