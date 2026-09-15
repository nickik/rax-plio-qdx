# NakedCard physical validation

This branch upgrades NakedCard from the semantic QLI fixture to the complete first card-interface tower:

```text
PLIO backplane
      |
   PLIO-TX
      | PTI
     QIC
      |
  QLI-16 pins
      |
 NakedDevice / protocol probe
```

`NakedDevice` remains deliberately worker-only. DMA and Notification coverage uses a separate protocol-probe endpoint so the basic configuration fixture does not acquire product/device semantics merely for testing.

## Required success paths

The physical fixtures cover:

- worker configuration read through QLI-16 request and response messages;
- worker `DEVICE_CONTROL` write;
- unsupported worker offset returning PLIO ERR;
- DEVICE_TO_HOST DMA at 1/4/8/16 words;
- HOST_TO_DEVICE DMA at 1/4/8/16 words;
- Notification request plus opposite-direction QLI-16 completion;
- PLIO data/parity generated and consumed through PLIO-TX;
- PTI direction changes through IDLE;
- QLI-16 direction changes through an idle local slot.

## Fault ladder

The executable Rust full-stack suite additionally exercises target BusError partial progress, bad incoming parity, malformed QLI-16 and reset safety. Existing QIC phase regressions remain the exhaustive oracle for 256-cycle PLIO timeout, BG loss, manager wait-state and MMIO-cancel corner cases; the integration workflow runs those regressions before the physical fixtures.

A later randomized integration phase may duplicate every QIC fault injection at the complete pin-level tower. The current milestone is considered complete when the deterministic Rust/Bluesim QLI-16 trace is exact and both full-stack Bluesim fixtures pass without PTI or QLI-16 protocol faults.
