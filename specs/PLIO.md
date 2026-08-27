# PLIO v0.6 — Peripheral Lighting I/O

**Status:** Draft

## 1. Purpose

PLIO is a standard 32-bit peripheral interconnect for intelligent I/O controllers. It connects a host CPU/memory complex, through one central PLIO controller, to storage, networking, graphics, streaming, accelerator, bridge, and other peripheral controllers.

PLIO is deliberately an **I/O bus**, not a processor bus, memory bus, cache-coherent interconnect, or general system fabric.

A PLIO segment contains exactly one host-side PLIO controller and up to eight logical peripheral slots. Processor and memory nodes are not peers on the PLIO backplane. A non-RAX computer may use PLIO by implementing its own host profile and PLIO host controller.

The baseline remains implementable with late-1970s TTL/SSI/MSI logic and modest LSI or ULA interface devices.

## 2. Architectural scope

PLIO defines:

- a shared synchronous 32-bit multiplexed address/data bus,
- mandatory byte-lane parity on the multiplexed address/data bus,
- eight logical peripheral slots,
- host-to-worker MMIO transactions,
- bus-manager arbitration,
- bounded 1/4/8/16-longword host-memory DMA bursts,
- protected DMA capability channels,
- **PLIO Notification**, the bus-local device-to-host asynchronous notification mechanism,
- basic timeout/error/reset behavior,
- a standard device identification/configuration header,
- separation between bus semantics, host profiles, and physical/mechanical profiles.

PLIO does **not** define:

- CPU-to-CPU communication,
- processor or memory nodes on the peripheral backplane,
- cache coherence,
- coherent accelerators,
- host physical address placement,
- host interrupt-vector architecture,
- a switched or serial fabric,
- peer-to-peer peripheral DMA,
- device-side page-table walking,
- arbitrary device-programmable interrupt targets,
- mandatory device firmware bytecode,
- hot insertion/removal in the baseline.

A future host may contain multiple CPUs behind one PLIO controller, but that is a host-platform issue. To PLIO the host remains one controller endpoint.

## 3. Terminology

- **PLIO controller** — centralized host-side logic that arbitrates the bus, injects host MMIO, validates/translates DMA capability channels, accepts controller-local transactions, handles timeout, parity faults, and notification state.
- **bus manager** — a peripheral currently granted authority to initiate a PLIO transaction.
- **worker** — a peripheral endpoint responding to host MMIO.
- **slot** — one logical peripheral endpoint number, 0..7. A slot may be a plug-in card or an onboard controller.
- **host** — the CPU/memory complex behind the PLIO controller.
- **host profile** — platform-specific mapping between a CPU's address/interrupt architecture and PLIO logical transactions.
- **physical profile** — mechanical, connector, power, and pin assignment standard for a PLIO implementation.
- **DMA capability channel** — controller-owned mapping granting one slot bounded device-read/device-write access to one host physical-memory region.
- **DMA generation** — controller-managed version tag carried in device-visible DMA addresses to reject stale references after revoke/rebind.
- **PLIO Notification** — one bus-local `SPACE=CONTROLLER` write by a granted peripheral that sets controller-owned pending state for one notification channel.
- **notification channel** — one of four controller-owned pending sources per slot used by PLIO Notification.
- **transaction space** — interpretation of `AD[31:0]` selected by `SPACE[1:0]` during the address phase.

The device-to-host mechanism defined by this specification is called **PLIO Notification**. Normative PLIO text does not use PCI-derived MSI/MSI-X terminology for it.

## 4. Topology

A PLIO segment has one host controller and at most eight peripheral slots:

```text
            host CPU(s)
                |
          memory system
                |
         PLIO controller
                |
================ PLIO =============================
   |         |          |          |         ...
 slot 0    slot 1     slot 2     slot 3
 QDX-B      GNET      QDX-G      bridge
```

The CPU-memory path does not traverse PLIO.

