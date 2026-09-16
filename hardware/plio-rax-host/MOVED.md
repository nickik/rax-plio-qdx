# Synthesizable PLIO host moved

The synthesizable PLIO host controller moved to **`nickik/LightingChips`**.

Authoritative files:

- `rtl/plio/PLIOHostCore.bsv`
- `rtl/plio/PLIOWorkerHost.bsv`
- `rtl/plio/PLIOHostManagerM2.bsv`
- `rtl/plio/PLIOHostDmaM3.bsv`
- host/memory contract documentation: `docs/PLIO-HOST.md`

Move branch/PR: `system-memory-plio-refactor`, LightingChips PR #4.

The files under this directory's `bluespec/` path are compatibility symlinks to `hardware/compat/lightingchips/plio/`. This keeps public RAX CI and the current MainboardFPGA integration buildable without credentials for the private LightingChips repository.

Do not independently edit the mirrored PLIO-host RTL here. Hardware fixes belong in LightingChips first and are then synchronized back here for PLIO/QDX integration tests.

`rax-plio-qdx` remains authoritative for the PLIO/QLI/QDX protocol specifications, card-side hardware, and functional/cycle-level protocol reference models.
