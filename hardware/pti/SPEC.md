# PTI v0.1 -- PLIO Transceiver Interface

**Status:** frozen digital/operational interface for the first PLIO-5 QIC/PLIO-TX implementation.

PTI is the logic-level boundary between the PLIO-QIC and the external electrical buffering collectively called **PLIO-TX**.

PTI exists so the QIC can be implemented as NMOS/ULA logic while bipolar/TTL devices handle backplane drive strength, receive thresholds, fanout, tri-state behavior, wide latching, and narrow/wide multiplexing.

PTI is an implementation interface. It MUST NOT change PLIO semantics.

This revision freezes the previously underspecified **operational** behavior between QIC and PLIO-TX. The existing 18-bit PTD token encoding is unchanged.

## 1. Scope and ownership

The QIC owns:

- all PLIO transaction state;
- request/grant participation and one-transaction-per-grant behavior;
- address/control sequencing;
- parity generation/checking;
- timeout/error policy;
- interpretation/generation of ACK/ERR;
- DMA and Notification sequencing.

The host PLIO controller owns arbitration policy, including the baseline rotating round-robin selection among requesting slots.

PLIO-TX owns only:

- electrical transmission/reception;
- 32-bit AD + 4-bit parity latching;
- control-image latching;
- narrow/wide multiplexing;
- PTD direction/turnaround;
- output enable/tri-state behavior;
- deterministic two-slot transfer timing;
- local malformed-framing/turnaround detection.

PLIO-TX MUST NOT understand DMA, transaction spaces, Notifications, capability handles, QLI, QDX, or grant policy. It does not decide whether QIC is *allowed* to drive the PLIO bus; it only obeys the explicit drive enables.

## 2. PLIO-5 timing model

This version targets **PLIO-5 only**: one 200 ns PLIO clock period.

Each PLIO clock period contains two ordered PTI transfer slots:

```text
PLIO CLK period (200 ns)

|------------- slot A -------------|------------- slot B -------------|
              half 0                              half 1
```

The specification defines two slot events per PLIO clock, not a mandatory separate 10 MHz clock pin. A historical implementation may derive two non-overlapping phases from PLIO CLK. An FPGA implementation may use a faster internal clock and two clock-enable events.

`PT_STB` identifies the slot event at the package boundary. PLIO-TX has no backpressure in v0.1; there is no PTI READY pin.

## 3. Frozen PTI signal groups

### 3.1 Multiplexed path

```text
PTD[17:0]     bidirectional
PT_KIND[1:0] QIC -> PLIO-TX
PT_DIR        QIC -> PLIO-TX
PT_STB        slot event
```

`PT_DIR` selects ownership of PTD:

- `QIC_TO_TX`: QIC drives PTD; PLIO-TX consumes the selected token/bank.
- `TX_TO_QIC`: PLIO-TX drives PTD; `PT_KIND` selects which receive bank QIC reads.

`PT_KIND` encodes:

```text
00 PT_IDLE
01 PT_DATA_LO
10 PT_DATA_HI
11 PT_CONTROL
```

The same kind values are used in both directions. In receive direction they are **bank selects**, not protocol operations.

### 3.2 QIC-controlled PLIO drive intent

```text
TX_DRIVE      manager/shared AD/PAR/control master enable
RESP_DRIVE    direction/enable for PT_ACK/PT_ERR
BR            dedicated slot request output
```

`TX_DRIVE` is a master safety gate. The latched control image further selects whether AD/PAR and/or the shared control group is actually driven.

`RESP_DRIVE` is separate because a selected worker must be able to drive ACK/ERR while not acting as a bus manager.

### 3.3 Response/status pair

Two QIC package pins are bidirectional through PLIO-TX:

```text
PT_ACK
PT_ERR
```

When `RESP_DRIVE=0`, PLIO-TX drives these pins **toward QIC** from sampled backplane ACK/ERR.

When `RESP_DRIVE=1`, QIC drives these pins **toward PLIO-TX**, which drives the corresponding backplane ACK/ERR response lines.

QIC MUST NOT request ACK and ERR simultaneously. PLIO-TX treats simultaneous asserted ACK+ERR while `RESP_DRIVE=1` as a local protocol fault and MUST NOT intentionally drive both asserted.

### 3.4 Dedicated auxiliary signals

These are not serialized through PTD:

```text
CLK
RESET
SEL
BG
BR
```

`SEL` and `BG` are received through PLIO-TX/simple auxiliary buffering and are directly observable by QIC. `BR` is QIC-controlled and buffered toward the backplane.

## 4. PTD data/parity banks

PTD carries **16 data bits + two parity bits**:

```text
PTD[15:0]  data halfword
PTD[17:16] parity fragment
```

For one 32-bit PLIO AD/PAR image:

- `PT_DATA_LO` carries `AD[15:0]` + `PAR[1:0]`;
- `PT_DATA_HI` carries `AD[31:16]` + `PAR[3:2]`.

Parity remains generated and checked by QIC. PLIO-TX only latches/multiplexes the parity bits.

### 4.1 QIC_TO_TX assembly

