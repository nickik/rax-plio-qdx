# PLIO hardware/interface validation TODO

Work top-to-bottom. Do not pull QDX or a production host controller into this effort.

## Immediate gated plan

### Gate A — direct test tooling — complete

- [x] Rust CI installs a stable Rust toolchain and runs the complete hardware workspace.
- [x] Pinned Bluespec CI installs BSC 2026.01 with checksum verification.
- [x] `make -C hardware test-rust` and `make -C hardware test-bluespec` are canonical entry points.
- [x] Cargo/rustc are available in the validation sandbox (`cargo 1.98.1`, `rustc 1.98.1`).
- [x] Direct sandbox run completed successfully for the pre-PTI/QLI-16 workspace: 41 tests passed, 0 failed.
- [x] Expanded PTI/QLI-16 Rust workspace is green in CI.

### Gate B — package, bandwidth, PTI and QLI-16 framing — complete for v0.1

- [x] Use a 64-pin QIC as the working target, with 84 pins only as an escape option.
- [x] Show that directly exposing all PLIO logical pins leaves no useful local-interface budget.
- [x] Use an 18-bit PTI datapath so each half-slot carries 16 data bits plus two PLIO parity bits.
- [x] Use a 16-bit QLI-16 datapath.
- [x] Updated working budget: PTI ~30 pins + QLI-16 ~22 + power/ground/test ~10 = ~62 pins, leaving two pins of margin.
- [x] PLIO-5 peak payload is 20 MB/s: one 32-bit beat per 200 ns.
- [x] Freeze two ordered PTI/QLI-16 transfer slots per 5 MHz PLIO period.
- [x] Do **not** define or require a second architectural 10 MHz clock. Historical logic may use phases; FPGA logic may use a faster internal clock with slot enables.
- [x] Freeze PTI v0.1 framing, reset/high-Z rules, parity transport, and turnaround rule.
- [x] Freeze QLI-16 v0.1 token framing.
- [x] Implement Rust PTI and QLI-16 encoders/tests.
- [x] Implement matching Bluespec PTI and QLI-16 encoding helpers/tests.
- [x] Automatically diff canonical Rust and Bluespec PTI/QLI-16 vectors in CI.

### Gate C — Rust reference behavior — complete

- [x] Implement semantic QLI types and handshakes in Rust.
- [x] Implement the Rust PLIO-QIC behavioral model for WORKER, HOST_DMA, and CONTROLLER/Notification transactions.
- [x] Implement Rust `NakedDevice` and compose `NakedCard = QIC + NakedDevice`.
- [x] Test complete PLIO -> QIC -> QLI -> NakedDevice worker read/write behavior.
- [x] Test legal 8/16/32-bit accesses and illegal/misaligned byte enables.
- [x] Test all 1/4/8/16-word DMA bursts in both directions.
- [x] Test waits, partial errors, parity faults, timeout, grant loss, reset, local producer backpressure, and Notification ordering/completion.
- [x] Keep QDX and production host-controller semantics out of the model.
- [ ] Optional/non-blocking: programmable pre-grant delay when arbitration-delay traces become useful.

### Gate D — QLI v0.1 — frozen

- [x] Freeze `hardware/qli/SPEC.md` from executable Rust behavior.
- [x] Freeze one-outstanding MMIO and one-outstanding DMA semantics.
- [x] Freeze MMIO, DMA stream, completion, Notification, reset, and scheduling behavior.
- [x] Keep QLI independent of slot IDs, CPU vectors, host physical addresses, QDX, and physical QLI-16 framing.
- [x] Local endpoint owns PLIO configuration contents for v0.1.

### Gate E — Bluespec QLI + NakedDevice — complete

- [x] Implement and simulate Bluespec QLI v0.1 types.
- [x] Implement Bluespec `NakedDevice`.
- [x] Test request/response backpressure and reset cancellation in Bluesim.
- [x] Compare canonical Rust and Bluespec NakedDevice MMIO vectors in CI.

### Gate F — implementation path selected

- [x] **Logic-first:** implement the QIC against abstract PLIO/QLI interfaces first.
- [x] Keep PTI and QLI-16 as separately tested boundary adapters.
- [x] Preserve the eventual target: complete QIC + PTI + QLI-16 implementation on iCE40 FPGA.

The next major implementation step is now the **Bluespec QIC core**, matched cycle-for-cycle/transaction-for-transaction against the existing Rust QIC reference model. Do not fold PTI or QLI-16 serialization into the QIC state machine.

---

## 0. Repository/bootstrap

- [x] Create hardware/interface validation tree.
- [x] Separate QLI, PTI, QLI-16, QIC, PLIO-TX, NakedCard, and testbench contracts.
- [x] Add Rust workspace and zero-dependency behavioral crates.
- [x] Add Bluespec source/test directories where hardware implementation is useful.
- [x] Add Rust CI.
- [x] Add pinned Bluespec CI.
- [x] Add Rust/Bluespec conformance-vector comparisons for NakedDevice, QLI-16, and PTI.
- [ ] Update `AGENTS.md` to describe Rust + Bluespec hardware-validation rules.
- [ ] Reconcile `docs/SIMULATION.md`: Python remains legacy/reference coverage; Rust is the preferred executable model for this hardware-interface tree.

## 1. QLI semantic v0.1 — frozen

- [x] One-outstanding worker-MMIO request semantics.
- [x] Naturally aligned 8/16/32-bit MMIO encodings.
- [x] MMIO wait / ReadOk / WriteOk / Error behavior.
- [x] DMA request: direction, 32-bit PLIO DMA handle, 1/4/8/16 words.
- [x] Streaming DMA words without redundant `last`.
- [x] Partial-transfer completion and `words_completed`.
- [x] DMA status: OK, BUS_ERROR, PARITY_ERROR, TIMEOUT, PROTOCOL_ERROR.
- [x] Completion-based Notification request.
- [x] Reset as out-of-band cancellation.
- [x] Notification priority over a simultaneously offered new DMA request, never preempting active DMA.
- [x] QLI contains no QDX semantics.

