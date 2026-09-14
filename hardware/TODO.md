# PLIO hardware/interface validation TODO

Work top-to-bottom. Do not pull QDX or a production host controller into this effort.

## 0. Repository/bootstrap

- [x] Create hardware/interface validation tree.
- [x] Separate QLI, PTI, QLI-16, QIC, PLIO-TX, NakedCard, and testbench contracts.
- [x] Add Rust workspace and initial zero-dependency crates.
- [x] Add Bluespec source/test directories where hardware implementation will be useful.
- [ ] Update `AGENTS.md` to describe Rust + Bluespec hardware-validation rules once the first interfaces are frozen.
- [ ] Reconcile `docs/SIMULATION.md`: Python remains legacy/reference coverage, Rust becomes the preferred model for this hardware-interface tree.
- [ ] Add CI job for `cargo test --manifest-path hardware/Cargo.toml`.
- [ ] Add Bluespec compiler/toolchain CI only after the first BSV package is committed.

## 1. Freeze QLI semantic v0.1

- [ ] Freeze one-outstanding worker-MMIO request semantics.
- [ ] Freeze MMIO response semantics: response absence means wait; explicit OK/error terminates the request.
- [ ] Freeze DMA request fields: direction, 32-bit PLIO DMA handle, burst length 1/4/8/16.
- [ ] Freeze streaming DMA word handshakes.
- [ ] Freeze partial-transfer completion semantics and `words_completed`.
- [ ] Freeze QLI notification request/backpressure semantics.
- [ ] Freeze reset/fault/status semantics.
- [ ] Confirm QLI carries no slot ID, CPU vector, host physical address, or QDX semantics.
- [ ] Decide whether standard PLIO configuration registers are implemented in the QIC or by the local QLI endpoint. Initial fixture assumes the local endpoint owns them.
- [ ] Add Rust property/unit tests for every frozen semantic rule.
- [ ] Add equivalent BSV type definitions and a compile-only package test.

## 2. NakedDevice / NakedCard

- [x] Add initial Rust `NakedDevice` implementing only the mandatory-ish test configuration surface and no DMA/notifications.
- [x] Add Rust tests proving worker-only identity and error behavior.
- [ ] Align exact test configuration values with the normative PLIO configuration constants once those values are frozen.
- [ ] Add 8/16/32-bit byte-enable tests.
- [ ] Add reset behavior.
- [ ] Add Bluespec `NakedDevice` implementing the same QLI behavior.
- [ ] Compare Rust and BSV responses for identical MMIO vectors.
- [ ] Once a QIC model exists, compose `NakedCard = QIC + NakedDevice`.

## 3. Rust PLIO-QIC behavioral model

- [ ] Implement worker-side PLIO address/data phase handling.
- [ ] Forward worker MMIO over QLI.
- [ ] Hold PLIO response in wait state while the QLI endpoint has not responded.
- [ ] Translate QLI OK/error into PLIO ACK/ERR.
- [ ] Implement card-side bus-request/grant participation.
- [ ] Implement exactly one PLIO transaction per grant.
- [ ] Implement QLI DMA request -> PLIO HOST_DMA transaction.
- [ ] Implement 1/4/8/16-word DMA data streaming.
- [ ] Implement partial-transfer completion reporting.
- [ ] Implement QLI Notification request -> single-beat CONTROLLER transaction.
- [ ] Implement parity generation/checking.
- [ ] Implement timeout/error recovery.
- [ ] No QDX parsing or queue logic in QIC.

## 4. Non-product PLIO testbench peer

- [ ] Inject WORKER read/write cycles toward one card.
- [ ] Observe BR and issue BG immediately or with programmable delay.
- [ ] Act as HOST_DMA target/source with deterministic data.
- [ ] ACK, wait, ERR, timeout, and parity-fault injection.
- [ ] Accept CONTROLLER/Notification cycles for observation only.
- [ ] Do not implement RAX address maps, capability tables, interrupt routing, or production arbitration policy.
- [ ] Run NakedCard worker-MMIO tests entirely against this peer.
- [ ] Run QIC DMA and Notification tests entirely against this peer.

## 5. PTI + PLIO-TX

- [ ] Freeze which PLIO signals cross PTI as buffered value/OE/sample triples.
- [ ] Freeze safe reset/high-impedance behavior.
- [ ] Keep parity generation/checking in QIC, not PLIO-TX.
- [ ] Decide whether low-fanout per-slot signals (`BR`, `BG`, `SEL`, clock/reset) bypass the main PLIO-TX data transceiver or use auxiliary buffers.
- [ ] Model bus turnaround and no-drive windows.
- [ ] Add Rust transparent-transceiver model.
- [ ] Add Bluespec digital PTI shim/model.
- [ ] Keep analog thresholds, loading, termination, and drive current in PLIO-E/electrical analysis rather than synthesizable BSV.

## 6. QLI-16 historical physical encoding

Do not freeze this merely because the semantic QLI exists.

- [ ] Establish realistic package/pin budget for a 1978/79 QIC.
- [ ] Calculate PTI + power/ground + clock/reset pins first.
- [ ] Determine remaining local-side pin budget.
- [ ] Determine required QLI local bandwidth to avoid throttling PLIO-5.
- [ ] Explicitly evaluate whether a 16-bit local bus needs ~2x PLIO beat rate to sustain 32-bit PLIO traffic.
- [ ] Compare 8-, 16-, and 32-bit local datapaths.
- [ ] Freeze transaction framing only after bandwidth and pin-count analysis.
- [ ] Add Rust encoder/decoder model.
- [ ] Add Bluespec QLI <-> QLI-16 bridge.
- [ ] Prove QLI-16 adds no new semantics; it is only a physical encoding.

## 7. Bluespec QIC

- [ ] Implement frozen QLI interfaces as BSV methods/FIFOs.
- [ ] Implement PLIO worker state machine.
- [ ] Implement manager request/grant state machine.
- [ ] Implement DMA burst sequencer.
- [ ] Implement Notification sequencer.
- [ ] Implement parity/timeout/error handling.
- [ ] Add invariants: never drive without ownership; one transaction per grant; no burst >16 words.
- [ ] Produce canonical traces matching the Rust QIC model.
- [ ] Generate Verilog with `bsc`.

## 8. FPGA flow

- [ ] Feed generated Verilog to Yosys.
- [ ] Add nextpnr-ice40 target.
- [ ] Meet PLIO-5 with comfortable margin.
- [ ] Keep FPGA-specific memories/FIFOs from silently changing the historical QIC boundary.
- [ ] Record LUT/FF/RAM use separately from historical gate/transistor estimates.
- [ ] Only then add a physical FPGA loopback/two-node rig.

## Deferred

- production PLIO host controller;
- PLIO-RAX host-controller logic;
- real host DMA capability translation;
- RAX interrupt/notification delivery;
- QDX and all QDX profiles;
- real device controllers.