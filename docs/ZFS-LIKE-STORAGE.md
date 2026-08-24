# Building a ZFS-like storage stack on QDX

**Status:** Non-normative design note

This note explains how QDX-B and QDX-BA can support a future copy-on-write, checksummed, pooled storage system comparable in architectural goals to modern ZFS, while keeping filesystem policy out of PLIO and QDX.

The comparison is conceptual. A 1970s/1980s DEC implementation would not depend on the historical ZFS codebase or terminology.

---

## 1. Architectural split

The intended stack is:

```text
applications
    |
Cosmic filesystem / volume layer
    |   owns:
    |   - allocation
    |   - copy-on-write trees
    |   - checksums
    |   - replica/parity topology
    |   - snapshots
    |   - scrub/repair policy
    |   - transaction commits
    |
QDX-B / QDX-BA
    |   provides:
    |   - asynchronous block I/O
    |   - namespaces
    |   - protected DMA
    |   - explicit FLUSH durability boundary
    |   - READ_OR
    |   - WRITE_OR
    |   - MULTI_WRITE
    |   - COPY
    |
PLIO
    |
storage controllers and media
```

The storage controller knows blocks, namespaces, DMA buffers, and completion status. It does not know files, directories, snapshots, pools, checksums, or filesystem transaction structure.

---

## 2. Why this separation matters

Putting filesystem semantics into the controller would create several problems:

- filesystem evolution would depend on controller firmware/hardware;
- third-party controllers would have to implement DEC filesystem policy;
- recovery behavior would become split across host and device;
- VirtuAll and other operating systems would inherit an unnecessary proprietary storage model;
- controller failures could hide or reinterpret data-integrity policy.

QDX instead standardizes the reusable primitive layer.

A sophisticated controller may accelerate ordinary operations, but the host can always reconstruct the same behavior with base QDX-B commands.

---

## 3. Copy-on-write

A copy-on-write filesystem never overwrites the currently committed version of important metadata in place.

A simplified update is:

```text
old committed tree
       |
       +----------------------+
                              |
                      allocate new blocks
                              |
                       write new data
                              |
                      write new metadata
                              |
                    flush durable writes
                              |
                    write new root record
                              |
                         flush root
                              |
                     new tree committed
```

QDX does not need a `SNAPSHOT`, `TRANSACTION`, or `ATOMIC_TREE_UPDATE` command.

The host controls reachability. Until the new root record is committed, partially written new blocks are merely unreferenced space that recovery can discard or reclaim.

This is why QDX-BA `MULTI_WRITE` does not need atomic all-target semantics.

---

## 4. Durability and transaction-group style commits

The essential QDX primitive is `FLUSH`.

For a transaction affecting several namespaces, a conservative commit sequence is:

```text
1. issue new data writes
2. wait for write completions
3. issue new indirect/metadata writes
4. wait for metadata completions
5. FLUSH every affected namespace
6. write new commit/root record(s)
7. wait for root write completion
8. FLUSH namespace(s) containing the root record
```

After step 8, recovery can select the latest valid root/sequence number and reconstruct the committed tree.

The exact filesystem may optimize this sequence, but QDX provides the necessary durable-write boundary without understanding the transaction itself.

A controller with no volatile write cache can complete FLUSH cheaply.

---

## 5. End-to-end checksums

The checksum belongs above QDX.

A typical block contains or is referenced by metadata containing:

```text
logical identity / location
checksum
birth or transaction generation
```

Read path:

```text
QDX READ
   |
bytes in host memory
   |
filesystem computes/verifies checksum
   |
accept or reject copy
```

The checksum may be calculated by the SIA CPU or a generic DSP/accelerator where useful. QDX-B/BA does not define a filesystem checksum algorithm.

This preserves end-to-end verification: the same checksum detects disk errors, controller errors, DMA corruption, and stale/wrong-block delivery rather than trusting the storage controller as the final authority.

---

## 6. Mirrors and READ_OR

Suppose the filesystem stores two replicas:

```text
copy A -> namespace 1 / LBA 10000
copy B -> namespace 2 / LBA 50000
```

