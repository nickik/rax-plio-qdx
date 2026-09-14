# PLIO hardware/interface validation TODO

Work top-to-bottom. Do not pull QDX or a production host controller into this effort.

## 0. Repository/bootstrap

- [x] Create hardware/interface validation tree.
- [x] Separate QLI, PTI, QLI-16, QIC, PLIO-TX, NakedCard, and testbench contracts.
- [x] Add Rust workspace and zero-dependency behavioral crates.
- [x] Add Bluespec source/test directories where hardware implementation is useful.
- [x] Add Rust CI running `cargo test --manifest-path hardware/Cargo.toml --all-targets`.
- [x] Add pinned Bluespec CI using BSC 2026.01 with checksum verification.
- [x] Add `make -C hardware test-rust` and `make -C hardware test-bluespec` entry points.
- [ ] Update `AGENTS.md` to describe Rust + Bluespec hardware-validation rules.
- [ ] Reconcile `docs/SIMULATION.md`: Python remains legacy/reference coverage; Rust is the preferred executable model for this hardware-interface tree.

## 1. QLI semantic v0.1 — frozen

- [x] Freeze one-outstanding worker-MMIO request semantics.
- [x] Freeze legal naturally aligned 8/16/32-bit MMIO address/byte-enable encodings.
- [x] Freeze MMIO response semantics: response absence means wait; `ReadOk`/`WriteOk`/`Error` terminates the request.
- [x] Keep MMIO error response code-free because PLIO carries only ACK/ERR for the transaction.
- [x] Freeze DMA request fields: direction, 32-bit PLIO DMA handle, burst length 1/4/8/16.
- [x] Freeze streaming DMA word handshakes; no redundant `last` bit because burst length is already known.
- [x] Freeze partial-transfer completion semantics and `words_completed` as acknowledged PLIO data beats.
- [x] Freeze DMA status values: OK, BUS_ERROR, PARITY_ERROR, TIMEOUT, PROTOCOL_ERROR.
- [x] Freeze Notification as completion-based: producer holds request until the PLIO Notification is ACKed.
- [x] Freeze reset as out-of-band cancellation rather than a synthetic DMA completion.
- [x] Confirm QLI carries no slot ID, CPU vector, host physical address, or QDX semantics.
- [x] Freeze initial scheduling rule: Notification wins over a simultaneously offered new DMA request but never preempts active DMA.
- [x] Decide configuration ownership for v0.1: local QLI endpoint owns PLIO configuration contents; QIC does not synthesize identity.
- [x] Add Rust unit/integration tests for the frozen semantic rules.
- [x] Add equivalent Bluespec type definitions and semantic validation tests.

## 2. NakedDevice / NakedCard

- [x] Implement Rust `NakedDevice` with only the PLIO test configuration surface and no DMA/Notifications.
- [x] Prove worker-only identity and unknown-register error behavior.
- [x] Test legal 8/16/32-bit MMIO and rejection of misaligned/non-contiguous byte enables.
- [x] Test Rust reset clearing a pending local response.
- [x] Compose `NakedCard = Rust QIC + NakedDevice` and run PLIO worker reads/writes through the complete path.
- [x] Implement Bluespec `NakedDevice` with the same QLI semantics.
- [x] Simulate Bluespec request/response backpressure and reset cancellation.
- [x] Compare canonical Rust and Bluespec MMIO response vectors in CI.
- [ ] Align the fixture's exact identification constants with final normative PLIO configuration constants when those are frozen.

## 3. Rust PLIO-QIC behavioral model

