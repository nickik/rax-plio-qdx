# Cosmic Storage Management

**Status:** Canonical architecture and terminology note

This document defines the public and architectural vocabulary for storage in **Cosmic OS**.

The central rule is that a **file system is one service built on storage management; it is not the storage architecture itself**. Cosmic Storage Management must support ordinary files, logical block volumes, and externally presented IBM-compatible DASD subsystems from the same underlying managed storage resources.

The terminology is deliberately suitable for a late-1970s DEC product and engineering environment. Modern terms such as *object store*, *zvol*, *storage virtualization*, and *distributed storage* may be useful as retrospective comparisons, but they are not canonical Cosmic product vocabulary.

---

## 1. Canonical hierarchy

The top-level OS facility is:

> **Cosmic Storage Management (CSM)**

CSM is the complete Cosmic facility for managing online mass storage. It includes storage-set management, extent allocation and integrity, logical volumes, file services, record services, and external DASD presentation.

```text
                             COSMIC OS
                                |
                                v
                  COSMIC STORAGE MANAGEMENT
                             (CSM)
                                |
        +-----------------------+-----------------------+
        |                       |                       |
        v                       v                       v
 Storage Set Services     Cosmic File Services     Volume Services
        |                      (CFS)                    |
        |                       |                  +----+----+
        |                       |                  |         |
        |                       v                  v         v
        |              Cosmic File Structure   Block     DASD
        |                    (CFS-1)            Volume    Volume
        |
        +--> Extent Manager
             allocation
             placement
             integrity
             duplicate copies
             recovery
             reorganization
             checkpoints
```

Above Cosmic File Services, applications may also use:

```text
Cosmic Record Services
        |
        v
Cosmic File Services
```

IBM-compatible presentation is provided by:

```text
DASD Volume
    |
DASD Services
    |
Channel Services
    |
PLIO-C370 / external channel adapter
    |
IBM host
```

---

## 2. Cosmic Storage Management (CSM)

**Cosmic Storage Management** is the umbrella operating-system facility.

CSM is responsible for the management of storage resources and the services constructed from them. It is not synonymous with a file system and it is not a disk driver.

CSM includes responsibility for:

- managed storage capacity;
- free-space accounting;
- allocation and relocation;
- copy-on-write metadata and transactional updates;
- checksums and integrity policy;
- duplicate-copy placement and recovery;
- online device addition and removal;
- background reorganization;
- checkpoints and snapshots;
- logical volume creation;
- file and directory services;
- record-oriented access services;
- DASD-compatible logical volumes;
- presentation of storage to external systems.

QDX and PLIO remain below this policy boundary. QDX provides queued device operations and acceleration; PLIO provides peripheral transport, protected DMA, and notification. Neither defines CSM allocation, file, volume, or DASD policy.

---

## 3. Storage Sets

The principal managed-capacity abstraction is the:

> **Storage Set**

A **Storage Set** is one or more physical storage devices managed by Cosmic as one storage resource.

A one-disk workstation may have:

```text
SYSTEM Storage Set
    |
  LDL 0
```

A server or Storage Director may have:

```text
PRODUCTION Storage Set
    |
    +-- LDL 0
    +-- LDL 1
    +-- LDL 2
    +-- LDL 3
    +-- ...
    +-- LDL 31
```

A Storage Set is **not a logical volume**. It is the managed physical-capacity resource from which file structures and logical volumes obtain storage.

Storage Set Services manage:

- member devices;
- available capacity;
- allocation state;
- failure domains;
- duplicate-copy policy;
- reserved recovery capacity;
- online expansion;
- device draining and removal;
- reorganization and rebalance;
- reconstruction after a device failure.

With one device, a Storage Set behaves much like conventional disk-backed storage. With two devices and two-copy policy, physical placement naturally resembles a mirror. With three or more devices, copies may be distributed across the entire set rather than bound to permanent mirror pairs.

### Dynamic addition

