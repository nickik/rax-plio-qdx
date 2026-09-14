# PLIO-QIC peripheral-side component contract

The PLIO-QIC is the reusable protocol engine on a peripheral card.

It sits between PTI/PLIO-TX on the backplane side and QLI on the local-device side.

## Responsibilities

- decode and ACK/ERR selected WORKER address phases, then present their data phase as QLI MMIO;
- turn QLI response delay into PLIO wait states and cancel an accepted local MMIO request if the PLIO data phase times out;
- generate PLIO ACK/ERR from QLI completion;
- request bus-manager ownership for outbound DMA/Notification work;
- perform exactly one PLIO transaction per grant;
- hold manager address/control stable until address-phase ACK/ERR/timeout before beginning data;
- turn QLI DMA requests into HOST_DMA address/data phases and bounded 1/4/8/16-word bursts;
- stream DMA data over QLI;
- report partial-transfer completion/errors over QLI;
- turn QLI Notification requests into single-beat CONTROLLER transactions;
- generate/check PLIO odd byte-lane parity;
- detect timeout/protocol errors and return to a safe idle state;
- control PTI output enables so it never drives the shared bus without the appropriate role/ownership.

## Explicit non-responsibilities

The QIC does not implement:

- QDX queues/opcodes/profiles;
- device-specific command interpretation;
- host DMA capability-table lookup/translation;
- host interrupt routing;
- RAX address mapping;
- PLIO electrical drive/receive characteristics.

## Baseline simplifications

- one outstanding local worker-MMIO request;
- one outbound DMA transaction at a time;
- one retained Notification request at a time unless tests prove another tiny queue is required;
- active DMA is never preempted by a Notification;
- after each transaction the grant is released and arbitration must occur again.

The first Rust QIC model should be written against QLI + a non-product testbench peer. Bluespec follows after those traces stabilize.
