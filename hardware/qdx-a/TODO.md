# QDX-A minimal implementation TODO

**Status:** planning / next implementation stage

This plan is intentionally implementation-gated: Rust is the executable oracle first, Bluespec follows only after the Rust contract is stable, and final acceptance runs through the already validated PLIO-TX/QIC/QLI-16 physical tower.

## Merge-ready planning invariants

Before implementation starts, preserve these invariants in every test layer:

- ring indices advance only for committed work;
- partial SQ DMA is never visible to the endpoint;
- partial CQ DMA never advances `CQ_TAIL`;
- reset cancels every in-flight DMA, endpoint, and notification operation and leaves no request asserted;
- endpoint and CQ backpressure may persist indefinitely without data loss;
- notification is edge/coalescing semantics: only CQ empty -> non-empty, and failure/retry never duplicates a completion;
- all queue-address arithmetic is checked for alignment, ring wrap, handle-generation preservation, and offset overflow;
- Rust and Bluespec must expose the same externally meaningful state transitions, not merely the same happy-path result.

## 1. Freeze contract

- [ ] Add `hardware/qdx-a/SPEC.md` as an implementation profile of generic QDX, not a new ABI.
- [ ] Reuse standard QDX registers beginning at worker offset `0x1000` and canonical little-endian structures.
- [ ] Use opaque 32-byte SQ and 16-byte CQ entries; one SQ, one CQ, one command in flight.
- [ ] Use Notification channel 0 only.
- [ ] Define exact CAP/STATUS/CONTROL/ERROR bits, reset values, alignment, legal queue size, and FAULT-vs-reject rules.
- [ ] Keep ABI extensible to 4..256 power-of-two entries even if the first RTL supports size 4 only.

State model: `RESET -> DISABLED -> READY`; fatal queue/DMA faults enter `FAULT`; RESET from any state returns to DISABLED. READY is the only state allowed to start SQ fetches.

## 2. Endpoint interface

- [ ] Freeze identical Rust/Bluespec ready-valid interfaces for opaque 32-byte commands and 16-byte completions.
- [ ] Endpoint backpressure is unbounded and legal.
- [ ] CQ-full backpressure retains completion and stops further SQ consumption.
- [ ] Reset cancels endpoint ownership.
- [ ] Test endpoint opcodes: immediate complete, echo, delayed complete, synthetic error.

## 3. Rust reference model

Create `hardware/qdx-a/rust/` and add it to the hardware workspace.

- [ ] Implement MMIO/state first: CAP, STATUS, CONTROL, SQ/CQ BASE/SIZE, SQ_TAIL, CQ_HEAD, SQ_HEAD, CQ_TAIL, ERROR.
- [ ] Enforce read-only/write restrictions and QLI width/alignment rules.
- [ ] Generate QLI DMA/Notification operations; never directly access host memory.
- [ ] One outstanding operation and one command maximum.

## 4. SQ engine

- [ ] Fetch exactly one 32-byte entry with one H->D 8-word DMA.
- [ ] Start only when READY and SQ non-empty.
- [ ] Compute checked handle `SQ_BASE + SQ_HEAD * 32`, preserving channel/generation bits.
- [ ] Commit `SQ_HEAD` only after all eight words are safely received.
- [ ] Parity/BusError/Timeout/ProtocolError never expose partial command data.
- [ ] Validate ring wrap and impossible/out-of-range host tail movement.

## 5. CQ engine

- [ ] Publish one 16-byte completion with one D->H 4-word DMA.
- [ ] Commit `CQ_TAIL` only after successful completion of all four words.
- [ ] Never overwrite an unconsumed entry.
- [ ] CQ full retains completion and stalls further command processing without loss.
- [ ] CQ DMA failure never falsely commits the entry.

## 6. Notification

- [ ] Notify channel 0 only for CQ empty -> non-empty when enabled.
- [ ] Additional completions while non-empty do not notify again.
- [ ] Host draining CQ to empty rearms notification.
- [ ] Notification latency/failure does not roll back CQ state or duplicate entries.
- [ ] Polling works with notification disabled.