PLIO cards are not processor cards in the VME/Multibus sense. A computer that uses a PACE, 68000, 8086, RAX, PDP-derived, or other CPU attaches that CPU on the **host side** of its PLIO controller. The CPU is not a normal PLIO slot participant.

## 5. Logical slots and worker address space

PLIO defines eight logical slots. Each slot exposes a **32 MiB slot-relative worker address space**:

```text
slot offset = 0x0000000 .. 0x1FFFFFF
```

PLIO itself does not assign those windows CPU physical addresses. A host profile maps CPU addresses, I/O instructions, or another host mechanism onto `(slot, slot_offset)`.

During a host-injected worker transaction:

- `SPACE=WORKER`,
- `SEL[n]*` identifies the selected slot,
- `AD[24:0]` contains the slot-relative byte offset,
- `AD[31:25]` MUST be zero in the baseline.

This keeps the peripheral card independent of the host CPU's physical address map.

## 6. Standard configuration area

Every populated PLIO slot MUST implement the first 256 bytes of its slot-relative worker address space as a standard configuration area.

| Offset | Width | Name | Meaning |
|---:|---:|---|---|
| `0x00` | 32 | `PLIO_ID` | PLIO signature / interface revision |
| `0x04` | 16 | `VENDOR_ID` | vendor identifier |
| `0x06` | 16 | `DEVICE_ID` | device identifier |
| `0x08` | 16 | `REVISION` | hardware revision |
| `0x0A` | 8 | `DEVICE_CLASS` | storage/network/graphics/etc. |
| `0x0B` | 8 | `FLAGS` | interface capabilities |
| `0x0C` | 16 | `QDX_PROFILE` | `0` if not QDX; otherwise profile ID |
| `0x0E` | 16 | `QDX_REVISION` | implemented QDX profile revision |
| `0x10` | 32 | `MMIO_LENGTH` | implemented slot-relative MMIO bytes |
| `0x14` | 32 | `DEVICE_STATUS` | reset/ready/fault state |
| `0x18` | 32 | `DEVICE_CONTROL` | device-level enable/reset controls |

All multibyte fields in the PLIO standard configuration area are **little-endian**.

Required `FLAGS` bits:

- bit 0: worker implemented
- bit 1: bus-manager capability
- bit 2: notification capability
- bit 3: QDX capability
- bits 4..7: reserved

A device that generates asynchronous PLIO Notifications MUST implement bus-manager capability because PLIO Notification is a PLIO bus transaction.

Any device that performs host-memory DMA MUST implement all four baseline DMA burst lengths.

## 7. Transaction spaces

`SPACE[1:0]` is valid during the address phase and determines how `AD[31:0]` is interpreted.

| `SPACE` | Name | Initiator | Meaning |
|---:|---|---|---|
| `00` | `WORKER` | host controller | slot-relative peripheral MMIO |
| `01` | `HOST_DMA` | granted bus manager | protected host-memory DMA handle |
| `10` | `CONTROLLER` | granted bus manager | PLIO-controller-local operation |
| `11` | reserved | — | reserved for future PLIO versions |

Peripheral bus managers MUST NOT originate `WORKER` transactions in PLIO v0.6. Peer-to-peer peripheral MMIO/DMA is not part of the baseline.

A host profile may expose PLIO-controller CSRs to its CPU at any host-specific address. Those host-side CSR addresses are not PLIO bus addresses.

## 8. Electrical/logical signal model

### 8.1 Shared signals

| Signal | Direction | Meaning |
|---|---|---|
| `CLK` | controller -> all | bus clock |
| `RESET*` | controller -> all | active-low reset |
| `AD[31:0]` | shared | multiplexed address/data |
| `PAR[3:0]` | shared | odd parity for the four AD byte lanes |
| `SPACE[1:0]` | manager -> bus | transaction-space selector during address phase |
| `AS*` | manager -> bus | address phase valid |
| `RD` | manager -> bus | 1=read, 0=write |
| `BE[3:0]` | manager -> bus | byte enables |
| `BLEN[1:0]` | manager -> bus | burst-length code during address phase |
| `DS*` | manager -> bus | data beat valid |
| `ACK*` | target -> manager | current address/data beat accepted |
| `ERR*` | target -> manager | transaction failed |