## 2. NakedDevice / NakedCard

- [x] Rust `NakedDevice`.
- [x] Rust full NakedCard path through QIC.
- [x] Bluespec `NakedDevice`.
- [x] Rust/Bluespec canonical vector conformance.
- [ ] Align exact fixture identification constants with final normative PLIO configuration constants when frozen.

## 3. Rust PLIO-QIC behavioral model

- [x] Worker PLIO address/data phases.
- [x] Worker parity/encoding rejection.
- [x] QLI MMIO forwarding and wait behavior.
- [x] Continuous 256-clock worker timeout budget.
- [x] Bus request/grant behavior and one transaction per grant.
- [x] HOST_DMA both directions, all four burst lengths.
- [x] Partial completion, parity, bus error, timeout, grant-loss/protocol-error, reset.
- [x] Notification sequencing.
- [x] Bounded local producer stalls.
- [x] Final ACKed HOST_TO_DEVICE word may drain locally after grant withdrawal.

## 4. Non-product PLIO testbench peer

- [x] Worker read/write injection.
- [x] Immediate one-card grant behavior.
- [x] HOST_DMA deterministic source/target.
- [x] Wait, ERR, parity-fault and timeout injection.
- [x] Notification observation.
- [x] No RAX/capability-table/production host-controller semantics.
- [ ] Optional programmable pre-grant delay.

## 5. PTI + PLIO-TX — v0.1 digital framing frozen

- [x] PTI uses `PTD[17:0]`: 16 data + 2 parity bits per slot.
- [x] Two ordered PTI slots per PLIO-5 period carry one complete 32-bit + 4-parity beat.
- [x] Stable address/data-phase controls are transferred as latched control images outside the payload-critical pair.
- [x] ACK/ERR/selected/grant status does not consume payload slots.
- [x] `CLK`, `RESET`, `SEL`, `BG`, `BR` remain dedicated/auxiliary signals rather than serialized payload.
- [x] Parity generation/checking remains in QIC.
- [x] PLIO-TX remains protocol-dumb: electrical buffering, latching and muxing only.
- [x] Reset disables all QIC-controlled shared-bus outputs.
- [x] Direction changes require an idle turnaround slot.
- [x] Rust PTI digital packing model and tests.
- [x] Bluespec PTI digital packing model and tests.
- [x] Rust/Bluespec canonical vectors match in CI.
- [ ] Later: detailed analog thresholds, loading, termination and drive-current work in PLIO-E.

## 6. QLI-16 v0.1 — framing frozen

- [x] 16-bit local datapath.
- [x] `LTYPE[2:0]`, `LREQ`, `LACK`, `LDIR`; reset out-of-band/card-distributed.
- [x] Two ordered local transfer slots per 5 MHz PLIO period.
- [x] Fixed little-endian halfword order.
- [x] MMIO request/response token encoding.
- [x] DMA request/data/completion token encoding.
- [x] Notification token encoding.
- [x] Reset cancels partial messages.
- [x] Direction changes require one idle slot.
- [x] Reserved/malformed encodings are errors, never alternate valid QLI operations.
- [x] Rust encoder/decoder model with round-trip/error tests.
- [x] Bluespec encoding helpers.
- [x] Rust/Bluespec canonical vectors match in CI.
- [ ] Later when integrating full adapters: prove complete semantic QLI streams survive QLI -> QLI-16 -> QLI under arbitrary legal backpressure.

See `qli16/PIN_BUDGET.md`.

## 7. Bluespec QIC — next major implementation

Implement against **abstract PLIO and semantic QLI**, not PTI/QLI-16 serialization.

- [ ] Define Bluespec QIC external abstract interfaces matching the Rust cycle model.
- [ ] Implement PLIO worker state machine.
- [ ] Implement manager request/grant state machine.
- [ ] Implement DMA burst sequencer.
- [ ] Implement Notification sequencer.
- [ ] Implement parity/timeout/error handling.
- [ ] Add invariants: never drive without ownership; one transaction per grant; no burst >16 words.
- [ ] Build a Bluespec non-product PLIO peer equivalent to the Rust peer.
- [ ] Produce canonical transaction traces from both Rust and Bluespec.
- [ ] Diff Rust and Bluespec traces in CI.
- [ ] Generate Verilog with `bsc`.

## 8. Boundary adapters and FPGA flow

Only after the abstract Bluespec QIC matches Rust:

- [ ] Implement synthesizable Bluespec QLI <-> QLI-16 stream adapter.
- [ ] Implement synthesizable Bluespec abstract-PLIO <-> PTI adapter.
- [ ] Integrate digital PLIO-TX FPGA model.
- [ ] Feed generated Verilog to Yosys.
- [ ] Add nextpnr-ice40 target.
- [ ] Implement two slot-enable events per 5 MHz PLIO period using a faster FPGA internal clock.
- [ ] Meet external PLIO-5 timing with comfortable margin.
- [ ] Keep FPGA memories/FIFOs from silently changing the historical QIC boundary.
- [ ] Record FPGA LUT/FF/RAM separately from historical transistor/gate estimates.
- [ ] Add physical FPGA loopback/two-node rig.

## Deferred

- production PLIO host controller;
- PLIO-RAX host-controller logic;
- real host DMA capability translation;
- RAX interrupt/notification delivery;
- QDX and all QDX profiles;
- real device controllers.
