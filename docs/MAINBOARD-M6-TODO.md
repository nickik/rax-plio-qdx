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

- [x] CPU request pending when PLIO DMA arrives.
- [x] PLIO request pending when CPU request arrives.
- [x] Hold backend `requestReady` low while both contenders are present.
- [x] Prove exactly one requester owns the MemoryController transaction.
- [x] Prove ownership does not change until completion/fault/reset.
- [x] Prove the losing requester remains pending rather than being dropped.
- [x] Prove no duplicate backend request is emitted.
- [x] Prove both transactions eventually complete once backpressure is removed.
- [x] Record deterministic arbitration policy and assert it in the test rather than relying on incidental Bluespec scheduling.

Acceptance:

- no request loss;
- no request duplication;
- one active owner at a time;
- owner stable through backend backpressure;
- both CPU and PLIO make forward progress.

## M6.2 — Fault propagation and response isolation

CPU path:

- [x] Backend fault during CPU read.
- [x] Backend fault during CPU write.
- [x] CPU receives the fault/completion exactly once.
- [x] PLIO receives no spurious response.

PLIO path:

- [x] Backend fault during PLIO DMA read.
- [x] Backend fault during PLIO DMA write.
- [x] PLIO receives the fault/completion exactly once.
- [x] CPU receives no spurious response.

Cross-requester isolation:

- [x] Keep the non-owner requester pending while the owner faults.
- [x] After fault completion, prove the pending requester can subsequently acquire memory and complete normally.

Acceptance:

- backend response/fault is routed only to the recorded transaction owner;
- transaction ownership is cleared exactly once at terminal completion;
- unrelated requester state is preserved.

## M6.3 — Reset during arbitration / outstanding transactions

CPU-owned case:

- [x] CPU owns an outstanding MemoryController transaction.
- [x] PLIO is waiting.
- [x] Assert reset before backend completion.
- [x] Prove Mainboard ownership/pending transaction state clears.
- [x] Prove MemoryController outstanding state clears.
- [x] Inject stale completion from the pre-reset backend request.
- [x] Prove stale completion reaches neither CPU nor PLIO.

PLIO-owned case:

- [x] PLIO owns an outstanding MemoryController transaction.
- [x] CPU is waiting.
- [x] Repeat the same reset/stale-response proof.

Recovery:

- [x] Fresh CPU transaction succeeds after reset.
- [x] Fresh PLIO transaction succeeds after reset.
- [x] No pre-reset ownership or response state influences the new transactions.

Acceptance:

- reset converges ownership and pending state to idle;
- no stale transaction survives reset;
- both requester paths recover immediately.

## M6.4 — Same-address coherence / serialized observation

Use the real production Mainboard + MemoryController + backend path.

- [x] Seed a known aligned 32-bit word.
- [x] CPU partial write, then PLIO read: PLIO observes the merged word.
- [x] PLIO full-word write, then CPU read: CPU observes the PLIO value.
- [x] Alternate CPU partial and PLIO full-word accesses to the same address.
- [x] Prove each completed transaction establishes the value observed by the next serialized transaction.
- [x] Include non-contiguous CPU byte enables (`0101`, `1010`).
- [x] Include `0000` CPU write as a successful no-op.
- [x] PLIO remains full-beat `BE=1111`.

This is serialized shared-memory behavior, not a cache-coherence protocol.

Acceptance:

- CPU and PLIO observe one shared memory image;
- completion order defines observable memory order;
- no hidden Mainboard-side merging or shadow memory exists.

## M6.5 — Final integration/regression gate

- [x] Focused arbitration tests.
- [x] Focused fault-routing tests.
- [x] Focused reset/arbitration tests.
- [x] Focused same-address coherence tests.
- [x] Existing Mainboard CPU grant/read/write/lifecycle tests.
- [x] Existing byte-enable propagation and semantics tests.
- [x] Registered-backend integration.
- [x] QDX-B/Mainboard integration.
- [x] Generated Verilog.
- [x] Yosys/synthesis sanity.
- [x] Broader affected Bluespec/PLIO/bus regression.
- [x] Freeze one exact SHA with the complete gate green before merge.

## Frozen verification record

M6.1-M6.5 are complete. Source checkpoint `a4299c8b627d371d0e312a5df4ffa01e1b535bec` passed Mainboard M6 Verification run 35205353981, Mainboard P0 Debug run 35205353978, Hardware Bluespec run 35205353982, Hardware Rust run 35205353992, Hardware PLIO Host M0-M1 run 35205354078, and Hardware PLIO Host M4 run 35205353965.

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
