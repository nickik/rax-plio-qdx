# PLIO-QIC peripheral-side component contract

The PLIO-QIC is the reusable protocol engine on a peripheral card.

It sits between PTI/PLIO-TX on the backplane side and QLI on the local-device side.

## Responsibilities

- decode and ACK/ERR selected WORKER address phases, then present their data phase as QLI MMIO;
- turn QLI response delay into PLIO wait states and cancel an accepted local MMIO request if the PLIO data phase times out;
- generate PLIO ACK/ERR from QLI completion;
- request bus-manager ownership for outbound DMA/Notification work;
- perform exactly one PLIO transaction per grant epoch;
- hold manager address/control stable until address-phase ACK/ERR/timeout before beginning data;
- turn QLI DMA requests into HOST_DMA address/data phases and bounded 1/4/8/16-word bursts;
- stream DMA data over QLI;
- report partial-transfer completion/errors over QLI;
- turn QLI Notification requests into single-beat CONTROLLER transactions;
- generate/check PLIO odd byte-lane parity;
- detect timeout/protocol errors and return to a safe idle state;
- control PTI output enables so it never drives the shared bus without the appropriate role/ownership.

## Pending manager work and worker preemption

An accepted QLI DMA or Notification request becomes **pending manager work** while the QIC asserts `BR` and waits for `BG`.

`BR` is only a request for a future grant. It is not ownership of the bus. Therefore, while pending manager work has not yet consumed a `BG` grant epoch, the host may select the same card for a WORKER transaction. In that case the QIC MUST:

1. retain the exact accepted manager request;
2. continue to represent that manager work as pending;
3. service the selected WORKER transaction without driving manager address/data signals;
4. restore the retained manager request to the bus-request state when the WORKER transaction completes; and
5. wait for a valid `BG` before beginning the manager address phase.

Restoring pending manager work is **not** a grant and does not authorize reuse of an old `BG` assertion.

Once a manager transaction has begun under a grant epoch, ordinary WORKER MMIO MUST NOT overlap that active manager transaction. Active DMA is also never preempted by a Notification.

A special local-tail case exists after the final physical PLIO DMA beat has completed but QLI still has a buffered host-to-device word or DMA-completion handshake to retire. No manager bus transaction remains active at that point. The QIC MAY suspend that purely local tail to service WORKER MMIO and then restore the exact local-tail state. This does not extend or reuse the completed grant epoch.

## Grant-epoch rules

The PLIO controller, not the QIC, drives `BG`. A continuous assertion of `BG` is one grant epoch and authorizes at most one manager transaction.

After a manager transaction completes, the controller MUST deassert `BG` regardless of whether the QIC keeps `BR` asserted. The QIC MAY keep `BR` asserted when more manager work is pending. Continuous `BR` does not extend the completed grant.

The QIC MUST NOT originate a second manager address phase until `BG` has been observed deasserted and a later grant epoch has begun. In implementation terms, any `grant_used`/equivalent latch is cleared only by observing `BG` low, not by completion of local QLI work.

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
- after each manager transaction the grant epoch ends and arbitration must occur again, even if `BR` remains asserted.

The Rust and Bluespec QIC implementations are required to implement the same cycle-visible PLIO/QLI semantics. Differential traces are the conformance oracle for behavior shared by the two implementations.
