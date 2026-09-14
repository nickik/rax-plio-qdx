# PLIO hardware/interface validation

This tree isolates the hardware-facing PLIO work from QDX and from any particular host controller.

The immediate objective is to specify and validate the reusable peripheral-side stack:

```text
PLIO logical protocol
        |
PLIO-E electrical/backplane
        |
PLIO-TX electrical buffer block
        |
PTI -- QIC/transceiver logic-level interface
        |
PLIO-QIC protocol engine
        |
QLI -- semantic local interface
        |
QLI-16 -- optional historical pin-level encoding
        |
NakedDevice / later real device logic
```

`NakedCard` is the first integration fixture. It will compose a PLIO-QIC with the smallest useful QLI endpoint and deliberately has no QDX behavior.

## Scope

In scope now:

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
- Bluespec implementations/tests after the semantic contracts are stable.

Out of scope for this phase:

- a production PLIO host controller;
- RAX host-controller implementation;
- DMA capability-table implementation on the host side;
- QDX queues, commands, profiles, or device semantics;
- storage/network/graphics device implementations.

## Sources of truth

The normative PLIO protocol remains `../specs/PLIO.md`.

The normative PLIO-E physical profile remains `../specs/PLIO-E.md`.

Files under this tree define implementation boundaries and test contracts. They MUST NOT silently redefine PLIO. If a test exposes a protocol ambiguity, fix the normative spec first.

## Model/implementation languages

Rust is the executable reference language for this hardware-interface work. The existing Python simulator is not deleted; migration/reconciliation is tracked in `TODO.md`.

Bluespec SystemVerilog is the preferred high-level hardware source for the QIC and small test components. Generated Verilog is a build artifact and should feed Yosys/nextpnr for FPGA work.

## Directory map

- `plio-logical/` -- model-facing view of the existing PLIO logical protocol.
- `plio-e/` -- electrical/backplane implementation boundary; canonical details stay in `specs/PLIO-E.md`.
- `qli/` -- QIC Local Interface semantic contract.
- `pti/` -- PLIO Transceiver Interface between QIC logic and external electrical buffering.
- `qli16/` -- proposed pin-level 16-bit multiplexed encoding of QLI; intentionally not frozen yet.
- `qic/` -- PLIO-QIC component responsibilities.
- `plio-tx/` -- PLIO-TX component responsibilities.
- `naked-card/` -- minimal card/device fixture used to validate QLI/QIC behavior.
- `testbench/` -- non-product PLIO peer used instead of implementing a real host controller.
- `trace/` -- common Rust/Bluespec comparison trace contract.
- `plio-rax-host/` -- placeholder only; intentionally deferred.

QDX is intentionally absent from this tree.