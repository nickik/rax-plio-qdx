# AGENTS.md

## Project purpose

This repository specifies and simulates the RAX **PLIO** I/O bus and **QDX** queued-device model, including block storage, streaming, GNET, 2D graphics, and DSP profiles.

The architecture is being designed as if it were started in the mid-1970s for a 1978-class RAX system. Preserve that constraint.

## Non-negotiable architectural decisions

- Use the terms **bus manager** and **worker**.
- PLIO is a **shared, synchronous, parallel 32-bit I/O bus** with a central controller.
- PLIO is **not** the CPU-memory bus and is not cache coherent.
- PLIO has **8 logical slots**, each with a fixed geographic MMIO window.
- PLIO host-memory DMA supports **bounded 1/4/8/16-word 32-bit bursts in the baseline**.
- A bus grant covers at most one transaction; one DMA transaction may contain at most **16 longwords / 64 bytes**, after which arbitration resumes.
- Programmed MMIO and notification writes remain single-beat in the baseline. Do not add worker-side block MMIO unless a later profile explicitly requires it.
- PLIO has **no dedicated per-device interrupt line**.
- Normal device notification is **message-signalled**: a bus manager writes to a fixed controller-owned notification aperture.
- The controller derives source identity from the active bus grant. Devices do not choose their trusted slot ID, CPU vector, class, or privilege.
- Normal notifications have controller-assigned classes; critical platform events are outside normal PLIO device notification.
- Bus managers perform DMA through controller-programmed **DMA capability channels**.
- Each DMA-capable slot has **16 DMA capability channels**.
- A 32-bit device-visible DMA address encodes **4-bit channel + 4-bit generation + 24-bit offset**.
- The controller validates `(source slot, channel, generation, offset, length, operation)` against a privileged mapping to host physical memory. For a burst, the complete burst extent must validate before beat 0.
- Revocation invalidates the mapping; rebinding advances the generation so stale DMA references cannot silently gain access to a replacement memory object.
- Revocation during an active burst must prevent later beats from using the revoked mapping; backing memory is not reusable until active use is terminated.
- Generation wrap requires proof that stale requests cannot survive; quiescing/resetting the slot is always sufficient.
- Do not add device page-table walking or a modern IOMMU protocol to the baseline.
- Privileged software binds/revokes DMA channels. The architecture should remain compatible with a capability-based microkernel where a driver holds authority to a device, memory object, DMA binding, and notification endpoint.
- QDX is above PLIO. PLIO defines transport/electrical/MMIO/DMA/notification behavior; QDX defines queues and device commands.
- QDX baseline requires only one SQ and one CQ per device.
- QDX-B supports multiple namespaces behind one controller.
- **QDX-G graphics and QDX-DSP are normal QDX/PLIO devices, not a second CPU-local accelerator architecture.** They reuse the standard SQ/CQ, capability-DMA, and message-signalled completion model.
- QDX-G v0.1 MUST support graphics surfaces in ordinary host RAM. CPU software and QDX-G may operate on the same host-memory surface with explicit visibility/synchronization because PLIO is not cache coherent.
- Graphics/DSP local SRAM is an implementation detail unless a later optional profile explicitly exposes something else. Do not make SRAM size, banking, or addresses part of the portable host ABI.
- QDX-DSP models computation on buffers; QDX-S models physical/sequential stream endpoints. A device may implement both profiles, but do not merge the semantics.
- A later QDX-G device may add private VRAM, scanout, or 3D acceleration without changing the base QDX queue and PLIO protection model.

## Simplicity rule

Before adding any mechanism, ask whether it is required for the target RAX system, whether software can do it cheaply, whether it adds wire/protocol/configuration state, and whether it can be deferred.

The baseline burst mechanism is intentionally small: two `BLEN` wires, fixed 1/4/8/16-longword lengths, one bounded grant, sequential host addresses, and per-beat ACK/ERR/wait states. Do not turn it into an arbitrary-length streaming protocol.

Do not copy PCI Express, MSI-X, NVMe, or later architectures wholesale. The PLIO message notification mechanism is intentionally tiny: fixed aperture, source inferred from grant, small per-slot channel state.

## Normative specification style

Use **MUST / MUST NOT**, **SHOULD / SHOULD NOT**, and **MAY** consistently.

When changing a normative structure or binary layout:

- update the relevant file under `specs/`,
- update Python constants/models,
- add or update a test,
- update `docs/ROADMAP.md` if compatibility is affected.

## Simulation rules

Maintain three conceptual levels:

1. functional QDX model — queues, commands, completions, capability-scoped DMA and notification;
2. cycle-level PLIO model — arbitration, address/data phases, bounded bursts, wait states, timeout, NOTIFY timing;
3. RTL — only after the first two stabilize.

Python simulation code must use only the standard library unless strongly justified, remain deterministic by default, expose traceable transactions, and test error paths.

## Immediate Codex priorities

1. Expand the PLIO cycle model to explicit address/data phases and `BLEN` handling.
2. Add rotating round-robin arbitration among bus managers and mandatory re-arbitration after each burst.
3. Add 1/4/8/16-beat host-memory DMA burst sequencing, including full-range capability validation.
4. Model `NOTIFY` as an actual controller-target single-beat bus write and measure contention latency behind a 16-word burst.
5. Add per-beat wait states, timeout, and worker error responses.
6. Add active-burst DMA revocation/interlock behavior.
7. Add QDX-B scatter/gather execution across DMA capability channels using bounded PLIO bursts.
8. Add namespace IDENTIFY structures and tests.
9. Add user/kernel notification-latency scenarios using the RAX normal/critical event model.
10. Add generation-aware DMA capability tests to the cycle model, including stale-reference rejection and wrap/reset behavior.
11. Add functional QDX-G and QDX-DSP reference-model coverage after their command layouts are frozen.
12. Only then create a small SystemVerilog PLIO controller and compare traces to the Python reference model.
