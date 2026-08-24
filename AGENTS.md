# AGENTS.md

## Project purpose

This repository specifies and simulates the **PLIO** peripheral bus and **QDX** queued-device model, including block storage, streaming, GNET, 2D graphics, and DSP profiles.

The architecture is being designed as if work began in the mid-1970s for a 1978-class implementation. Preserve that constraint.

## Non-negotiable architectural decisions

- Use the terms **bus manager** and **worker**.
- PLIO is a **shared, synchronous, parallel 32-bit peripheral I/O bus** with one central host controller.
- PLIO is **not a processor bus, memory bus, cache-coherent interconnect, or general system fabric**.
- CPUs and coherent memory live behind the host controller; they are not normal PLIO cards.
- The universal PLIO standard is host-neutral. Host CPU physical address maps belong in host profiles such as `PLIO-RAX.md`.
- PLIO has **8 logical peripheral slots**, each exposing a 32 MiB slot-relative worker address space.
- PLIO uses explicit transaction spaces: worker MMIO, protected host DMA, controller-local operations, and one reserved code.
- PLIO host-memory DMA supports **bounded 1/4/8/16-word 32-bit bursts in the baseline**.
- A grant covers at most one transaction; one DMA transaction may contain at most **16 longwords / 64 bytes**, after which arbitration resumes.
- Programmed MMIO and PLIO Notification writes remain single-beat in the baseline.
- PLIO has **no dedicated per-device interrupt line**.
- The canonical device-to-host asynchronous signalling mechanism is **PLIO Notification**: a bus manager writes to PLIO `CONTROLLER` space, not to a host physical address.
- Do **not** call PLIO Notification MSI or MSI-like in normative text. The mechanism has its own PLIO name and contract.
- The controller derives source identity from the active bus grant. Devices do not choose trusted slot ID, CPU vector, class, privilege, or CPU target.
- Normal PLIO Notifications have controller-assigned classes; critical platform events are outside normal PLIO device notification.
- The RAX host profile exposes aggregate eligible notification state to the CPU as **`NOTIFY_PENDING_INTERRUPT`**. This is a host-internal CPU interrupt condition, not a PLIO backplane signal.
- Bus managers perform DMA through controller-programmed **DMA capability channels**.
- Each DMA-capable slot has **16 DMA capability channels**.
- A 32-bit device-visible DMA address encodes **4-bit channel + 4-bit generation + 24-bit offset**.
- The controller validates `(source slot, channel, generation, offset, length, direction)` against a privileged mapping. A burst's complete extent must validate before beat 0.
- Revocation invalidates the mapping; rebinding advances generation so stale DMA references cannot silently gain access to replacement memory.
- Revocation during an active burst prevents later beats from continuing under revoked authority; backing memory cannot be reused until active use is terminated.
- Generation wrap requires proof that stale requests cannot survive; quiescing/resetting the slot is always sufficient.
- Do not add device page-table walking or a modern IOMMU protocol to the baseline.
- Privileged software binds/revokes DMA channels. The architecture should remain compatible with a capability-based microkernel where a driver holds authority to a device, memory object, DMA binding, and notification endpoint.
- QDX is above PLIO. PLIO defines transport/electrical/MMIO/DMA/notification behavior; QDX defines queues and device commands.
- **All QDX-defined multibyte control fields are little-endian regardless of host CPU byte order.**
- QDX baseline requires only one SQ and one CQ per device.
- QDX-B supports multiple namespaces behind one controller.
- QDX-G graphics and QDX-DSP are normal QDX/PLIO devices, not a second CPU-local accelerator architecture.
- QDX-G v0.1 MUST support graphics surfaces in ordinary host RAM. CPU software and QDX-G may operate on the same host-memory surface with explicit visibility/synchronization because PLIO is not cache coherent.
- Graphics/DSP local SRAM is an implementation detail unless a later optional profile explicitly exposes something else.
- QDX-DSP models computation on buffers; QDX-S models physical/sequential stream endpoints.
- The baseline plug-in physical profile is **PLIO-E: Eurocard mechanics with a 96-position DIN 41612-style P1 connector**.

## Simplicity rule

Before adding a mechanism, ask whether it is required for the target system, whether software can do it cheaply, whether it adds pins/protocol/configuration state, and whether it can be deferred.

The baseline burst mechanism is intentionally small: two `BLEN` wires, fixed 1/4/8/16-longword lengths, one bounded grant, sequential host addresses, and per-beat ACK/ERR/wait states.

**PLIO Notification** is intentionally small: one controller transaction space, four fixed offsets, source inferred from grant, and small per-slot pending state.

Do not copy PCI Express, MSI-X, NVMe, SBus DVMA, or later architectures wholesale.

## Normative specification style

Use **MUST / MUST NOT**, **SHOULD / SHOULD NOT**, and **MAY** consistently.

When changing a normative structure or binary layout:

- update the relevant file under `specs/`,
- update Python constants/models,
- add or update a test,
- update `docs/ROADMAP.md` if compatibility is affected,
- update the relevant host/physical profile rather than leaking platform-specific details back into the universal PLIO core.

## Simulation rules

Maintain three conceptual levels:

1. functional QDX model — queues, canonical byte order, commands, completions, capability-scoped DMA, PLIO Notifications;
2. cycle-level PLIO model — transaction spaces, arbitration, address/data phases, bounded bursts, waits, timeout, PLIO Notification timing;
3. RTL — only after the first two stabilize.

Python simulation code must use only the standard library unless strongly justified, remain deterministic by default, expose traceable transactions, and test error paths.

## Immediate priorities

1. Expand the PLIO cycle model to explicit `SPACE`, address/data, and `BLEN` phases.
2. Add rotating round-robin arbitration and mandatory re-arbitration after every transaction/burst.
3. Add 1/4/8/16-beat host-memory DMA burst sequencing with complete-range capability validation.
4. Model `SPACE=CONTROLLER` PLIO Notification as a real single-beat bus transaction and measure contention behind a maximum burst.
5. Add per-beat wait states, timeout, and worker error responses.
6. Add active-burst DMA revoke/interlock behavior.
7. Add QDX-B scatter/gather execution across capability channels using bounded bursts.
8. Add binary descriptor serialization tests using canonical little-endian QDX fields.
9. Add RAX host-profile mapping tests and keep host physical addresses out of the generic PLIO model.
10. Add namespace IDENTIFY structures and tests.
11. Add user/kernel PLIO Notification latency scenarios using `NOTIFY_PENDING_INTERRUPT` on RAX.
12. Add generation-aware cycle-model tests including stale-reference rejection and wrap/reset behavior.
13. Add functional QDX-G and QDX-DSP coverage after command layouts are frozen.
14. Only then create small SystemVerilog PLIO controller/interface blocks and compare traces to the Python reference model.
