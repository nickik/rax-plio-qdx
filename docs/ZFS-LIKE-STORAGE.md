# Building a ZFS-like storage stack on QDX

**Status:** Non-normative design note

This note explains how QDX-B and QDX-BA can support a future copy-on-write, checksummed, pooled storage system comparable in architectural goals to modern ZFS while keeping filesystem policy out of PLIO and QDX.

The comparison is conceptual. A 1970s/1980s DEC implementation does not depend on historical ZFS code or terminology.

---

## 1. Architectural split

```text
applications
    |
Cosmic filesystem / volume layer
    |   owns:
    |   - allocation
    |   - copy-on-write trees
    |   - checksum metadata / expected values
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
    |   - WRITE / WRITE_DURABLE / FLUSH
    |   - optional checksum calculation/comparison
    |   - READ_OR / WRITE_OR / MULTI_WRITE / COPY
    |
PLIO capability DMA + byte-lane parity
    |
storage controllers and media
```

The controller knows blocks, namespaces, DMA buffers, supplied checksums and completion status. It does not know files, directories, pools, snapshots, replica policy, checksum-tree structure or filesystem transaction structure.

---

## 2. Integrity ownership versus acceleration

The crucial rule is:

> **Cosmic owns checksum truth; QDX may accelerate checksum arithmetic.**

A checksum-protected block is referenced by higher metadata containing or implying an expected checksum.

Cosmic may submit that expected value with a QDX integrity descriptor. The controller calculates the checksum while bytes are already moving and reports match/mismatch.

The controller must not maintain a hidden authoritative checksum table.

This means an integrity-capable controller can detect silent corruption without becoming the layer that decides what the bytes are supposed to mean.

---

## 3. End-to-end integrity chain

Different mechanisms cover different failure domains:

```text
disk ECC / media recovery
       |
LDL CRC16                 link/frame corruption
       |
QDX integrity engine      payload vs host-supplied expected checksum
       |
PLIO PAR[3:0]             PLIO address/data transfer corruption
       |
host RAM parity/ECC       host-platform responsibility
       |
Cosmic checksum metadata  authoritative identity/correctness policy
```

QDX verification says the controller observed bytes matching the expected checksum. PLIO parity protects the controller-to-host transfer on PLIO, but host RAM/internal-memory protection must be supplied by the host platform if Cosmic intends to trust the hardware result without recomputing it after DMA.

A system may always recompute in software for additional assurance.

---

## 4. Copy-on-write

A simplified update:

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
                    establish durability
                              |
                    write new root record
                              |
                    establish root durability
                              |
                     new tree committed
```

QDX does not need SNAPSHOT or TRANSACTION commands. The host controls reachability; partially written new blocks remain unreferenced until the new root commits.

---

## 5. Durability tools

QDX-B deliberately provides three distinct primitives:

```text
WRITE           ordinary write; may complete into volatile device/controller cache
WRITE_DURABLE   this command's payload is durable before completion
FLUSH           all previously completed writes in the namespace become durable
```

A conservative transaction sequence is:

```text
1. issue new data WRITE commands
2. wait for completions
3. issue metadata WRITE commands
4. wait for completions
5. FLUSH affected namespaces
6. WRITE_DURABLE new root/commit record
```

or, where batching/root placement requires it:

```text
6. WRITE root
7. wait
8. FLUSH root namespace
```

`WRITE_DURABLE` is not an implicit flush of unrelated writes.

---

## 6. Read verification

Without controller acceleration:

```text
QDX READ
   |
bytes in host memory
   |
Cosmic computes checksum
   |
accept / reject
```

With `QDX_B_CAP_INTEGRITY`:

```text
Cosmic obtains expected checksum from metadata
   |
READ + VERIFY_EXPECTED
   |
controller computes CRC64_QDX1 (or future advertised algorithm)
   |
MATCH / INTEGRITY_MISMATCH
```

Cosmic still owns expected checksum selection and the response to a mismatch.

`RETURN_CALCULATED` lets the controller return a checksum without comparing it.

---

## 7. Write verification and calculation

Two useful cases:

### Verify a known buffer before media modification

```text
Cosmic already knows checksum X
   |
WRITE + VERIFY_EXPECTED(X)
   |
controller stages/reads complete payload
   |
checksum matches?
   | yes                 | no
write exact bytes        no media modification
                         INTEGRITY_MISMATCH
```

This catches corruption between checksum creation and the controller input.

### Calculate checksum while writing

```text
WRITE + RETURN_CALCULATED
   |
controller calculates checksum of source payload
   |
returns checksum
   |
