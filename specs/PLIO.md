# PLIO v0.3 — Peripheral Lighting I/O

**Status:** Draft

## 1. Purpose

PLIO is the standard 32-bit peripheral interconnect for RAX/SIA systems. It connects the CPU/memory-controller complex to storage, networking, graphics, terminal, accelerator, and bridge controllers.

PLIO is deliberately a **small-system shared bus**, not a switched fabric and not a coherent memory interconnect.

The intended implementation is a late-1970s TTL/SSI/MSI system with a modest number of onboard or plug-in controllers.

## 2. Scope

PLIO defines:

- shared 32-bit address/data transfer behavior,
- geographic device selection,
- bus-manager arbitration,
- programmed MMIO access,
- protected DMA access to system memory,
- **message-signalled device notifications with no per-device IRQ wire**,
- basic error/timeout behavior,
- device reset and discovery registers.

PLIO does **not** define:

- cache coherence,
- hot insertion/removal,
- a switched or serial fabric,
- packet routing,
- dedicated device interrupt lines,
- peer-to-peer device DMA,
- device-side page-table walking,
- mandatory device firmware bytecode,
- multiprocessing cache protocols.

## 3. Terminology

- **PLIO controller** — centralized motherboard logic that arbitrates the bus, routes host accesses, validates and translates DMA capability channels, selects workers, handles timeout, and accepts device notification messages.
- **bus manager** — a device currently permitted to initiate a PLIO transaction.
- **worker** — a PLIO endpoint responding to an MMIO transaction.
- **slot** — one logical PLIO endpoint number. A slot may correspond to a plug-in card or an onboard controller.
- **host** — the RAX CPU/memory complex behind the PLIO controller.
- **DMA capability channel** — a controller-owned mapping granting one slot bounded read/write access to one host physical-memory region.
- **DMA generation** — a small controller-managed version number attached to a DMA capability channel and carried in each device-visible DMA address to reject stale references after revocation/rebinding.
- **notification channel** — one controller-owned pending source associated with a slot. A device signals it by issuing a PLIO notification write.

## 4. Topology

A PLIO segment contains one PLIO controller and at most eight logical slots.

```text
       RAX CPU
          |
       RBUS
          |
  Memory Controller -------- Main Memory
          |
    PLIO Controller
          |
========== PLIO ================================
   |       |       |       |       ...
 slot0   slot1   slot2   slot3
 QDX-B   GNET    video   bridge
```

The CPU/memory path does not traverse PLIO.

## 5. Host MMIO address map

PLIO uses a 32-bit host physical address model.

The RAX Platform Standard reserves:

```text
0xF000_0000 .. 0xFFFF_FFFF    PLIO I/O space
```

The space is divided geographically into eight equal 32 MiB windows:

```text
slot = address[27:25]
offset = address[24:0]
```

| Slot | Base | End |
|---:|---:|---:|
| 0 | `0xF000_0000` | `0xF1FF_FFFF` |
| 1 | `0xF200_0000` | `0xF3FF_FFFF` |
| 2 | `0xF400_0000` | `0xF5FF_FFFF` |
| 3 | `0xF600_0000` | `0xF7FF_FFFF` |
| 4 | `0xF800_0000` | `0xF9FF_FFFF` |
| 5 | `0xFA00_0000` | `0xFBFF_FFFF` |
| 6 | `0xFC00_0000` | `0xFDFF_FFFF` |
| 7 | `0xFE00_0000` | `0xFFFF_FFFF` |

There is no BAR/resource-allocation protocol in this baseline.

## 6. Configuration area

Every populated PLIO slot MUST implement the first 256 bytes of its slot window as a standard configuration area.

| Offset | Width | Name | Meaning |
|---:|---:|---|---|
| `0x00` | 32 | `PLIO_ID` | signature/version |
| `0x04` | 16 | `VENDOR_ID` | vendor identifier |
| `0x06` | 16 | `DEVICE_ID` | device identifier |
| `0x08` | 16 | `REVISION` | hardware revision |
| `0x0A` | 8 | `DEVICE_CLASS` | storage/network/graphics/etc. |
| `0x0B` | 8 | `FLAGS` | capabilities |
| `0x0C` | 16 | `QDX_PROFILE` | `0` if not QDX; otherwise QDX profile ID |
| `0x0E` | 16 | `QDX_REVISION` | QDX revision |
| `0x10` | 32 | `MMIO_LENGTH` | implemented MMIO bytes |
| `0x14` | 32 | `DEVICE_STATUS` | reset/ready/fault state |
| `0x18` | 32 | `DEVICE_CONTROL` | device-level enable/reset controls |

Required `FLAGS` bits:

- bit 0: worker implemented
- bit 1: bus-manager capability
- bit 2: notification capability
- bit 3: QDX capability
- bits 4..7: reserved

A device that generates asynchronous PLIO notifications MUST implement bus-manager capability, because notification is a bus transaction rather than a dedicated pin.

## 7. Electrical/logical signal model

### 7.1 Shared signals

