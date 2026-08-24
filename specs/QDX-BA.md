# QDX-BA v0.2 — Block Acceleration Profile

**Status:** Draft

## 1. Purpose

QDX-BA is the optional block-acceleration extension to **QDX-B**.

QDX-B defines the block-storage abstraction and remains sufficient for correctness. QDX-BA exists only to let a more capable controller perform combinations of ordinary block operations with less host DMA, less queue traffic, or less host scheduling overhead.

The governing rule is:

> **Every QDX-BA operation must have a correct software fallback using ordinary QDX-B READ/WRITE/FLUSH operations.**

A filesystem, database, volume manager, or virtual-machine monitor MUST NOT require QDX-BA for correctness.

QDX-BA deliberately does **not** define filesystem or volume policy such as RAID levels, mirrors, pools, snapshots, checksums, deduplication, compression, parity layout, repair policy, copy-on-write allocation, or transaction commits.

---

## 2. Conformance

A controller claiming QDX-BA v0.2 MUST also conform to QDX-B and MUST implement:

- `READ_OR`,
- `WRITE_OR`,
- `MULTI_WRITE`,
- `COPY`,
- the QDX-BA parameter-block and per-target-result formats below.

The earlier draft capability name `QUEUED_COMMANDS` is removed. QDX is already a queued asynchronous interface; a separate capability saying that commands are queued has no useful semantic meaning.

QDX-BA supports at most **16 target entries per command** in v0.2.

A QDX-B controller advertises QDX-BA support through the `QDX_B_CAP_QDX_BA` bit in its `IDENTIFY_CONTROLLER` capability word.

---

## 3. Opcodes

QDX-BA reserves the following QDX-B opcode range:

| Opcode | Name | Meaning |
|---:|---|---|
| `0x20` | `READ_OR` | read one of several host-approved source extents |
| `0x21` | `WRITE_OR` | write to the first host-approved destination that succeeds |
| `0x22` | `MULTI_WRITE` | write the same host buffer to several destinations |
| `0x23` | `COPY` | copy blocks between namespaces behind the same controller |

Other `0x20..0x2F` opcodes are reserved for future QDX-BA revisions.

---

## 4. Use of the base QDX-B command descriptor

QDX-BA uses the normal 32-byte QDX-B command descriptor.

For all QDX-BA commands:

- `tag` has its normal QDX meaning;
- `block_count` is the common transfer length in logical blocks;
- `command_arg` is a device-visible PLIO DMA capability address pointing to a QDX-BA parameter block;
- `namespace_id` and `lba` in the base descriptor MUST be zero;
- reserved fields MUST be zero.

For `READ_OR`, `WRITE_OR`, and `MULTI_WRITE`, the normal QDX-B data-buffer rules are reused:

- if `sg_count == 0`, `data_addr` identifies one contiguous host buffer;
- if `sg_count > 0`, `sg_addr` identifies the QDX-B scatter/gather list and `data_addr` is ignored.

For `COPY`:

- `sg_count` MUST be zero;
- `data_addr` MUST be zero;
- `sg_addr` MUST be zero;
- data moves inside the controller and is not staged through host memory by the QDX interface.

The host MUST keep all input parameter blocks, SG lists, and write buffers stable until the command completes.

---

## 5. QDX-BA parameter block

`command_arg` points to a little-endian parameter block.

The header is 16 bytes:

| Offset | Size | Field | Meaning |
|---:|---:|---|---|
| `0x00` | 2 | `version` | MUST be `1` for QDX-BA v0.2 |
| `0x02` | 2 | `target_count` | number of target entries, 1..16 |
| `0x04` | 4 | `flags` | MUST be zero in v0.2 |
| `0x08` | 4 | `results_addr` | device-visible DMA address of result array |
| `0x0C` | 4 | reserved | MUST be zero |

The target array immediately follows the header at offset `0x10`.

The complete header plus target array MUST lie inside one valid device-readable PLIO DMA capability mapping. The controller MAY fetch it using several bounded PLIO bursts.

`results_addr` MUST identify a device-writable result array large enough for `target_count` result entries.

The controller MUST make the result array host-visible before publishing the QDX completion that refers to it.

---

## 6. Target entry

Each target entry is 8 bytes:

| Offset | Size | Field | Meaning |
|---:|---:|---|---|
| `0x00` | 2 | `namespace_id` | QDX-B namespace |
| `0x02` | 2 | `flags` | MUST be zero in v0.2 |
| `0x04` | 4 | `lba` | starting logical block address |

Every target in one QDX-BA command uses the base descriptor's common `block_count`.

