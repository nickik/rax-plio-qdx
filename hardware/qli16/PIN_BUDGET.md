# QIC package-pin and local-bandwidth study

**Status:** engineering input to QLI-16/PTI; not a frozen interface.

## Goal

Keep the first PLIO-QIC plausible for a 1978/79 NMOS/ULA program while preserving full PLIO-5 bandwidth. A 64-pin ceramic package is an intentionally aggressive but historically grounded target: Motorola shipped the 68000 in a 64-pin package in 1979, and Motorola's own oral history describes 64 pins as expensive and mechanically difficult at the time. That is a useful upper-pressure point rather than an invitation to assume 96+ pins are cheap.

Historical references:

- Computer History Museum, Motorola 68000 (1979): https://www.computerhistory.org/revolution/artifact/330/1581
- Motorola 68000 oral-history panel, Computer History Museum: https://archive.computerhistory.org/resources/access/text/2012/04/102658164-05-01-acc.pdf

## Why a thin electrical-only PLIO-TX does not solve the QIC package

If the QIC itself sees every PLIO logical wire directly, the PLIO-facing signal count is already:

| Group | Pins |
|---|---:|
| `AD[31:0]` | 32 |
| `PAR[3:0]` | 4 |
| `SPACE[1:0]`, `AS`, `RD`, `BE[3:0]`, `BLEN[1:0]`, `DS`, `ACK`, `ERR` | 13 |
| `CLK`, `RESET`, `SEL`, `BR`, `BG` | 5 |
| **PLIO logical subtotal** | **54** |

A real external-transceiver implementation then needs at least a few drive-enable/direction controls. With even three such controls and eight power/ground pins, a 64-pin package is already exceeded **before any card-side QLI pins exist**.

Even an 84-pin package would leave only about 19 pins after `54 + 3 + 8`, which is not enough for a useful 16-bit local datapath plus handshake/control.

Therefore the two-chip idea must be slightly stronger than "QIC plus analog buffer":

> **PLIO-TX remains protocol-dumb, but it may contain the wide electrical transceivers, 32-bit data/parity latches, and a narrow multiplexing datapath toward the QIC.**

It still does not know about DMA, spaces, arbitration policy, Notifications, timeout policy, or device semantics. It only moves/latches physical PLIO signal groups under explicit QIC control.

## 64-pin QIC working budget

A plausible working budget is:

### PTI / PLIO-facing side

| Function | Pins |
|---|---:|
| `PTD[15:0]` multiplexed transceiver/latch datapath | 16 |
| PTI bank/select | 2 |
| PTI strobe | 1 |
| PTI direction | 1 |
| PTI ready/phase-complete | 1 |
| manager-drive enable | 1 |
| worker-response-drive enable | 1 |
| direct/auxiliary `CLK`, `RESET`, `SEL`, `BG`, `BR` | 5 |
| **PTI subtotal** | **28** |

The exact PTI coding is not frozen by this document. The point is that the QIC should see a **narrow registered physical datapath**, not 36+ wide AD/PAR pins.

### Card-side QLI physical candidate

| Function | Pins |
|---|---:|
| `LD[15:0]` | 16 |
| local transaction type | 3 |
| request | 1 |
| acknowledge/ready | 1 |
| direction | 1 |
| **QLI-16 subtotal** | **22** |

### Package infrastructure

| Function | Pins |
|---|---:|
| power/ground target | 8 |
| test/factory reserve | 2 |
| **infrastructure subtotal** | **10** |

Working total:

```text
PTI       28
QLI-16    22
P/G/test  10
----------------
TOTAL     60
SPARE      4
```

This makes a 64-pin QIC possible without forcing the custom NMOS die itself to drive the PLIO backplane.

The four spare pins are deliberately not allocated yet. They are margin for clocking, test, a second PTI handshake, or a mistake discovered during RTL.

## Local bandwidth

PLIO-5 can transfer one 32-bit data beat every 200 ns in the no-wait ideal case:

```text
5,000,000 beats/s * 4 bytes = 20 MB/s raw payload rate
```

A 16-bit local datapath transfers two bytes per local transfer:

| Local transfer cadence | Payload ceiling | Effect on PLIO-5 |
|---:|---:|---|
| 5 MHz | 10 MB/s | throttles PLIO by ~2x |
| 10 MHz | 20 MB/s | just matches PLIO-5 payload rate |
| 12.5 MHz | 25 MB/s | useful timing/protocol headroom |

For the maximum 16-word PLIO burst:

```text
PLIO:    16 * 32-bit beats at 5 MHz  = 3.2 us
QLI-16:  32 * 16-bit transfers at 10 MHz = 3.2 us
```

So a 16-bit physical local interface must provide **two 16-bit transfer opportunities per PLIO-5 clock** if it is not to become the steady-state bottleneck.

That can be implemented either as:

1. a 10 MHz local transfer clock, or
2. two non-overlapping local transfer phases per 5 MHz PLIO clock.

The latter may be attractive for the first custom implementation because it keeps the architectural PLIO clock at 5 MHz while still giving the narrow datapath two slots per bus cycle.

Command/header traffic must not consume the same critical 32 halfword slots of a maximum burst. DMA command state should be loaded before bus ownership is granted, and one-word/ping-pong latches should decouple PTI/QLI transfer phasing from the PLIO backplane beat.

## Width comparison

### 8-bit local datapath

Needs four transfers per PLIO word, or a 20 MHz transfer cadence to avoid throttling PLIO-5. That is too aggressive for the first historical QIC unless the narrow serialization is moved almost entirely into faster bipolar logic.

### 16-bit local datapath

Needs two transfers per PLIO word. Ten million transfers/second exactly matches PLIO-5. It fits the 64-pin budget and is the current preferred physical width.

### 32-bit local datapath

Only needs 5 MHz for payload, but consumes roughly 16 additional QIC pins relative to QLI-16. With the proposed PTI and package infrastructure it no longer fits comfortably in 64 pins.

## Consequences

1. **Do not define QLI semantic operations in 16-bit terms.** QLI remains a 32-bit semantic interface.
2. **QLI-16 is only an encoding.** It must reproduce QLI semantics without adding transaction meaning.
3. **PTI should be redesigned around a registered/multiplexed 16-bit physical datapath.** The PLIO-TX can latch/multiplex signals but remains protocol-dumb.
4. **64 pins is the working QIC target.** An 84-pin escape option may exist, but the design should not depend on it.
5. **10 MHz-equivalent local transfer opportunity is the minimum no-throttle target for both PTI-16 and QLI-16.**
6. The QIC RTL should use one-word buffering at each narrow/wide boundary so local halfword movement can overlap PLIO bus timing.
