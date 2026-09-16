# Memory Controller TODO

## Completed reference/controller foundation

- [x] MC1 — define host/backend contract and one-outstanding transaction state machine.
- [x] MC2 — implement Rust controller, pluggable backend trait, and fake RAM backend.
- [x] MC3 — implement matching Bluespec controller and fake RAM backend.
- [x] MC4 — exact Rust ↔ Bluesim controller differential trace.
- [x] MC5 — integrate real `PLIOHostCore` DMA through controller + fake RAM in Rust and Bluespec.
- [x] MC6 — generate `mkMemoryController` Verilog and prove Yosys synthesis with zero inferred memories.
- [x] MC7 — wire the complete gate into normal hardware CI.

## FPGA memory

- [x] MC8a — synthesizable 32-bit BRAM backend, default 64 KiB with 128 KiB option.
- [x] MC8b — prove one-cycle synchronous reads, handshake/backpressure, range faults, RAW, multiple addresses and reset/recovery.
- [x] MC8c — prove Yosys native FPGA BRAM inference while `mkMemoryController` stays at zero inferred RAM.
- [x] MC8d — run `PLIOHostCore -> MemoryController -> BlockRamBackend` DMA read/write/fault integration with the same semantic vectors as the fake backend.

## External memory later

- [ ] MC9a — asynchronous/synchronous SRAM backend.
- [ ] MC9b — SDR/SDRAM backend including refresh and timing state.
- [ ] MC9c — DDR3/DDR4 controller adapter; keep PHY/training below the backend boundary.
- [ ] MC9d — board/mainboard configuration selects one physical backend at elaboration/build time without changing PLIO or the controller.