Cosmic stores it in parent metadata
```

This is a CPU offload, not a change in metadata ownership.

---

## 8. Mirrors and integrity-aware READ_OR

Suppose Cosmic knows two replicas:

```text
copy A -> namespace 1 / LBA 10000
copy B -> namespace 2 / LBA 50000
expected checksum = X
```

With integrity-aware QDX-BA:

```text
READ_OR {A, B}, expected = X
```

The controller:

1. reads A;
2. if A has media failure, tries B;
3. if A returns bytes but checksum != X, records `INTEGRITY_MISMATCH` and tries B;
4. selects the first candidate whose media read succeeds and checksum matches X.

The controller has not discovered the mirror relationship. Cosmic supplied both candidate locations and checksum truth.

---

## 9. Mirrored writes and MULTI_WRITE

Cosmic chooses explicit targets:

```text
A = namespace 1 / LBA 22000
B = namespace 2 / LBA 67000
```

It can submit:

```text
MULTI_WRITE buffer X -> {A, B}
```

If it already knows checksum X, it can request `VERIFY_EXPECTED` once before any target modification.

The result array may report:

```text
A = SUCCESS
B = MEDIA_ERROR
```

Cosmic decides whether to continue degraded, allocate another target or abort the transaction.

MULTI_WRITE remains non-atomic; COW metadata supplies atomic meaning.

---

## 10. WRITE_OR

WRITE_OR is host-controlled placement fallback, not allocation.

Cosmic supplies candidate extents. With integrity enabled, the common host source payload is verified before the first candidate is modified.

The controller never writes outside the explicit candidate set.

---

## 11. Integrity-aware COPY

COPY moves blocks between namespaces behind one controller without host-memory payload traffic.

For repair/rebuild where source integrity matters:

```text
COPY source -> destination
expected checksum = X
VERIFY_EXPECTED
```

The controller must read and verify the complete source before modifying the destination.

A mismatch aborts the copy with destination unchanged by that command.

This makes controller-local relocation useful for resilver while preserving Cosmic's authority.

---

## 12. RAID/parity

Parity geometry remains software policy.

Cosmic decides:

- stripe width;
- parity rotation;
- participating namespaces;
- reconstruction mathematics;
- degraded-write policy.

QDX sees explicit block operations. A CPU or generic accelerator may compute parity; QDX does not need a RAID opcode.

---

## 13. Scrub and self-healing

A scrub walks allocated data using metadata-supplied expected checksums.

With integrity-aware READ_OR:

```text
READ_OR replica set + expected checksum
       |
first verified copy returned
       |
Cosmic examines per-target failures/mismatches
       |
repair bad targets using WRITE/MULTI_WRITE/COPY
```

Cosmic still decides which targets are replicas and whether/how to repair them.

---

## 14. Resilver / replacement rebuild

General safe path:

```text
verified READ source
WRITE replacement
```

When source/destination share a controller:

```text
integrity-aware COPY
```

can avoid host-memory payload traffic while still validating against an expected checksum supplied by Cosmic.

---

## 15. Snapshots, clones, dedup and compression

These remain above QDX.

- snapshots retain old COW roots;
- clones share immutable blocks until modification;
- dedup owns reference/identity policy in the filesystem;
- compression decides what representation is stored and checksummed.

QDX COPY is a physical byte copy, not a clone primitive.

---

## 16. Failure model

| Failure | Mechanism |
|---|---|
| explicit media read/write failure | QDX status + alternate target |
| media silently returns wrong bytes | Cosmic checksum + optional QDX verification |
| corrected/retried/marginal media | LDL health telemetry -> QDX health/service log |
| LDL cable corruption | LDL CRC16 |
| PLIO transfer bit error | PLIO byte-lane parity |
| host RAM error | host parity/ECC policy |
| incomplete redundant write | per-target QDX-BA results + COW policy |
| host crash during update | COW roots + durability sequence |
| controller volatile buffering | WRITE_DURABLE / FLUSH |
| stale/rogue DMA | PLIO capability channels + generations |
| lost interrupt edge | PLIO Notification pending/coalescing |

No single layer pretends to solve every failure mode.

---

## 17. Example checksummed mirrored COW update

```text
new_data = application update
checksum = X
A = namespace 1 / LBA 120000
B = namespace 3 / LBA 45000
```

Possible sequence:

1. `MULTI_WRITE` new_data -> {A,B} with `VERIFY_EXPECTED(X)`.
2. Inspect exact per-target results.
3. Write new indirect metadata containing A, B and X.
4. FLUSH namespaces containing the new data/metadata.
5. WRITE_DURABLE the new root/commit record.
6. Only then make the new tree authoritative.

At no point does QDX need to understand files, mirrors, transaction groups or where checksum X came from.

---

## 18. Why this is useful for DEC

The same Cosmic storage system can run on:

- a minimal QDX-B controller with software checksums;
- a 1979 ULA QDX controller with QCRC-1;
- a later integrated NMOS controller with checksum and QDX-BA acceleration.

The optimization can move between CPU and controller without changing on-disk filesystem meaning.

The intended division of labor is:

> **Cosmic owns storage meaning and checksum truth. QDX accelerates checksum arithmetic and block movement. PLIO protects and constrains the transfer path.**