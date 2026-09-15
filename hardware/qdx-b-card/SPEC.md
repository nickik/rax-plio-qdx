# QDX-B physical card v0.1

The QDX-B card is the existing QDX-A physical card with its validation endpoint replaced by the mandatory QDX-B base-profile engine and a fake block-media backend.

```text
PLIO-E
  |
PLIO-TX
  | PTI
 QIC
  | QLI-16
QDX-A
  | command/completion
  | profile payload-DMA service
QDX-B
  | block-media operations
FakeMedia       <-- validation only
```

No card-level shortcut is added for block payloads. SQ fetch, QDX-B payload DMA, SG fetch, CQ publication and Notification all use the same QIC/QLI-16/PLIO path.

## Physical partition

The PLIO-TX, QIC and QDX-A chip boundaries defined by the QDX-A card remain unchanged. `QDXAProfileDma` is internal QDX-A profile-port glue: it permits the attached profile engine to consume the QLI DMA path only while QDX-A is in `AEndpointCompletion`, when the queue engine itself has no DMA operation outstanding.

The QDX-B profile engine may later be implemented as local logic or partly in a local processor on a more capable controller. In this first card it is explicit Bluespec logic.

## Fake media

`mkQDXBFakeMedia` implements the abstract media boundary for validation. It has two writable namespaces, 512-byte and 1024-byte logical blocks, 64 blocks each. It has no LDL protocol or disk timing. The future LDL implementation replaces this module below QDX-B; no host-visible QDX or QDX-B behavior changes.