- [x] Implement worker-side PLIO address/data phase handling.
- [x] Reject invalid worker address parity and invalid worker transfer encodings before QLI.
- [x] Forward worker MMIO over QLI.
- [x] Hold the PLIO transaction in wait while the local endpoint has not completed it.
- [x] Enforce one continuous 256-clock PLIO worker timeout budget; QLI acceptance does not restart it.
- [x] Translate QLI OK/error into PLIO ACK/ERR.
- [x] Implement card-side bus-request/grant participation.
- [x] Implement exactly one PLIO transaction per grant.
- [x] Implement QLI DMA request -> PLIO HOST_DMA transaction.
- [x] Implement all 1/4/8/16-word DMA bursts in both directions.
- [x] Implement PLIO wait-state handling.
- [x] Implement partial-transfer completion reporting.
- [x] Implement QLI Notification -> single-beat CONTROLLER transaction.
- [x] Implement parity generation/checking.
- [x] Implement bus error, timeout, grant-loss/protocol-error, and reset recovery.
- [x] Bound local producer stalls so DEVICE_TO_HOST DMA cannot retain a grant indefinitely.
- [x] Allow an already-ACKed final HOST_TO_DEVICE word to drain from the local QIC buffer after BG is withdrawn.
- [x] Keep all QDX parsing/queue logic out of QIC.

## 4. Non-product PLIO testbench peer

- [x] Inject WORKER read/write cycles toward one card.
- [x] Observe BR and issue a simple immediate BG for one-card tests.
- [ ] Add programmable pre-grant delay if/when arbitration-delay traces are needed.
- [x] Act as HOST_DMA target/source with deterministic data.
- [x] Inject per-beat wait states, ERR, and read parity faults.
- [x] Exercise QIC timeout by withholding required progress for the full timeout window.
- [x] Accept/record CONTROLLER/Notification cycles.
- [x] Do not implement RAX address maps, capability tables, interrupt routing, or production arbitration policy.
- [x] Run NakedCard worker-MMIO tests entirely against this peer/model boundary.
- [x] Run QIC DMA and Notification integration tests against this peer/model boundary.

## 5. PTI + PLIO-TX

- [ ] Freeze which PLIO signals cross PTI as buffered/latching groups.
- [ ] Freeze safe reset/high-impedance behavior.
- [x] Establish architectural rule: parity generation/checking remains in QIC, not PLIO-TX.
- [x] Establish architectural rule: PLIO-TX may contain wide electrical transceivers, latches, and mux/serialization but remains protocol-dumb.
- [ ] Decide exact handling of low-fanout per-slot signals (`BR`, `BG`, `SEL`, clock/reset): direct/auxiliary buffers versus PTI encoding.
- [ ] Model bus turnaround and no-drive windows.
- [ ] Add Rust PTI/PLIO-TX digital model.
- [ ] Add Bluespec PTI digital shim/model.
- [ ] Keep analog thresholds, loading, termination, and drive current in PLIO-E/electrical analysis rather than synthesizable BSV.

## 6. QLI-16 historical physical encoding

Do not freeze this merely because semantic QLI v0.1 is frozen.

- [x] Establish a realistic working package target: 64-pin QIC, with 84-pin only as an escape option.
- [x] Calculate why directly exposing all PLIO logical wires consumes roughly 54 QIC pins before local QLI and is therefore unsuitable.
- [x] Establish a working ~28-pin PTI budget using a 16-bit registered/multiplexed transceiver datapath.
- [x] Establish a working ~22-pin QLI-16 budget, leaving package margin for power/ground/test.
- [x] Calculate PLIO-5 ideal payload rate: 20 MB/s from one 32-bit beat per 200 ns.
- [x] Prove a 16-bit local path at only 5 MHz would cap payload at 10 MB/s and throttle PLIO-5.
- [x] Establish the no-throttle target: two 16-bit transfer opportunities per PLIO clock, equivalent to 10 MHz local transfers.
- [x] Compare 8-bit (~20 MHz required), 16-bit (~10 MHz), and 32-bit (~5 MHz but excessive pins) local datapaths.
- [ ] Decide whether QLI-16 uses a separate ~10 MHz local clock or two local phases per 5 MHz PLIO clock.
- [ ] Freeze QLI-16 transaction framing only after PTI framing and clocking are resolved.
- [ ] Add Rust QLI <-> QLI-16 encoder/decoder model.
- [ ] Add Bluespec QLI <-> QLI-16 bridge.
- [ ] Prove QLI-16 adds no new semantics; it is only a physical encoding.

See `qli16/PIN_BUDGET.md` for the current analysis.

## 7. Bluespec QIC — deliberately not started yet

Do not start this section until PTI/QLI-16 physical questions above are sufficiently resolved or we explicitly decide to model the QIC against abstract PLIO pins first.

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
