# Minimal QDX-B controller implementation

**Status:** implementation profile for the first physical QDX-B card

This module implements the mandatory base QDX-B v0.5 profile behind the already-defined QDX-A queue engine. The only deliberately fake component is the media/LDL side.

## Card layering

```text
PLIO-E
  |
PLIO-TX
  | PTI
 QIC
  | QLI-16
QDX-A queue chip
  | command/completion + profile DMA service
QDX-B profile engine
  | abstract block-media interface
FakeMedia (validation only; later replaced by LDL controller)
```

QDX-B has no direct path to QIC or PLIO. All descriptor, payload, SG-list, identify/health and completion traffic uses QDX-A and its profile DMA bridge.

## Mandatory v0.5 surface implemented

- NOP
- IDENTIFY_CONTROLLER
- IDENTIFY_NAMESPACE
- READ
- WRITE
- WRITE_DURABLE
- FLUSH
- GET_HEALTH
- direct contiguous buffers
- scatter/gather lists of 1..16 entries
- completion status/tag/blocks_done/info
- namespace validation and LBA range validation
- DMA failure -> `DMA_FAULT`
- reset/cancellation of an in-flight command
- fake-media read/write persistence for validation

The optional integrity extension is **not advertised** by this first controller and QDX-BA remains a later extension. `IDENTIFY_INTEGRITY` therefore completes `INVALID_OPCODE`.

## Namespace set

The validation controller exposes two fake namespaces so both mandatory logical block sizes are exercised:

| NSID | block size | blocks | flags |
|---:|---:|---:|---|
| 1 | 512 B | 64 | none |
| 2 | 1024 B | 64 | none |

`max_transfer_blocks = 1` for this first controller. This keeps the profile engine and fake media small while still implementing every mandatory command and buffer mechanism. Software may split larger transfers. A later LDL-backed controller can raise this limit without changing the ABI.

## DMA rules

QDX-B payload DMA is serialized behind the QDX-A queue engine. QDX-A owns SQ/CQ DMA. While QDX-A is waiting for the profile completion, the QDX-B engine may issue payload DMA through `QDXAProfileDma`.

Payload transfers use legal PLIO bursts of 1/4/8/16 words. A 512-byte block is eight 16-word bursts; a 1024-byte block is sixteen 16-word bursts.

SG-list entries are fetched through QDX-A profile DMA. The controller fetches each 8-byte SG entry as two 1-word reads, avoiding over-read beyond the caller's mapped SG array.

Because QLI/PLIO payload DMA is longword based, this first hardware profile requires SG `address` and `length_bytes` to be multiples of four. This implementation restriction is reported through `INVALID_FIELD`. The QDX-B architectural specification should eventually make DMA alignment requirements explicit.

## Fake media boundary

Fake media is not part of QDX-B semantics. It provides only logical block storage plus `flush`/durable completion. The validation implementation retains writes and therefore supports read-after-write tests. No LDL command format, seek timing, ECC, servo behavior or physical disk geometry is modeled here.

## Durability

Fake media has no volatile write cache. Therefore:

- ordinary WRITE is durable at successful completion;
- WRITE_DURABLE is also durable and sets `WRITE_DURABLE_DONE`;
- FLUSH succeeds after all prior operations complete.

IDENTIFY namespace/controller therefore report `VOLATILE_WRITE_CACHE=0`.

## Completion rules

The 16-byte completion is encoded exactly as QDX-B v0.5:

```text
word0 = tag
word1 = flags[31:16] | status[15:0]
word2 = blocks_done
word3 = info
```

Completion is presented to QDX-A only after all payload/SG/media work has committed or failed.
