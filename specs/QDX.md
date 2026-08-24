# QDX v0.4 — Queued Device Express Core

**Status:** Draft

## 1. Purpose

QDX is a standard software/device contract for asynchronous devices. It sits above PLIO and is intentionally independent of any one CPU's physical address map or native byte order.

PLIO answers how a controller performs MMIO, protected DMA, and notification transactions. QDX answers how software submits asynchronous work and receives completions.

The same QDX queue/profile semantics may later be transported over another interconnect without redefining device classes.

## 2. Canonical byte order

**All QDX-defined multibyte integer fields are little-endian.**

This rule applies to:

- QDX MMIO register representation where a bus/host bridge performs byte-lane mapping,
- submission descriptors,
- completion descriptors,
- scatter/gather entries,
- IDENTIFY structures,
- profile-defined parameter blocks and control structures.

Byte arrays, packet payloads, disk-sector contents, audio samples whose format explicitly defines its own byte order, and other opaque payload data are not byte-swapped merely because they are transported by QDX.

A big-endian host must convert QDX control structures at its software or host-interface boundary. A little-endian host normally requires no conversion.

The QDX byte order is part of the ABI and MUST NOT depend on the host CPU architecture.

## 3. Baseline goals

- one submission queue (SQ),
- one completion queue (CQ),
- fixed-size descriptors,
- DMA-visible shared memory,
- MMIO doorbells,
- completion notification/coalescing,
- 32-bit tags,
- out-of-order completion where the profile permits it,
- no mandatory admin queue,
- no mandatory multiple hardware queues.

## 4. Device state

A QDX device has four states:

```text
RESET -> DISABLED -> READY -> FAULT
```

## 5. Standard QDX MMIO registers

QDX registers begin at PLIO slot-relative worker offset `0x1000`.

| Offset | Width | Register | Meaning |
|---:|---:|---|---|
| `0x1000` | 32 | `QDX_CAP` | queue/profile capabilities |
| `0x1004` | 32 | `QDX_STATUS` | ready/fault state |
| `0x1008` | 32 | `QDX_CONTROL` | enable/reset/notification enable |
| `0x1010` | 32 | `SQ_BASE` | device-visible DMA capability address of SQ |
| `0x1014` | 16 | `SQ_SIZE` | number of entries, power of two |
| `0x1018` | 16 | `SQ_TAIL` | host doorbell: next free SQ position |
| `0x1020` | 32 | `CQ_BASE` | device-visible DMA capability address of CQ |
| `0x1024` | 16 | `CQ_SIZE` | number of entries, power of two |
| `0x1028` | 16 | `CQ_HEAD` | host doorbell: next CQ entry consumed |
| `0x1030` | 16 | `SQ_HEAD` | device progress, read-only |
| `0x1034` | 16 | `CQ_TAIL` | device progress, read-only |
| `0x1038` | 32 | `QDX_ERROR` | last queue/DMA protocol fault |

Queue bases and buffer addresses carried by QDX are device-visible PLIO DMA handles. Under PLIO v0.5:

```text
channel[31:28] | generation[27:24] | offset[23:0]
```

QDX does not expose host physical addresses to the device.

## 6. Queue size

Queue sizes MUST be powers of two from 4 through 256 entries. SQ and CQ sizes MAY differ. Ring indexes wrap modulo queue size.

## 7. Submission protocol

The host:

1. writes one or more complete little-endian command descriptors into free SQ entries,
2. performs the platform-defined visibility operation required before PLIO DMA,
3. writes the new producer position to `SQ_TAIL`.

The device observes `SQ_TAIL`, DMA-reads entries from its current `SQ_HEAD`, and advances `SQ_HEAD` after safely consuming descriptors.

Writing `SQ_TAIL` is a doorbell, not command payload.

A PLIO implementation SHOULD use bounded burst DMA where useful. For example, a 32-byte descriptor can be fetched as one 8-longword PLIO burst when alignment/capability bounds permit it.

## 8. Completion protocol

For each completed command the device:

1. writes a complete little-endian completion descriptor to `CQ[CQ_TAIL]`,
2. makes the completion host-visible,
3. advances `CQ_TAIL`,
4. sends the interconnect's normal notification when required.

On PLIO the normal notification is a bus-local `SPACE=CONTROLLER` message-signalled transaction.

The normal QDX coalescing rule is **notify on CQ empty -> non-empty transition**. Additional completions may be added while the CQ remains non-empty without additional notification transactions.

The host processes entries from `CQ_HEAD` through `CQ_TAIL` and writes the new consumed position to `CQ_HEAD`.

When the CQ becomes empty, the device is rearmed to notify on the next empty -> non-empty transition.

Polling is always legal.

## 9. Tags

Every command carries a 32-bit host-selected `tag`; the same numerical tag is returned in the completion. The on-memory representation is little-endian.

A device MAY complete commands out of order unless its profile imposes ordering. The host MUST NOT reuse an active tag until completion, abort, or reset.

## 10. Notification behavior

QDX does not require one notification per command.

```text
CQ empty
  -> completion A written
  -> normal notification
  -> completions B..H written while CQ remains non-empty
  -> no extra notification required
host drains A..H
CQ empty/rearmed
```

PLIO controller pending bits may additionally coalesce repeated messages.

A QDX device normally uses PLIO notification channel 0 unless a profile/later multi-queue extension assigns another channel. The device does not choose host CPU priority, vector, or privilege.

There is no QDX device IRQ line to acknowledge or deassert.

## 11. Queue overflow

The host MUST NOT advance `SQ_TAIL` into an unconsumed SQ entry. The device MUST NOT overwrite an unconsumed CQ entry.

If CQ space is exhausted, the device MUST stop publishing further completions and MUST send a notification/fault indication. Completion loss is forbidden.

## 12. DMA faults

If a descriptor or buffer references a handle rejected by the PLIO DMA capability mechanism, including generation, bounds, direction, or active-revocation failure, the command completes with a DMA fault if possible.

If the CQ mapping itself is inaccessible and the device cannot safely publish a completion, it enters `FAULT` and sends a notification if that path remains usable.

## 13. Reset

Reset discards outstanding queue state. DMA stops, notifications are disabled, and software must reinitialize queues before enabling QDX.

## 14. Profiles

QDX core defines queue transport only. Current profiles are:

- QDX-B / QDX-BA — block storage and optional block acceleration,
- QDX-S / QDX-SA — stream endpoints and optional stream acceleration,
- QDX-GNET / QDX-GNETA — GNET frame I/O and optional network acceleration,
- QDX-G — asynchronous 2D graphics acceleration,
- QDX-DSP — buffer-oriented signal-processing acceleration.

All profiles inherit the canonical little-endian control-structure rule unless a particular payload field is explicitly defined as opaque or as having an external media/network format.

QDX-G and QDX-DSP reuse the normal QDX queue, PLIO capability-DMA, and message-signalled completion mechanisms. They do not define a second CPU-local accelerator bus or an unrestricted DMA architecture.
