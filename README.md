# RAX PLIO / QDX

Draft specifications and executable reference models for the **PLIO** peripheral bus and **QDX** queued-device interface.

The design target is a late-1970s implementation, but PLIO is deliberately structured as a host-independent peripheral standard rather than a RAX-only CPU/system bus.

## Documents

- [`specs/PLIO.md`](specs/PLIO.md) — host-independent PLIO logical bus standard.
- [`specs/PLIO-E.md`](specs/PLIO-E.md) — Eurocard physical/backplane profile.
- [`specs/PLIO-RAX.md`](specs/PLIO-RAX.md) — RAX host address/notification integration profile.
- [`specs/QDX.md`](specs/QDX.md) — common queued-device model and canonical little-endian ABI.
- [`specs/QDX-B.md`](specs/QDX-B.md) — basic block-storage profile.
- [`specs/QDX-BA.md`](specs/QDX-BA.md) — optional block acceleration.
- [`specs/QDX-S.md`](specs/QDX-S.md) — basic streaming-device profile.
- [`specs/QDX-SA.md`](specs/QDX-SA.md) — optional streaming acceleration.
- [`specs/QDX-GNET.md`](specs/QDX-GNET.md) — basic GNET frame I/O profile.
- [`specs/QDX-GNETA.md`](specs/QDX-GNETA.md) — optional GNET acceleration.
- [`specs/QDX-G.md`](specs/QDX-G.md) — asynchronous 2D graphics profile.
- [`specs/QDX-DSP.md`](specs/QDX-DSP.md) — buffer-oriented DSP accelerator profile.
- [`specs/RAX-INTERRUPTS.md`](specs/RAX-INTERRUPTS.md) — RAX/PLIO Notification and CPU interrupt integration.
- [`docs/DESIGN-RATIONALE.md`](docs/DESIGN-RATIONALE.md) — architectural reasoning.
- [`docs/SIMULATION.md`](docs/SIMULATION.md) — simulation strategy.
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — open design decisions and implementation work.
- [`AGENTS.md`](AGENTS.md) — repository instructions.

## Current PLIO baseline

- 32-bit synchronous shared peripheral bus.
- Exactly one host-side PLIO controller per segment.
- Eight logical peripheral slots.
- **PLIO is not a processor bus, memory bus, or coherent system interconnect.**
- Host CPU physical addresses are defined by host profiles, not by the universal bus standard.
- Four transaction spaces distinguish worker MMIO, host-memory DMA, controller-local operations, and future use.
- Per-slot request/grant for bus-manager ownership.
- Baseline host-memory DMA bursts of 1, 4, 8, or 16 32-bit words.
- A grant covers at most one bounded 64-byte burst, after which arbitration resumes.
- Programmed MMIO and PLIO Notifications remain single-beat.
- **No dedicated device interrupt lines.**
- Normal device signalling uses **PLIO Notification**, a bus-local controller transaction to `CONTROLLER` space.
- The controller derives source identity from the active grant.
- Four controller-owned notification channels per slot; notification class/priority is host policy and cards do not choose CPU vectors or targets.
- Sixteen protected DMA capability channels per bus-manager slot.
- 32-bit device DMA handle: **4-bit channel + 4-bit generation + 24-bit offset**.
- The controller checks generation, bounds, direction permission, and complete burst extent before DMA begins.
- Rebinding advances generation so stale queued DMA handles cannot silently acquire authority to replacement memory.
- `PLIO-E` uses 3U/6U × 160 mm Eurocard mechanics and one 96-position DIN 41612-style P1 connector.

## Host independence

The universal PLIO standard does not contain the RAX address range `0xF0000000..0xFFFFFFFF`.

Instead, a host profile maps CPU addresses to:

```text
(slot, slot-relative worker offset)
```

The RAX host profile retains the historical geographic mapping:

```text
0xF000_0000 .. 0xFFFF_FFFF
```

but this is a RAX platform decision, not something a PLIO card must understand.

Likewise, a PLIO Notification does not use a host physical address such as the older draft's `0xEFFF_F000`. A card issues:

```text
SPACE = CONTROLLER
AD    = 0x0, 0x4, 0x8, or 0xC
```

and the host profile decides how pending/claim state is represented to its CPU/kernel.

For RAX, the aggregate CPU-side condition is named:

```text
NOTIFY_PENDING_INTERRUPT
```

This is an internal host-controller-to-CPU interrupt condition, not a PLIO backplane signal.

## QDX byte order

All QDX-defined multibyte control fields are **little-endian**, independent of host CPU byte order.

This includes queue descriptors, completions, SG entries, IDENTIFY structures, and profile control blocks. Opaque payload bytes are not transformed merely because they travel through QDX.

## Capability rule

PLIO devices never receive unrestricted host physical-memory access. Privileged software binds a host memory region and permissions to one of the device's DMA capability channels. The card addresses only `(channel, generation, offset)`; the PLIO controller performs enforcement and translation.

For a burst, the full span must validate before beat 0. Revocation during an active burst prevents later beats from continuing with revoked authority.

A capability-oriented microkernel may represent authority to the device, memory object, DMA binding, and notification endpoint as software capabilities while using the small PLIO hardware table as the enforcement mechanism.

## Profile rule

QDX-B/QDX-S/QDX-GNET/QDX-G/QDX-DSP define device-class contracts above the same QDX queue and PLIO DMA/notification mechanisms. Optional `A` profiles let more intelligent hardware accelerate equivalent work without making correctness depend on proprietary features.

QDX-G and QDX-DSP do not introduce a second accelerator interconnect. Graphics and DSP may be onboard or plug-in PLIO devices while presenting the same software contract.

## Run the reference model

Requires Python 3.11+ and no third-party dependencies.

```bash
python -m unittest discover -s tests -v
PYTHONPATH=. python -m sim.plio_sim.scenario
```

The current Python model is functional rather than fully cycle-accurate. The next major step is the explicit clock-by-clock PLIO transaction/arbitration/burst model described in `docs/SIMULATION.md`.

## Design rule

PLIO deliberately standardizes **peripheral I/O**, not processors. A RAX, PDP-derived, PACE, 68000, 8086, or other computer may host PLIO through its own controller/profile, but CPUs and coherent memory are not ordinary PLIO cards.

The canonical name for the device-to-host asynchronous signalling mechanism is **PLIO Notification**. It is deliberately small: fixed controller-local offsets, source inferred from the active grant, small pending state, no arbitrary target addresses, and no card-selected CPU vectors.

The design deliberately avoids copying later fabrics wholesale. Every mechanism must remain defensible for a 1978 implementation.
