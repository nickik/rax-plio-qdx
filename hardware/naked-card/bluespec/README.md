# Bluespec NakedCard/NakedDevice

First BSV target after QLI types are frozen:

- implement the same worker-only configuration responses as the Rust `NakedDevice`;
- no DMA request method calls;
- no Notification request method calls;
- unsupported offsets return QLI error;
- `DEVICE_CONTROL` write is accepted as a no-op;
- expose deterministic vectors so Rust and BSV responses can be compared.

Only after the QIC exists should `NakedCard` compose QIC + NakedDevice.
