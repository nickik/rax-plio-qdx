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
- [`specs/QDX-G.md`](specs/QDX-G.md) — asynchronous 2D graphics profile.
- [`specs/QDX-DSP.md`](specs/QDX-DSP.md) — buffer-oriented DSP accelerator profile.
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
- **Baseline host-memory DMA bursts of 1, 4, 8, or 16 32-bit words.**
- A grant may cover one bounded burst, with arbitration repeated after at most 16 longwords / 64 bytes.
- Programmed MMIO and notification transactions remain single-beat.
- **No dedicated device interrupt lines.**
- Normal device completion uses **message-signalled PLIO notifications**: a bus-manager write to a controller-owned notification aperture.
- Four controller-assigned normal notification classes; the device cannot choose privilege or priority.
- Separate critical platform handling outside ordinary PLIO device notification.
- Sixteen protected **DMA capability channels** per bus-manager slot.
- A 32-bit device DMA address encodes **4-bit channel + 4-bit generation + 24-bit offset**.
- The controller maps `(source slot, channel)` to host physical memory and checks generation, bounds, and device-read/device-write permissions.
- Revocation invalidates a channel; rebinding advances its generation so stale queued DMA references cannot silently acquire authority to replacement memory.
- QDX uses one submission queue and one completion queue in the baseline.
- Base profiles define the minimum device abstraction; `A` profiles are optional acceleration only.
- QDX-B supports multiple block namespaces.
- QDX-G defines asynchronous 2D acceleration and MUST support host-RAM graphics surfaces; optional device SRAM is an implementation detail.
- QDX-DSP defines asynchronous block-oriented signal processing over capability-scoped host buffers.

## Capability rule

PLIO devices never receive unrestricted host physical-memory access. Privileged system software binds a host memory region and permissions to one of the device's DMA capability channels. The card addresses only `(channel, generation, offset)`; the PLIO controller performs generation, bounds, permission, and physical-address translation checks.

A PLIO burst is validated as one bounded authority use: the complete 1/4/8/16-word span must fit inside one active capability mapping before the first beat is accepted. The controller then increments the translated host address per acknowledged beat.

The operating system may represent authority to create, bind, revoke, or use those channels as capability objects. The hardware contract is the small protected per-slot channel table, not device-side page-table walking.

Generation values are for stale-reference rejection, not secrecy. Before a finite generation value is safely reused, software must guarantee that old requests carrying that value cannot survive; resetting/quiescing the slot is sufficient.

## Profile rule

QDX-B/QDX-S/QDX-GNET/QDX-G/QDX-DSP define device-class contracts above the same QDX queue and PLIO DMA/notification mechanisms. Optional `A` profiles let more intelligent block/stream/network hardware perform equivalent work more efficiently.

QDX-G and QDX-DSP do **not** introduce a second accelerator interconnect. Graphics and DSP may be soldered to the motherboard or placed on expansion cards, but software sees normal QDX devices either way.

Correctness must remain possible using the base profile. Acceleration profiles must not absorb higher-level filesystem, networking, graphics, audio, or application policy.

## Graphics and DSP model

The baseline graphics model keeps framebuffer surfaces in ordinary host RAM so CPU software and QDX-G can operate on the same objects. A display server normally owns the QDX-G capability and chooses between CPU rendering and queued hardware operations. A QDX-G implementation may use private SRAM internally to tile and pipeline work, but software does not address that SRAM directly.

The baseline DSP model similarly treats the DSP as a queued computational worker. It consumes and produces capability-scoped host buffers and may use private local SRAM, coefficient memory, or microcode internally. QDX-S remains the profile for physical stream endpoints such as audio I/O; QDX-DSP is the profile for computation on buffers.

## Run the reference model

Requires Python 3.11+ and no third-party dependencies.

```bash
python -m unittest discover -s tests -v
PYTHONPATH=. python -m sim.plio_sim.scenario
```

The current Python model is functional rather than cycle accurate. The next major step is the explicit clock-by-clock PLIO transaction and burst state machine described in `docs/SIMULATION.md`.

## Design rule

PLIO's notification mechanism is **MSI-like in principle but intentionally much smaller than PCI MSI/MSI-X**. A device writes to one fixed controller aperture; the controller derives the source from bus ownership and supplies policy such as class/masking. Devices do not program arbitrary interrupt target addresses or CPU vectors.

PLIO burst mode is likewise deliberately small: two `BLEN` control bits select only 1/4/8/16 longwords, bursts are host-memory DMA only, and every grant is bounded to at most 64 bytes before arbitration resumes.

This repository does not copy PCI Express, NVMe, or other later standards wholesale. Every mechanism must justify its hardware and protocol cost for the target RAX system.