New self-describing LDL devices may be admitted to a Storage Set while it remains online. New allocation can immediately favor the added capacity; background reorganization may redistribute existing extents later.

### Failure and replacement

If a member fails, CSM uses surviving copies and available capacity elsewhere in the Storage Set to reconstruct lost redundancy. A replacement physical disk is treated as a new device identity, not as an implicit continuation of the failed medium.

### Controlled removal

A healthy member may be **drained**: new allocation stops, required data copies are established elsewhere, and the device becomes safe to remove once no live allocation remains.

---

## 4. Extent Manager

The internal allocation mechanism is the:

> **Extent Manager**

The Extent Manager is an implementation component of Storage Set Services, not a primary marketing name.

It deals in logical extents and physical placements. It need not understand whether an extent belongs to a file, a block volume, or an IBM CKD record.

A conceptual mapping is:

```text
logical extent 9811
    owner       = logical storage object
    offset      = ...
    length      = ...
    generation  = ...
    checksum    = ...

physical copies:
    LDL 07 / extent ...
    LDL 18 / extent ...
```

The higher layer supplies meaning. For example:

```text
Cosmic File Services:
    extent 9811 -> bytes of CUSTOMER.DAT

DASD Services:
    extent 9811 -> cylinder 214 / head 7 / record 3
```

The Extent Manager owns or coordinates:

- logical-to-physical extent mapping;
- free-space allocation;
- copy placement;
- checksum metadata linkage;
- copy-on-write replacement;
- allocation generation/state;
- recovery placement;
- reorganization and movement.

This keeps file semantics, IBM geometry, and physical disk placement cleanly separated.

---

## 5. Volume Services

**Cosmic Volume Services** creates logical disk-like storage from a Storage Set.

A **volume** is a logical storage resource. It is distinct from both the physical Storage Set below it and the file structure that may or may not be placed on it.

The first two canonical volume classes are:

1. **Block Volume**
2. **DASD Volume**

### 5.1 Block Volume

A **Block Volume** presents a linear block address space.

```text
BLOCK VOLUME DB01
capacity = 200 MB
```

The consumer sees conceptually:

```text
block 0
block 1
block 2
...
```

Typical uses include:

- database raw storage;
- DEC-compatible virtual disks;
- guest operating systems;
- future SCSI-style storage;
- network block-storage services.

The implementation may allocate the volume sparsely and distribute its extents anywhere in the Storage Set. The consumer need not know the physical placement.

### 5.2 DASD Volume

A **DASD Volume** presents IBM-compatible direct-access storage semantics rather than a simple linear block device.

```text
DASD VOLUME PAYROLL
compatibility = IBM 3350
```

The external semantics may include:

```text
cylinder
head
record
count
key
data
```

IBM geometry exists in DASD metadata and presentation logic; it is not reproduced as physical geometry across LDL disks.

For example:

```text
IBM C=214 H=7 R=3
        |
        v
DASD logical record/extent
        |
        v
Extent Manager
        |
        +--> LDL 07 physical extent
        +--> LDL 31 physical extent
```

The historical design placeholders **BVol** and **DVol** are retired from public terminology. Engineering shorthand may use `BV` and `DV`, but documents should normally say **Block Volume** and **DASD Volume**.

---

## 6. Cosmic File Services (CFS)

The canonical file layer is:

> **Cosmic File Services (CFS)**

CFS is one client of Cosmic Storage Management.

CFS provides file-system meaning:

- directories;
- file names;
- file contents and offsets;
- ownership and protection;
- links;
- attributes;
- timestamps;
- namespace operations.

CFS does **not** own the concept of a physical disk pair, RAID group, or IBM DASD geometry. It obtains managed extents from Storage Set Services.

Conceptually:

```text
/docs/report
    |
file object / file metadata
    |
logical extent
    |
Storage Set Services / Extent Manager
    |
QDX-B
    |
LDL devices
```

This terminology avoids calling the entire Cosmic storage architecture a "filesystem" merely because files are one of its presentations.

---