With base QDX-B, software may do:

```text
READ A
if media failure:
    READ B
```

QDX-BA `READ_OR` turns that into one command whose ordered candidate list is supplied by the host.

Important distinction:

- if A reports a media error, QDX-BA can automatically try B;
- if A reports success but the filesystem checksum fails, the filesystem must reject A and explicitly read B.

The controller does not know whether two blocks are true replicas. The host says only, for this command, that these candidate extents may satisfy the read.

---

## 7. Mirrored writes and MULTI_WRITE

For a new mirrored block, the filesystem already knows the intended locations:

```text
copy A -> namespace 1 / LBA 22000
copy B -> namespace 2 / LBA 67000
```

Base QDX-B fallback:

```text
WRITE A from buffer X
WRITE B from buffer X
```

QDX-BA:

```text
MULTI_WRITE buffer X -> {A, B}
```

The controller may stage a chunk from host memory once and write it to both media targets.

The result array might report:

```text
A = SUCCESS
B = MEDIA_ERROR
```

The filesystem then decides whether:

- the transaction may continue degraded;
- another replica should be allocated;
- the pool should be faulted;
- repair should be scheduled.

QDX never decides how many replicas are enough.

---

## 8. Why MULTI_WRITE is deliberately non-atomic

Requiring all-or-nothing multi-disk writes would make the controller responsible for a distributed transaction protocol and persistent recovery log.

That is both expensive and the wrong layer.

With copy-on-write, the host can tolerate:

```text
new copy A written
new copy B failed
new metadata not yet committed
```

because the old committed tree remains valid.

If the filesystem decides one successful replica is insufficient, it simply does not publish the new root.

Thus COW metadata provides atomic *meaning* without requiring QDX-BA to provide atomic physical writes.

---

## 9. WRITE_OR and host-controlled allocation fallback

`WRITE_OR` is not a free-space allocator.

The filesystem first chooses several legal candidate extents:

```text
candidate 0
candidate 1
candidate 2
```

The controller attempts them in host-defined order and returns the selected successful index.

This can reduce host round trips when media or a namespace is failing, while keeping allocation policy in the filesystem.

If candidate 0 is partially modified before failing, that is harmless to COW correctness because the filesystem never commits metadata pointing to that failed destination.

---

## 10. RAID-Z-like parity

Parity layout remains a host software function.

For a stripe such as:

```text
D0 D1 D2 P
```

Cosmic decides:

- which namespaces participate;
- stripe width;
- parity rotation;
- reconstruction mathematics;
- checksum policy;
- degraded-write policy.

The CPU or generic accelerator computes parity data. QDX receives ordinary explicit writes to the already chosen data and parity extents.

For example:

```text
WRITE D0
WRITE D1
WRITE D2
WRITE P
```

or several `MULTI_WRITE` operations where identical payload replication is actually useful.

QDX-BA does not define a parity opcode because parity geometry and recovery semantics belong to the storage software.

---

## 11. Scrub and self-healing

A scrub walks allocated blocks and verifies their end-to-end checksums.

Simplified mirror scrub:

```text
READ copy A
verify checksum

if good:
    optionally inspect B

if bad:
    READ copy B
    verify checksum
    if B good:
        repair A with WRITE
```

QDX-BA helps with transport:

- `READ_OR` handles ordinary media-error fallback;
- `MULTI_WRITE` can repair several replicas from one verified buffer;
- QDX queues allow many scrub operations to remain outstanding.

The filesystem decides which copy is correct by checksum and metadata context.

---

## 12. Resilver / replacement-disk rebuild

When a disk is replaced, the filesystem enumerates blocks that belong on the replacement target.

Safe general path:

```text
READ known-good source
verify checksum
WRITE replacement
```

If several replacement copies are required:

```text
READ source
verify checksum
MULTI_WRITE verified buffer -> replacement targets
```

`COPY` can accelerate controller-local relocation where the source is already trusted and source/destination sit behind the same QDX-BA controller.

However, COPY itself performs no filesystem checksum validation. A storage implementation should not use it to bypass an end-to-end verification step where correctness depends on that verification.

