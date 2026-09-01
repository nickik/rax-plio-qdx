# PLIO-RAX v0.2 — RAX Host Profile

**Status:** Draft

## 1. Purpose

This profile binds the host-independent PLIO v0.6 logical bus to the RAX CPU/memory architecture.

PLIO itself does not assign CPU physical addresses and does not define a CPU interrupt-vector scheme. Those decisions belong here.

## 2. RAX CPU physical MMIO map

The RAX platform reserves:

```text
0xF000_0000 .. 0xFFFF_FFFF    PLIO peripheral MMIO space
```

The 256 MiB region is divided into eight geographic 32 MiB CPU-visible slot windows:

```text
slot        = address[27:25]
slot_offset = address[24:0]
```

| Slot | CPU physical base | CPU physical end |
|---:|---:|---:|
| 0 | `0xF000_0000` | `0xF1FF_FFFF` |
| 1 | `0xF200_0000` | `0xF3FF_FFFF` |
| 2 | `0xF400_0000` | `0xF5FF_FFFF` |
| 3 | `0xF600_0000` | `0xF7FF_FFFF` |
| 4 | `0xF800_0000` | `0xF9FF_FFFF` |
| 5 | `0xFA00_0000` | `0xFBFF_FFFF` |
| 6 | `0xFC00_0000` | `0xFDFF_FFFF` |
| 7 | `0xFE00_0000` | `0xFFFF_FFFF` |

When the CPU accesses one of these addresses, the RAX PLIO controller converts it into a PLIO worker transaction:

```text
SPACE = WORKER
SEL   = decoded slot
AD    = slot_offset
```

The full RAX CPU physical address is never placed on the PLIO backplane.

There is no BAR/resource-allocation protocol. Moving the board to another slot changes its RAX CPU-visible geographic window automatically.

## 3. PLIO host-controller CSR reservation

RAX reserves the following privileged CPU physical range for PLIO host-controller management:

```text
0xEFFF_F000 .. 0xEFFF_FFFF    RAX PLIO host-controller CSR region
```

This region is host-side logic. It is **not** a device-visible PLIO address range.

The exact CSR layout for DMA-channel bind/revoke state, notification claim/mask state, timeout diagnostics, and controller identification is a RAX platform specification item and may evolve independently of card-visible PLIO transactions.

Earlier PLIO drafts treated `0xEFFF_F000 .. 0xEFFF_F00F` as an address written directly by devices to signal notifications. That model is obsolete.

In PLIO v0.6 a device sends a **PLIO Notification** using the bus-local controller transaction:

```text
SPACE = CONTROLLER
AD    = 0x0000_0000 + 4 * channel
```

The RAX CPU physical map is therefore not embedded in the peripheral protocol.

## 4. DMA capability programming

Only privileged RAX platform software may modify the PLIO controller's DMA capability table.

For each `(slot, channel)` the RAX PLIO controller stores:

```text
host_physical_base
length
permissions
generation
valid
```

A capability-oriented OS may require authority to both the PLIO device and the memory object before binding a region into one of that device's channels.

The user-space driver receives only the resulting `(channel, generation)` handle information. The card never receives the RAX host physical base.

Revocation and active-burst interlock follow PLIO v0.6.

## 5. PLIO Notification integration

Normal device signalling uses **PLIO Notification** transactions. The RAX PLIO controller records pending state indexed by `(slot, channel)`.

The RAX controller exposes one aggregate CPU-side interrupt condition named:

```text
NOTIFY_PENDING_INTERRUPT
```

`NOTIFY_PENDING_INTERRUPT` is asserted whenever at least one enabled, unmasked normal PLIO Notification is pending and eligible for delivery.

This is an internal RAX platform condition between the PLIO controller and CPU/memory complex. It is **not** a PLIO backplane pin and is not generated directly by any card.

The kernel claims the next source through privileged controller state and receives `(slot, channel)` atomically while clearing that pending source.

Class, masking, and future CPU-routing policy are controlled by privileged RAX software, never by the card.

See `RAX-INTERRUPTS.md` for the intended microkernel delivery model.

## 6. Cache and memory visibility

RAX software MUST perform the platform-defined visibility operation before a device DMA-reads CPU-written descriptors or payloads.

Likewise, after a completion indicates device writes are finished, software MUST perform any platform-defined operation required before the CPU consumes those writes.

The initial RAX implementation may use physically addressed/non-coherent caches. PLIO does not provide cache coherence.

## 7. Byte order

PLIO configuration structures and all QDX control structures use the canonical **little-endian** representation defined by their respective standards.

The RAX implementation SHOULD therefore expose them without byte swapping.

## 8. Non-goal: processor attachment

RAX CPUs, additional processors, and coherent memory are not installed as ordinary PLIO cards.

A multiprocessor RAX system places those processors behind the host-side CPU/memory interconnect and presents one PLIO controller to the peripheral bus.
