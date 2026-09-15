# QLI-16 v0.1 -- physical encoding of QLI

**Status:** frozen first physical encoding for PLIO-5 validation.

QLI-16 is a low-pin-count physical encoding of the semantic QLI v0.1 contract for a late-1970s QIC package.

QLI-16 MUST NOT add device semantics. It serializes QLI messages onto a 16-bit local path.

## 1. Timing model

The PLIO backplane remains **5 MHz**.

QLI-16 defines **two ordered local transfer slots per PLIO clock period**. This is a 10-million-transfer/second equivalent local cadence, but it is not PLIO-10 and does not require a separately visible 10 MHz architectural clock.

```text
PLIO CLK period = 200 ns

|------------- local slot A -------------|------------- local slot B -------------|
```

A historical implementation may realize these slots with two clock phases. An FPGA implementation SHOULD use a faster internal clock and generate two local slot enables per PLIO period.

At full rate, two 16-bit QLI-16 data tokens carry one 32-bit QLI DMA word per 200 ns, matching PLIO-5's 20 MB/s payload ceiling.

## 2. Physical signals

Working pin-level interface:

```text
LD[15:0]       token payload
LTYPE[2:0]     token type
LREQ            producer asserts token valid
LACK            consumer accepts token
LDIR            0 = QIC -> device, 1 = device -> QIC
LRESET          out-of-band reset
```

The producer holds `LD`, `LTYPE`, and `LDIR` stable while `LREQ=1` until the consumer asserts `LACK` in a transfer slot.

Only one side may assert `LREQ` for a given direction at a time. Messages are not interleaved.

The original pin-budget study reserved roughly 22 local-interface pins. `LRESET` may share the card reset distribution rather than consume a dedicated QIC-local pin; exact package assignment remains an implementation detail.

## 3. Token types

Three type bits encode eight token classes:

| `LTYPE` | Name | Meaning |
|---:|---|---|
| `000` | `IDLE` | no semantic payload / turnaround |
| `001` | `MMIO_HEADER` | MMIO request header word |
| `010` | `MMIO_DATA` | MMIO request/response data halfword |
| `011` | `MMIO_RESPONSE` | MMIO response status or QIC->device MMIO cancellation |
| `100` | `DMA_HEADER` | DMA request header word |
| `101` | `DMA_DATA` | DMA data halfword |
| `110` | `DMA_COMPLETION` | DMA completion |
| `111` | `NOTIFICATION` | device->QIC request or QIC->device completion |

`IDLE` is not a QLI message. It may be used for turnaround and unused local slots.

## 4. Halfword order

All 32-bit values use little-endian halfword order:

```text
first token  = value[15:0]
second token = value[31:16]
```

This order is fixed in v0.1.

## 5. MMIO request encoding

A read request is two `MMIO_HEADER` tokens:

```text
H0: LD = address[15:0]
H1: LD[8:0]   = address[24:16]
    LD[9]     = write (0)
    LD[13:10] = byte_enable[3:0]
    LD[15:14] = 0
```

A write request appends two `MMIO_DATA` tokens containing `write_data` low then high halfword.

Therefore:

- read request = 2 tokens;
- write request = 4 tokens.

Illegal QLI MMIO encodings remain illegal after decoding and MUST be rejected.

## 6. MMIO response and cancellation encoding

A normal local-device response uses `MMIO_RESPONSE` with `LDIR=1` (device -> QIC):

```text
LD[1:0] status
    00 = ReadOk
    01 = WriteOk
    10 = Error
    11 = reserved/invalid
LD[15:2] = 0
```

`ReadOk` is followed by two `MMIO_DATA` tokens containing the returned 32-bit word low then high halfword.

`WriteOk` and `Error` contain no data tokens.

QLI semantic `mmio_cancel` uses the same `MMIO_RESPONSE` token class in the otherwise-unused opposite direction:

```text
LTYPE = MMIO_RESPONSE
LDIR  = 0                 // QIC -> device
LD     = 0x0000
```

This exact token means **cancel the currently accepted MMIO request**. It is not a response status. Reusing the class avoids adding a ninth token type or another pin, while `LDIR` makes the meaning unambiguous.

Rules:

- only payload `0x0000` is valid for QIC->device `MMIO_RESPONSE`;
- any non-zero payload in that direction is malformed;
- device->QIC response tokens are never interpreted as cancellation;
- cancellation is only valid after a semantic MMIO request has been accepted and before its response has completed;
- the endpoint MUST discard retained MMIO response state and become ready for another request after accepting the cancellation token.

## 7. DMA request encoding

A DMA request is three `DMA_HEADER` tokens:

```text
H0: address[15:0]
H1: address[31:16]
H2:
    LD[0]   direction: 0=HOST_TO_DEVICE, 1=DEVICE_TO_HOST
    LD[2:1] burst:     00=1, 01=4, 10=8, 11=16 words
    LD[15:3] = 0
```

The decoded 32-bit address is the QLI/PLIO DMA handle, not a host physical address.

## 8. DMA data encoding

Every semantic QLI `DmaWord` is exactly two `DMA_DATA` tokens:

```text
D0 = data[15:0]
D1 = data[31:16]
```

There is no `last` token. The accepted DMA request already fixes the word count.

For a 16-word burst, exactly 32 `DMA_DATA` tokens are transferred.

## 9. DMA completion encoding

One `DMA_COMPLETION` token:

```text
LD[2:0] status
    000 = OK
    001 = BUS_ERROR
    010 = PARITY_ERROR
    011 = TIMEOUT
    100 = PROTOCOL_ERROR
    101..111 = reserved

LD[7:3] words_completed (0..16)
LD[15:8] = 0
```

The decoded completion MUST still satisfy semantic QLI validation rules.

## 10. Notification request and completion encoding

`NOTIFICATION` is directional and uses one token in either direction:

```text
LD[1:0] channel (0..3)
LD[15:2] = 0
```

Direction defines its meaning:

```text
LDIR = 1   device -> QIC   Notification request
LDIR = 0   QIC -> device   Notification completion
```

The semantic QLI Notification remains completion-based. Accepting the device->QIC request token with `LACK` means only that the physical request has crossed QLI-16; it MUST NOT produce semantic `notification_ready`.

After accepting that request, the QIC-side QLI-16 endpoint retains it and continues presenting the same semantic `notification_request` to QIC until QIC reports semantic `notification_ready`, which occurs only after the corresponding PLIO CONTROLLER data beat is ACKed.

The endpoint then emits the opposite-direction `NOTIFICATION` token with the same channel. Acceptance of that completion token produces semantic `notification_ready` at the device-side endpoint.

```text
device                       QIC
   |                           |
   |-- NOTIFICATION(ch) ------>|
   |<--------- LACK -----------|   physical request accepted
   |                           |
   |       PLIO transaction    |
   |                           |
   |<-- NOTIFICATION(ch) ------|   semantic completion
   |----------- LACK --------->|
   | notification_ready        |
```

Rules:

- request direction is always device->QIC;
- completion direction is always QIC->device;
- completion channel MUST equal the retained request channel;
- reserved payload bits MUST be zero in both directions;
- a duplicate request while the same request is retained is not a second semantic Notification;
- reset discards a retained request or pending completion without synthesizing `notification_ready`.

## 11. Reset

Reset remains out-of-band. `LRESET` cancels any partially encoded message and returns both endpoints to idle. A partial QLI-16 message does not generate a synthetic QLI completion.

`MMIO_CANCEL` is deliberately distinct from reset: it cancels only the currently accepted MMIO operation and does not affect DMA, Notification, or unrelated device state.

## 12. Turnaround and malformed sequences

- message tokens are contiguous in logical order, though backpressure may insert unused slots between accepted tokens;
- direction may change only between complete messages;
- a direction change MUST include at least one idle transfer slot;
- a decoder MUST reject reserved bits that are non-zero;
- a decoder MUST reject unexpected token kinds or premature end-of-message;
- QIC->device `MMIO_RESPONSE` with non-zero payload MUST be rejected;
- QIC->device `NOTIFICATION` is valid only as completion of the retained same-channel request;
- malformed physical framing is a local protocol error and MUST NOT create a different valid QLI operation.

## 13. Rust / Bluespec conformance requirement

Rust is the executable reference encoding.

Bluespec MUST produce identical token vectors and stateful link behavior for the canonical cases:

- 8/16/32-bit MMIO reads and writes;
- ReadOk, WriteOk, Error responses;
- MMIO_CANCEL and malformed opposite-direction response rejection;
- both DMA directions and all 1/4/8/16 burst encodings;
- representative DMA data words;
- every DMA completion status and boundary word count;
- all four Notification request/completion channels;
- held final tokens under backpressure;
- direction turnaround through an idle slot;
- malformed/reserved encodings rejected identically;
- reset discarding partial link state.

The CI conformance test compares canonical Rust and Bluespec physical slot traces as well as decoded semantic results.

## 14. Relationship to FPGA implementation

The QIC core may first be implemented in Bluespec against abstract semantic QLI and abstract PLIO signals. QLI-16 is then a boundary adapter.

This keeps the QIC state machine readable and allows the FPGA implementation to use a faster internal clock while preserving the exact two-slot-per-PLIO-cycle QLI-16 contract.
