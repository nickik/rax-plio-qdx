# Mainboard FPGA roadmap

The active pre-merge verification plan is
[`docs/MAINBOARD-M6-TODO.md`](../../docs/MAINBOARD-M6-TODO.md). M6.1 through
M6.5 must be green on one exact SHA before any work below begins. The older
P0/M0/M1 numbering duplicated completed diagnostics and conflicted with that
plan; it is intentionally retired.

## Post-M6 hardware composition

### H1 — standard board memory

- [ ] Make the repository-standard 1 MiB `BlockRamBackend` the default
  synthesizable Mainboard composition behind `MemoryController`.
- [ ] Keep fake RAM only in test infrastructure.
- [ ] Define the elaboration-time backend seam for SRAM/SDRAM/file-backed
  simulation without changing CPU or PLIO interfaces.
- [ ] Prove reset, bounds, faults, and architectural traces across backends.

### H2 — physical card composition

- [ ] Freeze the eight-slot QLIO boundary compatible with `mkQDXBCard`.
- [ ] Prove empty slots, one real QDX-B, shared DMA memory, and reset during
  active card/DMA traffic.
- [ ] Scale to several card FPGA models without changing Mainboard semantics.

### H3 — real CPU-board boundary

- [ ] Replace the synthetic M6 CPU master with the Lighting Compute Board at
  the existing `LightingBusMasterDrive` boundary.
- [ ] Pin the shared LightingChips interface package and add equivalence
  checks before removing the compatibility copy.
- [ ] Verify grant delay, faults, reset, and PLIO IRQ end-to-end.

### H4 — privileged PLIO host control

- [ ] Replace testbench worker injection with the final privileged host
  register block.
- [ ] Expose DMA bind/revoke and notification claim/configuration there,
  without adding RAX address policy to generic PLIO.

### H5 — physical FPGA target

- [ ] Add a synthesizable pin wrapper with board-level clocks and reset
  synchronization.
- [ ] Build default BRAM and external-memory variants; record timing and
  LUT/FF/BRAM usage.

### H6 — LightingSimulation composition

- [ ] Describe CPU board, Mainboard, memory backend, and 0–8 card models in
  one manifest.
- [ ] Run unchanged guest images on fast and FPGA-derived compositions.

## Invariants

- No private Mainboard RAM or duplicate `MemoryController` implementation.
- Memory-backend selection must not alter CPU or QLIO interfaces.
- No Mainboard RMW/hidden shadow memory; backend owns byte merging.
- Do not begin H1–H6 until M6.1–M6.5 are frozen and merged.
