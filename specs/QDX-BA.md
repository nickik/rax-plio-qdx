# QDX-BA v0.3 — Block Acceleration Profile

**Status:** Draft

## 1. Purpose

QDX-BA is the optional block-acceleration extension to **QDX-B**.

QDX-B defines the block-storage abstraction and remains sufficient for correctness. QDX-BA exists only to let a more capable controller perform combinations of ordinary block operations with less host DMA, less queue traffic, or less host scheduling overhead.

The governing rule is:

> **Every QDX-BA operation must have a correct software fallback using ordinary QDX-B operations.**

A filesystem, database, volume manager, or virtual-machine monitor MUST NOT require QDX-BA for correctness.

QDX-BA does not own filesystem or volume policy such as RAID levels, mirrors, pools, snapshots, checksum metadata, deduplication, compression, parity layout, repair policy, copy-on-write allocation, or transaction commits.

QDX-BA v0.3 may use the **QDX-B integrity descriptor** supplied by higher software. This lets the controller accelerate checksum calculation/comparison without making the controller the owner of checksum truth.

---

## 2. Conformance

A controller claiming QDX-BA v0.3 MUST also conform to QDX-B v0.5 and MUST implement:

- `READ_OR`,
- `WRITE_OR`,
- `MULTI_WRITE`,
- `COPY`,
- the parameter-block and per-target-result formats below.

QDX-BA supports at most **16 target entries per command**.

A QDX-B controller advertises QDX-BA support through `QDX_B_CAP_QDX_BA`.

A controller may support QDX-BA without QDX-B integrity. Integrity-aware QDX-BA commands require both capabilities.

---

## 3. Opcodes

| Opcode | Name | Meaning |
|---:|---|---|
| `0x20` | `READ_OR` | read the first host-approved source extent that satisfies the requested media/integrity conditions |
| `0x21` | `WRITE_OR` | write to the first host-approved destination that succeeds |
| `0x22` | `MULTI_WRITE` | write the same host buffer to several destinations |
| `0x23` | `COPY` | copy blocks between namespaces behind the same controller |

Other `0x20..0x2F` opcodes are reserved.

---

## 4. Use of the base QDX-B command descriptor

QDX-BA uses the normal 32-byte QDX-B command descriptor.

For all QDX-BA commands:

- `tag` has its normal QDX meaning;
- `block_count` is the common transfer length in logical blocks;
- `command_arg` is a device-visible PLIO DMA capability address pointing to a QDX-BA parameter block;
- `namespace_id` and `lba` in the base descriptor MUST be zero;
- base QDX-B `QDX_B_F_INTEGRITY` MUST be zero because QDX-BA uses `integrity_addr` inside its own parameter block;
- reserved fields MUST be zero.

For `READ_OR`, `WRITE_OR`, and `MULTI_WRITE`, the normal QDX-B data-buffer rules are reused.

For `COPY`, host data-buffer fields MUST be zero because data moves inside the controller.

The host MUST keep all input parameter blocks, integrity descriptors, SG lists, and write buffers stable until command completion.

---

## 5. QDX-BA parameter block

`command_arg` points to a little-endian parameter block.

The v0.3 header is **24 bytes**:

| Offset | Size | Field | Meaning |
|---:|---:|---|---|
| `0x00` | 2 | `version` | MUST be `2` for QDX-BA v0.3 |
| `0x02` | 2 | `target_count` | number of target entries, 1..16 |
| `0x04` | 4 | `flags` | QDX-BA flags |
| `0x08` | 4 | `results_addr` | device-visible address of result array |
| `0x0C` | 4 | `integrity_addr` | device-readable QDX-B integrity descriptor, or zero |
| `0x10` | 4 | reserved | zero |
| `0x14` | 4 | reserved | zero |

Flags:

| Bit | Name | Meaning |
|---:|---|---|
| 0 | `QDX_BA_F_INTEGRITY` | use the QDX-B integrity descriptor at `integrity_addr` |
| 1..31 | reserved | zero |

If `QDX_BA_F_INTEGRITY` is clear, `integrity_addr` MUST be zero.

