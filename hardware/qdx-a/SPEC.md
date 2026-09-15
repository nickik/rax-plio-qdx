# QDX-A v0.1 -- minimal queued-device adapter chip

**Status:** implementation profile / first chip model

## 1. Purpose

QDX-A is the smallest reusable hardware engine that implements the generic QDX queue machinery behind a PLIO QIC.

It is a **chip boundary**, not a board and not a device profile. QDX-A knows QDX queues and the local QIC contract. It does not know PLIO electrical signalling, PTI, PLIO arbitration, block storage, namespaces, disks, or a local CPU.

```text
PLIO backplane
      |
   PLIO-TX chip
      | PTI
     QIC chip
      |
   local QIC link
      |
    QDX-A chip
      |
 profile / endpoint logic
```

The first implementation uses the semantic QLI contract as the explicit QIC/QDX-A chip boundary. A later PCB wrapper will serialize this exact contract onto the already-frozen QLI-16 pins. No QDX-A queue state or behavior may depend on which physical QLI encoding is used.

## 2. Chip-boundary rule

QDX-A may observe only the QIC-facing local-device contract:

- reset;
- worker MMIO request / ready / response / cancel;
- DMA request / ready;
- host-to-device DMA words;
- device-to-host DMA words;
- DMA completion;
- Notification request / completion.

QDX-A MUST NOT observe:

- PLIO `BG`, `BR`, `SEL`, `AS`, `DS`, `SPACE`, ACK/ERR, parity pins or bus ownership;
- PTI tokens;
- PLIO slot number;
- host physical addresses;
- CPU interrupt vector, priority or target.

Therefore the future PCB connection can change from a semantic simulation wire to physical QLI-16 without changing the QDX-A queue engine.

## 3. QIC-facing connection

For the current Bluespec chip model:

```text
QIC QliOut  ---------------------->  QDX-A
QIC QliIn   <----------------------  QDX-A
```

The concrete type aliases live in `bluespec/QDXAQicPort.bsv`.

The mapping is direct:

| QIC -> QDX-A | Meaning |
|---|---|
| `reset` | chip reset |
| `mmioRequest*` | standard QDX worker-register access |
| `mmioResponseReady` | QIC consumed response |
| `mmioCancel` | cancel accepted MMIO after PLIO termination |
| `dmaRequestReady` | QIC accepted QDX-A DMA request |
| `dmaRead*` | host-to-device DMA word |
| `dmaWriteReady` | QIC accepted device-to-host DMA word |
| `dmaCompletion*` | completed PLIO DMA transaction |
| `notificationReady` | PLIO Notification completed |

| QDX-A -> QIC | Meaning |
|---|---|
| `mmioReady` | QDX-A can accept worker request |
| `mmioResponse*` | QDX register response |
| `dmaRequest*` | SQ/CQ DMA operation |
| `dmaReadReady` | QDX-A can accept H->D word |
| `dmaWrite*` | QDX-A supplies D->H word |
| `dmaCompletionReady` | QDX-A can accept DMA completion |
| `notification*` | Notification channel 0 request |

This is deliberately a **logical chip link**, not yet a PCB pinout. The physical board implementation will insert a device-side QLI-16 serializer/deserializer at this boundary.

## 4. Minimal implementation limits

The v0.1 chip is intentionally serial:

- one SQ;
- one CQ;
- fixed queue size of 4 entries;
- one command in flight;
- 32-byte SQ entry;
- 16-byte CQ entry;
- one QLI DMA operation in flight;
- one 8-word H->D burst per SQ fetch;
- one 4-word D->H burst per CQ publication;
- Notification channel 0 only;
- no scatter/gather;
- no profile decode;
- no command reordering.

The endpoint sees opaque command and completion payloads.

## 5. Queue positions

The v0.1 implementation uses 16-bit producer/consumer **positions**. The low two bits select one of four physical ring entries; the full 16-bit value advances monotonically modulo 2^16.

This avoids the empty/full alias that occurs if only a modulo-4 index is retained.

```text
physical entry = position[1:0]
occupancy      = producer_position - consumer_position
```

Software MUST keep occupancy in `0..4`. A producer movement that would make occupancy exceed four is a queue protocol error.

The generic QDX wording describing ring indexes as wrapping directly modulo queue size should be reconciled with this position-counter formulation before QDX v1.0 is frozen.

## 6. Standard MMIO registers

QDX-A implements the standard QDX offsets:

| Offset | Width | Register |
|---:|---:|---|
| `0x1000` | 32 | `QDX_CAP` |
| `0x1004` | 32 | `QDX_STATUS` |
| `0x1008` | 32 | `QDX_CONTROL` |
| `0x1010` | 32 | `SQ_BASE` |
| `0x1014` | 16 | `SQ_SIZE` |
| `0x1018` | 16 | `SQ_TAIL` |
| `0x1020` | 32 | `CQ_BASE` |
| `0x1024` | 16 | `CQ_SIZE` |
| `0x1028` | 16 | `CQ_HEAD` |
| `0x1030` | 16 | `SQ_HEAD` |
| `0x1034` | 16 | `CQ_TAIL` |
| `0x1038` | 32 | `QDX_ERROR` |

