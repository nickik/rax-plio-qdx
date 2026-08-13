# Design rationale

## Why this is closer to SBus than PCI Express

The useful SBus lessons for PLIO are architectural simplicity rather than literal copying:

- a centralized bus controller,
- synchronous shared transfers,
- explicit request/grant arbitration for DMA-capable devices,
- geographic device selection,
- a small-system/motherboard-oriented topology,
- clear separation between bus workers and DMA-capable bus managers,
- centralized synchronization of asynchronous device interrupts.

The SBus B.0 specification describes a centralized controller, synchronous operation, request/grant arbitration, geographic selection, DVMA support, and a small physical-span system design. Those are useful precedents for a compact RAX I/O bus.

PLIO deliberately does **not** copy SBus DVMA page translation. QDX scatter/gather plus controller DMA windows give the first RAX system a simpler implementation and a clean microkernel security boundary.

SBus also used shared asynchronous interrupt lines. PLIO v0.1 takes an even simpler-to-route small-system approach: one dedicated level IRQ per logical slot, synchronized and prioritized by the central controller.

## Why not copy VAXBI

VAXBI demonstrates several concepts worth retaining:

- centralized/standard bus node behavior,
- explicit arbitration,
- bus-manager DMA adapters,
- transaction error handling,
- device interrupt/vector concepts,
- strong maintainability expectations.

But VAXBI grew into a broad system interconnect with:

- multiple transaction types,
- multiprocessor/cache interactions,
- many interrupt transaction cases,
- node register requirements,
- sophisticated retry/status behavior,
- extensive electrical/mechanical/system rules.

That is too broad for the first PLIO target.

PLIO is intentionally only an **I/O bus**. Multiprocessor coherence, memory-node semantics, console protocol, clustering, and processor-to-processor transactions belong elsewhere.

## Why no message-signalled interrupts in v0.1

A message-signalled interrupt is elegant once a transaction fabric already exists, but it is not necessary for the first PLIO/QDX-B implementation.

QDX already places the real completion information in memory. One level-triggered interrupt per device is enough to say:

> drain the completion queue.

With only eight slots, eight dedicated IRQ wires are cheap, easy to debug, and remove an interrupt-message transaction from the bus protocol.

The interrupt controller still aggregates those eight lines into one normal CPU interrupt signal and applies the four-class policy.

## Why geographic MMIO windows

PCI-style run-time address resource allocation solves a scale/flexibility problem PLIO v0.1 does not have.

With only eight logical slots and a 32-bit RAX physical address space, assigning each slot a fixed 32 MiB MMIO window removes:

- BAR sizing,
- relocation registers,
- address-allocation firmware,
- jumper configuration.

The device is still self-identifying through its fixed configuration header.

## Why QDX is separate

A queue ABI should survive changes to the physical bus.

QDX-B therefore describes commands, queues, completions, namespaces, and scatter/gather independently of PLIO electrical details.

A future GNET storage transport could carry QDX-B semantics without pretending GNET is PLIO.

## Source material used as design references

- *SBus Specification B.0*, Sun Microsystems, December 1990.
- *VAXBI System Reference Manual*, Digital Equipment Corporation, revision February 1989.

These documents are design references, not normative dependencies of PLIO/QDX.