All target namespaces in one QDX-BA command MUST have the same logical block size. A controller that detects incompatible block sizes completes the command with `INVALID_FIELD` before performing media writes.

For `COPY`, target entry 0 is the source and target entry 1 is the destination.

---

## 7. Per-target result entry

Each result entry is 8 bytes and corresponds by index to one target entry:

| Offset | Size | Field | Meaning |
|---:|---:|---|---|
| `0x00` | 2 | `status` | QDX-B status code or `NOT_ATTEMPTED` |
| `0x02` | 2 | `flags` | result flags |
| `0x04` | 4 | `blocks_done` | blocks successfully transferred for this target |

Result flags:

| Bit | Name | Meaning |
|---:|---|---|
| 0 | `ATTEMPTED` | controller attempted this target |
| 1 | `SELECTED` | this target satisfied `READ_OR` or `WRITE_OR` |
| 2..15 | reserved | zero |

The special per-target status value:

```text
0xFFFF  NOT_ATTEMPTED
```

is used only inside QDX-BA result arrays. It is not a normal QDX-B command completion status.

A failed write or copy destination MAY have been partially modified. `blocks_done` reports known progress, but QDX-BA provides no rollback guarantee.

---

## 8. QDX-BA completion summaries

QDX-BA reuses the normal 16-byte QDX-B completion descriptor.

Two extension status codes are defined:

| Status | Name | Meaning |
|---:|---|---|
| `0x0100` | `PARTIAL_SUCCESS` | some but not all requested target operations succeeded |
| `0x0101` | `NO_TARGET_SUCCEEDED` | no candidate target satisfied the command |

`DMA_FAULT`, `INVALID_FIELD`, `QUEUE_ERROR`, and other QDX-B errors retain their normal meaning for command-level faults.

The `info` field is interpreted as follows:

- `READ_OR`: selected target index, or `0xFFFF_FFFF` if none;
- `WRITE_OR`: selected target index, or `0xFFFF_FFFF` if none;
- `MULTI_WRITE`: low 16 bits = successful target count, high 16 bits = failed target count;
- `COPY`: zero in v0.2.

For `MULTI_WRITE`, the per-target result array is authoritative when the completion status is `PARTIAL_SUCCESS`.

---

## 9. READ_OR

### 9.1 Semantics

`READ_OR` gives the controller an **ordered list of host-approved source extents** representing equivalent data from the higher software layer's point of view.

The controller attempts candidates in list order until one complete read succeeds.

Conceptually the software fallback is:

```text
for source in candidates:
    status = READ(source, host_buffer)
    if status == SUCCESS:
        return source
return failure
```

QDX-BA performs the same operation with one submitted command.

### 9.2 Success

On success:

- one target result has `ATTEMPTED | SELECTED` and `SUCCESS`;
- earlier failed candidates have `ATTEMPTED` with their QDX-B failure status;
- later candidates are `NOT_ATTEMPTED`;
- the host destination buffer contains the complete selected extent;
- CQ `status = SUCCESS`;
- CQ `blocks_done = block_count`;
- CQ `info = selected target index`.

### 9.3 Failure and buffer contents

A failed candidate may have partially overwritten the host destination buffer before its media error became known.

If a later candidate succeeds, the controller MUST overwrite the complete requested host-buffer range with the successful candidate before reporting success.

If no candidate succeeds, final host-buffer contents are undefined and MUST NOT be consumed as valid data.

### 9.4 What READ_OR does not do

`READ_OR` recognizes device/media success and failure. It does **not** understand a filesystem checksum.

If a candidate returns `SUCCESS` but higher-level checksum verification fails, software must reject that copy and issue another read—possibly another `READ_OR` excluding the bad candidate.

This distinction is important for checksummed filesystems.

---

## 10. WRITE_OR

### 10.1 Semantics

`WRITE_OR` gives the controller an ordered list of **host-approved alternative destinations**. The controller attempts destinations in list order and stops after the first complete successful write.

Software fallback:

```text
for destination in candidates:
    status = WRITE(host_buffer, destination)
    if status == SUCCESS:
        return destination
return failure
```

The controller is not allocating storage on its own. Every candidate namespace/LBA was supplied by software.

### 10.2 Success

On success:

- one result entry is `ATTEMPTED | SELECTED` with `SUCCESS`;
- earlier candidates contain their failure results;
- later candidates are `NOT_ATTEMPTED`;
- CQ `status = SUCCESS`;
- CQ `blocks_done = block_count`;
- CQ `info = selected target index`.

### 10.3 Partial media modification

A failed candidate MAY have received some blocks before failure. QDX-BA does not roll such writes back.

Higher-level software MUST treat only the selected successful target as authoritative. A copy-on-write allocator can simply avoid publishing metadata references to failed candidate extents.

