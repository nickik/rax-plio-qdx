# AGENTS.md

## Project purpose

This repository specifies and simulates the RAX **PLIO** I/O bus and **QDX** queued-device model, with **QDX-B block storage** as the first complete profile.

The architecture is being designed as if it were started in the mid-1970s for a 1978-class RAX system. Preserve that constraint.

## Non-negotiable architectural decisions

- Use the terms **bus manager** and **worker**. Do not use master/slave terminology in new text or code.
- PLIO is a **shared, synchronous, parallel 32-bit I/O bus** with a central PLIO controller.
- PLIO is **not** the CPU-memory bus and is **not** cache coherent.
- PLIO v0.1 has **8 logical slots**, each with a fixed geographic MMIO window.
- PLIO v0.1 uses **one level-triggered IRQ line per slot**. Do not add MSI/MSI-X/message-signalled interrupts unless a later spec version explicitly adopts them.
- Normal interrupts have **four controller-assigned classes (0..3)**. The device does not choose its own class.
- A separate platform **critical interrupt** may interrupt kernel mode, but it is not a normal PLIO device interrupt.
- Bus managers perform DMA through controller-programmed **DMA windows**. Do not add device page-table walking or a modern IOMMU protocol to v0.1.
- QDX is above PLIO. PLIO defines transport/electrical/MMIO/DMA/IRQ behavior; QDX defines queues and device commands.
- QDX v0.1 requires only **one submission queue and one completion queue** per device.
- QDX-B supports **multiple namespaces** behind one controller.
- Keep IPC implications in mind: the RAX microkernel has very small register IPC and normal kernel paths should remain short and mostly non-preemptible.

## Simplicity rule

Before adding any mechanism, ask:

1. Is it required for a 1978 RAX/QDX-B system?
2. Can software do it without making the common path materially slower?
3. Does it add new wire states, negotiation states, or configuration state?
4. Can the feature be an optional later extension instead?

Prefer the smaller design unless there is measured benefit.

Do not copy PCI Express or NVMe architecture wholesale. Later standards may be useful as evidence that a concept works, but the implementation must be reduced to what is credible and useful for this architecture.

## Normative specification style

Use these words consistently:

- **MUST / MUST NOT** — required for conformance.
- **SHOULD / SHOULD NOT** — recommended unless a documented reason exists.
- **MAY** — optional.

When changing any normative structure or binary layout:

- update the relevant file under `specs/`,
- update the Python constants/packers,
- add or update a test,
- update `docs/ROADMAP.md` if compatibility is affected.

## Simulation rules

The simulator is an executable architectural model, not a performance claim.

Maintain three conceptual levels:

1. **Functional QDX model** — queues, commands, completions, DMA visibility.
2. **Cycle-level PLIO model** — arbitration, address/data phases, wait states, timeout, IRQ timing.
3. **RTL** — only after the first two stabilize.

Do not jump directly to RTL for unresolved protocol questions.

Python simulation code must:

- use only the standard library unless there is a strong reason otherwise,
- remain deterministic by default,
- expose traceable transactions,
- test error paths as well as success paths.

## Immediate Codex priorities

1. Expand the PLIO cycle model from aggregate cycle counts to explicit address/data phases.
2. Add round-robin arbitration among multiple bus managers.
3. Add PLIO timeout and worker error responses.
4. Add QDX-B scatter/gather list execution.
5. Add namespace IDENTIFY data structures and tests.
6. Add a user/kernel interrupt-latency scenario using the RAX normal/critical interrupt model.
7. Only after these are stable, create a small SystemVerilog PLIO controller prototype and compare its trace to the Python reference model.