`BLEN[1:0]` encodes:

| `BLEN` | Data beats | Maximum payload |
|---:|---:|---:|
| `00` | 1 | 4 bytes |
| `01` | 4 | 16 bytes |
| `10` | 8 | 32 bytes |
| `11` | 16 | 64 bytes |

All programmed MMIO, controller-local PLIO Notification writes, and sub-32-bit transactions MUST use `BLEN=00`.

### 8.2 Per-slot signals

For each slot `n`:

| Signal | Direction | Meaning |
|---:|---|---|
| `SEL[n]*` | controller -> slot | slot selected as worker |
| `BR[n]*` | slot -> controller | request bus-manager ownership |
| `BG[n]*` | controller -> slot | bus-manager grant |

**There is no `IRQ[n]` signal.**

A worker-only card MAY omit active drive circuitry for `BR[n]*`; such a card cannot generate asynchronous PLIO Notifications and is normally polled.

The normative Eurocard implementation is defined by `PLIO-E.md`.

### 8.3 Mandatory parity

PLIO v0.6 adds deliberately minimal protection for the multiplexed address/data path.

Parity is **odd parity**, one bit per byte lane:

```text
PAR0 protects AD[7:0]
PAR1 protects AD[15:8]
PAR2 protects AD[23:16]
PAR3 protects AD[31:24]
```

The endpoint currently driving `AD[31:0]` MUST drive the corresponding parity bits.

Rules:

- during every address phase all four parity bits are valid and checked;
- during a 32-bit data beat all four parity bits are valid and checked;
- during 8/16-bit worker MMIO only byte lanes selected by `BE[3:0]` require valid/checkable parity;
- parity does **not** cover `SPACE`, `RD`, `BE`, `BLEN`, arbitration, or other control wires in the baseline;
- parity is error detection only; PLIO does not attempt bus-level error correction.

On an address or write-data parity error the receiving target MUST reject the transfer with `ERR*` rather than `ACK*` where timing permits.

On a read-data parity error the receiving manager MUST discard the affected beat, terminate the transaction as failed, and report a local parity/data-path fault to its higher-level logic. A read-data receiver cannot rely on `ERR*` because `ERR*` is target-to-manager.

The PLIO controller SHOULD record parity faults with source/target slot, transaction space, direction, address/offset, and phase for diagnostics.

## 9. Clocking

PLIO is synchronous.

- all normal bus control signals are sampled on the rising edge of `CLK`,
- PLIO-5 operates at 5 MHz,
- PLIO-10 operates at 10 MHz,
- every baseline card MUST operate at 5 MHz,
- a card declaring PLIO-10 capability MUST also operate at 5 MHz.

PLIO-5 is the required interoperability rate. PLIO-10 is a speed grade of the same logical protocol, not a different bus.

## 10. Programmed worker MMIO

A host access is injected by the PLIO controller.

### 10.1 Address phase

The controller:

1. selects the logical slot using `SEL[n]*`,
2. drives `SPACE=WORKER`,
3. drives the slot-relative byte offset on `AD[24:0]`,
4. drives odd `PAR[3:0]` for the complete address,
5. drives `RD`, `BE[3:0]`, and `BLEN=00`,
6. asserts `AS*`.

### 10.2 Data phase

For a write, the controller drives the data and parity and asserts `DS*`. For a read, the selected worker drives data and parity. The selected worker eventually asserts `ACK*` or `ERR*`.

A worker MAY insert wait states by asserting neither response.

Parity failures are handled according to section 8.3.

### 10.3 Transfer sizes

