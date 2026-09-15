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

**Status: planned on branch `plio-host-adapter-m4`; not yet implemented.**

M4 combines the independently verified M1/M2/M3 engines into the actual host-independent PLIO bus controller. There must be exactly one owner of the physical PLIO output image each cycle and one explicit scheduler deciding whether the host is acting as worker, bus manager for a card transaction, DMA target/source, or idle.

### M4a — Freeze the integrated scheduling contract

- Define the Rust `PLIOHostCore` top-level API before composing implementations.
- Inputs must include:
  - current physical PLIO card/backplane input image;
  - eight card request lines;
  - optional host worker request;
  - host-memory request readiness / response;
  - reset.
- Outputs must include:
  - one canonical PLIO host/backplane drive image;
  - optional worker completion;
  - optional host-memory request;
  - notification-pending summary / claim information;
  - typed host fault/completion state;
  - detailed debug snapshot.
- Define scheduler priority explicitly and identically in Rust and Bluespec.
- Proposed initial priority:
  1. reset / abort cleanup;
  2. finish an already-active physical PLIO transaction;
  3. service an already-active DMA memory beat;
  4. accept/advance a host worker operation;
  5. arbitrate a requesting card;
  6. idle.
- A started transaction cannot be preempted by a new worker request or another card request.
- Remove the remaining M3 public-method scheduler ambiguity by placing M3 behind the integrated core scheduler instead of allowing unrelated action methods to fire concurrently.
- Freeze debug ownership fields: active role, active slot, PLIO phase, DMA phase, memory-port phase, arbitration cursor, wait counter, completion/fault.

### M4b — Rust `PLIOHostCore` composition

- Compose the existing M1 worker, M2 manager/notification and M3 DMA capability/memory semantics behind one Rust core.
- Reuse M1/M2/M3 logic rather than creating a second independent implementation.
- Implement one `step()`/cycle transition that computes the only physical PLIO output image.
- Card-request arbitration must feed either notification handling or DMA transaction handling according to the actual controller-space address phase received from the card.
- Host worker operations must coexist correctly with card-originated manager transactions.
- DMA capability lookup must happen before acknowledging the device DMA address phase.
- Memory stalls must stall only the active DMA transaction, not corrupt worker or arbitration state.
- Preserve exact M1/M2/M3 timeout and partial-progress rules.
- Add integrated invariants:
  - never more than one PLIO driver owner;
  - never grant two slots simultaneously;
  - no DMA ACK before capability validation;
  - no device→host DMA beat ACK before corresponding memory write completion;
  - no host→device data beat before memory read completion;
  - worker bus image remains stable while stalled;
  - reset leaves bus tri-stated and no stale completion appears.

### M4c — Bluespec `mkPLIOHostCore`

- Build the synthesizable Bluespec top from the verified M1/M2/M3 blocks or shared extracted logic.
- Introduce one explicit top-level scheduler/arbiter for all host-side bus ownership.
- Do not rely on rule-order shadowing to resolve ownership.
- Eliminate/scope the M3 same-cycle action warnings through structural composition rather than warning suppression.
- Expose the same logical top-level interfaces and debug state as Rust.
- Ensure all host outputs are deterministic and tri-stated when idle/reset.
- Generate standalone `mkPLIOHostCore.v`.

### M4d — Integrated deterministic differential tests

Create `PLIOHOSTCORETRACE|v1` and exact-diff Rust vs Bluesim.

Mandatory scenarios:

1. host worker read while no card requests;
2. host worker write with address/data waits;
3. card request arriving during an active worker operation waits until worker completion;
4. two card requests demonstrate rotating round-robin grant order;
5. notification transaction end-to-end through the integrated manager;
6. device→host DMA burst through capability validation and asynchronous memory writes;
7. host→device DMA burst through asynchronous memory reads;
8. memory backpressure during DMA;
9. notification immediately followed by DMA from the same slot;
10. worker request queued while DMA is active;
11. invalid/stale DMA generation rejected before transfer;
12. permission/range failure;
13. PLIO parity error during DMA;
14. host-memory fault after partial DMA progress;
15. exact 256-cycle timeout in each applicable integrated phase;
16. reset during worker address/data;
17. reset during grant/address phase;
18. reset during DMA memory wait;
19. revoke during active DMA;
20. mixed multi-slot sequence proving no stale grant/completion/state leakage.

For every scenario compare at least:
- physical bus drive/phase ordering where deterministic;
- selected/granted slot;
- worker result;
- DMA completion status and acknowledged beat count;
- host-memory addresses/data/direction;
- notification pending/payload;
- arbitration cursor;
- final idle/debug state.

### M4e — Seeded stress/conformance

- Add deterministic seeded mixed worker/card/DMA/notification sequences.
- Use bounded random wait states on both PLIO and memory sides.
- Randomly insert legal card requests, notifications, DMA bursts and worker accesses.
- Compare Rust and Bluesim after every semantic event and at final state.
- Keep failures reproducible by printing seed, cycle, active role, slot, PLIO phase and memory phase.
- Include assertions for one-hot grant, single bus owner, capability bounds and no ACK-before-memory-completion.

### M4f — M4 acceptance gate

M4 is complete only when all of the following pass on the same commit:

- existing M1 Rust↔Bluesim exact differential;
- existing M2 Rust↔Bluesim exact differential;
- existing M3 Rust↔Bluesim exact differential;
- integrated deterministic `PLIOHOSTCORETRACE|v1` exact differential;
- seeded integrated stress differential;
- standalone `mkPLIOWorkerHost.v` generation;
- standalone `mkPLIOHostManagerM2.v` generation;
- standalone `mkPLIOHostDmaM3.v` generation;
- standalone integrated `mkPLIOHostCore.v` generation;
- no unresolved Bluespec scheduling/ownership warnings in `mkPLIOHostCore` that can change externally visible behavior.

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

Implement M4 only. Do not start the RAX CPU/CSR attachment (M5), concrete RAX memory-controller bridge (M6), or full QDX integration (M7) until M4's integrated Rust↔Bluesim gate is fully green.