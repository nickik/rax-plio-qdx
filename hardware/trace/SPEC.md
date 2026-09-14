# PLIO-QIC differential trace format v1

This format is the canonical Rust/Bluespec cycle-comparison record for the abstract QIC core.

It is intentionally textual, deterministic, and line-oriented so the same scenarios can be emitted by Rust, Bluesim, generated-Verilog testbenches, and later FPGA capture tools.

## Record shape

Each sampled PLIO clock produces exactly one line:

```text
TRACE|v1|c=00000000|pi=<PLIO-input>|qi=<QLI-input>|po=<PLIO-output>|qo=<QLI-output>|ev=<event>
```

Rules:

- ASCII only.
- No spaces.
- Fields occur in exactly the order above.
- `c` is an eight-digit lowercase hexadecimal cycle number.
- Multi-bit numeric values are lowercase hexadecimal with fixed width.
- Booleans are `0` or `1`.
- Optional bus values use a leading valid bit followed by the fixed-width value. Invalid payload bits MUST be printed as zero so traces are canonical.
- `ev` is a stable symbolic event name used for diagnostics; wire/QLI fields remain authoritative.

## PLIO input image (`pi`)

Field order:

```text
rst,sel,bg,ad_v,ad[31:0],par_v,par[3:0],space_v,space[1:0],as,rd,be[3:0],blen[1:0],ds,ack,err
```

Canonical text form:

```text
rst.sel.bg.ad_v.ad8.par_v.par1.space_v.space1.as.rd.be1.blen1.ds.ack.err
```

## QLI input image (`qi`)

Field order:

```text
mmio_ready,mmio_resp_v,mmio_resp_kind,mmio_resp_data,
dma_req_v,dma_dir,dma_addr,dma_words,
dma_read_ready,dma_write_v,dma_write_data,dma_completion_ready,
notification_v,notification_channel
```

Invalid payload values print zero.

## PLIO output image (`po`)

Field order:

```text
br,ad_v,ad[31:0],par_v,par[3:0],space_v,space[1:0],as,rd,be[3:0],blen[1:0],ds,ack,err
```

## QLI output image (`qo`)

Field order:

```text
reset,mmio_req_v,mmio_addr,mmio_write,mmio_be,mmio_wdata,mmio_resp_ready,mmio_cancel,
dma_req_ready,dma_read_v,dma_read_data,dma_write_ready,dma_comp_v,dma_comp_status,dma_comp_words,
notification_ready
```

## Event names

The initial stable diagnostic vocabulary is:

```text
idle
reset
worker_address
worker_data
manager_request
manager_address
dma_data
dma_complete
notification_data
fault
```

Adding event names alone does not change the version. Changing field order or encoding requires `v2`.

## Sampling rule

A trace line represents values visible during one PLIO clock interval immediately before the state update at the active PLIO clock edge. Rust and Bluespec testbenches therefore:

1. construct/apply PLIO and QLI inputs;
2. sample QIC combinational outputs;
3. emit one trace line;
4. advance one QIC clock/state transition.

This matches the Rust `drive()` then `clock()` reference model and is mandatory for differential tests.

## Phase-0 formatter vector

Before the Bluespec QIC exists, both languages emit this exact line to prove byte-for-byte formatter compatibility:

```text
TRACE|v1|c=0000002a|pi=0.1.0.1.00000100.1.7.1.0.1.1.f.0.0.0.0|qi=1.0.0.00000000.0.0.00000000.0.1.0.00000000.1.0.0|po=0.0.00000000.0.0.0.0.0.0.0.0.0.0.0|qo=0.0.00000000.0.0.00000000.0.0.0.0.00000000.0.0.0.00.0|ev=worker_address
```

CI compares Rust and Bluespec output byte-for-byte after normalizing line endings only.
