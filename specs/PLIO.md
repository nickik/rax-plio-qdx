# PLIO v0.1 — Peripheral Lighting I/O

**Status:** Draft

## 1. Purpose

PLIO is the standard 32-bit peripheral interconnect for RAX systems. It connects the RAX memory/controller complex to storage, networking, graphics, terminal, accelerator, and bridge controllers.

PLIO is deliberately a **small-system shared bus**, not a switched fabric and not a coherent memory interconnect.

The intended implementation is a late-1970s TTL/SSI/MSI system with a modest number of onboard or plug-in controllers.

## 2. Scope

PLIO v0.1 defines:

- shared 32-bit address/data transfer behavior,
- geographic device selection,
- bus-manager arbitration,
- programmed MMIO access,
- DMA access to system memory,
- basic error/timeout behavior,
- device reset and discovery registers,
- one physical normal interrupt request per slot,
- four controller-assigned normal interrupt classes.

PLIO v0.1 does **not** define:

- cache coherence,
- hot insertion/removal,
- a switched or serial fabric,
- packet routing,
- message-signalled interrupts,
- peer-to-peer device DMA,
- device-side page-table walking,
- mandatory device firmware bytecode,
- multiprocessing cache protocols.

These omissions are intentional.

## 3. Terminology

- **PLIO controller** — centralized motherboard logic that arbitrates the bus, routes host accesses, validates DMA, selects workers, handles timeout, and aggregates interrupts.
- **bus manager** — a device currently permitted to initiate a PLIO transaction.
- **worker** — a PLIO endpoint responding to an MMIO transaction.
- **slot** — one logical PLIO endpoint number. A slot may correspond to a plug-in card or an onboard controller.
- **host** — the RAX CPU/memory complex behind the PLIO controller.

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

## 5. Address map

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

There is no BAR/resource-allocation protocol in v0.1.

The PLIO controller MUST generate a slot-select signal from the geographic address.

## 6. Configuration area

Every populated PLIO slot MUST implement the first 256 bytes of its slot window as a standard configuration area.

### 6.1 Required configuration registers

| Offset | Width | Name | Meaning |
|---:|---:|---|---|
| `0x00` | 32 | `PLIO_ID` | ASCII-equivalent magic/version signature |
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
- bit 2: normal interrupt capability
- bit 3: QDX capability
- bits 4..7: reserved

Unimplemented slots MUST read as all ones in `PLIO_ID` and MUST NOT assert `ACK*` for ordinary accesses outside discovery handling.

## 7. Electrical/logical signal model

PLIO v0.1 defines the following logical signals. Exact connector pin placement is a separate mechanical annex.

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
| `IRQ[n]*` | slot -> controller | level-triggered normal interrupt |

A worker-only device MAY omit active drive circuitry for `BR[n]*`.

## 8. Clocking

PLIO is synchronous except for device interrupt inputs.

- All normal bus control signals are sampled on the rising edge of `CLK`.
- PLIO-5 systems operate at 5 MHz.
- PLIO-10 systems operate at 10 MHz.
- Every v0.1 device MUST operate at 5 MHz.
- A device that declares PLIO-10 capability MUST also operate at 5 MHz.

The controller MUST synchronize asynchronous `IRQ[n]*` inputs before using them in synchronous logic.

## 9. Programmed MMIO transaction

A host access is injected by the PLIO controller as a bus-manager transaction.

### 9.1 Address phase

On a rising edge:

- the manager drives `AD[31:0]` with the byte address,
- drives `RD`, `BE[3:0]`,
- asserts `AS*`.

The controller decodes the address and asserts the selected `SEL[n]*`.

### 9.2 Data phase — write

On the following data phase:

- manager drives write data on `AD[31:0]`,
- manager asserts `DS*`,
- selected worker eventually asserts `ACK*` or `ERR*`.

A worker MAY insert wait states by asserting neither response.

### 9.3 Data phase — read

On the data phase:

- manager releases `AD[31:0]`,
- selected worker drives read data,
- manager asserts `DS*`,
- worker asserts `ACK*` with valid data or `ERR*`.