The baseline requires naturally aligned 8-, 16-, and 32-bit MMIO transfers. Unaligned multi-byte accesses are not required.

Worker-side burst MMIO is not part of PLIO v0.6.

## 11. Bus-manager arbitration and bounded DMA bursts

### 11.1 Arbitration

A DMA/notification-capable slot requests bus ownership by asserting `BR[n]*`.

The PLIO controller MUST provide fair arbitration. The baseline algorithm is rotating round-robin.

A grant is communicated by `BG[n]*`. Only one slot may own a grant at a time.

A grant covers exactly one PLIO transaction:

- one single-beat controller-local transaction, including PLIO Notification, or
- one host-memory DMA burst of 1, 4, 8, or 16 longwords.

At the end of the transaction the controller MUST withdraw the grant and arbitrate again. A manager with additional work MAY keep `BR[n]*` asserted.

The controller derives the trusted source slot from the active grant. A device cannot claim to be another slot.

### 11.2 DMA burst scope

A burst is valid only with `SPACE=HOST_DMA`.

Burst transfers MUST:

- use naturally aligned 32-bit longwords,
- use `BE=1111`,
- contain exactly 1, 4, 8, or 16 data beats,
- carry valid odd parity on all four byte lanes for every address/data beat,
- access consecutive host addresses increasing by four bytes per acknowledged beat,
- remain wholly inside one active `(slot, channel, generation)` DMA capability mapping.

### 11.3 Address phase and complete-range validation

During the address phase the manager places the device-visible DMA address of the first longword on `AD[31:0]`, drives its parity, and supplies `SPACE=HOST_DMA`, `RD`, `BE=1111`, and `BLEN`.

Before beat 0 is accepted, the controller MUST validate both the address parity and the complete burst extent:

```text
transfer_length = burst_words * 4

mapping.valid == 1
request_generation == mapping.generation
offset is 32-bit aligned
offset + transfer_length <= mapping.length
required direction permission is granted
```

If validation or address parity fails, the controller returns `ERR*` and no data beat is committed.

After validation:

```text
host_address = mapping.host_physical_base + offset
```

and the controller increments the translated host address by four after each acknowledged beat.

### 11.4 Data beats, waits, and faults

Each data beat is individually acknowledged.

For device-to-host DMA writes, the manager drives one 32-bit word plus `PAR[3:0]` and asserts `DS*`; the controller checks parity and acknowledges only when the word is accepted into the host memory path.

For host-to-device DMA reads, the controller presents one 32-bit word plus `PAR[3:0]`; the device checks parity before accepting the beat.

The host memory path MAY insert wait states on any beat.

If `ERR*`, a parity fault, or a timeout occurs, the remaining burst MUST abort and the grant MUST be released. Already acknowledged beats are not rolled back. Higher-level protocols such as QDX must report or recover from partial transfer.

The baseline timeout is 256 PLIO clocks per outstanding address/data beat.

### 11.5 Fairness bound

The maximum burst is 16 longwords = 64 bytes. No peripheral may retain a grant longer than one such transaction.

At PLIO-5, sixteen no-wait data beats require 3.2 microseconds of data-beat time. With one arbitration opportunity and one address phase per burst, an idealized large transfer approaches 17.8 MB/s payload. This is a design ceiling, not guaranteed application throughput.

The 64-byte bound provides a predictable arbitration opportunity for latency-sensitive traffic and PLIO Notification traffic.

## 12. DMA capability channels

### 12.1 Principle

PLIO devices MUST NOT receive unrestricted host physical addresses.

Each DMA-capable slot has **sixteen controller-owned DMA capability channels**. Privileged host software binds a host physical-memory region and permissions to a channel. The device then addresses that authority using `(channel, generation, offset)`.

### 12.2 Device-visible DMA address

A 32-bit device-visible DMA address is:

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

Each channel can describe at most 16 MiB. Larger/discontiguous transfers use multiple channel mappings and/or scatter/gather.

