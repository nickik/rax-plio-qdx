# Design rationale

## Why this is closer to SBus than PCI Express

Useful SBus lessons for PLIO are architectural simplicity rather than literal copying:

- a centralized bus controller,
- synchronous shared transfers,
- explicit request/grant arbitration for DMA-capable devices,
- geographic device selection,
- a small-system/motherboard-oriented topology,
- clear separation between workers and DMA-capable bus managers.

PLIO deliberately does **not** copy SBus DVMA page translation. QDX scatter/gather plus a small controller-owned DMA capability table give the first RAX system a simpler implementation and a clean microkernel security boundary.

PLIO also deliberately does **not** copy dedicated/asynchronous device interrupt wiring. Intelligent PLIO/QDX cards are already bus managers, so they signal completion with an ordinary write transaction to a fixed controller aperture.

## Why bounded burst DMA is in the baseline

A 32-bit multiplexed address/data bus wastes too much bandwidth if every longword requires a new arbitration and address phase. The extra logic for a short synchronous burst is small compared with the bus, transceivers, arbitration, and DMA protection hardware already required.

PLIO therefore defines only four burst lengths:

```text
1, 4, 8, or 16 longwords
```

Two `BLEN` control bits select the length. One address phase identifies the first device-visible DMA address, and subsequent accepted beats advance the translated host address by four bytes.

The maximum burst is deliberately only **16 longwords / 64 bytes**. After that transaction the grant ends and rotating round-robin arbitration runs again. This gives bulk storage, networking, graphics, and DSP traffic good efficiency without allowing one controller to hold the shared bus for an arbitrary transfer.

At PLIO-5 the raw 32-bit data rate is 20 MB/s. An idealized 16-word burst with one arbitration opportunity, one address phase, and sixteen no-wait data beats approaches 17.8 MB/s payload. Real systems will be lower because of memory wait states and contention, but burst mode lets the 5 MHz electrical standard remain useful much longer.

Burst is restricted to protected host-memory DMA in the baseline. Programmed MMIO and notification writes stay single-beat. This avoids forcing simple workers to implement FIFOs or block-transfer state.

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

The cost is one short bus transaction when notification is needed. Since QDX normally notifies on CQ empty -> non-empty rather than once per completion, this cost is small. The 64-byte maximum DMA burst also bounds how long an already-granted bulk transfer can delay a notification request.

## Why capability-scoped DMA channels

PLIO makes DMA authority explicit rather than giving a card unrestricted host physical addresses.

A 32-bit device-visible DMA address is:

```text
channel[31:28] | generation[27:24] | offset[23:0]
```

The controller therefore performs:

```text
slot from current bus grant
channel from address[31:28]
generation from address[27:24]
offset from address[23:0]
       |
       v
protected channel table
       |
       +-- validate generation
       +-- validate permissions
       +-- validate complete transfer/burst bounds
       |
       v
host_base + offset
```

There are sixteen channels per DMA-capable slot. Each mapping may cover up to 16 MiB. Scatter/gather can reference several channel/generation/offset handles when a transfer spans discontiguous regions.

This maps naturally onto a capability OS. Cosmic can require a driver to hold both device authority and memory authority before the kernel binds a memory region into a device channel. The card never sees an unrestricted host physical address and cannot reprogram the binding.

The 4-bit generation field provides temporal safety. When a channel is revoked and rebound, the generation changes, so a stale queued descriptor does not silently acquire authority to the replacement memory merely because the same channel number was reused. Generation wrap requires device quiescence/reset or another proof that old references cannot survive.

For a burst, the whole span must pass the generation, permission, and bounds checks before beat 0. If a mapping is revoked during an active burst, later beats must not continue using that authority.

This provides most of the protection benefit needed from later IOMMU-style systems without requiring page-table walking in a 1978 controller.

## Why geographic MMIO windows

With eight logical slots and a 32-bit physical address space, assigning each slot a fixed 32 MiB MMIO window removes BAR sizing, relocation registers, address-allocation firmware, and jumper configuration.

The device remains self-identifying through its fixed configuration header.

## Why QDX is separate

A queue ABI should survive changes to the physical bus. QDX profiles describe commands, queues, completions, namespaces/ports/endpoints, and scatter/gather independently of PLIO electrical details.

A future GNet storage transport could carry QDX semantics without pretending GNet is PLIO.

QDX also benefits directly from PLIO burst sizing: a 32-byte QDX-B submission descriptor fits naturally in an 8-longword burst, a 16-byte completion in a 4-longword burst, and bulk payloads can use repeated 16-longword bursts.

## Why not copy VAXBI

VAXBI contains useful precedents for arbitration, bus-manager DMA adapters, transaction error handling, and maintainability, but it is a much broader system interconnect with processor/memory-node and cache/multiprocessor concerns.

PLIO is intentionally only an I/O bus. Multiprocessor coherence, memory-node semantics, clustering, and processor-to-processor transactions belong elsewhere.

## Source material used as design references

- *SBus Specification B.0*, Sun Microsystems, December 1990.
- *VAXBI System Reference Manual*, Digital Equipment Corporation, revision February 1989.

These are design references, not normative dependencies.
