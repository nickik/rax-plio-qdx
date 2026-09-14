# QIC package-pin and local-bandwidth study

**Status:** engineering input to frozen PTI v0.1 / QLI-16 v0.1.

## Goal

Keep the first PLIO-QIC plausible for a 1978/79 NMOS/ULA program while preserving full PLIO-5 bandwidth. A 64-pin ceramic package remains the working target, with 84 pins only as an escape option.

## Why a thin electrical-only PLIO-TX does not solve the QIC package

If the QIC itself sees every PLIO logical wire directly, the PLIO-facing signal count is already:

| Group | Pins |
|---|---:|
| `AD[31:0]` | 32 |
| `PAR[3:0]` | 4 |
| `SPACE[1:0]`, `AS`, `RD`, `BE[3:0]`, `BLEN[1:0]`, `DS`, `ACK`, `ERR` | 13 |
| `CLK`, `RESET`, `SEL`, `BR`, `BG` | 5 |
| **PLIO logical subtotal** | **54** |

That leaves no credible local-device interface in a 64-pin package.

Therefore PLIO-TX is more than an analog line driver but remains protocol-dumb: it contains the wide electrical transceivers, AD/parity latches, and the narrow multiplexing needed to connect the QIC to the backplane.

## 64-pin QIC working budget

### PTI / PLIO-facing side

PTI v0.1 uses an 18-bit narrow datapath so one 32-bit data beat plus four parity bits still fits in exactly two local slots:

| Function | Pins |
|---|---:|
| `PTD[17:0]` multiplexed data/parity path | 18 |
| PTI kind/bank select | 2 |
| PTI strobe/slot control | 1 |
| PTI direction | 1 |
| PTI ready/phase-complete | 1 |
| manager-drive enable | 1 |
| worker-response-drive enable | 1 |
| direct/auxiliary `CLK`, `RESET`, `SEL`, `BG`, `BR` | 5 |
| **PTI subtotal** | **30** |

The important change from the earlier 16-bit sketch is that parity travels with each halfword:

```text
slot A = AD[15:0]  + PAR[1:0]
slot B = AD[31:16] + PAR[3:2]
```

Parity is still generated/checked by the QIC. PLIO-TX only latches and multiplexes those bits.

### Card-side QLI-16

| Function | Pins |
|---|---:|
| `LD[15:0]` | 16 |
| `LTYPE[2:0]` | 3 |
| `LREQ` | 1 |
| `LACK` | 1 |
| `LDIR` | 1 |
| **QLI-16 subtotal** | **22** |

Reset may use the board/card reset distribution and does not need to consume another dedicated semantic QLI pin.

### Package infrastructure

| Function | Pins |
|---|---:|
| power/ground target | 8 |
| test/factory reserve | 2 |
| **infrastructure subtotal** | **10** |

Working total:

```text
PTI       30
QLI-16    22
P/G/test  10
----------------
TOTAL     62
SPARE      2
```

This is tight but still fits the 64-pin target. The two spare pins are deliberately retained as engineering margin.

## PLIO-5 bandwidth

PLIO-5 transfers at most one 32-bit data beat every 200 ns:

```text
5,000,000 beats/s * 4 bytes = 20 MB/s raw payload rate
```

QLI-16 carries two bytes per local transfer, so it requires two accepted local transfers per PLIO clock period to sustain that rate:

```text
2 halfwords / 200 ns = 10 million local transfers/s
```

This is a **10 MHz-equivalent transfer cadence**, not a second bus speed.

The frozen timing model is therefore:

```text
PLIO 5 MHz period (200 ns)

|------------- slot A -------------|------------- slot B -------------|
```

The architecture does not require a separate 10 MHz clock pin. A historical implementation may use two non-overlapping phases; an FPGA implementation may use a faster internal clock with two slot-enable events.

For a 16-word PLIO burst:

```text
PLIO:    16 * 32-bit beats = 3.2 us
QLI-16:  32 * 16-bit slots = 3.2 us
PTI:     32 * 18-bit slots = 3.2 us
```

Thus neither narrow boundary throttles ideal PLIO-5 steady-state payload.

## Width comparison

- **8-bit local:** four transfers per PLIO word, 20 million transfers/s required; rejected for v0.1.
- **16-bit QLI:** two transfers per PLIO word; current card-side choice.
- **18-bit PTI:** two transfers per PLIO word while carrying parity with data; current backplane-side choice.
- **32-bit local:** only one transfer per PLIO beat but consumes too many QIC pins for the 64-pin target.

## Implementation consequences

1. QLI remains a 32-bit semantic interface; QLI-16 is only an encoding.
2. PTI is 18 bits because PLIO parity must cross the boundary without an extra slot.
3. The QIC should contain one-word buffering at each narrow/wide boundary.
4. Command/header state must be loaded before the payload-critical slots of an active burst.
5. The first Bluespec QIC should be written against abstract PLIO/QLI interfaces; PTI and QLI-16 remain boundary adapters.
6. The iCE40 implementation may run internally faster than 5 MHz, but the external PLIO protocol remains strictly PLIO-5.