Each channel entry contains:

```text
host_physical_base
length                    # 1 .. 16 MiB
permissions: device-read / device-write
generation: 0 .. 15
valid
```

The card never learns or programs `host_physical_base`.

### 12.3 Binding, revocation, and active transfers

A channel follows:

```text
UNBOUND -> BOUND(generation N) -> REVOKED -> BOUND(generation N+1)
```

Only privileged host software may bind, modify, or revoke a channel.

A new binding MUST use a generation different from the immediately preceding binding of the same `(slot, channel)`. Increment modulo 16 is the baseline policy.

Revocation MUST clear `valid` before backing memory may be reassigned to another protection domain.

If revocation occurs during an active burst, the controller MUST interlock revocation with that transaction. It MAY allow the currently acknowledged beat to finish, but no later beat may use the revoked mapping. The burst then terminates with a DMA protection error. Software MUST NOT treat revocation as complete or reuse the memory until the controller reports no active transfer remains.

Before a finite generation value is reused after wrap, privileged software MUST prove that no stale request carrying that value can survive. Quiescing and resetting the slot is always sufficient.

The generation field is a stale-reference tag, not a secret or cryptographic token.

### 12.4 OS capability relationship

A capability-based OS may expose software objects such as:

```text
PLIO-device capability
memory-region capability
DMA-channel capability
notification capability
```

A driver possessing appropriate device and memory authority asks privileged software to bind a memory region. The driver receives the channel/generation pair and constructs device-visible handles. This maps software capabilities onto a deliberately small hardware enforcement table without device-side page-table walking.

### 12.5 Scatter/gather

QDX scatter/gather descriptors MAY reference several `(channel, generation, offset)` handles. Each individual PLIO burst MUST remain inside one mapping.

### 12.6 No peer-to-peer DMA

Peripheral-to-peripheral DMA is not supported by PLIO v0.6. Device bus managers target host memory or the PLIO controller only.

## 13. PLIO Notification

### 13.1 No dedicated interrupt wires

Normal asynchronous peripheral signalling uses **PLIO Notification**, a controller-local PLIO write transaction. There is no per-slot IRQ signal and no host physical interrupt address in the PLIO standard.

A PLIO Notification uses:

```text
SPACE = CONTROLLER
BLEN  = 00
RD    = 0
BE    = 1111
AD    = 0x0000_0000 + 4 * notification_channel
```

The address and write-data phases use normal PLIO parity.

The baseline PLIO Notification aperture is therefore the following bus-local controller offsets:

```text
0x0000_0000   channel 0
0x0000_0004   channel 1
0x0000_0008   channel 2
0x0000_000C   channel 3
```

These are **PLIO controller-space offsets**, not CPU physical addresses. A host profile may expose unrelated CPU-visible controller-management registers wherever appropriate for that platform.

### 13.2 PLIO Notification transaction

To notify the host a device:

1. publishes any completion/status writes to host-visible memory,
2. asserts `BR[n]*`,
3. receives `BG[n]*`,
4. performs one parity-protected `SPACE=CONTROLLER` 32-bit write to the chosen PLIO Notification channel offset,
5. releases the bus.

The controller derives the source slot from the active grant. The device does not provide a trusted slot ID, host vector, privilege, CPU target, or priority.

The write data MAY contain an advisory cause/cookie for diagnostics. Correctness MUST NOT depend on every payload being retained; queued devices put real completion information in the CQ.

### 13.3 Controller PLIO Notification state

For each `(slot, notification_channel)` the controller maintains privileged state including:

```text
enabled
class: 0..3
masked
pending
optional last-data/debug field
```

Receiving an enabled PLIO Notification sets `pending`. Repeated PLIO Notifications while pending MAY coalesce.

The device cannot choose or elevate its class or CPU routing.

### 13.4 Host delivery