### 9.4 Transfer sizes

`BE[3:0]` defines valid bytes. v0.1 requires naturally aligned:

- 8-bit,
- 16-bit,
- 32-bit transfers.

Unaligned multi-byte accesses are not required.

## 10. Bus-manager arbitration

A DMA-capable slot requests the bus by asserting `BR[n]*`.

The PLIO controller MUST provide fair arbitration among requesting bus managers.

The baseline algorithm is rotating round-robin.

A grant is communicated by `BG[n]*`. Only one slot may have an active grant at a time.

The manager MUST release ownership after each transaction in v0.1. Multi-word burst ownership is reserved for a later extension.

This rule deliberately bounds bus occupancy and keeps arbitration logic small.

## 11. DMA

A bus manager may initiate memory reads and writes after receiving a grant.

### 11.1 No device virtual memory

PLIO v0.1 devices do not walk CPU page tables and do not issue CPU virtual addresses.

QDX and driver software express fragmented memory using scatter/gather descriptors when necessary.

### 11.2 DMA windows

For a protected RAX system, every DMA-capable slot has four controller-owned DMA mapping windows.

Each window contains:

```text
device_base
host_physical_base
length
permissions: read / write
valid
```

A manager-provided DMA address MUST match one enabled window. The controller translates:

```text
host_address = host_physical_base + (device_address - device_base)
```

If no enabled window matches, the transaction fails with a DMA protection error.

Only kernel-mode software may configure DMA windows.

An unprotected small system MAY use a single identity-mapped window covering installed memory.

### 11.3 Peer-to-peer transfers

Bus-manager accesses to another PLIO slot are not supported by v0.1. DMA targets are host memory only.

## 12. Interrupts

PLIO v0.1 uses one dedicated, level-triggered `IRQ[n]*` input per slot.

A device with one or more pending causes:

1. writes all completion/status data to DMA-visible memory or its MMIO state,
2. asserts `IRQ[n]*`,
3. keeps `IRQ[n]*` asserted until software has serviced/acknowledged all causes that require the line.

A device MUST NOT encode its own CPU priority on the wire.

The PLIO interrupt controller assigns every slot one of four normal classes:

```text
3  urgent
2  high
1  normal
0  background
```

The class controls arbitration among simultaneously pending normal interrupts only.

See `RAX-INTERRUPTS.md` for CPU integration.

## 13. Error handling and timeout

A worker signals a transaction failure with `ERR*`.

The controller MUST time out a transaction that receives neither `ACK*` nor `ERR*` within the implementation-defined timeout interval.

The baseline RAX platform timeout is 256 PLIO clocks.

A timeout MUST:

- terminate the bus transaction,
- record slot/address/operation in controller error registers,
- return an error to the initiating CPU or bus manager.

## 14. Reset

On `RESET*` assertion:

- bus managers MUST release `BR[n]*`,
- devices MUST deassert `IRQ[n]*`,
- QDX queues MUST be disabled,
- device DMA MUST cease,
- devices MUST enter a discoverable but inactive state.

The PLIO controller MUST disable all DMA windows before releasing reset unless platform firmware explicitly establishes an identity-mapped unprotected environment.

## 15. Memory ordering

The PLIO controller must preserve ordering for accesses from one manager unless the standard explicitly permits otherwise.

For QDX use, software follows this rule:

```text
write descriptors to memory
    -> ensure descriptor writes are globally visible
    -> write QDX doorbell MMIO register
```

A doorbell write MUST NOT become visible to a worker before preceding host memory writes from the same CPU have become visible to PLIO DMA.

## 16. Required v0.1 conformance

A PLIO worker MUST support:

- reset,
- configuration area,
- geographic slot selection,
- 8/16/32-bit MMIO accesses,
- `ACK*` and `ERR*` behavior.

A PLIO bus manager additionally MUST support:

- request/grant arbitration,
- 32-bit memory DMA reads/writes,
- controller DMA-window faults.

A QDX device additionally MUST implement `specs/QDX.md` and its declared profile.
