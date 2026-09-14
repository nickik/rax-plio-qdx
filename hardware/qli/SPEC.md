# QLI v0.1 draft -- QIC Local Interface

QLI is the **semantic local interface** between the reusable peripheral-side PLIO-QIC and card-specific logic.

QLI is not a backplane, software ABI, or QDX interface. It hides PLIO arbitration, phase sequencing, parity, wait states, and bus ownership from local device logic.

## Invariants

- QLI carries no host physical address; DMA uses the 32-bit PLIO device-visible DMA handle.
- QLI carries no trusted source slot; the PLIO controller derives source from the active grant.
- QLI carries no CPU vector/target/priority.
- QLI contains no QDX queues, opcodes, descriptors, or profile semantics.
- v0.1 permits at most one outstanding worker-MMIO request and one outbound DMA transaction per QIC.
- Absence of a response is backpressure/wait, not an error.

## Worker MMIO channel

QIC -> local device:

```text
MmioRequest {
    address      : 25-bit slot-relative byte address
    write        : bool
    byte_enable  : 4 bits
    write_data   : 32 bits
}
```

Local device -> QIC:

```text
MmioResponse =
    ReadOk(data: 32 bits)
  | WriteOk
  | Error(code)
```

A response may be delayed arbitrarily within the PLIO timeout budget. The QIC converts that delay into PLIO wait states.

## DMA command channel

Local device -> QIC:

```text
DmaRequest {
    direction : HOST_TO_DEVICE | DEVICE_TO_HOST
    address   : 32-bit PLIO DMA handle
    words     : 1 | 4 | 8 | 16
}
```

The QIC owns BR/BG, address phase, BLEN, parity, per-beat ACK/wait/error handling, and grant release.

## DMA data channels

DMA moves 32-bit words. For HOST_TO_DEVICE the QIC produces words for the local endpoint. For DEVICE_TO_HOST the local endpoint produces words for the QIC.

The semantic interface uses ready/valid or equivalent guarded-method backpressure. The physical encoding is not defined here.

## DMA completion

QIC -> local device:

```text
DmaCompletion {
    status          : OK | BUS_ERROR | PARITY_ERROR | TIMEOUT | RESET
    words_completed : 0..16
}
```

`words_completed` is required because PLIO permits a burst to fail after earlier beats have already been acknowledged.

## PLIO Notification channel

Local device -> QIC:

```text
NotificationRequest {
    channel : 0..3
}
```

The QIC may backpressure the request until it can retain it. A Notification never preempts an active PLIO transaction.

## Reset/diagnostics

The QIC provides local reset state and may expose sticky transport diagnostics. Device-specific fault policy remains outside QLI.

## Configuration ownership

For the first validation fixture, the local endpoint implements the mandatory PLIO configuration area through ordinary QLI worker-MMIO. The QIC does not synthesize vendor/device identity. This decision may be revisited before silicon freeze, but tests must make ownership explicit.