PLIO defines only PLIO Notification pending/source state. The host profile defines how the PLIO controller presents aggregate pending state and claim operations to the CPU/kernel.

Claiming a source MUST atomically return the selected `(slot, channel)` and clear that pending bit. If a new PLIO Notification arrives afterward, the bit is set again. If a source is masked, arriving PLIO Notifications still set pending and become deliverable after unmask.

For RAX, aggregate eligible PLIO Notification state is presented to the CPU as the host-internal condition **`NOTIFY_PENDING_INTERRUPT`**. This name belongs to the RAX host profile; it is not a PLIO backplane signal.

For RAX integration see `PLIO-RAX.md` and `RAX-INTERRUPTS.md`.

## 14. Error handling and timeout

A target signals transaction failure with `ERR*`.

The controller MUST time out a transaction that receives neither `ACK*` nor `ERR*` within the platform timeout. The baseline timeout is 256 PLIO clocks per outstanding address or data beat.

Parity error, timeout, and ordinary target failure are distinct diagnostic causes even though each makes the current transaction fail.

A timeout or parity fault SHOULD record source, transaction space, address/offset, direction, and phase for diagnostics.

## 15. Reset

On `RESET*` assertion:

- bus managers MUST release `BR[n]*`,
- QDX queues MUST be disabled,
- device DMA MUST cease,
- devices MUST enter a discoverable inactive state.

The PLIO controller MUST invalidate all DMA capability channels and clear/mask normal PLIO Notification state before releasing reset unless trusted platform firmware deliberately establishes bootstrap mappings.

After reset has guaranteed that no pre-reset request can survive, generation allocation for that slot may restart.

## 16. Memory ordering

The controller MUST preserve ordering for transactions from one manager unless a higher-level profile explicitly permits otherwise.

For QDX submission:

```text
host writes descriptor(s)
    -> makes descriptor writes visible to PLIO DMA
    -> writes QDX doorbell MMIO
```

For completion notification:

```text
device DMA-writes completion(s)
    -> makes completion writes host-visible
    -> issues PLIO Notification (`SPACE=CONTROLLER` write)
```

A PLIO Notification MUST NOT become observable by the host before preceding completion-memory writes by that manager are visible.

Parity protects transmission on PLIO; host profiles remain responsible for defining any parity/ECC requirements for host RAM and internal memory paths.

## 17. Host and physical profiles

The PLIO logical bus is intentionally host-independent.

A **host profile** MUST define at least:

- how CPU/software addresses map to PLIO `(slot, slot_offset)` worker transactions,
- how privileged software programs DMA capability channels,
- how aggregate PLIO Notification pending/claim state reaches the host CPU/kernel,
- cache/visibility operations required around DMA,
- how PLIO parity faults are surfaced to privileged software and, where relevant, device drivers.

The RAX profile is `PLIO-RAX.md`.

A **physical profile** MUST define connector, mechanics, pinout, power, signal electrical requirements, and clock/loading rules.

The baseline interoperable card/backplane profile is `PLIO-E.md`, using Eurocard mechanics and a 96-position DIN 41612-style connector.

## 18. Required conformance

A PLIO worker MUST support:

- reset,
- standard configuration header,
- slot selection,
- `SPACE=WORKER` 8/16/32-bit MMIO,
- mandatory `PAR[3:0]` generation/checking for the AD byte lanes,
- `ACK*`/`ERR*` behavior.

A PLIO bus manager additionally MUST support:

- request/grant arbitration,
- `SPACE=HOST_DMA`,
- all 1/4/8/16-longword baseline burst lengths,
- parity generation/checking on every address/data beat,
- protected DMA faults including generation validation.

A device advertising notification capability MUST be capable of issuing the single-beat `SPACE=CONTROLLER` **PLIO Notification** transaction.

A QDX device additionally MUST implement `QDX.md` and its declared profile.

Conformance to a particular backplane/card form factor additionally requires the relevant physical profile, normally PLIO-E.