| Signal | Direction | Meaning |
|---|---|---|
| `CLK` | controller -> all | bus clock |
| `RESET*` | controller -> all | active-low reset |
| `AD[31:0]` | shared | multiplexed address/data |
| `AS*` | manager -> bus | address phase valid |
| `RD` | manager -> bus | 1=read, 0=write |
| `BE[3:0]` | manager -> bus | byte enables |
| `DS*` | manager -> bus | data phase valid |
| `ACK*` | worker/controller -> manager | transfer accepted |
| `ERR*` | worker/controller -> manager | transfer failed |

### 7.2 Per-slot signals

For each slot `n`:

| Signal | Direction | Meaning |
|---|---|---|
| `SEL[n]*` | controller -> slot | slot selected as worker |
| `BR[n]*` | slot -> controller | request bus-manager ownership |
| `BG[n]*` | controller -> slot | bus-manager grant |

**There is no `IRQ[n]` signal.**

A worker-only device MAY omit active drive circuitry for `BR[n]*`, but such a device cannot generate asynchronous notifications and is normally polled.

## 8. Clocking

PLIO is synchronous.

- All normal bus control signals are sampled on the rising edge of `CLK`.
- PLIO-5 systems operate at 5 MHz.
- PLIO-10 systems operate at 10 MHz.
- Every baseline device MUST operate at 5 MHz.
- A device declaring PLIO-10 capability MUST also operate at 5 MHz.

No asynchronous per-device interrupt inputs cross the PLIO backplane.

## 9. Programmed MMIO transaction

A host access is injected by the PLIO controller as a bus-manager transaction.

### 9.1 Address phase

On a rising edge the manager drives `AD[31:0]` with the byte address, drives `RD` and `BE[3:0]`, and asserts `AS*`.

The controller decodes host-injected MMIO addresses and asserts the selected `SEL[n]*`.

### 9.2 Data phase

For a write the manager drives data and asserts `DS*`; for a read the selected worker drives data. The target eventually asserts `ACK*` or `ERR*`. A worker MAY insert wait states by asserting neither response.

### 9.3 Transfer sizes

`BE[3:0]` defines valid bytes. The baseline requires naturally aligned 8-, 16-, and 32-bit transfers. Unaligned multi-byte accesses are not required.

## 10. Bus-manager arbitration

A DMA/notification-capable slot requests the bus by asserting `BR[n]*`.

The PLIO controller MUST provide fair arbitration among requesting managers. The baseline algorithm is rotating round-robin.

A grant is communicated by `BG[n]*`. Only one slot may own a grant at a time.

The manager MUST release ownership after each transaction in the baseline protocol. Multi-word burst ownership is reserved for a later extension.

The controller always knows the physical source slot of a manager transaction from the active grant. A device therefore cannot claim to be another slot when performing DMA or notification.

## 11. DMA capability channels

### 11.1 Principle

PLIO devices MUST NOT receive unrestricted host physical addresses.

Each DMA-capable slot has **sixteen controller-owned DMA capability channels**. Privileged system software binds a host physical-memory region and permissions to a channel. The device then addresses that memory using a channel number, generation number, and byte offset.

This is the hardware enforcement mechanism used by the OS capability model for device memory access.

### 11.2 Device-visible DMA address

A 32-bit device-visible DMA address is encoded as:

```text
31          28 27          24 23                         0
+--------------+--------------+---------------------------+
| channel 0..15| generation   | byte offset (24 bits)    |
+--------------+--------------+---------------------------+
```

Thus:

```text
channel    = address[31:28]
generation = address[27:24]
offset     = address[23:0]
```

Each capability can therefore describe up to **16 MiB** of host memory. Larger transfers use multiple capability mappings and/or scatter/gather descriptors.

Each channel entry contains:

```text
host_physical_base
length                    # 1 .. 16 MiB
permissions: device-read / device-write
generation: 0 .. 15
valid
```

For a DMA transaction the controller selects the entry using `(source_slot, channel)` and verifies:

```text
valid == 1
request_generation == entry_generation
offset + transfer_length <= length
required permission is granted
```

It then translates:

```text
host_address = host_physical_base + offset
```

A failed generation, bounds, validity, or permission check terminates the transaction with a DMA protection error.

The generation field is not a secret and is not an authentication token. Its purpose is temporal safety: a stale `(channel, generation, offset)` reference MUST NOT silently become valid for a newly bound memory object after revocation.

Only privileged platform/kernel software may bind, modify, or revoke a hardware DMA capability channel.

### 11.3 Binding, revocation, and generation lifecycle

A channel follows this lifecycle:

```text
UNBOUND -> BOUND(generation N) -> REVOKED -> BOUND(generation N+1)
```

A new binding MUST use a generation different from the immediately preceding binding of the same `(slot, channel)`. Increment modulo 16 is the baseline policy.

Revocation MUST clear `valid` before the backing physical memory may be reassigned to a different protection domain. Any DMA request carrying the revoked generation then fails even if the channel is later rebound with another generation.

Because the generation field is finite, generation values eventually wrap. Before privileged software reuses a generation value for a channel, it MUST ensure that no stale device request or descriptor carrying that old generation can still be issued. Quiescing and resetting the slot is always sufficient. A platform MAY prove quiescence by stronger device-specific means, but it MUST NOT allow unsafe generation reuse.