## 7. Cosmic File Structure

The on-storage file organization is named separately from the OS service.

The initial format is:

> **Cosmic File Structure, Level 1 (CFS-1)**

This follows the useful distinction between a file service and an on-disk/on-storage structure.

A CFS-1 structure may occupy storage supplied by a one-device Storage Set or a many-device Storage Set. The term **File Structure** therefore does not imply one physical disk.

Future incompatible format generations may be named CFS-2, CFS-3, and so on without renaming Cosmic File Services itself.

---

## 8. Cosmic Record Services (CRS)

The canonical record-oriented application layer is:

> **Cosmic Record Services (CRS)**

CRS sits above Cosmic File Services and provides business/data-processing record abstractions appropriate to the period.

It may support organizations such as:

- sequential records;
- fixed-length records;
- variable-length records;
- relative records;
- indexed records;
- keyed records.

Applications that want record semantics use CRS. Applications that want direct file/byte-stream semantics may use CFS directly.

```text
record-oriented application
        |
Cosmic Record Services
        |
Cosmic File Services
        |
Cosmic Storage Management
```

CRS is therefore not part of the physical-storage allocator and does not need to know where file extents are placed.

---

## 9. DASD Services

IBM-compatible storage presentation is provided by:

> **Cosmic DASD Services**

DASD Services interprets DASD Volume metadata and provides the device/control-unit behavior required by an external IBM-compatible channel interface.

It is deliberately not called "IBM emulation" in product terminology.

A configured path may look like:

```text
IBM System/370
      |
Bus and Tag
      |
PLIO-C370 Channel Adapter
      |
Channel Services
      |
DASD Services
      |
DASD Volume 180  -> IBM 3350 personality
DASD Volume 181  -> IBM 3350 personality
DASD Volume 182  -> IBM 3350 personality
      |
Storage Set Services
      |
QDX-B / LDL
```

QDX-B and LDL do not understand IBM channel commands or CKD records. IBM semantics remain above the common storage-management layer.

---

## 10. Channel Services

**Channel Services** owns the operating-system integration for external channel adapters such as PLIO-C370.

Its responsibilities include the software-visible management of:

- channel attachment;
- external device addresses;
- control-unit associations;
- path state;
- command/status exchange;
- connection between channel-facing devices and DASD Services.

The physical adapter handles the channel protocol and DMA/queue interface. DASD Services supplies the logical device behavior. Storage Set Services supplies persistent storage.

This preserves a strict separation:

```text
IBM protocol and addresses     -> Channel/DASD Services
logical DASD geometry          -> DASD Volume
allocation and redundancy      -> Storage Set Services
queued block operations        -> QDX-B
physical device/link behavior  -> LDL
peripheral transport           -> PLIO
```

---

## 11. Storage Subsystem

A **Storage Subsystem** is the externally presented equipment/service complex, not an individual DASD Volume and not a Storage Set.

For example:

```text
IBM host
   |
   v
Digital Storage Subsystem
   |
   +-- virtual/control-unit function
   +-- DASD Volume 180
   +-- DASD Volume 181
   +-- DASD Volume 182
   +-- DASD Volume 183
```

This lets product literature say:

> **Cosmic Storage Management can construct complete IBM-compatible DASD storage subsystems from Digital mass-storage resources.**

A customer can therefore distinguish clearly between:

- the **Storage Set** supplying managed capacity;
- the **DASD Volumes** representing logical disks;
- the **Storage Subsystem** presented to the IBM host.

---

## 12. Device Services and the lower boundary

At the bottom of CSM are the device-facing services that operate QDX/PLIO hardware.

```text
CSM policy
    |
QDX-B driver / Device Services
    |
QDX queues, durability, integrity acceleration
    |
PLIO protected DMA and Notification
    |
LDL controller
    |
physical disk
```

The ownership rule is:

> **CSM owns storage meaning and policy. QDX may accelerate block movement and integrity arithmetic. PLIO provides peripheral transport and protection. LDL provides the storage-device link and device functions.**