`PT_DATA_LO` begins a pending wide image. The following non-idle payload token MUST be `PT_DATA_HI` in the immediately following slot. `PT_DATA_HI` atomically commits the complete 32-bit AD + 4-bit PAR drive latch.

A HI without a pending LO, or a LO interrupted by CONTROL/another LO, is malformed. The incomplete image MUST NOT become the committed drive image.

### 4.2 TX_TO_QIC sampling

On a receive `PT_DATA_LO` slot, PLIO-TX captures the complete current backplane AD + PAR image and returns its low half through PTD. A following `PT_DATA_HI` returns the high half from the **same captured image**, even if the backplane changes between the two slots.

A receive HI without a preceding receive LO is malformed and does not return a valid data bank.

This latch is what makes two narrow reads represent one coherent wide backplane sample.

## 5. Control image

The frozen 16-bit control payload is unchanged:

```text
bits  1:0   SPACE
bit     2   AS
bit     3   RD
bits  7:4   BE
bits  9:8   BLEN
bit    10   DS
bit    11   drive_ad_par
bit    12   drive_control
bits 15:13  reserved = 0
```

### 5.1 QIC_TO_TX control write

A valid `PT_CONTROL` token has zero PTD parity fragment and zero reserved bits. PLIO-TX latches the complete image.

`drive_ad_par` and `drive_control` do not themselves grant ownership. They are subgroup enables under `TX_DRIVE`.

### 5.2 TX_TO_QIC control read

In receive direction, `PT_CONTROL` selects the live/captured PLIO control bank:

```text
SPACE, AS, RD, BE, BLEN, DS
```

PLIO-TX returns `drive_ad_par=0` and `drive_control=0`; those fields have no receive-side meaning. ACK/ERR are carried by the dedicated PT_ACK/PT_ERR pair and therefore do not consume PTD payload slots.

This allows a steady full-rate PLIO data burst to use both PTD slots for DATA_LO/DATA_HI while ACK/ERR remains observable without stealing bandwidth.

## 6. Backplane drive mapping

When `RESET` is inactive and no local safety violation blocks the drive:

```text
AD/PAR driven   = TX_DRIVE && control.drive_ad_par && committed_data_valid
control driven  = TX_DRIVE && control.drive_control && control_valid
BR asserted     = bus_request/BR input from QIC
ACK/ERR driven  = RESP_DRIVE using PT_ACK/PT_ERR values from QIC
```

The shared control group is exactly:

```text
SPACE[1:0], AS, RD, BE[3:0], BLEN[1:0], DS
```

PLIO-TX never synthesizes, modifies, or interprets those values.

If QIC requests a subgroup before the required latch is valid, PLIO-TX MUST keep that subgroup non-driving and report a local protocol fault.

## 7. Reset, turnaround, and malformed input

- reset immediately disables AD/PAR, shared-control, ACK/ERR, and BR outputs;
- reset clears partial LO/HI assembly and local protocol-fault state;
- PTD direction changes MUST pass through at least one `PT_IDLE` slot;
- a rise of `TX_DRIVE` after a non-driving interval MUST be preceded by a `PT_IDLE` slot;
- deasserting an output enable is always allowed immediately;
- malformed PTI ordering MUST NOT commit a partial wide image;
- invalid CONTROL reserved/parity bits MUST NOT replace the current valid control latch;
- a local protocol fault is sticky until reset in the executable logical models;
- sampled backplane inputs remain observable while local outputs are disabled.

The logical model may additionally report contention when local and external drive intents overlap. Contention detection is a simulation aid, not PLIO protocol interpretation.

## 8. Throughput

One PLIO-5 payload beat is 32 bits every 200 ns. Two PTI slots carry exactly one complete data/parity beat:

```text
slot A: 16 data + 2 parity
slot B: 16 data + 2 parity
```

Therefore PTI does not reduce the PLIO-5 peak payload rate of 20 MB/s. Control images are loaded outside a payload-critical DATA_LO/DATA_HI pair; ACK/ERR and SEL/BG do not consume PTD slots.

## 9. 64-pin QIC package budget

The frozen operational contract uses:

```text
PTD[17:0]                 18
PT_KIND                     2
PT_STB                      1
PT_DIR                      1
TX_DRIVE                    1
RESP_DRIVE                  1
PT_ACK/PT_ERR               2
CLK/RESET/SEL/BG/BR         5
--------------------------------
PTI / PLIO-facing total    31
```

With QLI-16 at 22 pins and the current 10-pin power/ground/test allowance:

```text
PTI       31
QLI-16    22
P/G/test  10
----------------
TOTAL     63
SPARE      1
```

The previously sketched PTI READY pin is removed: v0.1 is fixed-cadence and has no transceiver-side backpressure. The two response/status pins now have an explicit direction rule, closing the earlier package-budget ambiguity.

## 10. FPGA/historical mapping

The logical contract is technology-independent.

A historical PLIO-TX may be one bipolar custom part, several bipolar/TTL transceivers/latches, or a small chip family. An FPGA test implementation may emulate it with ordinary registers and tri-state boundary logic.

The executable Rust and Bluespec PLIO-TX models MUST implement only this logical contract. Analog thresholds, current drive, termination, loading, propagation delay, and exact transistor partitioning belong to PLIO-E / later bipolar implementation work.
