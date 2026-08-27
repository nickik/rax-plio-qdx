# QDX-B v0.5 — Block Storage Profile

**Status:** Draft

## 1. Purpose

QDX-B defines the standard asynchronous block-storage command set carried by QDX.

One QDX-B controller may expose multiple **namespaces**. A namespace normally represents one physical disk, but it may also represent a logical volume.

The initial RAX storage design expects a PLIO QDX-B controller to attach one or more LDL, LDLe, or bridged MASSBUS disks.

All multibyte QDX-B control fields use the canonical **little-endian** QDX byte order. Media payload bytes are transferred unchanged.

QDX-B v0.5 adds an optional **integrity engine**. Higher software remains the owner of checksum metadata and repair policy; QDX may calculate or compare a checksum supplied by software while bytes are already passing through the controller.

## 2. Required capabilities

A QDX-B v0.5 controller MUST support:

- one QDX submission/completion queue pair,
- at least one namespace,
- READ,
- WRITE,
- WRITE_DURABLE,
- FLUSH,
- GET_HEALTH,
- IDENTIFY CONTROLLER,
- IDENTIFY NAMESPACE,
- completion status reporting,
- direct contiguous buffers,
- scatter/gather lists of up to 16 segments.

The checksum/integrity facility is optional and is advertised by capability bit. QDX-BA is also optional. Base QDX-B correctness MUST NOT depend on either extension.

## 3. Command descriptor

Every QDX-B submission entry is 32 bytes.

| Offset | Size | Field |
|---:|---:|---|
| `0x00` | 1 | `opcode` |
| `0x01` | 1 | `flags` |
| `0x02` | 2 | `namespace_id` |
| `0x04` | 4 | `tag` |
| `0x08` | 4 | `lba` |
| `0x0C` | 2 | `block_count` |
| `0x0E` | 1 | `sg_count` |
| `0x0F` | 1 | reserved |
| `0x10` | 4 | `data_addr` |
| `0x14` | 4 | `sg_addr` |
| `0x18` | 4 | `command_arg` |
| `0x1C` | 4 | reserved |

Reserved fields MUST be written as zero and ignored by a v0.5 device.

A naturally aligned 32-byte command descriptor fits one PLIO 8-longword DMA burst when its DMA capability mapping also permits the complete burst.

### 3.1 Base command flags

| Bit | Name | Meaning |
|---:|---|---|
| 0 | `QDX_B_F_INTEGRITY` | `command_arg` points to an integrity descriptor |
| 1..7 | reserved | zero |

`QDX_B_F_INTEGRITY` is legal only for commands explicitly defined to use it and only when the controller advertises `QDX_B_CAP_INTEGRITY`.

## 4. Opcodes

| Opcode | Name | Meaning |
|---:|---|---|
| `0x00` | `NOP` | no operation; useful for testing |
| `0x01` | `IDENTIFY_CONTROLLER` | return controller information |
| `0x02` | `IDENTIFY_NAMESPACE` | return namespace information |
| `0x03` | `IDENTIFY_INTEGRITY` | return checksum/integrity capability information |
| `0x10` | `READ` | namespace -> host memory |
| `0x11` | `WRITE` | host memory -> namespace using normal namespace write-completion policy |
| `0x12` | `FLUSH` | make previously completed writes durable as supported by media |
| `0x13` | `GET_HEALTH` | return current namespace/controller health summary |
| `0x14` | `WRITE_DURABLE` | write this payload and do not complete until this write is durable |

Opcodes `0x20..0x2F` are reserved for QDX-BA when that extension is advertised.

Other opcodes are reserved.

## 5. Namespace identifiers

`namespace_id = 0` refers to the controller when used with controller-wide commands.

Normal block commands require a nonzero namespace ID.

A controller MAY expose up to 65535 namespace IDs, though early implementations are expected to expose far fewer.

Namespace IDs need not be contiguous, but simple controllers SHOULD assign them starting at 1.

## 6. Block addressing

QDX-B v0.5 uses a 32-bit logical block address.

The namespace identifies its logical block size.

Required supported block sizes are 512 and 1024 bytes. A controller MAY support additional power-of-two block sizes.

`block_count` is the number of logical blocks and MUST be nonzero for READ/WRITE/WRITE_DURABLE.

A request extending beyond namespace capacity completes with `LBA_RANGE`.

## 7. Data buffers

