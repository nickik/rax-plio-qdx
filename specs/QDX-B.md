# QDX-B v0.1 — Block Storage Profile

**Status:** Draft

## 1. Purpose

QDX-B defines the standard asynchronous block-storage command set carried by QDX.

One QDX-B controller may expose multiple **namespaces**. A namespace normally represents one physical disk, but it may also represent a logical volume.

The initial RAX storage design expects a PLIO QDX-B controller to attach one or more LDL disks.

## 2. Required capabilities

A QDX-B v0.1 controller MUST support:

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

All multibyte fields use the RAX platform byte order.

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

Reserved fields MUST be written as zero and ignored by a v0.1 device.

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

Namespace IDs need not be physically contiguous, but simple controllers SHOULD assign them starting at 1.

## 6. Block addressing

QDX-B v0.1 uses a 32-bit logical block address.

The namespace identifies its logical block size.

Required supported block sizes are 512 and 1024 bytes. A controller MAY support additional power-of-two block sizes.

`block_count` is the number of logical blocks and MUST be nonzero for READ/WRITE.

A request that extends beyond namespace capacity completes with `LBA_RANGE`.

## 7. Data buffers

### 7.1 Direct buffer

If `sg_count == 0`, `data_addr` is the device-visible DMA address of one contiguous buffer large enough for the complete transfer.

### 7.2 Scatter/gather buffer

If `sg_count > 0`:

- `sg_count` MUST be 1..16,
- `sg_addr` points to an array of SG entries,
- `data_addr` is ignored.

Each SG entry is 8 bytes:

| Offset | Size | Field |
|---:|---:|---|
| `0x00` | 4 | `address` |
| `0x04` | 4 | `length_bytes` |

The sum of SG lengths MUST be at least the requested transfer size.

The controller MUST process only the number of bytes required by the block command.

All SG addresses remain subject to PLIO DMA-window checks.

## 8. Completion descriptor

Every QDX-B completion entry is 16 bytes.

| Offset | Size | Field |
|---:|---:|---|
| `0x00` | 4 | `tag` |
| `0x04` | 2 | `status` |
| `0x06` | 2 | `flags` |
| `0x08` | 4 | `blocks_done` |
| `0x0C` | 4 | `info` |

`tag` MUST exactly match the submitted command.

`blocks_done` is zero for commands that transfer no blocks. For a successful READ/WRITE it normally equals `block_count`.

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

`IDENTIFY_CONTROLLER` writes a 64-byte structure containing QDX-B version, namespace count, SG limit, capability bits, maximum transfer size, model identifier, serial/controller identifier, and reserved space.

## 11. Identify namespace data

`IDENTIFY_NAMESPACE` writes a 64-byte structure containing namespace ID, flags, block size, total logical blocks, recommended alignment, model/media identifier, serial identifier, and reserved space.

## 12. READ

For READ:

1. controller validates namespace/LBA/range,
2. obtains data from the namespace/media,
3. DMA-writes the data into host buffers,
4. writes the CQ completion,
5. advances `CQ_TAIL`,
6. asserts IRQ if enabled/needed.

The completion MUST NOT become visible before the DMA data it reports as complete is visible to the host.

## 13. WRITE

For WRITE:

1. controller validates namespace/LBA/range,
2. DMA-reads host data,
3. writes data to media/controller buffering,
4. completes according to the namespace write-completion policy.

A `SUCCESS` completion for WRITE means the data has reached the persistence level advertised by the controller. If volatile write buffering exists, `FLUSH` makes the durability boundary explicit.

## 14. FLUSH

`FLUSH` requests that all previously completed writes to the selected namespace become durable according to the media/controller contract.

A controller with no volatile write cache may complete FLUSH immediately after ordering requirements are satisfied.

## 15. Interrupt behavior

QDX-B v0.1 uses the one PLIO IRQ line assigned to its slot.

The controller SHOULD assert the line when the CQ transitions from no-notification-needed to notification-needed.

While the IRQ remains asserted, additional completions do not require additional interrupt events.

The host drains the CQ before acknowledging the device interrupt condition.

## 16. Ordering

Commands may complete out of order unless a command's semantics impose an ordering dependency or the host uses FLUSH to establish a durability boundary.

A controller MUST preserve data integrity for overlapping commands even if it reorders them internally.

## 17. Reset and media state

QDX reset discards outstanding commands but does not imply destructive media reset.

After reset, the host must rediscover namespaces before assuming they are ready.
