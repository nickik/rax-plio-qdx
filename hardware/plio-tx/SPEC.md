# PLIO-TX v0.1 logical/electrical-buffer contract

**Status:** frozen logical component contract. Electrical implementation details remain deferred to PLIO-E.

PLIO-TX is the transmission/reception block between the narrow PTI package interface and the wide PLIO-E backplane.

The name describes a logical component. A historical implementation may use one custom bipolar part, several bipolar/TTL transceivers and latches, or a small chip family. The executable Rust and Bluespec models below are deliberately **transistor-independent**.

Normative PTI pin/slot semantics are in `../pti/SPEC.md`.

## 1. Responsibilities

PLIO-TX MUST:

- buffer/level-shift PLIO backplane signals;
- assemble QIC->TX DATA_LO/DATA_HI into one 32-bit AD + 4-bit PAR image;
- capture one coherent 32-bit AD + 4-bit PAR backplane image for TX->QIC DATA_LO/DATA_HI reads;
- latch the outbound PTI control image;
- multiplex the receive control/data banks onto PTD;
- obey `TX_DRIVE` and subgroup output enables;
- obey `RESP_DRIVE` for the ACK/ERR pair;
- buffer the dedicated `SEL`, `BG`, and `BR` paths;
- force all card-driven PLIO outputs safe/non-driving during reset;
- enforce the frozen PTI LO/HI and direction-turnaround safety rules;
- expose malformed PTI/turnaround as a local sticky protocol fault in the logical models.

The simulation model MAY additionally detect overlapping local/external drive intent as contention.

## 2. Non-responsibilities

PLIO-TX MUST NOT:

- calculate or check PLIO parity;
- interpret `SPACE` values;
- understand address versus data phases beyond latching the supplied bits;
- arbitrate or decide whether BG authorizes a transaction;
- generate PLIO ACK/ERR policy;
- perform DMA;
- understand Notification semantics;
- understand QLI, QLI-16, QDX, slots, capability handles, or CPU state.

If the QIC requests an electrically unsafe or malformed action, PLIO-TX may suppress the affected drive group and raise its local fault, but it does not replace QIC protocol policy with its own.

## 3. Internal logical state

The technology-independent model contains only small latches/state:

```text
out_control_valid
out_control[12:0]
out_data_valid
out_ad[31:0]
out_par[3:0]

out_low_pending
out_low_data[15:0]
out_low_par[1:0]

in_low_pending
in_sample_ad[31:0]
in_sample_par[3:0]

pti_direction_valid
pti_direction
previous_slot_idle
previous_tx_drive
protocol_fault_sticky
contention_sticky   // simulation aid
```

No queue, DMA state, PLIO transaction state machine, timeout counter, or arbitration state belongs in PLIO-TX.

## 4. QIC -> PLIO-TX narrow writes

Every PTI slot is one sampled `PT_STB` event.

### `PT_CONTROL`

A valid outbound control token:

- has zero PTD parity fragment;
- has reserved bits 15:13 clear;
- atomically replaces the outbound control latch.

An invalid control token raises `protocol_fault` and leaves the previous valid control latch unchanged.

### `PT_DATA_LO` / `PT_DATA_HI`

`PT_DATA_LO` stores a pending low half. The immediately following payload slot must be `PT_DATA_HI`.

A valid HI commits the complete AD/PAR image atomically:

```text
AD[15:0]   = pending LO data
PAR[1:0]   = pending LO parity
AD[31:16]  = HI data
PAR[3:2]   = HI parity
```

HI without LO, or interruption/replacement of a pending LO by a non-HI payload token, raises `protocol_fault`. A partial pair never replaces the committed wide output image.

`PT_IDLE` performs no data/control update and is the legal turnaround token.

## 5. PLIO backplane -> QIC narrow reads

In `TX_TO_QIC` direction, QIC still drives `PT_KIND`; PLIO-TX drives PTD.

### `PT_CONTROL`

Returns a packed image of the currently sampled backplane:

```text
SPACE, AS, RD, BE, BLEN, DS
```

Outbound-only `drive_ad_par` and `drive_control` bits are returned as zero. PTD parity fragment is zero.

### `PT_DATA_LO`

Captures the complete current backplane AD/PAR image into the input sample latch and returns its low data/parity half.

### `PT_DATA_HI`

Requires a preceding receive DATA_LO and returns the high half from the same captured image. Backplane changes between LO and HI therefore cannot tear one 32-bit sample.

HI without a pending receive LO is malformed and produces no valid receive token.

## 6. Backplane drive behavior

The outbound latched control image contains two subgroup enables:

```text
drive_ad_par
drive_control
```

They are subordinate to the external `TX_DRIVE` master gate.

When legal and valid:

```text
AD/PAR = committed out_ad/out_par         if TX_DRIVE && drive_ad_par
CONTROL = SPACE/AS/RD/BE/BLEN/DS latch    if TX_DRIVE && drive_control
BR = QIC bus_request
```

If `TX_DRIVE` requests a subgroup whose latch is not valid, that subgroup remains non-driving and `protocol_fault` is raised.

PLIO-TX does not gate `TX_DRIVE` with BG. Grant interpretation is QIC policy.

## 7. ACK/ERR response pair

`PT_ACK` and `PT_ERR` are bidirectional package signals under `RESP_DRIVE`.

- `RESP_DRIVE=0`: backplane ACK/ERR is passed toward QIC.
- `RESP_DRIVE=1`: QIC ACK/ERR values are passed toward the backplane.

ACK and ERR simultaneously asserted by QIC is malformed. The logical model suppresses the response drive for that slot and raises `protocol_fault`.

This path is independent of `TX_DRIVE`, allowing worker ACK/ERR while the card is not a bus manager.

## 8. Direction and turnaround

PTD direction has two states:

```text
QIC_TO_TX
TX_TO_QIC
```

After reset, the first non-IDLE slot establishes a direction. A later direction change is legal only through a `PT_IDLE` slot. A non-IDLE token presented in the opposite direction raises `protocol_fault` and is ignored for narrow transfer purposes.

For shared PLIO drive, a rising `TX_DRIVE` after a non-driving interval must have a preceding `PT_IDLE` slot. An illegal rise is suppressed for that slot and raises `protocol_fault`.

Deasserting `TX_DRIVE` or `RESP_DRIVE` is always immediately safe.

## 9. Reset

While reset is asserted:

- AD/PAR is non-driving;
- shared control is non-driving;
- ACK/ERR response is non-driving;
- BR is inactive;
- PTD does not intentionally drive a receive payload;
- partial LO/HI state is cleared;
- control/data-valid state is cleared;
- protocol/contention fault state is cleared.

Reset dominates all slot processing.

## 10. Simulation-only contention observation

The logical Rust/Bluespec fixtures may be told whether an external actor is driving:

```text
external_ad_par_drive
external_control_drive
external_response_drive
```

If a local output group overlaps the corresponding external drive intent, the model raises a sticky `contention` indication. This does not define analog current or logic-level resolution; it exists only to catch invalid ownership in simulation.

## 11. What this model intentionally omits

The logical model does not model:

- TTL threshold voltages;
- source/sink current;
- propagation delay;
- rise/fall time;
- connector/backplane capacitance;
- termination;
- open-collector resistor sizing;
- metastability;
- transistor count;
- bipolar process choice.

Those belong to the later physical PLIO-TX/PLIO-E work. The logical model is the frozen functional target that such a bipolar implementation must realize.
