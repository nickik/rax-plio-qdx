# RAX PLIO / QDX

Draft specifications and executable reference models for the RAX **PLIO** peripheral bus and **QDX** queued-device interface, with **QDX-B** block storage as the first profile.

The design target is a late-1970s RAX system. The project deliberately favors a small, synchronous, shared 32-bit I/O bus over later fabric-style designs.

## Documents

- [`specs/PLIO.md`](specs/PLIO.md) — PLIO bus standard.
- [`specs/QDX.md`](specs/QDX.md) — common queued-device model.
- [`specs/QDX-B.md`](specs/QDX-B.md) — block-storage profile.
- [`specs/RAX-INTERRUPTS.md`](specs/RAX-INTERRUPTS.md) — RAX/PLIO interrupt integration.
- [`docs/DESIGN-RATIONALE.md`](docs/DESIGN-RATIONALE.md) — architectural reasoning.
- [`docs/SIMULATION.md`](docs/SIMULATION.md) — simulation strategy.
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — open design decisions and implementation work.
- [`AGENTS.md`](AGENTS.md) — instructions for Codex and other coding agents.

## Current baseline

- 32-bit synchronous shared PLIO bus.
- Central PLIO controller.
- Eight logical slots with geographic MMIO windows.
- Per-slot request/grant and level-triggered normal IRQ.
- Four controller-assigned normal interrupt classes.
- Separate critical platform interrupt outside normal PLIO device service.
- DMA constrained by controller-programmed windows.
- QDX uses one submission queue and one completion queue in v0.1.
- QDX-B supports multiple block namespaces.

## Run the reference model

Requires Python 3.11+ and no third-party dependencies.

```bash
python -m unittest discover -s tests -v
PYTHONPATH=. python -m sim.plio_sim.scenario
```

The current Python model is functional rather than cycle accurate. The next major step is the explicit clock-by-clock PLIO transaction state machine described in `docs/SIMULATION.md`.

## Design rule

This repository does not treat PCI Express, MSI/MSI-X, NVMe, or later interconnects as templates. Later systems may prove that an idea is useful, but every PLIO/QDX mechanism must justify its hardware and protocol cost for the target RAX system.