The first RTL accepts 32-bit access (`BE=1111`) for 32-bit registers and low-halfword access (`BE=0011`) for 16-bit registers.

### QDX_CONTROL

```text
bit 0 ENABLE
bit 1 RESET       write-one command, self-clearing
bit 2 NOTIFY_EN
bits 31:3 zero
```

### QDX_STATUS

```text
bits 1:0 state
  00 DISABLED
  01 READY
  10 FAULT
  11 reserved
bits 31:2 zero
```

### QDX_ERROR

```text
0 NONE
1 BAD_CONFIG
2 SQ_DMA
3 CQ_DMA
4 QUEUE_PROTOCOL
5 ENDPOINT_PROTOCOL
```

### QDX_CAP

The v0.1 implementation reports:

```text
bits 7:0   QDX implementation ABI revision = 1
bits 11:8  log2(SQ entry bytes) = 5
bits 15:12 log2(CQ entry bytes) = 4
bits 19:16 log2(max queue entries) = 2
bit 20     PLIO Notification supported
bit 21     serial one-command engine
bits 31:22 zero
```

This capability encoding is part of the QDX-A implementation profile and must be reconciled with the generic `QDX_CAP` definition before QDX v1.0.

## 7. Configuration rules

Configuration registers are writable only while DISABLED.

Enable succeeds only when:

- `SQ_SIZE == 4`;
- `CQ_SIZE == 4`;
- `SQ_BASE` is 32-byte aligned;
- `CQ_BASE` is 16-byte aligned;
- adding all four entries cannot carry from DMA offset bits `[23:0]` into channel/generation bits `[31:24]`.

Invalid enable enters FAULT with `BAD_CONFIG`.

Writing RESET or receiving QLI reset returns the chip to DISABLED, clears queue positions and errors, cancels DMA/Notification traffic, drops any endpoint command/completion, and pulses endpoint reset.

## 8. SQ fetch

When READY, `SQ_HEAD != SQ_TAIL`, and the CQ has room for a future completion:

1. issue one H->D QLI DMA request for 8 words at `SQ_BASE + SQ_HEAD[1:0] * 32`;
2. collect exactly eight DMA words;
3. accept a successful completion reporting eight words;
4. only then advance `SQ_HEAD`;
5. offer the complete opaque 32-byte command to the endpoint.

A partial/failing SQ DMA never reaches the endpoint.

## 9. Endpoint contract

The endpoint contract is defined in `QDXAEndpointIfc.bsv`.

- command: eight 32-bit words / 32 bytes;
- completion: four 32-bit words / 16 bytes;
- standard valid/ready semantics;
- one outstanding command;
- endpoint may apply arbitrary backpressure;
- reset cancels the in-flight command.

QDX-A does not interpret the opaque words.

## 10. CQ publication

After an endpoint completion is accepted:

1. issue one D->H QLI DMA request for 4 words at `CQ_BASE + CQ_TAIL[1:0] * 16`;
2. present all four completion words in order;
3. wait for successful DMA completion reporting four words;
4. only then advance `CQ_TAIL`;
5. if the CQ was empty before publication and notifications are enabled, request Notification channel 0.

A failed CQ DMA does not advance `CQ_TAIL` and enters FAULT.

## 11. Notification rule

QDX-A follows the generic QDX empty-to-non-empty rule.

The CQ entry is committed before Notification begins. Notification latency or retry never rolls back the CQ entry. The request is held until QIC reports `notificationReady`.

When software advances `CQ_HEAD` to equal `CQ_TAIL`, the CQ becomes empty and the next publication is eligible to notify again.

## 12. Fault policy

The minimal chip treats these as fatal until reset:

- invalid enable configuration;
- SQ DMA failure;
- CQ DMA failure;
- queue producer/consumer movement beyond the four-entry capacity;
- impossible endpoint sequencing.

FAULT suppresses new DMA and Notification requests.

## 13. Source and physical boundaries

The intended hierarchy is:

```text
QDXARegisters.bsv       source-level block inside chip
QDXAQueueEngine.bsv     source-level block inside chip
          \             /
             QDXA.bsv              <- one physical QDX-A chip
                |
          semantic QIC port         <- current chip connection
                |
       future QLI-16 PCB wrapper    <- later board work
                |
             QIC chip
```

The first implementation may keep registers and queue engine in one `QDXA.bsv` source file while behavior is being stabilized. Splitting source modules later MUST NOT create new physical chip boundaries.
