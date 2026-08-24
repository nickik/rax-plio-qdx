# AGENTS.md

## Project purpose

This repository specifies and simulates the RAX **PLIO** I/O bus and **QDX** queued-device model, including block storage, streaming, GNET, 2D graphics, and DSP profiles.

The architecture is being designed as if it were started in the mid-1970s for a 1978-class RAX system. Preserve that constraint.

## Non-negotiable architectural decisions

- Use the terms **bus manager** and **worker**.
- PLIO is a **shared, synchronous, parallel 32-bit I/O bus** with a central controller.
- PLIO is **not** the CPU-memory bus and is not cache coherent.
- PLIO has **8 logical slots**, each with a fixed geographic MMIO window.
- PLIO has **no dedicated per-device interrupt line**.
- Normal device notification is **message-signalled**: a bus manager writes to a fixed controller-owned notification aperture.
- The controller derives source identity from the active bus grant. Devices do not choose their trusted slot ID, CPU vector, class, or privilege.
- Normal notifications have controller-assigned classes; critical platform events are outside normal PLIO device notification.
- Bus managers perform DMA through controller-programmed **DMA capability channels**. A 32-bit device DMA address encodes a channel selector plus offset.
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
2. cycle-level PLIO model — arbitration, address/data phases, wait states, timeout, NOTIFY timing;
3. RTL — only after the first two stabilize.

Python simulation code must use only the standard library unless strongly justified, remain deterministic by default, expose traceable transactions, and test error paths.

## Immediate Codex priorities

1. Expand the PLIO cycle model to explicit address/data phases.
2. Add rotating round-robin arbitration among bus managers.
3. Model `NOTIFY` as an actual controller-target bus write and measure contention latency.
4. Add timeout and worker error responses.
5. Add QDX-B scatter/gather execution across DMA capability channels.
6. Add namespace IDENTIFY structures and tests.
7. Add user/kernel notification-latency scenarios using the RAX normal/critical event model.
8. Add functional QDX-G and QDX-DSP reference-model coverage after their command layouts are frozen.
9. Only then create a small SystemVerilog PLIO controller and compare traces to the Python reference model.