### 7.1 Direct buffer

If `sg_count == 0`, `data_addr` is the device-visible DMA capability address of one contiguous buffer large enough for the complete transfer.

### 7.2 Scatter/gather buffer

If `sg_count > 0`:

- `sg_count` MUST be 1..16,
- `sg_addr` points to an array of SG entries,
- `data_addr` is ignored.

Each SG entry is 8 bytes and all fields are little-endian:

| Offset | Size | Field |
|---:|---:|---|
| `0x00` | 4 | `address` |
| `0x04` | 4 | `length_bytes` |

The sum of SG lengths MUST be at least the requested transfer size.

The controller MUST process only the number of bytes required by the block command.

All SG handles remain subject to PLIO channel, generation, bounds, direction, and revocation checks.

A controller SHOULD use repeated 16-longword PLIO bursts for large aligned payload regions and shorter baseline bursts at SG boundaries or transfer tails.

## 8. Completion descriptor

Every QDX-B completion entry is 16 bytes.

| Offset | Size | Field |
|---:|---:|---|
| `0x00` | 4 | `tag` |
| `0x04` | 2 | `status` |
| `0x06` | 2 | `flags` |
| `0x08` | 4 | `blocks_done` |
| `0x0C` | 4 | `info` |

All multibyte fields are little-endian.

`tag` MUST numerically match the submitted command tag.

`blocks_done` is zero for commands that transfer no blocks. For a successful READ/WRITE/WRITE_DURABLE it normally equals `block_count`.

A 16-byte completion fits one PLIO 4-longword DMA burst when alignment/capability bounds permit it.

### 8.1 Completion flags

| Bit | Name | Meaning |
|---:|---|---|
| 0 | `INTEGRITY_CHECKED` | controller calculated a QDX integrity checksum for this command |
| 1 | `INTEGRITY_MATCH` | supplied expected checksum matched; valid only with `INTEGRITY_CHECKED` |
| 2 | `INTEGRITY_RESULT_WRITTEN` | integrity result descriptor was written |
| 3 | `WRITE_DURABLE_DONE` | this command's write payload is durable before completion |
| 4..15 | reserved | zero |

## 9. Status codes

| Status | Name |
|---:|---|
| `0x0000` | `SUCCESS` |
| `0x0001` | `INVALID_OPCODE` |
| `0x0002` | `INVALID_NAMESPACE` |
| `0x0003` | `INVALID_FIELD` |
| `0x0004` | `LBA_RANGE` |
| `0x0005` | `DMA_FAULT` |
| `0x0006` | `MEDIA_ERROR` |
| `0x0007` | `WRITE_PROTECTED` |
| `0x0008` | `NOT_READY` |
| `0x0009` | `QUEUE_ERROR` |
| `0x000A` | `INTERNAL_ERROR` |
| `0x000B` | `INTEGRITY_MISMATCH` |

Status range `0x0100..0x01FF` is reserved for QDX-BA extension completions.

An unsupported integrity algorithm or invalid integrity descriptor completes with `INVALID_FIELD`; `INTEGRITY_MISMATCH` specifically means that a valid expected checksum was compared and did not match the bytes processed by the controller.

## 10. IDENTIFY_CONTROLLER data

`IDENTIFY_CONTROLLER` writes exactly 64 bytes to the normal QDX-B data buffer.

Layout:

| Offset | Size | Field | Meaning |
|---:|---:|---|---|
| `0x00` | 2 | `profile_revision` | QDX-B revision, `0x0005` for this profile |
| `0x02` | 2 | `namespace_count` | currently exposed namespaces |
| `0x04` | 2 | `max_sg_entries` | MUST be at least 16 for v0.5 |
| `0x06` | 2 | `controller_flags` | controller behavior flags |
| `0x08` | 4 | `max_transfer_blocks` | maximum block_count accepted by one block command |
| `0x0C` | 4 | `capability_bits` | optional profile/features |
| `0x10` | 16 | `model_id` | opaque ASCII-compatible byte field |
| `0x20` | 16 | `serial_id` | opaque controller identifier byte field |
| `0x30` | 16 | reserved | zero |

All integer fields are little-endian. `model_id` and `serial_id` are byte arrays and are not byte-swapped.

### 10.1 controller_flags

