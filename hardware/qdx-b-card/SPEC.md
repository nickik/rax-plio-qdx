# QDX-B physical card / FPGA v0.2

The QDX-B card is one system-integration unit.  Its implementation remains the existing chip-faithful PLIO/QDX chain, but the whole chain may be elaborated and synthesized into a single FPGA.

```text
                 QDX-B card FPGA
+------------------------------------------------+
| PLIO-E                                         |
|   |                                            |
| PLIO-TX                                        |
|   | PTI                                        |
|  QIC                                           |
|   | QLI-16                                     |
| QDX-A                                          |
|   | command/completion                         |
|   | profile payload-DMA service                |
| QDX-B                                          |
+----------------------|-------------------------+
                       |
                 QDXBMediaIfc
                       |
          pluggable storage backend
```

The QIC, QLI-16, QDX-A and QDX-B boundaries remain explicit inside the implementation so the RTL continues to model the intended historical hardware faithfully.  They are **not** system-level simulator components.  A system simulator or later multi-FPGA machine sees a single QDX-B card attached to PLIO.

No card-level shortcut is added for block payloads. SQ fetch, QDX-B payload DMA, SG fetch, CQ publication and PLIO Notification all use the same QIC/QLI-16/PLIO path.

## FPGA integration boundary

`QDXBCardFpgaIfc` is the opaque system-facing boundary.  It exposes only the sampled PLIO/card cycle interface required by the physical harness.  Internal QIC/QLI-16/QDX-A/QDX-B state is deliberately absent.

The Bluespec clock/reset remain the FPGA clock/reset boundary; PLIO reset is sampled through the physical PLIO input image.  The detailed `QDXBCardIfc` remains available only for card-level conformance and debug tests.

System integration MUST treat the card internals as opaque.  In particular, LightingSimulation must not depend on QIC state, QLI-16 codec state, QDX-A queue-engine state, or QDX-B endpoint state when the FPGA-backed card path is selected.

## Pluggable media

The QDX-B storage side is the `QDXBMediaIfc` module parameter.

- `mkQDXBCardWithMedia(media)` builds the detailed chip-faithful card around an injected backend for conformance/debugging.
- `mkQDXBCardFpga(media)` builds the opaque system-facing FPGA unit around the same implementation.
- `mkQDXBCard` remains a compatibility constructor that supplies `mkQDXBFakeMedia` for existing standalone validation.

`mkQDXBFakeMedia` remains validation-only. It has two writable namespaces, 512-byte and 1024-byte logical blocks, 64 blocks each. It has no LDL protocol or disk timing. Future LDL, simulated-disk, FPGA-BRAM, or other media implementations replace only this backend; no host-visible PLIO/QDX/QDX-B behavior changes.

## Physical partition

The current internal implementation remains:

```text
PLIO-TX -> QIC -> QLI-16 -> QDX-A -> QDX-B -> QDXBMediaIfc
```

`QDXAProfileDma` is internal QDX-A profile-port glue: it permits the attached profile engine to consume the QLI DMA path only while QDX-A is in `AEndpointCompletion`, when the queue engine itself has no DMA operation outstanding.

Keeping these boundaries internally allows exact comparison against the historical multi-chip design now, while permitting synthesis tools to place the complete controller into one FPGA and permitting a later optimized implementation to be differential-tested behind the same card boundary.
