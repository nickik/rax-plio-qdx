# Bluespec QLI

The first BSV package should mirror `../SPEC.md` exactly:

- worker MMIO request/response types;
- DMA request/data/completion types;
- Notification request;
- reset/diagnostic contract;
- one-outstanding-operation baseline.

Prefer guarded methods/FIFOs so absence of a response naturally represents backpressure. Do not add AXI/Wishbone/PCI-style IDs or multiple outstanding transactions.

The first compile target should be a QLI-only NakedDevice test, before the PLIO QIC is implemented.