If set, the controller MUST advertise `QDX_B_CAP_INTEGRITY`, and the referenced descriptor uses the exact format and algorithm definitions in QDX-B v0.5.

The target array immediately follows the header at offset `0x18`.

The complete header plus target array MUST lie inside valid device-readable PLIO DMA mappings. `results_addr` MUST identify a writable result array large enough for `target_count` result entries.

The controller MUST make result arrays and any integrity result host-visible before publishing the QDX completion that refers to them.

---

## 6. Target entry

Each target entry is 8 bytes:

| Offset | Size | Field | Meaning |
|---:|---:|---|---|
| `0x00` | 2 | `namespace_id` | QDX-B namespace |
| `0x02` | 2 | `flags` | MUST be zero in v0.3 |
| `0x04` | 4 | `lba` | starting logical block address |

Every target in one command uses the base descriptor's common `block_count`.

All target namespaces in one command MUST have the same logical block size.

For `COPY`, target 0 is the source and target 1 is the destination.

---

## 7. Per-target result entry

Each result entry is 8 bytes:

| Offset | Size | Field | Meaning |
|---:|---:|---|---|
| `0x00` | 2 | `status` | QDX-B status code or `NOT_ATTEMPTED` |
| `0x02` | 2 | `flags` | result flags |
| `0x04` | 4 | `blocks_done` | blocks transferred for this target |

Result flags:

| Bit | Name | Meaning |
|---:|---|---|
| 0 | `ATTEMPTED` | controller attempted this target |
| 1 | `SELECTED` | this target satisfied READ_OR or WRITE_OR |
| 2 | `INTEGRITY_CHECKED` | target data was checksum-checked |
| 3 | `INTEGRITY_MATCH` | supplied expected checksum matched |
| 4..15 | reserved | zero |

`0xFFFF NOT_ATTEMPTED` is used only inside QDX-BA result arrays.

A failed write or copy destination MAY have been partially modified unless a command-specific rule below explicitly requires pre-write validation.

---

## 8. QDX-BA completion summaries

QDX-BA reuses the normal QDX-B 16-byte completion descriptor.

| Status | Name | Meaning |
|---:|---|---|
| `0x0100` | `PARTIAL_SUCCESS` | some but not all requested target operations succeeded |
| `0x0101` | `NO_TARGET_SUCCEEDED` | no candidate target satisfied the command |

Normal QDX-B errors retain their meaning, including `INTEGRITY_MISMATCH` where a command-level integrity precondition fails.

`info`:

- READ_OR: selected target index, or `0xFFFF_FFFF`;
- WRITE_OR: selected target index, or `0xFFFF_FFFF`;
- MULTI_WRITE: low 16 bits successful-target count, high 16 bits failed-target count;
- COPY: zero.

---

## 9. READ_OR

### 9.1 Base semantics

`READ_OR` gives the controller an **ordered list of host-approved source extents** representing equivalent data from the higher software layer's point of view.

Without integrity checking, the controller attempts candidates in order until one complete media read succeeds.

Software fallback:

```text
for source in candidates:
    status = READ(source, host_buffer)
    if status == SUCCESS:
        return source
return failure
```

### 9.2 Integrity-aware READ_OR

If `QDX_BA_F_INTEGRITY` is set and the integrity descriptor requests `VERIFY_EXPECTED`, a candidate succeeds only if:

1. the media read succeeds, **and**
2. the checksum of the complete requested payload matches the host-supplied expected checksum.

A media-successful candidate whose checksum mismatches gets per-target status `INTEGRITY_MISMATCH`, `ATTEMPTED | INTEGRITY_CHECKED`, and the controller proceeds to the next candidate.

Conceptually:

```text
for source in candidates:
    bytes = READ(source)
    if media failure:
        continue
    if checksum(bytes) != expected:
        record INTEGRITY_MISMATCH
        continue
    copy complete bytes to host buffer
    return source
return failure
```

This is still an acceleration of host policy. The host supplied both the candidate list and the expected checksum.

### 9.3 CALCULATE without VERIFY