| Bit | Name | Meaning |
|---:|---|---|
| 0 | `VOLATILE_WRITE_CACHE` | one or more namespaces may report ordinary WRITE completion before durable media; FLUSH or WRITE_DURABLE is required where durability matters |
| 1..15 | reserved | zero |

### 10.2 capability_bits

| Bit | Name | Meaning |
|---:|---|---|
| 0 | `QDX_B_CAP_QDX_BA` | controller implements the complete advertised QDX-BA profile |
| 1 | `QDX_B_CAP_INTEGRITY` | controller implements QDX-B integrity descriptors and `IDENTIFY_INTEGRITY` |
| 2..31 | reserved | zero |

If `QDX_B_CAP_QDX_BA` is set, software may use `QDX-BA.md` after checking its supported revision through the normal QDX/PLIO profile revision mechanism.

## 11. IDENTIFY_NAMESPACE data

`IDENTIFY_NAMESPACE` writes exactly 64 bytes.

Layout:

| Offset | Size | Field | Meaning |
|---:|---:|---|---|
| `0x00` | 2 | `namespace_id` | namespace being described |
| `0x02` | 2 | `flags` | namespace flags |
| `0x04` | 4 | `block_size` | logical block size in bytes |
| `0x08` | 4 | `total_blocks` | total addressable logical blocks |
| `0x0C` | 4 | `recommended_alignment` | preferred host I/O alignment in bytes, zero if none |
| `0x10` | 16 | `model_media_id` | opaque media/model byte field |
| `0x20` | 16 | `serial_id` | opaque namespace/media identifier |
| `0x30` | 16 | reserved | zero |

Namespace flags:

| Bit | Name | Meaning |
|---:|---|---|
| 0 | `READ_ONLY` | namespace rejects WRITE and WRITE_DURABLE |
| 1 | `VOLATILE_WRITE_CACHE` | ordinary WRITE completion may precede durable media; FLUSH or WRITE_DURABLE establishes durability |
| 2..15 | reserved | zero |

## 12. Integrity extension

### 12.1 Architectural rule

The higher software layer owns checksum metadata and supplies the expected checksum when verification is desired.

QDX does not maintain a hidden authoritative checksum table and does not decide replica topology, repair policy, allocation, snapshots, or transaction semantics.

Conceptually:

```text
filesystem metadata
    |
expected checksum
    |
QDX-B command
    |
controller calculates / compares
    |
completion reports result
```

### 12.2 IDENTIFY_INTEGRITY

A controller advertising `QDX_B_CAP_INTEGRITY` MUST support `IDENTIFY_INTEGRITY` and MUST support `CRC64_QDX1`.

`IDENTIFY_INTEGRITY` writes exactly 64 bytes:

| Offset | Size | Field | Meaning |
|---:|---:|---|---|
| `0x00` | 2 | `integrity_revision` | `1` |
| `0x02` | 2 | reserved | zero |
| `0x04` | 4 | `algorithm_bits` | supported checksum algorithms |
| `0x08` | 4 | `max_integrity_read_blocks` | maximum READ blocks accepted with integrity enabled |
| `0x0C` | 4 | `max_integrity_write_blocks` | maximum WRITE/WRITE_DURABLE blocks accepted when pre-write verification is required |
| `0x10` | 48 | reserved | zero |

Algorithm bits:

| Bit | Algorithm |
|---:|---|
| 0 | `CRC64_QDX1` |
| 1..31 | reserved for future algorithms |

### 12.3 CRC64_QDX1

`CRC64_QDX1` is a 64-bit CRC designed for simple late-1970s XOR/shift-register implementation.

Canonical parameters:

```text
width       64
polynomial  0x42F0E1EBA9EA3693
initial     0x0000000000000000
reflect     no
xorout      0x0000000000000000
```

Payload bytes are processed in the exact byte order transferred by QDX. The checksum definition is independent of host integer byte order.

### 12.4 Integrity descriptor

When `QDX_B_F_INTEGRITY` is set on READ, WRITE, or WRITE_DURABLE, `command_arg` points to a 32-byte device-readable integrity descriptor:

| Offset | Size | Field | Meaning |
|---:|---:|---|---|
| `0x00` | 2 | `version` | MUST be `1` |
| `0x02` | 2 | `algorithm` | checksum algorithm ID |
| `0x04` | 4 | `flags` | integrity operation flags |
| `0x08` | 16 | `expected_checksum` | expected checksum, unused high bytes zero |
| `0x18` | 4 | `result_addr` | device-writable address of 32-byte integrity result, or zero if not requested |
| `0x1C` | 4 | reserved | zero |

