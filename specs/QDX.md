# QDX v0.1 — Queued Device Express Core

**Status:** Draft

## 1. Purpose

QDX is a standard software/device contract for asynchronous devices. It deliberately sits above PLIO.

PLIO answers:

> How does the controller electrically access registers and memory?

QDX answers:

> How does software submit asynchronous work and receive completions?

QDX is designed so that the same queue semantics can later be transported over other RAX interconnects without redefining device classes.

## 2. v0.1 goals

- one submission queue (SQ),
- one completion queue (CQ),
- fixed-size descriptors,
- DMA-visible shared memory,
- MMIO doorbells,
- completion coalescing behind one device interrupt,
- tagged out-of-order completion permitted,
- no mandatory admin queue,
- no mandatory multiple hardware queues.

## 3. Device state

A QDX device has four states:

```text
RESET -> DISABLED -> READY -> FAULT
```

- `RESET`: platform reset active.
- `DISABLED`: registers discoverable; DMA and queue processing stopped.
- `READY`: queues configured and command processing enabled.
- `FAULT`: unrecoverable device/QDX state; reset required unless profile says otherwise.

## 4. Standard QDX MMIO registers

QDX registers begin at PLIO slot offset `0x1000`.

| Offset | Width | Register | Meaning |
|---:|---:|---|---|
| `0x1000` | 32 | `QDX_CAP` | queue/profile capabilities |
| `0x1004` | 32 | `QDX_STATUS` | ready/fault state |
| `0x1008` | 32 | `QDX_CONTROL` | enable/reset/IRQ enable |
| `0x1010` | 32 | `SQ_BASE` | device-visible DMA base of SQ |
| `0x1014` | 16 | `SQ_SIZE` | number of entries, power of two |
| `0x1018` | 16 | `SQ_TAIL` | host doorbell: next free SQ position |
| `0x1020` | 32 | `CQ_BASE` | device-visible DMA base of CQ |
| `0x1024` | 16 | `CQ_SIZE` | number of entries, power of two |
| `0x1028` | 16 | `CQ_HEAD` | host doorbell: next CQ entry consumed |
| `0x1030` | 16 | `SQ_HEAD` | device progress, read-only |
| `0x1034` | 16 | `CQ_TAIL` | device progress, read-only |
| `0x1038` | 32 | `QDX_ERROR` | last queue/DMA protocol fault |

All queue bases MUST be naturally aligned to the descriptor size of the declared profile.

## 5. Queue size

QDX v0.1 queue sizes MUST be powers of two from 4 through 256 entries.

The SQ and CQ sizes MAY differ.

Ring indexes wrap modulo queue size.

## 6. Submission protocol

The host submits work as follows:

1. write one or more complete command descriptors into free SQ entries,
2. make descriptor memory writes visible to PLIO DMA,
3. write the new producer position to `SQ_TAIL`.

The device:

1. observes `SQ_TAIL`,
2. DMA-reads entries from its current `SQ_HEAD` up to the announced tail,
3. advances `SQ_HEAD` after it has safely consumed each descriptor.

Writing `SQ_TAIL` is a doorbell. It is not itself the command payload.

## 7. Completion protocol

For each completed command, the device:

1. writes a complete completion descriptor to `CQ[CQ_TAIL]`,
2. makes the completion visible in memory,
3. advances its `CQ_TAIL`,
4. asserts its PLIO interrupt if interrupts are enabled and notification is required.

The host:

1. reads completions from `CQ_HEAD` up to `CQ_TAIL`,
2. processes them,
3. writes the new consumed position to `CQ_HEAD`,
4. performs profile/device acknowledgement so the PLIO IRQ line can be deasserted.

## 8. Tags

Every command carries a 32-bit host-selected `tag`.

The device MUST return the same tag in the completion.

A device MAY complete commands out of submission order unless a profile explicitly requires ordering.

The host MUST NOT reuse an active tag until that command has completed or been aborted/reset.

## 9. Interrupt behavior

QDX does not require one interrupt per command.

A device SHOULD coalesce completions naturally:

```text
CQ gets 1 completion -> IRQ asserted
CQ gets 8 more completions while IRQ remains asserted -> no additional IRQ edge is required
host wakes -> drains all 9 completions
```

PLIO v0.1 uses a level-triggered per-slot IRQ line, so the QDX device keeps the line asserted while it has an interrupt-worthy condition that software has not acknowledged.

Polling the CQ is always legal.

## 10. Queue overflow rules

The host MUST NOT advance `SQ_TAIL` into an unconsumed SQ entry.

The device MUST NOT overwrite an unconsumed CQ entry.

If CQ space is exhausted, the device MUST stop completing additional commands into the CQ and MUST assert its interrupt/fault indication.

Loss of completions is not permitted.

## 11. DMA faults

If a QDX descriptor or data buffer references an address rejected by the PLIO DMA-window mechanism, the device command completes with a DMA fault if possible.

If the device cannot safely write the completion because the CQ itself is inaccessible, it enters `FAULT` and asserts its IRQ line.

## 12. Reset behavior

Reset discards all outstanding queue state.

After reset:

- `QDX_STATUS.READY = 0`,
- DMA is stopped,
- interrupts are disabled,
- queue base/size registers are not active,
- software must reinitialize queues before enabling QDX.

Profiles may define media/device state that survives a QDX reset.

## 13. Profiles

QDX core defines queue transport only.

The initial profile is:

- `QDX-B` — block storage

Future profiles may include networking, graphics, streaming, or accelerators without altering PLIO.
