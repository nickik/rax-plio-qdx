# MemoryController byte-enable TODO

Scope: MemoryController and its backends/tests only. Do not modify `hardware/mainboard-fpga`.

- [x] Add a 4-bit byte-enable field to the Rust controller-owned request model.
- [x] Define exact lane semantics; reads still return the complete 32-bit word.
- [x] Keep PLIO DMA full-word by adapting PLIO requests to BE=1111.
- [x] Propagate BE through the Bluespec MemoryController/backend boundary.
- [x] Implement masked writes in the fake/reference backend, including BE=0000 and all 16 masks.
- [x] Implement FPGA BRAM as four independently write-enabled 8-bit lanes, without controller-visible RMW.
- [x] Extend Rust and Bluesim controller/backend conformance traces for byte enables.
- [x] Extend PLIO -> MemoryController fake/BRAM integration while keeping PLIO BE=1111.
- [ ] Run focused Rust, Bluesim differential, backend and BRAM/synthesis gates on this clean branch.
- [ ] Run relevant full hardware regressions and require one exact green SHA before merge.