If the integrity descriptor requests `RETURN_CALCULATED` but not `VERIFY_EXPECTED`, READ_OR selects the first media-successful candidate and returns that payload's calculated checksum through the normal QDX-B integrity result descriptor.

### 9.4 Buffer contents

A failed candidate may partially overwrite an implementation's staging or host destination while the failure is discovered. If a later candidate succeeds, the controller MUST ensure the **entire** host destination range contains the selected successful candidate before reporting success.

If no candidate succeeds, final host-buffer contents are undefined and MUST NOT be consumed as valid data.

---

## 10. WRITE_OR

`WRITE_OR` gives the controller an ordered list of host-approved alternative destinations and stops after the first complete successful write.

Without integrity:

```text
for destination in candidates:
    status = WRITE(host_buffer, destination)
    if status == SUCCESS:
        return destination
return failure
```

If `QDX_BA_F_INTEGRITY` is set, integrity applies to the **single source host payload**, not separately to each destination.

If `VERIFY_EXPECTED` is requested, the controller MUST validate the complete payload before modifying any candidate destination, using the same pre-write rule as QDX-B WRITE. On mismatch the command completes `INTEGRITY_MISMATCH` and no target may have been modified.

If verification succeeds, WRITE_OR proceeds normally using the exact verified bytes.

Higher-level software treats only the selected successful target as authoritative. QDX-BA never allocates an extent outside the host-provided list.

---

## 11. MULTI_WRITE

`MULTI_WRITE` writes the same host buffer to every target.

A capable controller may fetch/stage chunks once and fan them out to several destinations.

If integrity is requested, it applies once to the common source payload:

- `VERIFY_EXPECTED` MUST complete before the first target is modified;
- `RETURN_CALCULATED` returns the checksum of the common payload.

Completion:

```text
all succeed       -> SUCCESS
some succeed      -> PARTIAL_SUCCESS
none succeed      -> NO_TARGET_SUCCEEDED
```

Per-target results are authoritative.

`MULTI_WRITE` is not atomic across destinations. Power failure, media error, reset, or controller failure may leave some destinations updated and others unchanged or partially written.

---

## 12. COPY

`COPY` performs a byte-for-byte block copy between two namespaces behind the same controller without staging the payload through host memory.

The parameter list MUST contain exactly two entries:

```text
entry 0 = source
entry 1 = destination
```

Restrictions:

- source and destination namespaces use the same logical block size;
- block_count is nonzero;
- overlapping source/destination ranges in one namespace are not allowed;
- COPY cannot cross controllers.

### 12.1 Integrity-aware COPY

If integrity requests `VERIFY_EXPECTED`, the controller MUST read and checksum the complete source payload **before modifying the destination**. A mismatch completes `INTEGRITY_MISMATCH` and the destination remains unmodified by this command.

If `RETURN_CALCULATED` is requested, the controller returns the checksum of the source payload.

This makes controller-local relocation useful for verified repair/resilver while the host still owns the expected checksum and destination choice.

### 12.2 Durability

A successful COPY has ordinary QDX-B WRITE durability semantics for the destination. If durable completion is required, software uses FLUSH after COPY.

---

## 13. Validation and errors

Before media modification begins, a controller MUST validate:

- parameter-block version and size;
- target_count limits;
- parameter-block DMA authority;
- result-array DMA authority;
- integrity-descriptor/result DMA authority where present;
- host data-buffer/SG format where applicable;
- target namespace existence where practical;
- compatible logical block size;
- command-specific entry-count rules.

Where `VERIFY_EXPECTED` is requested for a write-like command, checksum verification is also a pre-modification condition.

A fatal DMA fault that prevents required input or output terminates the command with `DMA_FAULT` if a CQ completion can still be written safely.

---

## 14. Ordering and durability

QDX-BA does not create a second ordering model.

Normal QDX-B rules remain in force:

- command completions may be out of submission order unless a dependency requires otherwise;
- ordinary write-like completion reports the namespace's normal write-completion level;
- FLUSH is the explicit durability boundary for previously completed writes;
- QDX-BA does not define an atomic FLUSH_ALL, transaction group, commit record, or storage quorum.

