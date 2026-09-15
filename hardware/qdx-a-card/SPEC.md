# QDX-A physical card v0.1

**Status:** first digital PCB integration model

## Purpose

This document defines the first board-level integration of the PLIO-TX, PLIO-QIC and QDX-A chips. It is deliberately a **PCB/net-level composition**, not a new protocol layer.

```text
PLIO-E connector
      |
      | PLIO backplane nets
+-----v-----+
|  PLIO-TX  |
+-----+-----+
      | PTI
+-----v-----+
|    QIC    |
+-----+-----+
      | QLI-16
+-----v-----+
|   QDX-A   |
+-----+-----+
      | endpoint interface
+-----v-------------+
| validation endpoint|
+-------------------+
```

The production board later replaces the validation endpoint with profile/device logic. QDX-A itself is unchanged.

## 1. Architectural rule

`QDXACard` contains no queue, DMA, notification, PLIO or device policy of its own. It only:

1. instantiates the existing component models;
2. connects their defined interfaces;
3. distributes clock/reset;
4. exposes the PLIO-facing card boundary;
5. exposes board-level diagnostic state for verification.

In particular:

- QDX-A MUST NOT see PLIO or PTI signals;
- PLIO-TX MUST NOT see QDX or endpoint semantics;
- the QIC/QDX-A connection MUST traverse the frozen QLI-16 physical encoding;
- the QIC/PLIO-TX connection MUST traverse PTI;
- no semantic QLI bypass is permitted in final card tests.

## 2. Component boundaries

### PLIO-TX

The existing `mkPLIOTx` implementation is the PLIO electrical/transceiver chip. In the simulation card it is exercised through the existing PTI physical harness. It owns electrical drive/receive behavior only.

### PLIO-QIC

The existing `mkPLIOQIC` implementation owns PLIO transaction sequencing and exposes semantic QLI internally. On the board, that semantic interface is encoded onto QLI-16 pins.

### QDX-A

The existing `mkQDXA` implementation is one logical chip. Its QIC-facing semantic port is reached only after QLI-16 decoding. QDX-A owns the generic QDX queue adapter and no block/device profile semantics.

### Validation endpoint

`mkQDXATestEndpoint` is test-only logic. It accepts one opaque QDX-A command and produces one deterministic completion. It is not part of the QDX-A chip and is not a production device profile.

## 3. QLI-16 board connection

The board carries the frozen QLI-16 signals between QIC and QDX-A:

```text
LD[15:0]
LTYPE[2:0]
LREQ
LACK
LDIR
LRESET / card reset distribution
```

The current Bluespec board model uses the canonical `QLI16Codec` to model serialization, two local transfer slots per PLIO clock and turnaround. This codec represents the combined pin-level behavior of the QIC-side encoder and QDX-A-side decoder. It is **not** a third physical chip.

A later implementation may split this source into explicit `QLI16QicPhy` and `QLI16DevicePhy` modules. Doing so MUST NOT change the wire protocol.

## 4. PTI board connection

PLIO-TX and QIC communicate only over the frozen PTI contract. The board-level simulation reuses `PLIOTxCardHarness`, which exercises the real PLIO-TX PTI token/control interface for receive and transmit paths.

The harness is a simulation convenience around the actual `mkPLIOTx`; it is not additional production board logic.

## 5. Clocking

Baseline timing remains:

- PLIO clock: 5 MHz, 200 ns period;
- QLI-16: two ordered transfer slots per PLIO clock;
- QIC and QDX-A are synchronous to card timing;
- the first board model does not model analog clock skew or trace delay.

A historical implementation may derive the QLI-16 two-phase cadence locally from PLIO clocking. The PCB does not define another architecturally visible bus clock.

## 6. Reset

Card reset is distributed to:

- PLIO-TX;
- QIC;
- QLI-16 endpoint state;
- QDX-A;
- validation endpoint.

Reset must immediately leave PLIO-TX non-driving and must discard partial QLI-16 messages. QDX-A returns to DISABLED with no DMA or Notification request outstanding.

## 7. PLIO-facing board model

The board integration fixture processes one logical PLIO cycle through these internal stages:

```text
backplane sample
  -> PLIO-TX receive/PTI
  -> QIC
  -> QLI-16 slot A
  -> QLI-16 slot B
  -> QDX-A / endpoint
  -> QIC
  -> PTI/PLIO-TX transmit
  -> backplane drive image
```

This sequencing is a simulation scheduling model. It must preserve the externally defined chip protocols and may not invent additional semantic communication.

## 8. First end-to-end proof

The first card test MUST perform, through the PLIO-facing boundary only:

1. reset the card;
2. program QDX-A `SQ_BASE`, `SQ_SIZE`, `CQ_BASE`, `CQ_SIZE` and control using worker MMIO;
3. enable QDX-A and Notification;
4. write `SQ_TAIL=1`;
5. observe the QDX-A 8-word H->D descriptor DMA traverse QLI-16, QIC, PTI and PLIO-TX;
6. supply eight descriptor words from the host-memory peer;
7. let the validation endpoint consume the exact command;
8. observe the 4-word D->H CQ publication through the same physical layers;
9. verify exact completion words at the PLIO boundary;
10. observe PLIO Notification channel 0 only after CQ publication;
11. verify final `SQ_HEAD=1`, `SQ_TAIL=1`, `CQ_HEAD=0`, `CQ_TAIL=1` and QDX-A READY.

No testbench may call QDX-A MMIO/DMA methods directly for this proof.

## 9. Out of scope

This first PCB model does not simulate:

- PCB trace impedance or propagation delay;
- TTL voltage margins;
- connector contact resistance;
- termination networks;
- decoupling/power transients;
- EMI/crosstalk;
- exact package pin numbering;
- QDX-B/QDX-BA;
- local CPU, disk, LDL or media electronics.

Those may be specified later without changing this digital board boundary.
