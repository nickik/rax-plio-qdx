# PLIO Host Adapter implementation TODO

Goal: build a production-quality PLIO host adapter in Rust and Bluespec, starting from the existing `TestPeer` bus-side behavior and preserving PLIO v0.6 semantics. The host core must remain independent of RAX-specific CPU addressing, memory-controller width, and interrupt-vector policy.

## M0 — Freeze interfaces and turn `TestPeer` into the Rust oracle

- Define a host-independent `PLIOHostCore` contract for one PLIO segment with up to eight slots.
- Define explicit CPU/host worker request and completion types for naturally aligned 8/16/32-bit MMIO.
- Define cycle-level PLIO bus input/output images using the canonical `plio-logical` types.
- Define a narrow asynchronous host-memory request/response interface suitable for later DMA:
  - aligned 32-bit physical reads/writes;
  - ready/valid backpressure;
  - explicit completion/fault;
  - no knowledge of cache line width or memory technology.
- Preserve `TestPeer` as the behavioral oracle for worker address/data sequencing, waits, parity, ACK/ERR handling, arbitration transaction boundaries, DMA phase sequencing, and notifications.
- Add deterministic `PLIOHOSTTRACE|v1` debug records covering every externally visible state transition.
- Document invariants:
  - worker address/control image remains stable through wait states;
  - worker write data remains stable through wait states;
  - worker read data is accepted only with valid parity;
  - one host worker transaction at a time in the first implementation;
  - manager grants are exactly one transaction;
  - reset cancels all in-flight host work and tri-states outputs;
  - no RAX physical address appears on the PLIO backplane.
- Add oracle tests that exercise worker read/write success, waits, ERR, bad read parity, reset during address/data, and all transfer widths.

## M1 — Rust worker-MMIO host engine

- Implement production Rust `WorkerMmioEngine` from the frozen M0 contract.
- Support host-issued 8-, 16-, and 32-bit naturally aligned worker reads and writes.
- Translate `(slot, slot_offset)` to PLIO `SPACE=WORKER`, slot select, address, parity, byte-enable, `BLEN=1` bus cycles.
- Implement explicit states for idle, worker address, worker data, completion, and abort/reset.
- Hold address/control and write data exactly stable while the card inserts wait states.
- Validate read-data parity only on selected byte lanes.
- Convert card `ERR` or read parity failure into typed host errors.
- Bound address/data wait states with the PLIO 256-clock timeout.
- Add detailed debug snapshots plus `PLIOHOSTTRACE|v1` records for request, address wait/ack, data wait/ack, read data, error, timeout, reset, and completion.
- Keep the engine host-profile-independent: requests carry slot + slot-relative offset, not RAX CPU physical addresses.
- Add a minimal Bluespec worker-MMIO engine/harness with the same state semantics so M1 can already exact-diff Rust vs Bluesim for worker transactions; full `PLIOHostCore` composition remains M4.
- Differential scenarios must include read/write success, address wait, data wait, ERR in either phase, bad read parity, timeout, and reset cancellation.

## M2 — Arbitration + notifications

- Implement rotating round-robin bus-manager arbitration across eight request lines.
- Grant exactly one transaction at a time and withdraw grant at transaction completion/fault/timeout.
- Implement controller-local PLIO Notification address/data handling for four channels per slot.
- Record pending notification state, payload/data if required by the host profile, enable/mask/class metadata, and deterministic claim order.
- Add fairness, repeated-request, backpressure, notification error, reset, and multi-slot tests.

## M3 — DMA capability table + asynchronous memory port

- Implement 8 slots × 16 DMA capability channels.
- Capability fields: host physical base, length, device-read/device-write permissions, generation, valid.
- Implement privileged bind/revoke semantics and active-burst interlock.
- Validate complete DMA burst extent before address ACK.
- Translate PLIO DMA handle `(channel,generation,offset)` to host physical address only inside the host core.
- Implement one 32-bit asynchronous memory request per acknowledged PLIO beat.
- Memory stalls become PLIO wait states.
- For device→host DMA, ACK a beat only after the memory write is accepted/completed according to the frozen memory-port contract.
- For host→device DMA, obtain memory data before presenting PLIO read data/parity/ACK.
- Preserve exact partial progress on memory fault, bus error, parity fault, timeout, reset, and revoke.
- Test all burst sizes 1/4/8/16 and both directions.

## M4 — Bluespec `PLIOHostCore`, exact Rust↔Bluesim differential

- Implement the complete host-independent core in Bluespec using the same frozen interfaces and states as Rust.
- Cover worker engine, arbitration, notifications, DMA table, memory port, timeout/fault accounting, and reset.
- Generate exact ordered `PLIOHOSTTRACE|v1` traces from Rust and Bluesim.
- Differential-test deterministic and seeded randomized sequences.
- Generate standalone synthesizable Verilog.

## M5 — RAX CPU/MMIO/CSR attachment

- Implement `RaxPlioHostAdapter` around `PLIOHostCore`.
- Decode `0xF000_0000..0xFFFF_FFFF` into eight geographic 32 MiB PLIO slot windows.
- Never place the full RAX CPU physical address on PLIO; emit only slot-relative worker offset.
- Implement privileged controller CSR region at `0xEFFF_F000..0xEFFF_FFFF`.
- Add controller ID/status/control, DMA bind/revoke, generation, notification pending/enable/mask/class/claim, and diagnostic CSRs.
- Expose aggregate `NOTIFY_PENDING_INTERRUPT`.

## M6 — Concrete RAX memory-controller bridge

- Adapt the generic 32-bit asynchronous `HostMemoryPort` onto the Lighting/RAX memory-controller interface.
- Define ordering and completion semantics precisely.
- Keep cache coherence out of PLIO; expose/document required software visibility operations.
- Support memory backpressure and faults without changing PLIO host-core semantics.
- Verify against a deterministic memory model before integrating a real memory controller.

## M7 — Real integration against NakedCard/QDX-A/QDX-B

- Replace test-peer ownership in full-system tests with the real host adapter.
- Validate worker MMIO through PLIO-TX/QIC/QLI-16.
- Validate QDX-A queue programming and DMA through the host capability table and memory port.
- Validate QDX-B READ/WRITE/WRITE_DURABLE/FLUSH plus notifications through the complete physical card path.
- Exercise parity faults, wait states, memory faults, DMA capability errors, reset, timeout, CQ/SQ traffic, and partial DMA progress.
- No special-case shortcuts from QDX to host memory are allowed.

## M8 — Stable simulation boundary for LightingSimulation

- Provide a stable cycle-stepped host-adapter simulation API usable from LightingSimulation.
- Allow software/reference PLIO and hardware/RTL PLIO modes during migration.
- Run identical CPU-visible scenarios against both and compare MMIO results, host memory, DMA progress, notifications, errors, and device-visible state at semantic boundaries.
- Once hardware mode has sufficient coverage and performance, retire the old simplified LightingSimulation PLIO path.

## Scope rule for the first implementation branch

Implement **M0 and M1 only**. Do not start arbitration, notifications, DMA capability state, RAX CSR attachment, or memory-controller integration on this branch. The only Bluespec permitted before M4 is the minimal worker-MMIO engine/harness needed to prove M1 Rust↔Bluesim behavioral equivalence.
