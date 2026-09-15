# QDX-A card signal groups

**Status:** board-level grouping; exact package pin numbers deferred

This file freezes which signals cross each chip boundary. It is not yet a mechanical connector/package pin assignment.

## PLIO-E connector -> PLIO-TX

The card uses the existing PLIO-E/PLIO electrical definition. PLIO-TX is the only chip permitted to attach directly to shared PLIO electrical groups.

Board routing groups:

- `AD[31:0]` + parity;
- PLIO transaction control;
- ACK/ERR response pair;
- BR request;
- BG grant;
- SEL;
- PLIO clock;
- card reset;
- power/ground.

The exact PLIO-E connector mapping remains canonical in `specs/PLIO-E.md`.

## PLIO-TX <-> QIC: PTI

Frozen logical package budget:

```text
PTD[17:0]       18
PT_KIND[1:0]     2
PT_STB           1
PT_DIR           1
TX_DRIVE         1
RESP_DRIVE       1
PT_ACK/PT_ERR     2
CLK RESET SEL
BG BR             5
-------------------
PTI              31 pins
```

No QDX or endpoint signal is routed across this boundary.

## QIC <-> QDX-A: QLI-16

The board carries:

```text
LD[15:0]       16   bidirectional token payload
LTYPE[2:0]      3   token type
LREQ            1   producer-valid
LACK            1   consumer-accept
LDIR            1   0=QIC->QDX-A, 1=QDX-A->QIC
-----------------------------------------------
                  22 signal pins
```

`LRESET` is distributed from board reset and therefore does not need to consume an additional dedicated inter-chip package pin in the first package budget.

Rules:

- QIC and QDX-A never exchange semantic sideband signals outside QLI-16;
- payload/type/direction remain stable while `LREQ` is asserted without `LACK`;
- direction turnaround requires the QLI-16 idle/turnaround behavior already defined in the QLI-16 specification;
- Notification request and completion use the directional `NOTIFICATION` token semantics already frozen.

## QDX-A <-> endpoint/profile logic

This connection is intentionally not frozen as a PCB pinout yet. The first card uses a validation endpoint implemented as local board logic.

The semantic boundary is:

```text
QdxCommand[32 bytes]      QDX-A -> endpoint
COMMAND_VALID
COMMAND_READY

QdxCompletion[16 bytes]   endpoint -> QDX-A
COMPLETION_VALID
COMPLETION_READY

RESET
```

A later QDX-B card may place endpoint/profile logic in another ASIC, a local processor subsystem, or glue logic. That later choice must not alter the QIC<->QDX-A QLI-16 boundary.

## Clock/reset distribution

```text
PLIO CLK ----------------+--> PLIO-TX
                         +--> QIC
                         +--> local phase/timing generation
                         +--> QDX-A timing domain (first model)

CARD RESET --------------+--> PLIO-TX
                         +--> QIC
                         +--> QLI-16 link state
                         +--> QDX-A
                         +--> endpoint/profile logic
```

The first board model assumes synchronous digital distribution. Electrical skew and clock-buffer implementation are deferred.

## Power concept

The digital model assumes common card logic rails and common ground. Exact rail voltages, current budget, regulator/decoupling placement and package-specific supply pins are deferred to a later electrical PCB specification.