For multi-namespace software transactions, the host flushes each namespace whose durability matters.

---

## 15. PLIO capability-DMA interaction

The QDX-BA parameter block, target/result arrays, integrity descriptor/result, host data buffers, and SG lists are ordinary QDX DMA objects and use protected PLIO `(channel, generation, offset)` handles.

The controller never receives unrestricted host physical addresses.

The host may revoke mappings after command completion and device quiescence.

---

## 16. Worked examples

### 16.1 Mirrored read with media-error fallback

```text
candidate 0: namespace 1, LBA 10000
candidate 1: namespace 2, LBA 10000
block_count: 8
```

If candidate 0 has a media error and candidate 1 succeeds:

```text
result[0] = MEDIA_ERROR, ATTEMPTED
result[1] = SUCCESS, ATTEMPTED | SELECTED
completion.status = SUCCESS
completion.info   = 1
```

### 16.2 Checksummed mirror with silent corruption

Software supplies expected checksum `X` with READ_OR.

```text
candidate 0: media read succeeds, checksum != X
candidate 1: media read succeeds, checksum == X
```

Result:

```text
result[0] = INTEGRITY_MISMATCH, ATTEMPTED | INTEGRITY_CHECKED
result[1] = SUCCESS, ATTEMPTED | SELECTED | INTEGRITY_CHECKED | INTEGRITY_MATCH
completion.status = SUCCESS
completion.info   = 1
```

QDX has not decided that the candidates are mirrors; software explicitly provided equivalent candidates and checksum truth.

### 16.3 Verified mirrored write

Software wants the same copy-on-write block on two targets and already knows checksum `X`.

It submits MULTI_WRITE with `VERIFY_EXPECTED`.

The controller verifies the host buffer against `X` before either target is modified. It then performs both writes and reports exact per-target results.

### 16.4 Host-controlled placement fallback

WRITE_OR tries only extents supplied by the host. A successful second candidate returns selected index 1; the controller never chooses storage on its own.

### 16.5 Verified controller-local relocation

```text
COPY
source      = namespace 2, LBA 120000
destination = namespace 7, LBA 40000
block_count = 128
expected    = X
```

The controller reads the source, verifies `X`, and only then writes the destination. If verification fails, destination modification does not begin.

---

## 17. Enabling a ZFS-like storage architecture

QDX-B/QDX-BA support a copy-on-write, checksummed, pooled storage system without implementing that filesystem inside the controller.

| Requirement | Owner | QDX support |
|---|---|---|
| copy-on-write allocation | filesystem/volume layer | WRITE, WRITE_OR |
| checksum metadata / expected value | filesystem | QDX integrity calculates/compares host-supplied checksum |
| mirrored copies | filesystem topology | MULTI_WRITE, integrity-aware READ_OR |
| RAID/parity layout | filesystem/volume layer | explicit READ/WRITE of chosen data/parity extents |
| transaction commit | filesystem | WRITE/WRITE_DURABLE/FLUSH sequencing |
| snapshots | filesystem metadata | no controller snapshot primitive |
| scrub | filesystem | READ/READ_OR + integrity verification |
| self-healing | filesystem decides | verified READ followed by WRITE/MULTI_WRITE/COPY |
| resilver/rebuild | filesystem/storage service | verified READ+WRITE or integrity-aware COPY |
| degraded mode | filesystem policy | exact per-target result reporting |

The key point is:

> **QDX may accelerate arithmetic and block movement; higher software owns meaning, checksum truth, placement, and recovery policy.**

---

## 18. Non-goals

QDX-BA MUST NOT be interpreted as defining:

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
CHECKSUM METADATA FORMAT
PARITY POLICY
REPAIR POLICY
TRANSACTION GROUP
ATOMIC MULTI-DISK COMMIT
```

QDX-BA should remain implementable by an advanced late-1970s controller using buffering, ULA/MSI sequencing logic, and a modest control processor rather than requiring a storage operating system on the card.