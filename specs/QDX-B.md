# QDX-B v0.3 — Block Storage Profile

**Status:** Draft

## 1. Purpose

QDX-B defines the standard asynchronous block-storage command set carried by QDX.

One QDX-B controller may expose multiple **namespaces**. A namespace normally represents one physical disk, but it may also represent a logical volume.

The initial RAX storage design expects a PLIO QDX-B controller to attach one or more LDL disks.

All multibyte QDX-B control fields use the canonical **little-endian** QDX byte order. Media payload bytes are transferred unchanged.

## 2. Required capabilities

A QDX-B v0.3 controller MUST support:

- one QDX submission/completion queue pair,
- at least one namespace,
- READ,
- WRITE,
- FLUSH,
- IDENTIFY CONTROLLER,
- IDENTIFY NAMESPACE,
- completion status reporting,
- direct contiguous buffers,
- scatter/gather lists of up to 16 segments.

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

Reserved fields MUST be written as zero and ignored by a v0.3 device.

A naturally aligned 32-byte command descriptor fits one PLIO 8-longword DMA burst when its DMA capability mapping also permits the complete burst.

## 4. Opcodes

| Opcode | Name | Meaning |
|---:|---|---|
| `0x00` | `NOP` | no operation; useful for testing |
| `0x01` | `IDENTIFY_CONTROLLER` | return controller information |
| `0x02` | `IDENTIFY_NAMESPACE` | return namespace information |
| `0x10` | `READ` | namespace -> host memory |
| `0x11` | `WRITE` | host memory -> namespace |
| `0x12` | `FLUSH` | make previously completed writes durable as supported by media |
| `0x13` | `GET_HEALTH` | return current namespace/controller health data |

Other opcodes are reserved.

## 5. Namespace identifiers

`namespace_id = 0` refers to the controller when used with controller-wide commands.

Normal block commands require a nonzero namespace ID.

A controller MAY expose up to 65535 namespace IDs, though early implementations are expected to expose far fewer.

Namespace IDs need not be contiguous, but simple controllers SHOULD assign them starting at 1.

## 6. Block addressing

QDX-B v0.3 uses a 32-bit logical block address.

The namespace identifies its logical block size.

Required supported block sizes are 512 and 1024 bytes. A controller MAY support additional power-of-two block sizes.

`block_count` is the number of logical blocks and MUST be nonzero for READ/WRITE.

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

`blocks_done` is zero for commands that transfer no blocks. For a successful READ/WRITE it normally equals `block_count`.

A 16-byte completion fits one PLIO 4-longword DMA burst when alignment/capability bounds permit it.

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

## 10. Identify controller data

`IDENTIFY_CONTROLLER` writes a 64-byte little-endian QDX control structure containing QDX-B version, namespace count, SG limit, capability bits, maximum transfer size, model identifier, serial/controller identifier, and reserved space.

Character/string byte arrays inside the structure are opaque byte sequences and are not byte-swapped.

## 11. Identify namespace data

`IDENTIFY_NAMESPACE` writes a 64-byte little-endian control structure containing namespace ID, flags, block size, total logical blocks, recommended alignment, model/media identifier, serial identifier, and reserved space.

## 12. READ

For READ:

1. controller validates namespace/LBA/range,
2. obtains data from the namespace/media,
3. DMA-writes data into host buffers,
4. writes the CQ completion,
5. advances `CQ_TAIL`,
6. sends a PLIO normal notification when QDX notification rules require one.

The completion MUST NOT become visible before the DMA data it reports as complete is host-visible.

A PLIO notification MUST NOT become observable before the completion it announces is host-visible.

## 13. WRITE

For WRITE:

1. controller validates namespace/LBA/range,
2. DMA-reads host data,
3. writes data to media/controller buffering,
4. completes according to the namespace write-completion policy.

A `SUCCESS` completion for WRITE means data has reached the persistence level advertised by the controller. If volatile write buffering exists, `FLUSH` makes the durability boundary explicit.

## 14. FLUSH

`FLUSH` requests that all previously completed writes to the selected namespace become durable according to the media/controller contract.

A controller with no volatile write cache may complete FLUSH immediately after ordering requirements are satisfied.

## 15. Notification behavior

QDX-B uses the common QDX message-signalled notification mechanism transported by PLIO.

There is **no dedicated PLIO IRQ line** for a QDX-B controller.

A QDX-B controller that generates asynchronous notifications MUST be a PLIO bus manager. To notify the host it requests ownership, receives its grant, and issues one bus-local `SPACE=CONTROLLER` write to the PLIO notification offset for its channel.

The PLIO controller derives the trusted source slot from the active grant. The QDX-B device does not choose host CPU vector, privilege, interrupt class, or CPU routing.

QDX-B normally uses notification channel 0 unless a later profile assigns another channel.

The normal QDX rule is to notify when the CQ transitions from empty to non-empty. Additional completions MAY accumulate while the CQ remains non-empty without additional notification transactions. PLIO pending state may coalesce repeated notifications.

The host drains CQ entries. When the CQ becomes empty, the device is rearmed to notify on the next empty-to-non-empty transition. Polling remains legal.

## 16. Ordering

Commands may complete out of order unless semantics impose a dependency or the host uses FLUSH to establish a durability boundary.

A controller MUST preserve data integrity for overlapping commands even if it reorders them internally.

## 17. Reset and media state

QDX reset discards outstanding commands but does not imply destructive media reset.

After reset the host must rediscover namespaces before assuming they are ready.
