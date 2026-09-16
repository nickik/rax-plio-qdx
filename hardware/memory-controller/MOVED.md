# Memory-controller hardware moved

The synthesizable memory-controller implementation moved to **`nickik/LightingChips`**.

Authoritative files:

- `rtl/memory/MemoryController.bsv`
- `rtl/memory/BlockRamBackend.bsv`
- contract documentation: `docs/MEMORY-CONTROLLER.md`

Move branch/PR: `system-memory-plio-refactor`, LightingChips PR #4.

The files under this directory's `bluespec/` path are compatibility symlinks to `hardware/compat/lightingchips/memory/` so the public RAX CI and existing integration tests continue to work without access to the private LightingChips repository.

Do not make new memory-controller RTL changes here. Make them in LightingChips, validate them there, then refresh the compatibility snapshot.

The RAX-side Rust reference/conformance material remains here for now because it is coupled to RAX PLIO reference-model types. It is a test/reference fixture, not the owner of the synthesizable controller.
