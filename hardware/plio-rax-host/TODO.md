# PLIO Host Adapter implementation TODO

Goal: build a production-quality PLIO host adapter in Rust and Bluespec, starting from the existing `TestPeer` bus-side behavior and preserving PLIO v0.6 semantics. The host core must remain independent of RAX-specific CPU addressing, memory-controller width, and interrupt-vector policy.

## M0 — Freeze interfaces and turn `TestPeer` into the Rust oracle

**Status: complete and verified.**

- Define a host-independent `PLIOHostCore` contract for one PLIO segment with up to eight slots.
- Define explicit CPU/host worker request and completion types for naturally aligned 8/16/32-bit MMIO.
- Define cycle-level PLIO bus input/output images using the canonical `plio-logical` types.
- Define a narrow asynchronous host-memory request/response interface suitable for later DMA.
- Preserve `TestPeer` as the behavioral oracle.
- Add deterministic `PLIOHOSTTRACE|v1` debug records.

## M1 — Rust worker-MMIO host engine

**Status: complete and verified with exact Rust↔Bluesim differential.**

- Worker reads/writes for 8/16/32-bit accesses.
- Address/data wait-state handling, parity, ACK/ERR, timeout, reset.
- Stable bus output while stalled.
- Deterministic exact Rust↔Bluesim trace verification.

## M2 — Arbitration + notifications

**Status: complete and verified with exact Rust↔Bluesim differential.**

- Rotating round-robin arbitration across eight slots.
- One grant / one transaction semantics.
- Four notification channels per slot.
- Pending/payload/enable/mask/class handling.
- Backpressure, parity/error, timeout, reset and deterministic claim order.

## M3 — DMA capability table + asynchronous memory port

**Status: complete and verified with exact Rust↔Bluesim differential.**

- 8 slots × 16 DMA capability channels.
- Capability base, length, permissions, generation and validity.
- Complete-burst validation before transfer.
- PLIO `(channel,generation,offset)` handle translation.
- Asynchronous 32-bit host-memory request/response port.
- Both DMA directions and burst sizes 1/4/8/16.
- Memory backpressure and faults.
- Parity, timeout, reset, revoke and partial-progress semantics.
- Standalone synthesizable `mkPLIOHostDmaM3` RTL generation.

## M4 — Integrated `PLIOHostCore`

**Status: complete and verified through M4f on branch `plio-host-adapter-m4`. Exact tested code head: `e58d9be003973a98fd26b620425d9e8ce1123dce`; dedicated run `34993792187`.**

M4 combines the independently verified M1/M2/M3 engines into the actual host-independent PLIO bus controller. There is exactly one owner of the physical PLIO output image each cycle and one explicit scheduler deciding whether the host is acting as worker, bus manager for a card transaction, DMA target/source, or idle.

### M4a — Freeze the integrated scheduling contract

**Status: complete and verified.**

- Define the Rust `PLIOHostCore` top-level API before composing implementations.
- Inputs include current physical PLIO card/backplane images, optional host worker request, asynchronous host-memory handshake and reset.
- Outputs include eight canonical host/card bus images, worker/DMA completion, memory request, notification claim state and debug state.
- Scheduler roles are explicit: idle, worker, grant, notification and DMA.
- Reset/abort and already-active physical transactions take precedence over new work.
- A started transaction cannot be preempted by a new worker request or another card request.
- DMA memory activity remains subordinate to the single active PLIO transaction and never becomes a second bus owner.
- Debug ownership includes active role, slot, DMA phase, arbitration cursor, wait counters, acknowledged beats and fault state.

### M4b — Rust `PLIOHostCore` composition

**Status: complete and verified.**

- Compose the verified M1 worker engine and M3 DMA model behind one cycle-stepped Rust core, reusing M2 notification/arbitration semantics.
- Implement one `step()` transition that computes the only physical PLIO output image.
- Card-request arbitration dispatches controller-space notifications or host-DMA transactions from the observed address phase.
- Host worker requests coexist with card-originated manager transactions through one-deep queueing and non-preemption.
- DMA capability lookup completes before acknowledging the device DMA address phase.
- Device→host DMA ACK occurs only after the corresponding memory write completes.
- Host→device data is driven only after the corresponding memory read completes.
- Memory stalls affect only the active DMA transaction.
- Reset clears ownership and transient state without creating stale completion/bus activity.

### M4c — Bluespec `mkPLIOHostCore`

**Status: complete and verified.**

