# PLIO-E v0.1 — Eurocard Physical Profile

**Status:** Draft physical profile

## 1. Purpose

PLIO-E defines the baseline interoperable mechanical, connector, power, and pin-assignment profile for plug-in PLIO cards.

The logical PLIO protocol is defined by `PLIO.md`. A soldered/onboard PLIO device need not use Eurocard mechanics, but a plug-in card advertised as **PLIO-E** MUST conform to this profile.

The objective is to use an existing industrial card-cage ecosystem rather than invent a DEC-specific board size or connector.

## 2. Mechanics

The baseline card is a **3U Eurocard, 100 mm × 160 mm**, installed vertically in a Eurocard card cage.

The nominal card-slot pitch is **4 HP = 20.32 mm**. A system MAY provide wider positions for unusually large cards, but one PLIO-E electrical slot occupies one logical PLIO slot regardless of mechanical width.

A larger **6U × 160 mm** card MAY be used where board area is required. The lower P1 connector and PLIO electrical interface remain identical to the 3U card. An optional upper connector may be used for device-specific rear I/O, but MUST NOT redefine or extend the baseline PLIO bus.

Front-panel handles, ejectors, card guides, retaining hardware, and EMC mechanics follow normal Eurocard practice for the intended enclosure.

## 3. Backplane connector

PLIO-E uses one **96-position, three-row, 32-column DIN 41612 Type-C-compatible connector** as P1.

Rows are named `a`, `b`, and `c`; positions are numbered 1..32.

The mating backplane connector MUST provide all PLIO bus signals, slot-specific `SEL/BR/BG`, power, and ground through P1.

The board MUST NOT depend on a second connector for baseline PLIO operation.

## 4. Electrical baseline

The initial PLIO-E electrical profile uses 5 V TTL-compatible signalling.

- `+5V` is the mandatory logic supply.
- `+12V` and `-12V` are auxiliary rails intended for analog, serial-interface, storage-interface, or other peripheral circuitry.
- PLIO logic MUST NOT require the ±12 V rails.
- System/card current limits are declared by the platform/card documentation; the bus standard does not promise unlimited rail current.
- Signal drivers MUST enter a non-driving state during reset unless the signal is explicitly defined as controller-driven.
- Shared data/control outputs MUST use suitable tri-state/open-collector-compatible interface circuitry as required by the signal definition.

PLIO-10 compliance additionally requires the loading, trace, termination, setup/hold, and clock-skew limits established by the PLIO-E electrical timing annex. PLIO-5 remains mandatory for every card.

## 5. P1 pin assignment

The initial pin assignment deliberately allocates many ground contacts to reduce crosstalk and provide a usable path toward PLIO-10 without changing the connector.

### 5.1 Address/data and grounds — positions 1..16

| Pos | Row a | Row b | Row c |
|---:|---|---|---|
| 1 | `AD0` | `AD16` | GND |
| 2 | `AD1` | `AD17` | GND |
| 3 | `AD2` | `AD18` | GND |
| 4 | `AD3` | `AD19` | GND |
| 5 | `AD4` | `AD20` | GND |
| 6 | `AD5` | `AD21` | GND |
| 7 | `AD6` | `AD22` | GND |
| 8 | `AD7` | `AD23` | GND |
| 9 | `AD8` | `AD24` | GND |
| 10 | `AD9` | `AD25` | GND |
| 11 | `AD10` | `AD26` | GND |
| 12 | `AD11` | `AD27` | GND |
| 13 | `AD12` | `AD28` | GND |
| 14 | `AD13` | `AD29` | GND |
| 15 | `AD14` | `AD30` | GND |
| 16 | `AD15` | `AD31` | GND |

### 5.2 Control/arbitration — positions 17..25

| Pos | Row a | Row b | Row c |
|---:|---|---|---|
| 17 | `SPACE0` | `SPACE1` | GND |
| 18 | `AS*` | `RD` | GND |
| 19 | `BE0` | `BE1` | GND |
| 20 | `BE2` | `BE3` | GND |
| 21 | `BLEN0` | `BLEN1` | GND |
| 22 | `DS*` | `ACK*` | GND |
| 23 | `ERR*` | `CLK` | GND |
| 24 | `RESET*` | `SEL*` | GND |
| 25 | `BR*` | `BG*` | GND |

`SEL*`, `BR*`, and `BG*` are the signals for the physical/logical slot in which the card is installed. The backplane performs the per-slot fanout/routing; the card sees only its own three slot-specific pins.

### 5.3 Power/reserved — positions 26..32

| Pos | Row a | Row b | Row c |
|---:|---|---|---|
| 26 | `+5V` | `+5V` | GND |
| 27 | `+5V` | `+5V` | GND |
| 28 | `+12V` | `-12V` | GND |
| 29 | GND | GND | GND |
| 30 | reserved | reserved | GND |
| 31 | reserved | reserved | GND |
| 32 | reserved | reserved | GND |

Reserved pins MUST remain unconnected by v0.1 cards except where a later PLIO-E revision explicitly assigns them.

## 6. Backplane organization

A PLIO-E backplane contains:

- one host-controller connection,
- up to eight card slots,
- shared `AD`, `SPACE`, control, response, `CLK`, and `RESET*` lines,
- one `SEL*`, `BR*`, and `BG*` route for each slot,
- distributed power and ground.

The host controller drives the eight slot-select and eight grant signals separately and receives eight request signals separately. These per-slot signals are not wired as daisy chains.

PLIO-E does not require processor/memory cards or a processor arbitration hierarchy. The host controller is fixed on the host side of the backplane.

## 7. Slot identity and configuration

PLIO uses geographic slot selection. A card does not contain address jumpers or DIP switches for selecting its PLIO MMIO base.

The host profile determines how a logical slot appears in the host CPU address map. The backplane connects that slot's `SEL/BR/BG` lines to the installed card.

The card exposes its vendor/device/profile information through the standard PLIO configuration area. Moving a card to another slot changes only its host-side geographic mapping; it does not require reprogramming card address switches.

## 8. Front/rear I/O

Device-specific external connectors SHOULD normally be placed on the front panel.

A 6U card MAY use a separate upper rear-I/O connector for storage channels, instrumentation, networking, or other device-specific signals. Those signals are not PLIO and MUST NOT be required by an unrelated PLIO-E card.

The baseline P1 connector MUST remain sufficient for all PLIO bus operation.

## 9. Physical conformance

A PLIO-E v0.1 card MUST:

- fit the specified 3U or permitted 6U × 160 mm Eurocard mechanics,
- use the 96-position three-row P1 connector and pinout above,
- operate at PLIO-5,
- use only assigned/reserved pins as specified,
- obtain its geographic identity from the slot rather than address switches,
- conform to PLIO v0.5 logical/electrical signalling.

PLIO-10 is an additional speed-grade qualification on the same connector and pinout.

## 10. Design intent

PLIO-E deliberately follows established Eurocard mechanics so independent chassis, backplane, power-supply, card-guide, industrial, laboratory, telecom, and military suppliers can build compatible infrastructure without adopting a DEC-specific mechanical ecosystem.

The 96-pin connector has enough contacts to carry the 32-bit multiplexed bus, transaction-space and burst controls, per-slot arbitration, reset/clock, auxiliary power, and substantial ground distribution while retaining reserved contacts for controlled future evolution.
