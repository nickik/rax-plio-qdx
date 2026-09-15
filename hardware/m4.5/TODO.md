# M4.5 — Host/Card Physical Integration

Branch: `plio-host-card-m4.5`

Goal: prove the real synthesizable `mkPLIOHostCore` and real physical card stacks interoperate directly on PLIO. No `TestPeer` sits between host and card in these integration tests.

## M4.5a — NakedCard

- [x] Real `mkPLIOHostCore` ↔ PLIO-TX/PTI/QIC/QLI-16/NakedDevice composition.
- [x] Worker read and write transactions.
- [x] PLIO ACK/ERR handling and typed worker error propagation.
- [x] `BUS_REQ` → `BUS_GRANT` ownership.
- [x] Reset behavior.
- [x] Exact 256-cycle timeout behavior.
- [x] Existing complete NakedCard physical DMA/notification/fault regression remains part of the M4.5 acceptance gate.

## M4.5b — QDX-A

- [x] Real `mkPLIOHostCore` ↔ real `mkQDXACard` physical composition.
- [x] Discovery/configuration through worker cycles.
- [x] Host DMA capabilities match QDX-A handles/generations.
- [x] SQ command fetch through physical host DMA.
- [x] CQ write through physical host DMA.
- [x] Completion notification reaches host pending state.
- [x] Queue state and host RAM CQ contents checked exactly.

## M4.5c — Full QDX-B

- [x] Real host ↔ `mkQDXBCard` physical stack: PLIO-TX/PTI/QIC/QLI-16/QDX-A/QDX-B/FakeMedia.
- [x] Real QDX-B command supplied from host RAM.
- [x] Worker configuration and SQ doorbell.
- [x] SQ fetch through host DMA.
- [x] QDX-B `WRITE_DURABLE` execution against FakeMedia.
- [x] Payload DMA crosses the real physical stack.
- [x] CQ write through host DMA.
- [x] Completion notification reaches host pending state.
- [x] CQ words, queue state, status and FakeMedia durability semantics checked.

`WRITE_DURABLE` commits directly to durable FakeMedia and therefore leaves `flush_count=0`; the explicit `FLUSH` opcode and its counter increment are covered by the existing QDX-B regression gate.

## Acceptance gate

`hardware/scripts/test-plio-host-card-m4.5.sh` is authoritative and must pass on the exact candidate head. It runs:

- [x] M4.5 NakedCard direct host/card integration.
- [x] M4.5 QDX-A direct host/card integration.
- [x] M4.5 QDX-B full end-to-end transaction.
- [x] M4 host acceptance/regression gate.
- [x] Complete existing NakedCard physical Rust/Bluesim differential + fault matrix.
- [x] Existing QDX-A physical card gate.
- [x] Existing QDX-B gate.

BSC may report stage-disjoint testbench urgency (`G0010`) warnings in integration harnesses. These are harness scheduling diagnostics between mutually exclusive setup/consume stages, not unresolved PLIO ownership in `mkPLIOHostCore`.

**Scope stops here. Do not start M5 as part of M4.5.**
