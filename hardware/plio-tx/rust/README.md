# Rust PLIO-TX model

This crate is the executable reference for the frozen transistor-independent PLIO-TX v0.1 logical contract in `../SPEC.md` and the PTI boundary in `../../pti/SPEC.md`.

It models only digital behavior:

- PTI DATA_LO/DATA_HI assembly and coherent receive capture;
- outbound control latching;
- PTD direction and idle-turnaround rules;
- `TX_DRIVE` subgroup gating;
- `RESP_DRIVE` ACK/ERR direction;
- dedicated request/status observation;
- reset safety;
- sticky malformed-framing and simulation-only contention diagnostics.

It deliberately does not model analog thresholds, drive current, termination, propagation delay, transistor implementation, DMA, Notification, arbitration, QLI, or QDX semantics.

`src/bin/conformance.rs` emits the canonical `TXTRACE|v1` sequence used for exact Rust/Bluesim comparison.
