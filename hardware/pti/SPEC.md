# PTI v0.1 draft -- PLIO Transceiver Interface

PTI is the logic-level boundary between the PLIO-QIC and the external electrical buffering collectively called **PLIO-TX**.

PTI exists so the QIC can be designed as NMOS/ULA logic while bipolar/TTL devices handle backplane drive strength, receive thresholds, fanout, and tri-state behavior.

## Principle

PLIO-TX is deliberately unintelligent. It MUST NOT understand DMA, arbitration policy, transaction spaces, Notification semantics, or QDX.

The QIC remains responsible for:

- protocol state;
- ownership/drive decisions;
- parity generation/checking;
- timeout/error policy.

PLIO-TX remains responsible for electrical transmission/reception.

## Shared-bus signal representation

For every buffered shared output, PTI conceptually exposes:

```text
value
output_enable
sampled_input
```

At minimum the 32-bit AD path and 4 parity lanes use this model.

The final PTI signal list must explicitly classify `SPACE`, `AS`, `RD`, `BE`, `BLEN`, `DS`, `ACK`, and `ERR` as either:

1. handled through PLIO-TX/auxiliary line buffers using value/OE/sample semantics, or
2. connected directly/through simple dedicated buffers outside the main data transceiver.

That choice is not frozen in v0.1.

## Per-slot/control signals

`CLK`, `RESET*`, `SEL*`, `BG*`, and `BR*` are logically part of PLIO but may not need the same wide transceiver device as AD/PAR. PTI must document their electrical-buffer path before silicon/package freeze.

## Safety

- reset must disable all QIC-controlled shared-bus drivers;
- bus turnaround must include a no-contention state;
- PLIO-TX must not invent ACK/ERR or alter parity;
- input sampling remains available while outputs are disabled where the electrical implementation permits it.

PTI is an implementation interface, not externally visible PLIO architecture.