Integrity flags:

| Bit | Name | Meaning |
|---:|---|---|
| 0 | `VERIFY_EXPECTED` | compare calculated checksum with `expected_checksum` |
| 1 | `RETURN_CALCULATED` | write an integrity result descriptor |
| 2..31 | reserved | zero |

At least one of `VERIFY_EXPECTED` or `RETURN_CALCULATED` MUST be set.

For `CRC64_QDX1`, the first 8 bytes of `expected_checksum` contain the 64-bit checksum in little-endian control-field representation and the remaining 8 bytes MUST be zero.

### 12.5 Integrity result descriptor

If `RETURN_CALCULATED` is set, `result_addr` MUST identify a writable 32-byte result:

| Offset | Size | Field | Meaning |
|---:|---:|---|---|
| `0x00` | 2 | `version` | `1` |
| `0x02` | 2 | `algorithm` | algorithm actually used |
| `0x04` | 4 | `flags` | result flags |
| `0x08` | 16 | `calculated_checksum` | calculated checksum; unused high bytes zero |
| `0x18` | 4 | `bytes_processed` | payload bytes included |
| `0x1C` | 4 | reserved | zero |

Result flags:

- bit 0: `CALCULATED_VALID`
- bit 1: `EXPECTED_MATCH`
- bits 2..31: reserved

The result descriptor MUST be host-visible before the CQ completion that refers to it becomes visible.

### 12.6 Scope of verification

The checksum covers exactly the payload bytes of the QDX command, in logical transfer order, across all SG segments used by that command.

A QDX integrity result says what the controller observed. PLIO parity protects transmission on the PLIO bus, but host RAM parity/ECC and CPU-side memory integrity remain host-platform responsibilities.

## 13. READ

For ordinary READ:

1. controller validates namespace/LBA/range,
2. obtains data from the namespace/media,
3. DMA-writes data into host buffers,
4. writes the CQ completion,
5. advances `CQ_TAIL`,
6. sends a PLIO Notification when QDX notification rules require one.

With `QDX_B_F_INTEGRITY`, the controller additionally calculates the selected checksum over the media payload.

If `VERIFY_EXPECTED` is set:

- a match completes normally with `INTEGRITY_CHECKED | INTEGRITY_MATCH`;
- a mismatch completes with `INTEGRITY_MISMATCH` and `INTEGRITY_CHECKED`; the host buffer may contain the bytes read but they MUST be treated as untrusted.

If `RETURN_CALCULATED` is set, the integrity result is written before the CQ completion.

The completion MUST NOT become visible before the DMA data and any integrity result it reports as complete are host-visible.

A PLIO Notification MUST NOT become observable before the completion it announces is host-visible.

## 14. WRITE

### 14.1 Ordinary WRITE

For WRITE:

1. controller validates namespace/LBA/range,
2. DMA-reads host data,
3. writes data to media/controller buffering,
4. completes according to the namespace write-completion policy.

A `SUCCESS` completion for ordinary WRITE means data has reached the persistence level advertised by the namespace/controller.

If `VOLATILE_WRITE_CACHE` is clear for that namespace, successful WRITE completion is durable with respect to the storage device contract.

If `VOLATILE_WRITE_CACHE` is set, the host uses `FLUSH` or `WRITE_DURABLE` when it needs durability.

### 14.2 WRITE with integrity verification

If WRITE uses `VERIFY_EXPECTED`, the controller MUST calculate and compare the checksum of the **complete host payload before the first media modification for that command**.

The implementation may stage the complete payload in controller buffer/cache or use another mechanism that provides equivalent pre-write verification. A controller MAY reject an integrity WRITE larger than `max_integrity_write_blocks`; software can split the transfer.

If verification fails:

- no media block from that command may have been modified,
- completion status is `INTEGRITY_MISMATCH`.

If verification succeeds, the exact verified staged bytes are the bytes written to media.

`RETURN_CALCULATED` may be combined with verification or used alone.

## 15. WRITE_DURABLE

`WRITE_DURABLE` transfers the same payload as WRITE but MUST NOT complete successfully until the data written by **this command** is durable according to the namespace media contract.

It is the per-command durable-write primitive.