`WRITE_OR` is therefore an acceleration of explicit host-controlled placement fallback, not a controller-managed spare or remapping policy.

---

## 11. MULTI_WRITE

### 11.1 Semantics

`MULTI_WRITE` writes the **same host buffer** to every target entry.

Software fallback:

```text
for destination in destinations:
    submit WRITE(host_buffer, destination)
wait for every result
```

A capable controller may reduce host-memory traffic by fetching chunks of the source buffer once and reusing them for several destination writes.

The standard does not require a particular staging-buffer size or require that host memory be read exactly once. Those are implementation/performance choices.

### 11.2 Completion

The controller SHOULD attempt every valid target unless a command-level failure such as loss of the input DMA mapping prevents continued execution.

If every target succeeds:

```text
CQ status = SUCCESS
CQ blocks_done = block_count
```

If at least one but not every target succeeds:

```text
CQ status = PARTIAL_SUCCESS
CQ blocks_done = 0
```

If no target succeeds:

```text
CQ status = NO_TARGET_SUCCEEDED
CQ blocks_done = 0
```

CQ `info` reports successful and failed target counts; the result array identifies exactly which destinations succeeded.

### 11.3 No atomic multi-target write

`MULTI_WRITE` is **not atomic across targets**.

A power failure, media error, reset, or controller failure may leave some destinations updated and others unchanged or partially written.

This is intentional. Crash consistency, redundancy quorum, and commit policy belong to the higher software layer.

For a copy-on-write filesystem, new blocks remain unreachable until filesystem metadata commits them, so partial `MULTI_WRITE` execution does not require the controller to implement a distributed storage transaction.

---

## 12. COPY

### 12.1 Semantics

`COPY` performs a physical byte-for-byte block copy between two namespaces behind the same QDX-BA controller without transferring the payload through host memory.

The parameter list MUST contain exactly two entries:

```text
entry 0 = source
entry 1 = destination
```

Software fallback:

```text
READ source -> host buffer
WRITE host buffer -> destination
```

### 12.2 Restrictions

- source and destination namespaces MUST use the same logical block size;
- `block_count` MUST be nonzero;
- if source and destination are the same namespace, the source and destination ranges MUST NOT overlap;
- COPY cannot cross two different QDX controllers;
- COPY does not imply cloning, reference counting, deduplication, snapshotting, or shared physical blocks.

### 12.3 Data integrity

COPY preserves the bytes returned by the source media and writes them to the destination.

It does not validate higher-level checksums. If silent corruption of the source is a concern, a checksummed filesystem should read and verify the source before using COPY for repair, or perform the repair through a verified host buffer.

### 12.4 Durability

A successful COPY completion has the same destination write-completion semantics as a normal QDX-B WRITE. If the namespace has volatile write buffering, the host still uses `FLUSH` to establish the required durability boundary.

---

## 13. Validation and errors

Before media modification begins, a controller MUST validate:

- QDX-BA parameter-block version and size;
- `target_count` limits;
- parameter-block DMA authority;
- result-array DMA authority;
- host data-buffer/SG format where applicable;
- target namespace existence where practical;
- compatible logical block size;
- command-specific entry-count rules.

Errors discovered only while media I/O is already in progress are reported in per-target results and may leave partial target modification.

A fatal DMA fault that prevents the controller from reading required command/input data or writing required results terminates the command with `DMA_FAULT` if a CQ completion can still be written safely.

---

## 14. Ordering and durability

QDX-BA does not create a second ordering model.

The normal QDX-B rules remain in force:

- command completions may be out of submission order unless a dependency requires otherwise;
- a successful WRITE-like completion reports the namespace's advertised write-completion level;
- `FLUSH` is the explicit durability boundary for previously completed writes when volatile buffering exists.

For multi-namespace software transactions, the host issues FLUSH to every affected namespace whose durability matters.

QDX-BA does not define an atomic `FLUSH_ALL`, transaction group, commit record, or storage quorum.

---

## 15. PLIO capability-DMA interaction

The QDX-BA parameter block, result array, host data buffers, and SG lists are ordinary QDX DMA objects and therefore use protected PLIO `(channel, generation, offset)` handles.

The controller never receives unrestricted host physical addresses.

A typical advanced write therefore uses distinct bounded capabilities for:

```text
SQ / CQ memory
QDX-BA parameter block
QDX-BA result array
payload buffer or SG list
```

The host may revoke those mappings after the command has completed and all device use has quiesced.

QDX-BA does not weaken PLIO's capability checks simply because one command references several media destinations.

---

## 16. Worked examples