## 7. Error/reset matrix

Test invalid enable/configuration, bad size/alignment, illegal head/tail movement, CQ full, all SQ/CQ DMA completion errors, and reset while: idle, requesting SQ DMA, receiving SQ words, endpoint owns command, waiting for CQ space, publishing CQ, and notification outstanding.

For every case assert exact committed indices, no stale response/completion after reset, no asserted DMA/notification after reset, and no partial descriptor/completion visibility.

## 8. Rust test gate

Before Bluespec begins, Rust must cover:

- [ ] complete MMIO/state transition table and reset from every state;
- [ ] one command and four-command wrap;
- [ ] SQ empty, CQ full/drain/resume, endpoint backpressure and delay;
- [ ] byte-exact command/completion preservation;
- [ ] exact DMA direction, length and handle at every ring position;
- [ ] every DMA failure class at word progress 0/1/middle/final boundary where applicable;
- [ ] notification coalescing/rearm/retry;
- [ ] deterministic randomized model test varying host doorbells, endpoint delay, QLI backpressure, failures and reset;
- [ ] invariant/property checks after every randomized step.

## 9. Bluespec implementation

Only after the Rust gate is green, create `QDXA.bsv`, `QDXAEndpointIfc.bsv`, and `TbQDXA.bsv`.

Use bounded explicit storage only: 32-byte command buffer, 16-byte completion buffer, one outstanding QLI operation, no dynamic allocation or unbounded FIFO. Match the Rust state machine and commit points.

## 10. Rust <-> Bluespec differential

Define canonical `QDXATRACE|v1` including cycle/event, state, SQ/CQ indices, DMA state, notification state and fault.

- [ ] Exact directed success, wrap/full, DMA-error and reset traces.
- [ ] Deterministic pseudo-random backpressure/fault/reset trace.
- [ ] Compare semantic events exactly; where cycle scheduling legitimately differs, normalize only explicitly documented non-semantic idle cycles.

## 11. Full physical integration

Insert QDX-A behind PLIO-TX -> QIC -> QLI-16; do not bypass QLI-16.

- [ ] Configure exclusively through PLIO worker MMIO.
- [ ] Fetch exact 32-byte SQ entry via physical H->D DMA.
- [ ] Endpoint receives exact bytes and produces completion.
- [ ] Publish exact 16-byte CQ entry via physical D->H DMA.
- [ ] Observe channel-0 notification, drain CQ, run second command and prove rearm.
- [ ] Physical faults: waits, parity, target errors, timeout, BG loss, QLI-16 backpressure, and reset at SQ/CQ/notification phases.
- [ ] Assert PLIO-TX never drives accidentally after reset/fault.

## 12. Test memory fixture

- [ ] SQ and CQ DMA mappings using real channel + generation + offset handles.
- [ ] Inject waits/errors/parity/timeouts at deterministic beats.
- [ ] Record every DMA beat and assert no out-of-range access.
- [ ] Keep fixture out of production RTL.

## 13. Synthesis checkpoint

- [ ] Generate Verilog and run Yosys.
- [ ] Record QDX-A-alone and QIC+QLI-16+QDX-A LUT/FF/BRAM estimates.
- [ ] Check 5 MHz PLIO / 10 MHz two-slot local timing.
- [ ] Record storage/state cost relevant to a late-1970s custom implementation.

## 14. Definition of done

One full scenario must work identically in Rust and Bluespec through physical PLIO: program queues, enable, submit, H->D fetch, endpoint process, D->H completion, empty->non-empty notification, host drain, wrap/rearm. Then repeat under deterministic backpressure and the complete fault/reset matrix.

Required final gates:

- Rust unit/integration/property tests green;
- Bluespec directed and stress tests green;
- exact/normalized documented QDXATRACE differential green;
- full NakedCard physical success and fault integration green;
- existing NakedCard/QIC/QLI-16 regressions remain green;
- synthesis succeeds with recorded resource/timing results;
- no profile-specific QDX-B semantics have leaked into QDX-A.
