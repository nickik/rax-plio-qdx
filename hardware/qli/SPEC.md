# QLI v0.1 — QIC Local Interface

**Status:** frozen semantic interface for the first PLIO-QIC implementation and Rust/Bluespec conformance work.

QLI is the **semantic local interface** between the reusable peripheral-side PLIO-QIC and card-specific logic.

QLI is not a backplane, software ABI, physical pinout, or QDX interface. It hides PLIO arbitration, address/data phase sequencing, parity, wait states, timeout handling, and bus ownership from local device logic.

The normative executable reference for v0.1 is `rust/src/lib.rs` plus the PLIO-QIC and NakedCard Rust tests. A later physical encoding such as QLI-16 MUST preserve these semantics without adding new device meaning.

## 1. Invariants

- QLI carries **no host physical address**. DMA uses the 32-bit PLIO device-visible DMA handle.
- QLI carries **no trusted source slot**. The PLIO controller derives source identity from the active grant.
- QLI carries no CPU vector, CPU target, interrupt priority, or host interrupt architecture.
- QLI contains no QDX queues, descriptors, opcodes, profiles, or QDX-specific state.
- QLI v0.1 permits at most **one outstanding worker-MMIO request** and **one outbound DMA transaction** per QIC.
- A PLIO grant covers one transaction only; QLI never exposes grant ownership to the local device.
- Absence of a valid payload is wait/backpressure, not an error.
- Once a producer presents a valid payload, it MUST hold that payload stable until the corresponding acceptance/completion handshake occurs.
- Reset is out-of-band and cancels in-flight local-interface state. Reset does not require a synthetic completion record.

In the Rust cycle model, `Option<T>` represents a valid payload and Boolean `*_ready` fields represent the corresponding acceptance event.

## 2. Worker MMIO

### 2.1 Request

QIC -> local device:

```text
MmioRequest {
    address      : 25-bit slot-relative byte address
    write        : bool
    byte_enable  : 4 bits
    write_data   : 32 bits
}
```

`write_data` is meaningful only when `write=true`.

The QIC presents `mmio_request` and keeps it stable until the local endpoint asserts `mmio_ready`. Acceptance transfers ownership of exactly one request to the local endpoint. The QIC does not issue another worker request until the accepted request has produced one response.

### 2.2 Legal transfer encodings

PLIO v0.6 requires naturally aligned 8-, 16-, and 32-bit worker accesses. QLI therefore accepts only these address/byte-enable combinations within the 25-bit slot-relative address space:

| Width | `address[1:0]` | `byte_enable` |
|---:|---:|---:|
| 8 | `00` | `0001` |
| 8 | `01` | `0010` |
| 8 | `10` | `0100` |
| 8 | `11` | `1000` |
| 16 | `00` | `0011` |
| 16 | `10` | `1100` |
| 32 | `00` | `1111` |

Zero, non-contiguous, out-of-range, and misaligned byte-enable combinations are invalid and MUST be rejected by the QIC before they reach a conforming local endpoint.

The local endpoint receives the original byte address. A register implementation may align the address internally when selecting a containing 32-bit register word.

### 2.3 Response

Local device -> QIC:

```text
MmioResponse =
    ReadOk(data: 32 bits)
  | WriteOk
  | Error
```

There is deliberately no QLI MMIO error code in v0.1. PLIO transports only successful completion or error for this transaction; a device-specific diagnostic code would require a separate device register if needed.

The endpoint presents exactly one response for every accepted request and holds it until `mmio_response_ready` is asserted by the QIC.

For a read, the endpoint returns the complete containing 32-bit word. PLIO byte enables determine which byte lanes are architecturally selected by the host access.

For a write, `WriteOk` means the local endpoint accepted the selected byte lanes according to its register semantics.

### 2.4 Wait and timeout behavior

A delayed `mmio_ready` or delayed response becomes PLIO wait states. The PLIO timeout budget is one continuous budget for the outstanding PLIO data phase; accepting the request on QLI does **not** restart that timeout.

If the PLIO timeout expires, the QIC terminates the bus transaction with PLIO error and discards the outstanding local transaction state.

## 3. DMA command

Local device -> QIC:

```text
DmaRequest {
    direction : HOST_TO_DEVICE | DEVICE_TO_HOST
    address   : 32-bit PLIO DMA handle
    words     : 1 | 4 | 8 | 16
}
```

The 32-bit DMA handle is the exact device-visible PLIO address placed in the `HOST_DMA` address phase. It is **not** a host physical address. It MUST be longword aligned.

The producer presents one request and holds it until `dma_request_ready`. Acceptance means the QIC has taken responsibility for performing that complete PLIO DMA transaction and will eventually present one `DmaCompletion`, unless reset cancels the interface.

QLI v0.1 has no transaction tag because only one DMA request may be outstanding.

The QIC owns:

- `BR`/`BG` participation;
- the PLIO `HOST_DMA` address phase;
- `BLEN` encoding;
- parity generation/checking;
- per-beat ACK/wait/error handling;
- timeout handling;
- release of the grant after the one transaction.

The local device does not observe those mechanisms.

## 4. DMA data

DMA data is a stream of exactly the number of 32-bit words fixed by the accepted `DmaRequest`.

```text
DmaWord {
    data : 32 bits
}
```

There is deliberately **no `last` field**. A separate end marker would duplicate information already fixed by the 1/4/8/16-word request and would add state/pins to a future physical QLI encoding.

### 4.1 HOST_TO_DEVICE

The QIC is the producer and local device is the consumer:

