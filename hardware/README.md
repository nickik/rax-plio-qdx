# PLIO hardware/interface validation

This tree isolates hardware-facing PLIO work from QDX and from any particular production host controller.

The reusable peripheral-side stack is:

```text
              PLIO backplane
                   |
              PLIO-TX
       electrical drive/receive,
       wide latches + mux only
                   |
                  PTI
                   |
               PLIO-QIC
          PLIO protocol engine
                   |
                  QLI
          semantic local API
                   |
        future QLI-16 encoding
                   |
          local device logic
```

`NakedCard` is the first integration fixture: Rust PLIO-QIC + the smallest useful QLI endpoint. It deliberately has no QDX behavior.

## Current milestone

QLI semantic v0.1 is frozen from executable Rust behavior.

Completed:

- Rust PLIO logical model;
- Rust QLI semantic types/validation;
- Rust peripheral-side QIC cycle model;
- Rust non-product PLIO test peer;
- Rust NakedDevice and composed NakedCard worker tests;
- QLI worker MMIO, DMA, Notification, parity, timeout, reset, grant-loss and partial-transfer tests;
- Bluespec QLI v0.1 types and validation tests;
- Bluespec NakedDevice with request/response backpressure and reset tests;
- canonical Rust-vs-Bluespec NakedDevice response-vector comparison in CI;
- initial 64-pin QIC / 16-bit local-datapath package and bandwidth study.

Not started deliberately:

- Bluespec QIC state machine;
- QLI-16 physical framing;
- PTI physical framing;
- production host-controller logic;
- QDX behavior.

## Scope

In scope for this tree:

- PLIO logical signal/cycle representation;
- PLIO-E electrical boundary documentation;
- QLI semantic interface;
- PTI QIC-to-transceiver interface;
- QLI-16 pin-level local-interface study;
- PLIO-QIC peripheral-side behavior;
- PLIO-TX electrical-buffer behavior;
- a non-product PLIO testbench peer;
- NakedCard validation;
- Rust architectural/cycle models;
- Bluespec implementation and simulation after each semantic boundary is frozen.

Out of scope for this phase:

- a production PLIO host controller;
- RAX host-controller implementation;
- DMA capability-table implementation on the host side;
- QDX queues, commands, profiles, or device semantics;
- storage/network/graphics device implementations.

## Sources of truth

The normative PLIO protocol remains `../specs/PLIO.md`.

The normative PLIO-E physical profile remains `../specs/PLIO-E.md`.

`qli/SPEC.md` is the frozen QLI v0.1 semantic contract.

Files under this tree define implementation boundaries and test contracts. They MUST NOT silently redefine PLIO. If a test exposes a PLIO protocol ambiguity, fix the normative PLIO spec rather than hiding the difference in an implementation model.

## Model/implementation languages

Rust is the executable reference language for this hardware-interface work. The existing Python simulator is not deleted; migration/reconciliation is tracked in `TODO.md`.

Bluespec SystemVerilog is the preferred high-level hardware source. BSC 2026.01 is pinned in CI for reproducibility. Generated Verilog will later feed Yosys/nextpnr for FPGA work.

## Tests

From this directory:

```sh
make test-rust
make test-bluespec
```

`make test-rust` runs the complete Cargo workspace with all targets.

`make test-bluespec`:

1. compiles and simulates the QLI type tests with Bluesim;
2. compiles and simulates the Bluespec NakedDevice;
3. tests NakedDevice response stability/backpressure and reset cancellation;
4. runs the Rust NakedDevice conformance-vector generator;
5. diffs the Rust and Bluespec canonical response vectors.

When both toolchains are installed:

```sh
make test
```

runs both suites.

## Directory map

- `plio-logical/` -- model-facing view of the existing PLIO logical protocol.
- `plio-e/` -- electrical/backplane implementation boundary; canonical details stay in `specs/PLIO-E.md`.
- `qli/` -- QIC Local Interface semantic contract.
- `pti/` -- PLIO Transceiver Interface between QIC logic and external electrical buffering/latching.
- `qli16/` -- proposed physical 16-bit multiplexed encoding of QLI; intentionally not frozen yet.
- `qic/` -- PLIO-QIC component responsibilities and Rust reference model.
- `plio-tx/` -- PLIO-TX component responsibilities.
- `naked-card/` -- minimal card/device fixture used to validate QLI/QIC behavior.
- `testbench/` -- non-product PLIO peer used instead of implementing a real host controller.
- `trace/` -- common Rust/Bluespec comparison trace contract.
- `plio-rax-host/` -- placeholder only; intentionally deferred.

QDX is intentionally absent from this hardware-validation effort.
