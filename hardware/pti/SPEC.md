# PTI v0.1 -- PLIO Transceiver Interface

**Status:** frozen digital interface for the first PLIO-5 QIC/PLIO-TX implementation.

PTI is the logic-level boundary between the PLIO-QIC and the external electrical buffering collectively called **PLIO-TX**.

PTI exists so the QIC can be implemented as NMOS/ULA logic while bipolar/TTL devices handle backplane drive strength, receive thresholds, fanout, tri-state behavior, wide latching, and narrow/wide multiplexing.

PTI is an implementation interface. It MUST NOT change PLIO semantics.

## 1. Scope and ownership

The QIC owns:

- PLIO transaction state;
- request/grant participation and one-transaction-per-grant behavior;
- address/control sequencing;
- parity generation/checking;
- timeout/error policy;
- interpretation of ACK/ERR;
- DMA and Notification sequencing.

The host PLIO controller owns arbitration policy, including the baseline rotating round-robin selection among requesting slots.

PLIO-TX owns only:

- electrical transmission/reception;
- 32-bit AD + 4-bit parity latching;
- narrow/wide multiplexing;
- output enable/tri-state behavior;
- deterministic two-slot transfer timing.

PLIO-TX MUST NOT understand DMA, transaction spaces, Notifications, capability handles, QLI, or QDX.

## 2. PLIO-5 timing model

This version targets **PLIO-5 only**: one 200 ns PLIO clock period.

Each PLIO clock period contains two ordered PTI transfer slots:

```text
PLIO CLK period (200 ns)

|------------- slot A -------------|------------- slot B -------------|
              half 0                              half 1
```

The specification defines two slots per PLIO clock, not a mandatory separate 10 MHz clock pin. A historical implementation may use opposite clock phases or equivalent local timing. An FPGA implementation may use a faster internal clock and two clock-enable events.

The externally visible PLIO bus remains 5 MHz.

## 3. PTD datapath

PTI uses an **18-bit multiplexed datapath**:

```text
PTD[17:0]
```

For a PLIO data beat:

- slot A carries `AD[15:0]` plus `PAR[1:0]`;
- slot B carries `AD[31:16]` plus `PAR[3:2]`.

This is deliberate. A 16-bit PTI would require separate parity pins or an extra transfer slot and would therefore either consume package pins or throttle a full-rate PLIO-5 stream.

Parity remains generated and checked by the QIC. PLIO-TX only latches/multiplexes the parity bits supplied on PTD.

## 4. Transaction setup/control image

PLIO signals that are stable for an address phase or data phase are loaded into PLIO-TX as a compact control image before the corresponding backplane action.

Conceptually:

```text
PtiControl {
    space[1:0]
    as
    rd
    be[3:0]
    blen[1:0]
    ds
    drive_ad_par
    drive_control
}
```

The physical encoding uses PTD plus a small `PT_KIND` field. Control-image transfers occur before the data slots they govern and are not inserted between the two halfwords of a full-rate data beat.

PLIO-TX stores the current control image in simple latches. This is serialization/latching, not protocol interpretation.

## 5. PTI transfer kinds

The digital model defines these token kinds:

```text
PT_DATA_LO      lower 16 data bits + parity lanes 0..1
PT_DATA_HI      upper 16 data bits + parity lanes 2..3
PT_CONTROL      control-image fragment
PT_IDLE         no transfer / turnaround slot
```

`PT_DATA_LO` and `PT_DATA_HI` MUST occur as an ordered pair for one 32-bit PLIO data beat.

The Rust and Bluespec models use the same token encoding and reject malformed sequences such as HI without a preceding LO.

## 6. Immediate response/status signals

Beat-completion information is latency-sensitive and MUST NOT consume one of the two payload slots. PTI therefore exposes sampled status separately:

```text
sample_ack
sample_err
sample_selected
sample_grant
```

Likewise, QIC ownership/drive intent is explicit rather than inferred by PLIO-TX:

```text
drive_enable
response_enable
bus_request
```

Exact pad/buffer assignment is a PLIO-E implementation detail, but the digital behavior above is frozen.

## 7. Per-slot signals

`CLK`, `RESET*`, `SEL*`, `BG*`, and `BR*` remain low-fanout/dedicated PLIO signals. They may use simple auxiliary bipolar buffers rather than the main 18-bit PLIO-TX datapath.

PTI does not serialize the PLIO clock or reset.

## 8. Turnaround and safety

- reset immediately clears all PLIO-TX output enables;
- an ownership-direction change MUST include at least one `PT_IDLE` slot before the opposite side is allowed to drive the shared AD/PAR bus;
- PLIO-TX never invents ACK/ERR;
- PLIO-TX never modifies parity;
- outputs are high-impedance unless explicitly enabled by the QIC;
- sampled input remains observable while outputs are disabled;
- malformed PTI token ordering is a local protocol fault and MUST NOT cause an unintended PLIO drive.

## 9. Throughput requirement

One PLIO-5 payload beat is 32 bits every 200 ns. Two PTI slots per PLIO period carry exactly one complete data/parity beat:

```text
slot A: 16 data + 2 parity
slot B: 16 data + 2 parity
```

Therefore PTI itself does not reduce the PLIO-5 peak payload rate of 20 MB/s.

## 10. FPGA mapping

The first Bluespec QIC may operate against an abstract PLIO interface. PTI is implemented as a boundary adapter around that core.

On iCE40, the two-slot PTI contract SHOULD be implemented using a faster internal FPGA clock plus slot clock-enables rather than relying on dual-edge logic. This is an implementation choice and does not alter PTI semantics.
