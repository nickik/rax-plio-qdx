# LightingChips compatibility snapshot

The synthesizable **system memory controller** and **PLIO host controller** are now owned by the private `nickik/LightingChips` repository.

This directory is a public-CI compatibility snapshot so `rax-plio-qdx` can continue to build and test mainboards and PLIO cards without requiring credentials for the private repository. It is not an independent implementation.

Authoritative destinations:

- `LightingChips/rtl/memory/MemoryController.bsv`
- `LightingChips/rtl/memory/BlockRamBackend.bsv`
- `LightingChips/rtl/plio/PLIOHostCore.bsv`
- `LightingChips/rtl/plio/PLIOWorkerHost.bsv`
- `LightingChips/rtl/plio/PLIOHostManagerM2.bsv`
- `LightingChips/rtl/plio/PLIOHostDmaM3.bsv`

Initial move: LightingChips PR #4, branch `system-memory-plio-refactor`.
The imported hardware behavior is based on `rax-plio-qdx` commit `4e1c07e23738630ec50a05ffdbc08fc78c936b58`.

The old BSV paths are symlinks into this snapshot so existing RAX test/build paths remain stable. Future synthesizable-host or memory-controller fixes must be made in LightingChips first, then deliberately synchronized here with integration/equivalence validation.

PLIO/QLI/QDX protocol specifications and the protocol/reference models remain authoritative in `rax-plio-qdx`.
