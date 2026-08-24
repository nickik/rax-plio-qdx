# Design rationale

## Why PLIO is a peripheral bus, not a processor/system bus

PLIO deliberately stops at the I/O boundary.

Processor-to-processor communication, coherent memory, CPU caches, memory-node discovery, and multiprocessor ordering have much harder requirements than peripheral I/O. Trying to make one late-1970s bus do both jobs would increase electrical loading, arbitration complexity, protocol states, and long-term compatibility burden.

The host therefore owns CPUs and memory behind a PLIO controller:

```text
CPU(s) <-> host memory interconnect <-> memory
                    |
               PLIO controller
                    |
                 PLIO I/O
```

A PACE, 68000, 8086, PDP-derived, RAX, or other computer can use PLIO by implementing a host controller/profile. That does not make the CPU a PLIO slot node.

This is a deliberate difference from buses such as Multibus, VME, and VAXBI, which can serve broader processor/system roles.

## Why host physical addresses are not in the universal bus standard

The earlier PLIO draft embedded the RAX physical range:

```text
0xF000_0000 .. 0xFFFF_FFFF
```

That makes sense for RAX, but not for a universal peripheral standard.

PLIO v0.5 instead defines eight logical slots with 32 MiB **slot-relative** worker spaces. A host profile maps its CPU-visible addresses to `(slot, slot_offset)` and the PLIO controller places only the slot-relative offset on the bus while asserting the selected slot's `SEL*`.

The RAX mapping remains unchanged in `PLIO-RAX.md`; it is simply no longer something every PLIO card must understand.

This allows a non-RAX host to adopt PLIO without emulating a RAX physical address map.

## Why transaction spaces exist

PLIO v0.5 adds a small two-bit `SPACE` field:

```text
WORKER      host -> peripheral MMIO
HOST_DMA    peripheral -> protected host memory
CONTROLLER  peripheral -> PLIO controller local operation
RESERVED
```

The two pins remove several architectural ambiguities.

A device-visible DMA handle can use all 32 bits without colliding with a magic notification address. Worker MMIO can be slot-relative instead of host-physical. Controller notifications have their own bus-local namespace. Future host profiles can therefore change CPU physical address placement without changing card silicon.

The hardware cost is two control pins and a small decode.

## Why bus-local message-signalled notification is preferable

The earliest draft used one level-triggered IRQ wire per slot. That was rejected.

Intelligent PLIO/QDX devices are already bus managers, so they can signal completion with an ordinary short controller-target transaction:

```text
device requests bus
    -> receives grant
    -> SPACE=CONTROLLER
    -> writes notification offset 0/4/8/C
    -> controller records pending(slot, channel)
```

There is no host physical notification address in the card protocol. The source slot comes from the active grant, so the card cannot spoof another slot. The card also cannot choose CPU vector, privilege, priority, or routing.

This is MSI-like in principle but intentionally much smaller than later PCI MSI/MSI-X.

QDX puts real completion data in the CQ. The notification merely says work is available, so repeated notifications can safely coalesce.

## Why bounded burst DMA is in the baseline

A 32-bit multiplexed address/data bus wastes too much bandwidth if every longword requires new arbitration and a new address phase.

PLIO therefore defines only four DMA transaction lengths:

```text
1, 4, 8, or 16 longwords
```

Two `BLEN` bits select the size. One grant covers one bounded transaction and arbitration runs again after at most 64 payload bytes.

At PLIO-5 the raw 32-bit data phase is 20 MB/s. An idealized 16-longword sequence with one arbitration opportunity and one address phase approaches 17.8 MB/s payload before memory waits/contention.

The 64-byte maximum balances bulk efficiency with deterministic fairness and bounds how long a notification can sit behind one already-granted transfer.

Burst is restricted to protected host-memory DMA. Simple worker MMIO and controller notifications remain single-beat, so inexpensive cards do not need worker-side block-transfer machinery.

## Why capability-scoped DMA channels

PLIO makes DMA authority explicit instead of giving a card unrestricted host physical addresses.

A device-visible handle is:

```text
channel[31:28] | generation[27:24] | offset[23:0]
```

The controller derives the slot from the active grant and checks:

```text
(slot, channel)
      -> valid mapping
      -> generation match
      -> read/write permission
      -> complete transfer/burst bounds
      -> host_base + offset
```

There are sixteen channels per DMA-capable slot; each mapping can cover up to 16 MiB. QDX scatter/gather can reference several mappings.

This fits a capability OS naturally: privileged software requires authority to both a device and a memory object before binding them together. The card never sees the host physical base.

The 4-bit generation field adds temporal safety. Revoke/rebind changes the generation, preventing a stale queued descriptor from silently acquiring authority to replacement memory. Generation wrap requires quiescence/reset or another proof that old requests cannot survive.

This gives much of the isolation value later associated with IOMMUs without requiring device-side page-table walking in a 1978 controller.

## Why canonical little-endian QDX structures

If QDX is to be usable by multiple CPU families, its descriptor representation cannot mean “whatever byte order the host uses.”

QDX therefore uses one permanent little-endian representation for all multibyte control fields.

This is especially cheap for the intended RAX/PDP/Intel environment. A big-endian host pays the conversion cost at its software or bridge boundary, but every peripheral sees one stable ABI.

Opaque payloads keep their own media/network format and are not transformed merely because they use QDX.

## Why geographic worker addressing

Every slot receives a fixed 32 MiB logical worker window. The host profile decides where that window appears to its CPU.

This removes card BAR sizing, relocation registers, address jumpers, and host-specific physical-address assumptions.

The first 256 bytes are a fixed configuration header containing vendor, device, revision, class, QDX profile, and status/control information.

Thus installation is based on slot geography plus self-identification rather than manually coordinating base addresses and interrupt resources.

## Why Eurocard mechanics

A bus intended for outside adoption should not require a proprietary DEC card cage.

PLIO-E therefore uses established 3U/6U × 160 mm Eurocard mechanics and a 96-position, three-row DIN 41612-style P1 connector.

The connector has enough positions for the 32-bit multiplexed bus, `SPACE`, `BLEN`, slot-specific arbitration, clock/reset, power, and substantial ground distribution while keeping several pins reserved.

Using standard mechanics allows independent chassis, backplane, industrial, telecom, laboratory, and military suppliers to participate without first reproducing DEC-specific mechanical infrastructure.

## Why QDX is separate

PLIO defines electrical/logical transport, worker MMIO, protected DMA, arbitration, and notification.

QDX defines queues, commands, completions, tags, and device-class profiles.

Keeping them separate means QDX semantics can survive a later physical interconnect while PLIO can carry non-QDX workers.

QDX also benefits directly from PLIO burst sizing: a 32-byte QDX-B submission descriptor fits an 8-longword burst, a 16-byte completion fits a 4-longword burst, and block payloads use repeated 16-longword bursts.

## Why not copy VME/VAXBI wholesale

VME and VAXBI contain useful lessons about multi-master arbitration, block transfer, diagnostics, identification, and merchant ecosystems, but both address broader system-bus roles than PLIO needs.

PLIO intentionally avoids processor/memory-node semantics and distributed coherence concerns. That lets the host controller remain the trusted boundary for DMA capability enforcement and message source identity.

## Source material used as design references

- *SBus Specification B.0*, Sun Microsystems, December 1990.
- *VAXBI System Reference Manual*, Digital Equipment Corporation, revision February 1989.
- NuBus documentation for synchronous multiplexed block-transfer and geographic-addressing design lessons.
- Eurocard / DIN 41612 mechanical practice for the PLIO-E physical profile.

These are design references, not normative dependencies.