`WRITE_DURABLE` does **not** implicitly establish ordering or durability for unrelated outstanding writes. Software that needs all previously completed writes to become durable uses `FLUSH`.

Integrity semantics are identical to WRITE. When successful, the completion sets `WRITE_DURABLE_DONE`.

This gives software three distinct tools:

```text
WRITE           normal possibly cached write
WRITE_DURABLE   this command is durable before completion
FLUSH           make previously completed writes durable
```

## 16. FLUSH

`FLUSH` requests that all previously completed writes to the selected namespace become durable according to the media/controller contract.

A controller with no volatile write cache may complete FLUSH immediately after ordering requirements are satisfied.

A successful FLUSH is a durability barrier for writes to that namespace that completed before the FLUSH was submitted after their completions were observed by software.

For software transactions spanning several namespaces, software must FLUSH each namespace whose durability is required.

## 17. GET_HEALTH

`GET_HEALTH` writes a 64-byte standardized summary. Controllers may aggregate richer transport-specific telemetry, such as LDL health logs, into these counters while preserving detailed diagnostics through controller-specific service interfaces.

| Offset | Size | Field |
|---:|---:|---|
| `0x00` | 2 | health revision (`1`) |
| `0x02` | 2 | health flags |
| `0x04` | 4 | media-error count |
| `0x08` | 4 | corrected-data event count |
| `0x0C` | 4 | retry event count |
| `0x10` | 4 | write-fault count |
| `0x14` | 4 | seek/positioning fault count |
| `0x18` | 4 | transport/parity/CRC fault count |
| `0x1C` | 4 | marginal-LBA event count |
| `0x20` | 4 | last-error LBA |
| `0x24` | 28 | reserved |

Health flags include `DEGRADED`, `MEDIA_WARNING`, `TRANSPORT_WARNING`, and `SERVICE_RECOMMENDED`; exact threshold policy belongs to controller/host software rather than the wire protocol.

## 18. PLIO Notification behavior

QDX-B uses the common QDX completion-notification mechanism. On PLIO the mechanism is called **PLIO Notification**.

There is **no dedicated PLIO IRQ line** for a QDX-B controller.

A QDX-B controller that generates asynchronous notifications MUST be a PLIO bus manager. To notify the host it requests ownership, receives its grant, and issues one bus-local `SPACE=CONTROLLER` PLIO Notification to the configured notification channel.

The PLIO controller derives the trusted source slot from the active grant. The QDX-B device does not choose host CPU vector, privilege, notification class, or CPU routing.

QDX-B normally uses PLIO notification channel 0 unless a later profile assigns another channel.

The normal QDX rule is to send a PLIO Notification when the CQ transitions from empty to non-empty. Additional completions MAY accumulate while the CQ remains non-empty without additional notification transactions. PLIO pending state may coalesce repeated Notifications.

The host drains CQ entries. When the CQ becomes empty, the device is rearmed to notify on the next empty-to-non-empty transition. Polling remains legal.

## 19. Ordering

Commands may complete out of order unless semantics impose a dependency or the host uses completion observation plus FLUSH to establish a durability boundary.

A controller MUST preserve data integrity for overlapping commands even if it reorders them internally.

Higher-level crash-consistent software MUST NOT infer atomicity across several independent WRITE commands merely because they were submitted together or completed close together.

`WRITE_DURABLE` guarantees durability of its own payload, not ordering against unrelated commands.

## 20. Reset and media state

QDX reset discards outstanding commands but does not imply destructive media reset.

After reset the host must rediscover namespaces before assuming they are ready.

Reset does not turn partially completed media writes into transactions. Higher software layers remain responsible for recovery from interruption between block operations.

## 21. Checksummed copy-on-write software

QDX-B integrity acceleration is intentionally suitable for a checksummed copy-on-write filesystem while keeping policy above QDX.

Examples:

- software reads a parent block pointer, obtains the expected checksum, and submits READ + `VERIFY_EXPECTED`;
- software submits WRITE + `RETURN_CALCULATED`, then stores the returned checksum in higher-level metadata;
- software uses WRITE + `VERIFY_EXPECTED` to ensure a host buffer still matches an already-known checksum before media modification;
- software uses ordinary WRITE for bulk data and a later FLUSH to batch durability;
- software uses WRITE_DURABLE for a particular block that must be durable before its completion is accepted.

QDX never invents the expected checksum and never treats its own locally stored metadata as authoritative filesystem truth.