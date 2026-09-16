# M6 — Mainboard shared-memory arbitration and fault semantics

Branch: `m6-mainboard-arbitration-faults`

Base: `main` at `054bc263e415953fa508edacb2aa657432a8db1e`

## Goal

Prove that CPU and PLIO share the production Mainboard memory path correctly under contention, faults, reset, and same-address access.

```text
CPU ──┐
      ├── Mainboard arbiter ── MemoryController ── RAM
PLIO ─┘

exactly one owner
stable ownership
correct completion routing
correct fault routing
reset-safe
```

M6 is a Mainboard integration/verification milestone. Do not add RMW behavior to MainboardFPGA or MemoryController. Byte merging remains a memory-backend responsibility.

## M6.1 — CPU/PLIO arbitration under contention

- [ ] CPU request pending when PLIO DMA arrives.
- [ ] PLIO request pending when CPU request arrives.
- [ ] Hold backend `requestReady` low while both contenders are present.
- [ ] Prove exactly one requester owns the MemoryController transaction.
- [ ] Prove ownership does not change until completion/fault/reset.
- [ ] Prove the losing requester remains pending rather than being dropped.
- [ ] Prove no duplicate backend request is emitted.
- [ ] Prove both transactions eventually complete once backpressure is removed.
- [ ] Record deterministic arbitration policy and assert it in the test rather than relying on incidental Bluespec scheduling.

Acceptance:

- no request loss;
- no request duplication;
- one active owner at a time;
- owner stable through backend backpressure;
- both CPU and PLIO make forward progress.

## M6.2 — Fault propagation and response isolation

CPU path:

- [ ] Backend fault during CPU read.
- [ ] Backend fault during CPU write.
- [ ] CPU receives the fault/completion exactly once.
- [ ] PLIO receives no spurious response.

PLIO path:

- [ ] Backend fault during PLIO DMA read.
- [ ] Backend fault during PLIO DMA write.
- [ ] PLIO receives the fault/completion exactly once.
- [ ] CPU receives no spurious response.

Cross-requester isolation:

- [ ] Keep the non-owner requester pending while the owner faults.
- [ ] After fault completion, prove the pending requester can subsequently acquire memory and complete normally.

Acceptance:

- backend response/fault is routed only to the recorded transaction owner;
- transaction ownership is cleared exactly once at terminal completion;
- unrelated requester state is preserved.

## M6.3 — Reset during arbitration / outstanding transactions

CPU-owned case:

- [ ] CPU owns an outstanding MemoryController transaction.
- [ ] PLIO is waiting.
- [ ] Assert reset before backend completion.
- [ ] Prove Mainboard ownership/pending transaction state clears.
- [ ] Prove MemoryController outstanding state clears.
- [ ] Inject stale completion from the pre-reset backend request.
- [ ] Prove stale completion reaches neither CPU nor PLIO.

PLIO-owned case:

- [ ] PLIO owns an outstanding MemoryController transaction.
- [ ] CPU is waiting.
- [ ] Repeat the same reset/stale-response proof.

Recovery:

- [ ] Fresh CPU transaction succeeds after reset.
- [ ] Fresh PLIO transaction succeeds after reset.
- [ ] No pre-reset ownership or response state influences the new transactions.

Acceptance:

- reset converges ownership and pending state to idle;
- no stale transaction survives reset;
- both requester paths recover immediately.

## M6.4 — Same-address coherence / serialized observation

Use the real production Mainboard + MemoryController + backend path.

- [ ] Seed a known aligned 32-bit word.
- [ ] CPU partial write, then PLIO read: PLIO observes the merged word.
- [ ] PLIO full-word write, then CPU read: CPU observes the PLIO value.
- [ ] Alternate CPU partial and PLIO full-word accesses to the same address.
- [ ] Prove each completed transaction establishes the value observed by the next serialized transaction.
- [ ] Include non-contiguous CPU byte enables (`0101`, `1010`).
- [ ] Include `0000` CPU write as a successful no-op.
- [ ] PLIO remains full-beat `BE=1111`.

This is serialized shared-memory behavior, not a cache-coherence protocol.

Acceptance:

- CPU and PLIO observe one shared memory image;
- completion order defines observable memory order;
- no hidden Mainboard-side merging or shadow memory exists.

## M6.5 — Final integration/regression gate

- [ ] Focused arbitration tests.
- [ ] Focused fault-routing tests.
- [ ] Focused reset/arbitration tests.
- [ ] Focused same-address coherence tests.
- [ ] Existing Mainboard CPU grant/read/write/lifecycle tests.
- [ ] Existing byte-enable propagation and semantics tests.
- [ ] Registered-backend integration.
- [ ] QDX-B/Mainboard integration.
- [ ] Generated Verilog.
- [ ] Yosys/synthesis sanity.
- [ ] Broader affected Bluespec/PLIO/bus regression.
- [ ] Freeze one exact SHA with the complete gate green before merge.

## Implementation constraints

- Prefer verification first; change production RTL only when a focused test proves a real defect.
- Keep arbitration semantics explicit and testable.
- Do not duplicate MemoryController behavior in testbenches.
- Use production Mainboard and MemoryController paths.
- Do not add Mainboard/MemoryController RMW logic.
- Keep commits small and avoid unnecessary CI triggers.
- Do not begin actual Lighting Compute Board integration until M6 is green and merged.

## After M6

Next milestone: integrate the actual Lighting Compute Board / CPU FPGA with the Mainboard so CPU traffic is produced by the real compute-board implementation rather than synthetic Mainboard testbench requests.