QDX must not become a hidden RAID controller and LDL must not learn file, volume, DASD, or replication policy.

---

## 13. Customer vocabulary

Four nouns should cover most customer-facing explanations.

### Storage Set

**Physical capacity managed together.**

Example:

> Add four disk units to the Storage Set.

### Volume

**Logical disk storage created from managed capacity.**

Example:

> Create a 300-megabyte Block Volume.

or:

> Create eight 3350-compatible DASD Volumes.

### File Structure

**The organized files and directories maintained by Cosmic.**

Example:

> Extend the Cosmic File Structure into the added capacity.

### Storage Subsystem

**A collection of logical devices and controller behavior presented to another computer.**

Example:

> Present the DASD Volumes as a System/370 Storage Subsystem.

These terms avoid forcing customers to understand internal extents, copy-on-write trees, object placement, or physical replica mappings.

---

## 14. Example configurations

### 14.1 Lighting workstation, one disk

```text
Cosmic OS
   |
CSM
   |
SYSTEM Storage Set
   |
LDL disk

CFS-1 occupies managed extents in SYSTEM.
```

The architecture is unchanged even though placement is trivial and no redundancy is available.

### 14.2 Lighting/server, two disks

```text
SYSTEM Storage Set
   |
   +-- LDL 0
   +-- LDL 1

policy: duplicate copies = 2
```

With only two devices, duplicate-copy placement is physically equivalent to mirroring, even though the abstraction remains extent replication.

### 14.3 Multi-disk server

```text
SERVER Storage Set
   |
   +-- LDL 0
   +-- LDL 1
   +-- LDL 2
   +-- LDL 3
   +-- ...
```

CSM may place different extent copies on different device combinations, allowing all devices to participate in capacity, reads, and failure reconstruction.

### 14.4 IBM Storage Director

```text
                         IBM System/370
                              |
                         Bus and Tag
                              |
                         PLIO-C370
                              |
                       Channel Services
                              |
                         DASD Services
                  +-----------+-----------+
                  |           |           |
             DASD Vol 180 DASD Vol 181 DASD Vol 182
                  \           |           /
                   \          |          /
                     PRODUCTION Storage Set
                              |
                     QDX-B / LDL devices
```

The IBM host sees DASD. CSM sees logical volumes and managed extents. LDL devices see sector/block operations.

---

## 15. Terminology to retire

The following terms may appear in historical design discussion but are not canonical going forward:

| Earlier shorthand | Canonical term |
|---|---|
| DEC Object Pool | Storage Set / Storage Set Services |
| Digital Extent Pool | Storage Set / Extent Manager |
| BVol | Block Volume |
| DVol | DASD Volume |
| DEC ZFS / Cosmic ZFS | Cosmic Storage Management; CFS where specifically discussing files |
| storage virtualization | Volume Services / DASD Services, depending on context |
| IBM emulation | DASD Services / IBM-compatible Storage Subsystem |

"Object" may still be used where an internal data structure genuinely is an object, and "extent" remains a canonical engineering term. Neither should replace **Storage Set** as the public managed-capacity abstraction.

---

## 16. Canonical naming summary

The naming hierarchy is frozen as:

```text
COSMIC OS
  |
  +-- Cosmic Storage Management (CSM)
       |
       +-- Storage Set Services
       |    +-- Storage Set
       |    +-- Extent Manager
       |
       +-- Cosmic File Services (CFS)
       |    +-- Cosmic File Structure Level 1 (CFS-1)
       |
       +-- Cosmic Record Services (CRS)
       |
       +-- Volume Services
       |    +-- Block Volume
       |    +-- DASD Volume
       |
       +-- DASD Services
       |
       +-- Channel Services
       |
       +-- Device Services / QDX integration
```

The externally visible equipment/service concept is:

> **Storage Subsystem**

The most important architectural sentence is:

> **Cosmic Storage Management is the storage architecture. The file system is one service built on it.**
