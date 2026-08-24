# Design rationale

## Why this is closer to SBus than PCI Express

Useful SBus lessons for PLIO are architectural simplicity rather than literal copying:

- a centralized bus controller,
- synchronous shared transfers,
- explicit request/grant arbitration for DMA-capable devices,
- geographic device selection,
- a small-system/motherboard-oriented topology,
- clear separation between workers and DMA-capable bus managers.

PLIO deliberately does **not** copy SBus DVMA page translation. QDX scatter/gather plus four small controller-owned DMA capability channels give the first RAX system a simpler implementation and a clean microkernel security boundary.

PLIO also deliberately does **not** copy dedicated/asynchronous device interrupt wiring. Intelligent PLIO/QDX cards are already bus managers, so they signal completion with an ordinary write transaction to a fixed controller aperture.

## Why message-signalled notification is preferable here

The earlier draft used one level-triggered IRQ wire per slot. That was rejected.

For this architecture, dedicated device IRQ lines have few advantages:

- every asynchronous QDX device already needs `BR/BG` to DMA;
- an IRQ wire adds pins/backplane traces and asynchronous synchronization logic;
- a level line carries almost no information beyond "service this device";
- physical interrupt wiring scales poorly to multiple queues/channels and future multiprocessors;
- bridges and virtualized devices must translate the physical line model.

The message model uses what PLIO already has:

```text
device requests bus
    -> receives grant
    -> writes fixed PLIO NOTIFY address
    -> controller records pending(slot, channel)
```

The controller knows the source from the bus grant, so the device cannot spoof another slot. The device also cannot choose its privilege, class, or CPU target.

This is **MSI-like**, but intentionally far simpler than PCI MSI/MSI-X:

- one fixed controller aperture,
- four small channels per slot,
- no arbitrary device-programmable target address,
- no large vector table in the device,
- no requirement for many queues,
- no dependency on PCI-style configuration machinery.

QDX puts real completion data in the CQ. The notification merely says that work is available, so repeated notifications can safely coalesce.

The cost is one short bus transaction when notification is needed. Since QDX normally notifies on CQ empty -> non-empty rather than once per completion, this cost is small.

## Why capability-scoped DMA channels

The earlier draft used four arbitrary `(device_base, host_base, length, permissions)` windows per slot. The revised design makes the capability structure explicit and simpler.

A device DMA address uses its top two bits as a channel selector and the remaining 30 bits as an offset. The controller therefore performs:

```text
slot from current bus grant
channel from address[31:30]
offset from address[29:0]
       |
       v
protected channel table -> host_base + offset
```

This needs a table lookup and bounds/permission check rather than four associative range comparisons.

It also maps naturally onto a capability OS. Cosmic can require a driver to hold both device authority and memory authority before the kernel binds a memory region into a device channel. The card never sees an unrestricted host physical address and cannot reprogram the binding.

Four channels are a deliberate first-generation compromise. A common QDX arrangement can dedicate one channel to queue/control memory and use the remaining channels for payload regions. Scatter/gather can reference offsets in any valid channel.

If workloads show that four channels are too restrictive, increasing the selector width is a later-version decision; device page-table walking is not required to solve the initial problem.

## Why geographic MMIO windows

With eight logical slots and a 32-bit physical address space, assigning each slot a fixed 32 MiB MMIO window removes BAR sizing, relocation registers, address-allocation firmware, and jumper configuration.

The device remains self-identifying through its fixed configuration header.

## Why QDX is separate

A queue ABI should survive changes to the physical bus. QDX profiles describe commands, queues, completions, namespaces/ports/endpoints, and scatter/gather independently of PLIO electrical details.

A future GNet storage transport could carry QDX semantics without pretending GNet is PLIO.

## Why not copy VAXBI

VAXBI contains useful precedents for arbitration, bus-manager DMA adapters, transaction error handling, and maintainability, but it is a much broader system interconnect with processor/memory-node and cache/multiprocessor concerns.

PLIO is intentionally only an I/O bus. Multiprocessor coherence, memory-node semantics, clustering, and processor-to-processor transactions belong elsewhere.

## Source material used as design references

- *SBus Specification B.0*, Sun Microsystems, December 1990.
- *VAXBI System Reference Manual*, Digital Equipment Corporation, revision February 1989.

These are design references, not normative dependencies.