```text
QIC -- dma_read(data) --> device
QIC <-- dma_read_ready -- device
```

Each word transfers once when valid and ready coincide. The QIC preserves ordering and presents exactly the requested number of words on a successful transaction.

A final word already ACKed on PLIO may remain in the QIC's one-word local buffer after the host controller withdraws `BG`; draining that already-owned word into QLI requires no further PLIO grant.

### 4.2 DEVICE_TO_HOST

The local device is the producer and QIC is the consumer:

```text
device -- dma_write(data) --> QIC
device <-- dma_write_ready -- QIC
```

The local device presents exactly the requested number of words and holds each word stable until accepted.

The QIC may backpressure data while waiting for the PLIO target. Conversely, after a device has initiated a DMA transaction, failure to provide required local write data cannot pin a PLIO grant indefinitely; the QIC applies its bounded transport timeout and completes the request as `TIMEOUT`.

## 5. DMA completion

QIC -> local device:

```text
DmaCompletion {
    status :
        OK
        BUS_ERROR
        PARITY_ERROR
        TIMEOUT
        PROTOCOL_ERROR

    words_completed : 0..16
}
```

The QIC holds the completion until the local endpoint asserts `dma_completion_ready`.

`words_completed` is the number of PLIO data beats successfully acknowledged before termination. This definition is intentionally bus-precise: for `HOST_TO_DEVICE`, a word may already have been ACKed into the QIC's local buffer before the local consumer accepts that word.

Rules:

- `OK` MUST report exactly the requested word count.
- Error completion MAY report any value from zero through the requested count.
- `BUS_ERROR` means PLIO `ERR` terminated the transfer.
- `PARITY_ERROR` means the QIC rejected received PLIO data because parity was wrong.
- `TIMEOUT` means required progress did not occur inside the QIC/PLIO bounded wait budget.
- `PROTOCOL_ERROR` means the transport contract was violated, such as losing an active PLIO grant before unfinished bus work completed.

Reset does not produce `DmaCompletion`; `reset` is a separate QLI event that cancels in-flight state.

## 6. PLIO Notification

Local device -> QIC:

```text
NotificationRequest {
    channel : 0..3
}
```

Notification uses a **completion handshake**, not an enqueue handshake:

```text
notification_request  -- held stable --> QIC
notification_ready    <-- pulse/true --- QIC
```

For QLI v0.1, `notification_ready` means:

> the corresponding PLIO `CONTROLLER` Notification transaction has actually completed successfully with PLIO ACK.

The producer MUST therefore keep the same request asserted until `notification_ready` is observed.

If arbitration is delayed, the request simply remains pending. If the PLIO Notification attempt loses its grant, errors, or times out, the QIC does not assert `notification_ready`; it returns to an idle/retryable state, and the still-held local request causes another attempt.

A Notification never preempts an active PLIO transaction. When the QIC is idle and both a new Notification and a new DMA request are presented, QLI v0.1 gives the Notification priority.

## 7. Reset

QIC -> local device:

```text
reset : bool
```

While reset is asserted:

- all QIC-controlled shared PLIO bus drives are inactive;
- no QLI request/data/completion transfer occurs;
- the QIC cancels all retained MMIO, DMA, and Notification state;
- the local endpoint MUST clear any handshake state that would otherwise refer to the cancelled transaction.

After reset is deasserted both sides restart from their idle interface state.

## 8. Configuration ownership

For QLI v0.1 and the first validation fixture, the **local endpoint owns the mandatory PLIO configuration register contents** and serves them through ordinary QLI worker-MMIO.

The QIC does not synthesize vendor/device identity or device class. This keeps the QIC reusable across unrelated peripheral types.

`NakedDevice` is the reference fixture: it implements only the small PLIO configuration surface needed for validation, performs no DMA, generates no Notifications, and contains no QDX behavior.

## 9. Ordering and arbitration visible at QLI

QLI deliberately exposes very little scheduling policy:

- one accepted MMIO request is completed before another worker request is accepted;
- one DMA request is outstanding at a time;
- a Notification never interrupts an active DMA;
- at an idle boundary, Notification has priority over a simultaneously presented new DMA request;
- after each outbound PLIO transaction the QIC relinquishes the grant and must arbitrate again for subsequent work.

No QLI endpoint may infer continued PLIO ownership from local back-to-back requests.

## 10. What QLI v0.1 does not specify

QLI v0.1 does not specify:

- physical pins;
- 8/16/32-bit local electrical datapath width;
- a local clock rate or two-phase encoding;
- PTI or PLIO-TX signaling;
- analog/electrical timing;
- host-controller implementation;
- DMA capability-table format or translation;
- QDX or any other higher-level device protocol.

Those are separate interfaces/layers. In particular, `../qli16/` may encode this interface on a narrower historical chip-to-chip connection, but it MUST NOT change QLI semantics.

## 11. v0.1 executable conformance coverage

The Rust reference currently verifies at least:

- legal and illegal 8/16/32-bit worker access encodings;
- worker read and write through complete PLIO -> QIC -> QLI -> NakedDevice paths;
- worker error and timeout behavior;
- all 1/4/8/16-word DMA lengths;
- both DMA directions;
- PLIO wait states;
- exact partial-transfer progress on bus error;
- parity failure before corrupted data reaches the local endpoint;
- grant loss as protocol error;
- bounded local producer stall;
- reset and inactive bus drive behavior;
- completion-based Notification semantics;
- Notification priority at an idle boundary without DMA preemption.

Bluespec QLI types and `NakedDevice` MUST match these frozen semantics before any Bluespec QIC state machine is implemented.