The controller SHOULD expose the generation chosen for a new binding to privileged software so the driver can construct device-visible DMA addresses. Devices do not program the capability table.

### 11.4 OS capability relationship

The hardware channel table is intentionally simple. Cosmic or another protected OS may expose higher-level capability objects such as:

```text
PLIO-device capability
memory-region capability
DMA-channel capability
notification-channel capability
```

A driver possessing appropriate authority may ask the kernel to bind a memory region to one of its device's channels. The driver receives the channel/generation pair and constructs device-visible addresses as `(channel, generation, offset)`. The card never receives the host physical base.

Revocation invalidates the channel entry. Rebinding uses a new generation so stale queued descriptors cannot acquire authority to the replacement memory object merely because the numeric channel was reused.

PLIO does not require tagged capability words in the device and does not require the device to understand process virtual memory.

### 11.5 Scatter/gather

QDX scatter/gather descriptors MAY reference several device-visible `(channel, generation, offset)` addresses. PLIO itself still performs only one protected translation per bus transaction.

### 11.6 Peer-to-peer

Manager accesses to another PLIO device are not supported by the baseline. DMA targets are host memory only.

## 12. Message-signalled notifications

### 12.1 No dedicated device interrupt wires

Normal PLIO device interrupts are represented by **notification write transactions**. There is no per-slot interrupt signal.

The RAX platform reserves the controller target aperture:

```text
0xEFFF_F000 .. 0xEFFF_F00F    PLIO normal notification aperture
```

The four aligned word addresses correspond to notification channels 0..3:

```text
0xEFFF_F000 + 4 * channel
```

This address range is intercepted by the PLIO controller before ordinary DMA translation.

### 12.2 Notification transaction

To notify the host a device:

1. finishes and publishes any completion/status data to host-visible memory,
2. requests bus ownership with `BR[n]*`,
3. receives `BG[n]*`,
4. performs a 32-bit write to its desired notification-channel address,
5. releases the bus after the transaction.

The controller derives the **source slot from the active bus grant**. The device does not place a trusted slot ID, CPU vector, privilege, or priority in the message.

The 32-bit write data MAY contain an advisory cause/cookie for diagnostics, but correctness MUST NOT depend on retaining every message payload. QDX completion information belongs in the completion queue.

### 12.3 Controller state

For each `(slot, notification_channel)` the controller maintains privileged state including:

```text
enabled
class: 0..3
masked
pending
optional last-data/debug field
```

Receiving an enabled notification sets `pending`. Repeated notifications while pending MAY coalesce into the same pending bit.

The device cannot choose or elevate its interrupt class. Privileged software configures class and any future CPU-routing policy.

### 12.4 Host delivery and race rule

The controller presents one aggregate **normal notification pending** condition to the CPU/memory complex. This is internal platform integration and is not a PLIO backplane interrupt line.

When the kernel claims a source, the controller MUST atomically return the selected `(slot, channel)` and clear that source's pending bit. If a new device notification arrives afterward, the bit is set again. If the source is masked, new notifications still set pending and are delivered when unmasked.

This prevents a completion arriving during driver service from being lost.

See `RAX-INTERRUPTS.md` for kernel integration.

## 13. Error handling and timeout

A worker/controller signals a transaction failure with `ERR*`.

The controller MUST time out a transaction that receives neither `ACK*` nor `ERR*` within the implementation-defined interval. The baseline RAX platform timeout is 256 PLIO clocks.

A timeout records source/target/address/operation and returns an error to the initiating CPU or bus manager.

## 14. Reset

On `RESET*` assertion:

- bus managers MUST release `BR[n]*`,
- QDX queues MUST be disabled,
- device DMA MUST cease,
- devices MUST enter a discoverable but inactive state.

The PLIO controller MUST invalidate all DMA capability channels and clear/mask all device notification state before releasing reset, unless explicitly configured by trusted platform firmware.

After a device reset has guaranteed that no pre-reset DMA request can survive, privileged software MAY restart generation allocation for that slot.

## 15. Memory ordering

The PLIO controller must preserve ordering for accesses from one manager unless the standard explicitly permits otherwise.

For QDX submission:

```text
write descriptors to memory
    -> ensure descriptor writes are globally visible
    -> write QDX doorbell MMIO register
```

For QDX completion notification:

```text
DMA-write completion(s)
    -> ensure completion writes are globally visible
    -> issue PLIO notification write
```

A notification MUST NOT become observable by the CPU before preceding completion-memory writes by the same device have become visible.

## 16. Required conformance

A PLIO worker MUST support reset, configuration area, geographic slot selection, 8/16/32-bit MMIO accesses, and `ACK*`/`ERR*` behavior.

A PLIO bus manager additionally MUST support request/grant arbitration and protected DMA-channel faults, including generation validation.

A PLIO device advertising notification capability MUST be capable of issuing the notification write transaction.

A QDX device additionally MUST implement `specs/QDX.md` and its declared profile.
