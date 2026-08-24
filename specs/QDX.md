# QDX v0.3 — Queued Device Express Core

**Status:** Draft

## 1. Purpose

QDX is a standard software/device contract for asynchronous devices. It deliberately sits above PLIO.

PLIO answers:

> How does the controller electrically access registers, protected memory channels, and host notification state?

QDX answers:

> How does software submit asynchronous work and receive completions?

QDX is designed so the same queue semantics can later be transported over other RAX interconnects without redefining device classes.

## 2. Baseline goals

- one submission queue (SQ),
- one completion queue (CQ),
- fixed-size descriptors,
- DMA-visible shared memory,
- MMIO doorbells,
- completion notification/coalescing,
- tagged out-of-order completion permitted,
- no mandatory admin queue,
- no mandatory multiple hardware queues.

## 3. Device state

A QDX device has four states:

```text
RESET -> DISABLED -> READY -> FAULT
```

## 4. Standard QDX MMIO registers

QDX registers begin at PLIO slot offset `0x1000`.

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

Queue bases and all buffer addresses are **device-visible PLIO DMA capability addresses**. On PLIO v0.3, bits 31:28 select one of sixteen protected DMA capability channels, bits 27:24 carry that channel's generation, and bits 23:0 are the byte offset within the bound memory region.

A QDX descriptor that retains an old DMA address after a channel is revoked cannot acquire authority to a later binding unless both the channel and generation match. PLIO defines the generation lifecycle and safe-wrap rule.

## 5. Queue size

Queue sizes MUST be powers of two from 4 through 256 entries. SQ and CQ sizes MAY differ. Ring indexes wrap modulo queue size.

## 6. Submission protocol

The host:

1. writes one or more complete command descriptors into free SQ entries,
2. makes descriptor memory writes visible to PLIO DMA,
3. writes the new producer position to `SQ_TAIL`.

The device observes `SQ_TAIL`, DMA-reads entries from its current `SQ_HEAD`, and advances `SQ_HEAD` after safely consuming descriptors.

Writing `SQ_TAIL` is a doorbell, not command payload.

## 7. Completion protocol

For each completed command, the device:

1. writes a complete completion descriptor to `CQ[CQ_TAIL]`,
2. makes the completion visible in host memory,
3. advances its `CQ_TAIL`,
4. sends a PLIO normal notification when notification is required.

The normal QDX coalescing rule is **notify on CQ empty -> non-empty transition**. Additional completions may be added while the queue remains non-empty without additional notification messages.

The host reads completions from `CQ_HEAD` up to `CQ_TAIL`, processes them, and writes the new consumed position to `CQ_HEAD`.

When the CQ becomes empty, the device is rearmed to notify on the next empty -> non-empty transition.

Polling the CQ is always legal.

## 8. Tags

Every command carries a 32-bit host-selected `tag`; the same tag is returned in the completion. A device MAY complete commands out of order unless a profile requires ordering. The host MUST NOT reuse an active tag until completion/abort/reset.

## 9. Notification behavior

QDX does not require one notification per command.

Example:

```text
CQ empty
  -> completion A written
  -> PLIO NOTIFY message
  -> completions B..H written while CQ remains non-empty
  -> no extra NOTIFY required
host drains A..H
CQ empty/rearmed
```

PLIO controller pending bits may additionally coalesce repeated messages.

A QDX device normally uses notification channel 0 unless a profile or later multi-queue extension assigns additional channels. The device does not choose CPU priority or vector; the PLIO controller supplies that policy.

There is no device IRQ line to acknowledge or deassert.

## 10. Queue overflow

The host MUST NOT advance `SQ_TAIL` into an unconsumed SQ entry. The device MUST NOT overwrite an unconsumed CQ entry.

If CQ space is exhausted, the device MUST stop publishing further completions and MUST send a notification/fault indication. Loss of completions is not permitted.

## 11. DMA faults

If a descriptor or buffer references an address rejected by the PLIO DMA capability-channel mechanism, including a generation mismatch, the command completes with a DMA fault if possible.

If the CQ capability itself is inaccessible and the device cannot safely publish a completion, it enters `FAULT` and sends a PLIO notification if its notification path remains usable.

## 12. Reset

Reset discards outstanding queue state. After reset DMA is stopped, notifications are disabled, and software must reinitialize queues before enabling QDX.

## 13. Profiles

QDX core defines queue transport only. Current profiles are:

- QDX-B / QDX-BA — block storage and optional block acceleration,
- QDX-S / QDX-SA — stream endpoints and optional stream acceleration,
- QDX-GNET / QDX-GNETA — GNET frame I/O and optional network acceleration,
- QDX-G — asynchronous 2D graphics acceleration, including shared-host-memory surfaces,
- QDX-DSP — buffer-oriented digital signal-processing acceleration.

QDX-G and QDX-DSP deliberately reuse the normal QDX queue, PLIO capability-DMA, and message-signalled completion mechanisms. They do not define a second CPU-local accelerator bus or a separate unrestricted DMA architecture.
