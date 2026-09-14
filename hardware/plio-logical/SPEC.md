# PLIO logical model boundary

**Status:** implementation companion, not a replacement normative specification.

The normative logical protocol is `../../specs/PLIO.md`.

This directory defines only the representation used by Rust/Bluespec validation code.

The model must represent at least:

- `CLK`, `RESET*`;
- `AD[31:0]`, `PAR[3:0]`;
- `SPACE[1:0]`, `AS*`, `RD`, `BE[3:0]`, `BLEN[1:0]`, `DS*`, `ACK*`, `ERR*`;
- per-slot `SEL*`, `BR*`, `BG*`;
- odd byte-lane parity;
- 1/4/8/16-longword HOST_DMA bursts;
- WORKER, HOST_DMA, CONTROLLER, and reserved transaction spaces;
- wait, error, timeout, reset, and bus-turnaround states.

The Rust model may use enums/structs for decoded values, but cycle tests must still be able to expose the wire-level state for comparison with Bluespec.

No QDX types belong here.