### 16.1 Mirrored read with media-error fallback

The filesystem knows that two extents contain equivalent data:

```text
candidate 0: namespace 1, LBA 10000
candidate 1: namespace 2, LBA 10000
block_count: 8
```

It submits one `READ_OR`.

Suppose namespace 1 reports a media error and namespace 2 succeeds:

```text
result[0] = MEDIA_ERROR, ATTEMPTED
result[1] = SUCCESS, ATTEMPTED | SELECTED
completion.status = SUCCESS
completion.info   = 1
```

The host receives one valid 8-block buffer from namespace 2.

A base QDX-B implementation performs the same logic as two ordinary READs.

### 16.2 Checksummed mirror with silent corruption

Suppose candidate 0 returns device-level `SUCCESS`, so `READ_OR` selects it, but the filesystem checksum does not match.

The filesystem does **not** ask QDX-BA to decide whether the bytes are correct. It submits a second read using candidate 1, verifies the checksum itself, and then repairs candidate 0 if appropriate.

This preserves the architectural split:

```text
QDX-BA     -> media transport/fallback
filesystem -> end-to-end data correctness
```

### 16.3 Mirrored write

The filesystem wants the same new copy-on-write block on two devices:

```text
target 0: namespace 1, LBA 25000
target 1: namespace 2, LBA 48000
```

It submits `MULTI_WRITE` with one host buffer.

If both writes succeed, the filesystem may later commit metadata referencing both copies.

If only target 0 succeeds:

```text
completion.status = PARTIAL_SUCCESS
result[0] = SUCCESS
result[1] = MEDIA_ERROR
```

The filesystem decides whether one replica is sufficient to continue in degraded mode. QDX-BA does not make that policy decision.

### 16.4 Host-controlled placement fallback

A copy-on-write allocator has already chosen three acceptable free extents:

```text
0: namespace 4, LBA 7000
1: namespace 4, LBA 9000
2: namespace 5, LBA 3000
```

`WRITE_OR` tries them in that order. If the first extent cannot be written and the second succeeds, the completion returns selected index 1. The filesystem records only that chosen extent in its metadata.

The controller never chooses storage outside the host-provided candidate list.

### 16.5 Controller-local relocation

A background storage service wants to move 128 blocks from an old disk to a replacement disk attached to the same controller:

```text
COPY
source      = namespace 2, LBA 120000
destination = namespace 7, LBA 40000
block_count = 128
```

The payload does not consume host-memory bandwidth.

If the storage stack requires end-to-end checksum validation, it verifies the data separately rather than assuming COPY implies checksum correctness.

---

## 17. Enabling a ZFS-like storage architecture

QDX-B/QDX-BA are intentionally designed to support a future **copy-on-write, checksummed, pooled storage system** without implementing that filesystem inside the controller.

The mapping is:

| ZFS-like requirement | Where it belongs | QDX support |
|---|---|---|
| copy-on-write allocation | filesystem/volume layer | ordinary WRITE, WRITE_OR as optional placement fallback |
| end-to-end checksum | filesystem/CPU/DSP | QDX transports bytes; no filesystem checksum policy |
| mirrored copies | filesystem topology | MULTI_WRITE, READ_OR |
| RAID/parity layout | filesystem/volume layer | ordinary READ/WRITE of explicitly chosen data/parity extents |
| transaction-group commit | filesystem | WRITE + FLUSH + commit/root WRITE + FLUSH |
| snapshots | filesystem metadata | no controller snapshot primitive required |
| scrub | filesystem | READ/READ_OR + checksum verification |
| self-healing | filesystem decides | verified READ followed by WRITE/MULTI_WRITE repair |
| resilver/rebuild | filesystem/storage service | READ + WRITE, or COPY when controller-local and already trusted |
| device failure/degraded mode | filesystem policy | per-target result reporting exposes exact failures |

The key point is that QDX-BA accelerates **data movement**, while the filesystem owns **meaning and correctness**.

A more detailed non-normative design note is provided in `docs/ZFS-LIKE-STORAGE.md`.

---

## 18. Non-goals

QDX-BA v0.2 MUST NOT be interpreted as defining any of the following:

```text
MIRROR
RAID
RAID-Z
POOL
VDEV
SNAPSHOT
CLONE
DEDUP
COMPRESSION
FILESYSTEM CHECKSUM
PARITY POLICY
REPAIR POLICY
TRANSACTION GROUP
ATOMIC MULTI-DISK COMMIT
```

Those are higher-level software concepts.

QDX-BA should remain small enough that an advanced late-1970s controller can implement it with additional buffering/sequencing logic rather than requiring a general-purpose storage operating system on the card.
