# Memory Controller TODO

- [ ] MC1 — define host/backend contract and one-outstanding transaction state machine.
- [ ] MC2 — implement Rust controller, pluggable backend trait, and fake RAM backend.
- [ ] MC3 — implement matching Bluespec controller and fake RAM backend.
- [ ] MC4 — exact Rust ↔ Bluesim controller differential trace.
- [ ] MC5 — integrate real `PLIOHostCore` DMA through controller + fake RAM in Rust and Bluespec.
- [ ] MC6 — generate `mkMemoryController` Verilog and prove Yosys synthesis with zero inferred memories.
- [ ] MC7 — wire the complete gate into normal hardware CI and merge only after the final branch head is green.
