# M4.5 — Host/Card Physical Integration

Branch: `plio-host-card-m4.5`

Goal: prove the real synthesizable `mkPLIOHostCore` and real physical card stacks interoperate directly on PLIO. No `TestPeer` may stand between host and card in these tests.

## M4.5a — NakedCard compatibility

- [ ] Real `mkPLIOHostCore` wired to PLIO-TX/PTI/QIC/QLI-16/NakedDevice.
- [ ] Worker reads and writes.
- [ ] Address/data wait behavior.
- [ ] Parity and ACK/ERR handling.
- [ ] Card BUS_REQ -> host BUS_GRANT.
- [ ] Notification delivery.
- [ ] Reset.
- [ ] Timeout/fault paths.

## M4.5b — QDX-A physical compatibility

- [ ] Real `mkPLIOHostCore` wired to real `mkQDXACard`.
- [ ] Discover/read QDX registers through worker cycles.
- [ ] Configure SQ/CQ through worker cycles.
- [ ] Program host DMA capabilities matching QDX handles/generations.
- [ ] QDX SQ fetch through real host DMA/memory port.
- [ ] QDX CQ write through real host DMA/memory port.
- [ ] Notification reaches host pending state.
- [ ] Verify queue state and host memory.

## M4.5c — Full QDX-B transaction

- [ ] Bring the verified QDX-B physical implementation onto this integration branch without replacing M4 host code.
- [ ] Real `mkPLIOHostCore` wired to `mkQDXBCard` (PLIO-TX/PTI/QIC/QLI-16/QDX-A/QDX-B/FakeMedia).
- [ ] Place a real QDX-B command in simulated host RAM.
- [ ] Configure QDX through real worker MMIO and ring SQ doorbell.
- [ ] SQ command DMA-fetches through `PLIOHostCore`.
- [ ] QDX-B executes against FakeMedia.
- [ ] CQ DMA-writes through `PLIOHostCore`.
- [ ] Host receives notification.
- [ ] Verify CQ host RAM, queue state, QDX-B status, and FakeMedia/flush state.

## Acceptance gate

- [ ] Existing M4 acceptance gate remains green.
- [ ] Existing QDX-A physical gate remains green.
- [ ] Existing QDX-B gate remains green.
- [ ] NakedCard host/card integration Bluesim passes.
- [ ] QDX-A host/card integration Bluesim passes.
- [ ] QDX-B end-to-end host/card integration Bluesim passes.
- [ ] Integration tops elaborate without unresolved ownership/scheduling warnings that can affect behavior.

Do not start M5 in this branch.