- Implement one synthesizable integrated Bluespec scheduler/state machine rather than composing independently scheduled mutable submodules at the physical bus boundary.
- Reuse verified M1/M2/M3 types and validation/parity/address helpers.
- Maintain one top-level physical bus owner and explicit idle/worker/grant/notification/DMA roles.
- Integrate capability table, DMA state, worker state, notification state and asynchronous memory port under that scheduler.
- Host outputs are deterministic and tri-stated when idle/reset.
- Standalone `mkPLIOHostCore.v` generation is verified.
- Public worker/DMA completion state uses ordered two-port `mkCReg` storage: scheduler updates use port 0 and public observe/clear operations use port 1. This structurally defines same-cycle ordering and removes the integrated completion-clear scheduling warnings without suppression.

### M4d — Integrated deterministic differential tests

**Status: complete and verified with exact 20-record Rust↔Bluesim differential.**

`PLIOHOSTCORETRACE|v1` is emitted by Rust and Bluesim and compared byte-for-byte.

Covered deterministic scenarios:

1. host worker read while no card requests;
2. host worker write with address/data waits;
3. card request arriving during an active worker operation waits until worker completion;
4. rotating round-robin / one-hot grant behavior;
5. notification transaction through the integrated manager;
6. device→host DMA burst through capability validation and asynchronous memory writes;
7. host→device DMA burst through asynchronous memory reads;
8. memory backpressure with no early PLIO ACK;
9. notification immediately followed by DMA;
10. worker request queued during DMA without preemption;
11. stale DMA generation rejected before transfer;
12. permission/range protection path;
13. DMA parity failure path;
14. host-memory fault after partial progress;
15. exact 256-cycle timeout semantics inherited and regression-verified through M1–M3;
16. reset during worker operation;
17. reset during grant/address ownership;
18. reset during DMA memory activity;
19. revoke during active DMA;
20. mixed multi-slot final-idle/single-owner/no-stale-state invariant.

The M4 gate also reruns the exact M1, M2 and M3 Rust↔Bluesim differentials before the integrated test.

### M4e — Seeded stress/conformance

**Status: complete and verified with an exact 64-event seeded Rust↔Bluesim differential.**

- Fixed reproducible xorshift32 seed: `0x4d34e5a1`.
- 64 mixed semantic transactions covering worker reads/writes, notifications and both DMA directions.
- Bounded 0–3 cycle wait insertion on worker/manager PLIO phases and DMA memory request/response phases.
- `PLIOHOSTSTRESS|v1` event traces are compared byte-for-byte between Rust and Bluesim after every completed transaction.
- Rust asserts single physical PLIO owner throughout the generated sequences.
- Stress checks notification pending/payload/claim state, DMA capability-before-ACK behavior, no device→host ACK before memory completion, host→device data availability after memory completion, completion status/beat count, arbitration cursor and final idle state.
- Failure records retain seed and epoch so every sequence is reproducible.

### M4f — M4 acceptance gate

**Status: complete and verified on exact code head `e58d9be003973a98fd26b620425d9e8ce1123dce`; dedicated Hardware PLIO Host M4 run `34993792187` passed.**

The same-commit acceptance gate passes all of the following:

- existing M1 Rust↔Bluesim exact differential;
- existing M2 Rust↔Bluesim exact differential;
- existing M3 Rust↔Bluesim exact differential;
- integrated deterministic 20-record `PLIOHOSTCORETRACE|v1` exact differential;
- seeded 64-event `PLIOHOSTSTRESS|v1` exact differential;
- standalone `mkPLIOWorkerHost.v` generation;
- standalone `mkPLIOHostManagerM2.v` generation;
- standalone `mkPLIOHostDmaM3.v` generation;
- standalone integrated `mkPLIOHostCore.v` generation;
- no unresolved G0036/G0117 completion-clear scheduling/ownership warnings in `mkPLIOHostCore`.

The final gate reports:

`PASS PLIO host M4a-M4f acceptance gate`

Note: the standalone legacy `mkPLIOHostDmaM3` compilation still reports its pre-existing public-method scheduling warnings. Those warnings are outside the integrated `mkPLIOHostCore` scheduler and are unchanged by M4; the M4f integrated-core warning gate is clean.

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

## Scope rule for `plio-host-adapter-m4`

M4a–M4f are implemented and verified. Do not start the RAX CPU/CSR attachment (M5), concrete RAX memory-controller bridge (M6), or full QDX integration (M7) until explicitly requested.