---

## 13. Snapshots

Snapshots require no special QDX operation.

A snapshot is primarily a filesystem metadata decision: retain an older committed root and prevent blocks reachable from that root from being freed.

```text
root N --------> old tree
root N+1 ------> new COW tree
```

QDX sees ordinary block writes and reads.

This is preferable to a controller `SNAPSHOT` command because snapshots then remain portable across controllers and storage generations.

---

## 14. Clones and deduplication

Likewise, block sharing/reference counting and deduplication belong in the filesystem.

QDX-BA `COPY` means **physical byte copy**. It does not create a shared block reference.

A filesystem clone may initially point two logical objects at the same immutable COW block and copy only on later modification. No controller operation is needed.

---

## 15. Compression

Compression is also above QDX.

A filesystem can:

```text
logical block
   -> compress
   -> checksum stored representation or chosen logical representation
   -> QDX WRITE compressed bytes
```

The on-disk extent size and metadata interpretation belong to the filesystem.

A generic CPU/DSP accelerator may speed compression, but QDX-B should not define filesystem compression policy.

---

## 16. Failure model

The design assumes failures can occur at every layer:

- media returns explicit error;
- media silently returns wrong data;
- one replica is unavailable;
- one target of a multi-write succeeds while another fails;
- controller resets mid-command;
- host crashes after data writes but before root commit;
- stale DMA references are attempted after memory reuse.

Different mechanisms address different failures:

| Failure | Mechanism |
|---|---|
| media read/write error | QDX status + alternate target |
| silent corruption | filesystem checksum |
| incomplete redundant write | QDX-BA per-target results + COW policy |
| host crash during update | COW roots + durability sequence |
| controller buffering | QDX-B FLUSH |
| rogue/stale DMA | PLIO capability channel + generation |
| lost interrupt edge | PLIO Notification pending/coalescing |

No single layer pretends to solve every failure mode.

---

## 17. Example transaction: checksummed mirrored COW update

Assume a file block changes and the filesystem wants two replicas.

### Step 1 — build data

```text
new_data = application update
checksum = checksum(new_data)
```

### Step 2 — allocate new extents

```text
A = namespace 1 / LBA 120000
B = namespace 3 / LBA 45000
```

Old extents remain untouched.

### Step 3 — issue accelerated mirrored write

```text
MULTI_WRITE new_data -> {A, B}
```

Suppose both result entries return `SUCCESS`.

### Step 4 — write new metadata

The filesystem writes new indirect/metadata blocks containing:

```text
A
B
checksum
transaction generation
```

### Step 5 — durable boundary

```text
FLUSH namespace 1
FLUSH namespace 3
FLUSH metadata namespace(s)
```

### Step 6 — publish new root

Write a new root/commit record pointing to the new metadata, then FLUSH that root.

Only now is the new tree authoritative.

At no point did QDX need to understand mirrors, files, checksums, or transaction groups.

---

## 18. Example recovery after partial MULTI_WRITE

Suppose:

```text
A = SUCCESS
B = MEDIA_ERROR
```

The filesystem has options:

1. abandon the transaction and leave the old tree authoritative;
2. allocate C and write a replacement replica, then continue;
3. commit in degraded mode if policy permits one good copy.

The QDX-BA controller reports facts. Cosmic chooses policy.

That is the intended boundary.

---

## 19. Why this is useful for DEC

This architecture allows DEC to build increasingly intelligent storage controllers without coupling the filesystem to one generation of controller silicon.

A low-cost QDX-B controller can provide ordinary READ/WRITE/FLUSH.

A high-end QDX-BA controller can reduce:

- repeated host DMA for mirrored writes;
- host scheduling for alternate-source reads;
- host-memory traffic for controller-local relocation;
- command/doorbell traffic for multi-target operations.

Both remain compatible with the same Cosmic filesystem semantics.

The result is a strong division of labor:

> **Cosmic owns storage intelligence and data meaning. QDX-BA accelerates movement of blocks whose meaning was already decided by Cosmic.**
