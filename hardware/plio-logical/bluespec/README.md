# Bluespec PLIO logical representation

Planned contents:

- wire-level PLIO types;
- decoded transaction-space/burst enums;
- parity helpers;
- trace conversion helpers.

Do not implement a production host controller here. The first BSV consumer should be the peripheral-side QIC plus the non-product testbench peer.
