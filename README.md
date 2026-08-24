# RAX PLIO / QDX

Draft specifications and executable reference models for the RAX **PLIO** peripheral bus and **QDX** queued-device interface.

The design target is a late-1970s RAX system. The project deliberately favors a small, synchronous, shared 32-bit I/O bus over later fabric-style designs.

## Documents

- [`specs/PLIO.md`](specs/PLIO.md) — PLIO bus standard.
- [`specs/QDX.md`](specs/QDX.md) — common queued-device model.
- [`specs/QDX-B.md`](specs/QDX-B.md) — basic block-storage profile.
- [`specs/QDX-BA.md`](specs/QDX-BA.md) — optional block acceleration.
- [`specs/QDX-S.md`](specs/QDX-S.md) — basic streaming-device profile.
- [`specs/QDX-SA.md`](specs/QDX-SA.md) — optional streaming acceleration.
- [`specs/QDX-GNET.md`](specs/QDX-GNET.md) — basic GNET frame I/O profile.
- [`specs/QDX-GNETA.md`](specs/QDX-GNETA.md) — optional GNET acceleration.
- [`specs/RAX-INTERRUPTS.md`](specs/RAX-INTERRUPTS.md) — RAX/PLIO notification integration.
- [`docs/DESIGN-RATIONALE.md`](docs/DESIGN-RATIONALE.md) — architectural reasoning.
- [`docs/SIMULATION.md`](docs/SIMULATION.md) — simulation strategy.
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — open design decisions and implementation work.
- [`AGENTS.md`](AGENTS.md) — instructions for Codex and other coding agents.

## Current baseline

- 32-bit synchronous shared PLIO bus.
- Central PLIO controller.
- Eight logical slots with geographic MMIO windows.
- Per-slot request/grant for bus-manager ownership.
- **No dedicated device interrupt lines.**
- Normal device completion uses **message-signalled PLIO notifications**: a bus-manager write to a controller-owned notification aperture.
- Four controller-assigned normal notification classes; the device cannot choose privilege or priority.
- Separate critical platform handling outside ordinary PLIO device notification.
- Four protected **DMA capability channels** per bus-manager slot.
- Device DMA addresses encode a channel number plus offset; the controller maps that capability to host physical memory and permissions.
- QDX uses one submission queue and one completion queue in v0.1.
- Base profiles define the minimum device abstraction; `A` profiles are optional acceleration only.
- QDX-B supports multiple block namespaces.

## Capability rule

PLIO devices never receive unrestricted host physical-memory access. Privileged system software binds a host memory region and permissions to one of the device's DMA capability channels. The card addresses only `(channel, offset)`; the PLIO controller performs bounds/permission checks and translation.

The operating system may represent authority to create, bind, revoke, or use those channels as capability objects. The hardware contract is the small protected per-slot channel table, not device-side page-table walking.

## Profile rule

QDX-B/QDX-S/QDX-GNET define what a device class can do. QDX-BA/QDX-SA/QDX-GNETA let more intelligent hardware perform equivalent work more efficiently.

Correctness must remain possible using the base profile. Acceleration profiles must not absorb higher-level filesystem, networking, graphics, or application policy.

## Run the reference model

Requires Python 3.11+ and no third-party dependencies.

```bash
python -m unittest discover -s tests -v
PYTHONPATH=. python -m sim.plio_sim.scenario
```

The current Python model is functional rather than cycle accurate. The next major step is the explicit clock-by-clock PLIO transaction state machine described in `docs/SIMULATION.md`.

## Design rule

PLIO's notification mechanism is **MSI-like in principle but intentionally much smaller than PCI MSI/MSI-X**. A device writes to one fixed controller aperture; the controller derives the source from bus ownership and supplies policy such as class/masking. Devices do not program arbitrary interrupt target addresses or CPU vectors.

This repository does not copy PCI Express, NVMe, or other later standards wholesale. Every mechanism must justify its hardware and protocol cost for the target RAX system.
