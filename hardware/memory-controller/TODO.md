# Memory Controller TODO

## Completed reference/controller foundation

- [x] MC1 — define host/backend contract and one-outstanding transaction state machine.
- [x] MC2 — implement Rust controller, pluggable backend trait, and fake RAM backend.
- [x] MC3 — implement matching Bluespec controller and fake RAM backend.
- [x] MC4 — exact Rust ↔ Bluesim controller differential trace.
- [x] MC5 — integrate `PLIOHostCore` DMA through controller + fake RAM in Rust and Bluespec as an independent semantic reference.
- [x] MC6 — generate `mkMemoryController` Verilog and prove Yosys synthesis with zero inferred memories.
- [x] MC7 — wire the complete gate into normal hardware CI.

## FPGA memory

- [x] MC8a — synthesizable 32-bit BRAM backend with 1 MiB system/simulation default and explicit 64 KiB / 128 KiB alternatives.
- [x] MC8b — prove one-cycle synchronous reads, handshake/backpressure, range faults, RAW, multiple addresses and reset/recovery.
- [x] MC8c — prove Yosys native FPGA BRAM inference while `mkMemoryController` stays at zero inferred RAM.
- [x] MC8d — run `PLIOHostCore -> MemoryController -> BlockRamBackend` DMA read/write/fault integration with the same semantic vectors as the reference backend.
- [x] MC8e — make the 1 MiB integrated BRAM backend the normal Bluesim memory path; fake RAM remains reference/differential infrastructure only.

## External memory later

- [ ] MC9a — asynchronous/synchronous SRAM backend.
- [ ] MC9b — SDR/SDRAM backend including refresh and timing state.
- [ ] MC9c — DDR3/DDR4 controller adapter; keep PHY/training below the backend boundary.
- [ ] MC9d — board/mainboard configuration selects one physical backend at elaboration/build time without changing PLIO or the controller; integrated 1 MiB BRAM remains the default when no external-memory backend is selected.
