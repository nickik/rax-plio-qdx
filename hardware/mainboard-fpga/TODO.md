# Mainboard FPGA TODO

The project is staged around stable hardware boundaries. The mainboard must compose the standard subsystems from this repository; it must not grow private copies of the memory controller, RAM backend, PLIO host, or card implementations.

Current P0 review base: current `rax-plio-qdx/main`, including the PLIO v0.6/QIC grant-epoch fixes. Do not reintroduce the older stacked copies of PLIO host/QIC logic when moving this work forward. `main` already provides the standard `MemoryController` plus the synthesizable 1 MiB `BlockRamBackend`, with `mkDefaultBlockRamBackend` as the system/default FPGA RAM implementation. Mainboard work should consume those modules directly.

Checkboxes below record implemented/proven P0 functionality. **Merge acceptance is intentionally not encoded as another checkbox:** the exact final commit must have `Hardware Rust`, all parallel `Hardware Bluespec` jobs, and all `Mainboard P0 Debug` jobs green after the last source/documentation change.

## Priority order

### P0 — restore a trustworthy board-level regression

Do not start new mainboard features until these isolated gates are green on the same exact final commit.

- [x] Split the broad mainboard regression into independently runnable diagnostic tests.
- [x] Make CI reject `FAIL|...` traces even when Bluesim exits successfully.
- [x] Require an explicit expected `PASS|...` marker for each isolated simulation.
- [x] Preserve compile/run logs as CI artifacts when a mainboard diagnostic fails.
- [x] Add non-intrusive board debug state for arbitration and cycle-boundary diagnosis.
- [x] Replace the overwrite-prone cycle input boundary with a backpressured registered FIFO boundary.
- [x] Correct the documentation to describe the actual `mkLFIFOF` boundary rather than the removed epoch-toggle model.
- [x] Rebase/repin P0 on current `main` so Mainboard uses the repository-standard PLIO v0.6/QIC grant-epoch implementation.
- [x] CPU `BUS_REQ` → retained `BUS_GRANT` minimal test passes.
- [x] CPU write → `MemoryController` backend request → completion minimal test passes.
- [x] CPU read → backend response → CPU `READY/readData` minimal test passes.
- [x] Reset during an outstanding memory request drops stale response state and recovers.
- [x] PLIO DMA → shared `MemoryController` path minimal test passes.
- [x] Final PLIO DMA beat is consumed through the registered FIFO; with BR held high, BG is sampled low before the same slot receives a fresh grant epoch.
- [x] Raw `mkQDXBCard` physical reset-cycle test exists and has passed on the P0 stack.
- [x] Mainboard QLIO slot ↔ `mkQDXBCard` reset-cycle test exists and has passed on the P0 stack.
- [x] Full mainboard ↔ physical QDX-B worker transaction test exists with explicit PASS/FAIL checking and has passed on the P0 stack.
- [x] Full focused mainboard regression is part of the permanent parallel Hardware Bluespec gate and has passed on the P0 stack.
- [x] Existing memory-controller regressions are isolated in their own parallel gate and pass unchanged.
- [x] Full QLI/QIC/Bluespec core regression remains covered by the parallel Hardware Bluespec gate.
- [x] Hardware Rust suite remains a separate gate.
- [x] Cache the pinned BSC toolchain and run independent mainboard/core/memory-controller regressions in parallel to keep the edit→diagnosis loop short.

Debug each failure at the smallest boundary first. Do not change arbitration, memory, and QDX behavior together in one diagnostic patch. Prefer traces and isolated tests before production RTL changes.

## M0 — composition scaffold

- [x] Create a separate `hardware/mainboard-fpga` component.
- [x] Instantiate the existing `PLIOHostCore`.
- [x] Instantiate the existing `MemoryController`.
- [x] Expose eight physical card-cycle ports compatible with the `mkQDXBCard` hardware boundary.
- [x] Add the Lighting Memory Bus compatibility boundary.
- [x] Arbitrate CPU and PLIO DMA onto the same memory controller.
- [x] Preserve the PLIO notification aggregate as the CPU's `plioIrq`.
- [x] Add focused board-level testbenches and diagnostics.

## M1 — standard mainboard memory subsystem

This is the first new implementation work after P0 is green on the exact final review commit.

### M1.1 — adopt the standard default memory backend

- [ ] Import and instantiate the repository-standard `BlockRamBackend`; do not implement RAM locally in `mainboard-fpga`.
- [ ] Default `MainboardFPGA` to the standard 1 MiB integrated backend (`mkDefaultBlockRamBackend`).
- [ ] Wire `MemoryController` ↔ `BlockRamBackend` entirely inside the default board composition.
- [ ] Remove the temporary raw externally-driven backend handshake from the default board interface once the real backend path is proven.
- [ ] Remove any local/fake board-level RAM implementation or configuration that duplicates the standard memory subsystem.
- [ ] Keep fake/reference RAM only where it is useful as test infrastructure; it must not be the production/default board memory path.
- [ ] Prove CPU-side write/read through `MainboardFPGA → MemoryController → 1 MiB BlockRamBackend`.
- [ ] Prove PLIO DMA through the same `MemoryController → 1 MiB BlockRamBackend` path.
- [ ] Verify board reset cancels controller/backend protocol state without clearing integrated RAM contents, matching the standard backend contract.
- [ ] Verify 1 MiB bounds and fault behavior at board level.

### M1.2 — board-level backend configurability

The memory implementation is a board composition choice; CPU and QLIO interfaces must not change when it changes.

- [ ] Define a clean board-level memory-backend composition/configuration seam around the existing `MemoryController` backend contract.
- [ ] Keep 1 MiB integrated BRAM as the default configuration.
- [ ] Allow an external SRAM/SDRAM adapter to replace the BRAM backend without changing CPU/mainboard interfaces.
- [ ] Allow a simulator/file-backed backend to replace the BRAM backend in simulation without changing CPU/mainboard interfaces.
- [ ] Do not duplicate `MemoryController` logic in any backend configuration.
- [ ] Prove architectural traces are identical across supported backends for the same request stream.

### M1.3 — remaining memory semantics

Do this after the real default BRAM path is stable.

- [ ] Extend `MemoryControllerIfc` with byte enables when required by the Lighting memory-bus integration.
- [ ] Remove the temporary `BE=0xf` restriction from the mainboard.
- [ ] Add byte/halfword/unaligned-policy tests matching LightingChips.
- [ ] Define backend fault timing precisely for all backend configurations.

## M2 — physical QLIO / QDX composition

- [ ] Name/freeze the physical slot boundary as the board's QLIO slot interface while retaining compatibility with the existing `mkQDXBCard` physical interface.
- [ ] Define correct empty-slot behavior and test all eight empty slots.
- [ ] Plug one existing `mkQDXBCard` FPGA implementation into slot 0 without adapters that bypass the physical card boundary.
- [ ] Prove `PLIO host → QLIO slot → QDX-B` independently of CPU memory traffic.
- [ ] Prove QDX-B DMA reaches the same standard mainboard memory subsystem.
- [ ] Add reset during active card traffic and active DMA.
- [ ] Add several simultaneous card FPGA models without changing mainboard semantics.

## M3 — stabilize the Lighting board dependency

- [ ] Replace `LightingMemoryBusCompat.bsv` with a shared/pinned LightingChips package.
- [ ] Add a compile-time/interface-equivalence gate before deleting the compatibility copy.
- [ ] Connect an actual Lighting CPU-board FPGA model, not a hand-written bus master.
- [ ] Verify reset, arbitration delay, target error, and lost-grant behavior end-to-end.
- [ ] Add main ROM as a peer Lighting-memory-bus target once the machine address map is frozen.

## M4 — stabilize PLIO host integration

- [ ] Replace direct `workerValid/workerRequest` injection with the final privileged host register block.
- [ ] Map DMA bind/revoke and notification claim/configuration through that register block.
- [ ] Keep the generic PLIO protocol free of Lighting/RAX physical-address policy.
- [ ] Add all eight slots to a multi-card simulation with independent request traffic.
- [ ] Run the same system image with zero, one, and several card FPGA models.

## M5 — FPGA build targets

- [ ] Define a synthesizable top-level pin wrapper for one target FPGA board.
- [ ] Separate simulation-only methods/debug state from the hardware pin boundary.
- [ ] Add clocks/reset synchronizers at the board wrapper, not inside protocol cores.
- [ ] Synthesize the default board with the standard 1 MiB FPGA BRAM backend.
- [ ] Synthesize with an external-memory controller configuration second.
- [ ] Record LUT/FF/BRAM usage and timing.

## M6 — LightingSimulator system composition

Only start after the board hardware composition is independently proven.

- [ ] Provide a manifest/configuration format describing `CPUBoardFPGA`, `MainboardFPGA`, memory-backend selection, and 0–8 card FPGA models.
- [ ] Teach LightingSimulation to instantiate the exact FPGA-derived board/card composition rather than reconstructing the components independently.
- [ ] First configuration: `CPUBoardFPGA + MainboardFPGA + default 1 MiB BRAM + no cards`.
- [ ] Second configuration: add one `QDXBCardFPGA`.
- [ ] Run one guest/software image unchanged across fast models and FPGA-derived models.
- [ ] Later add network/graphics/other QLIO cards without changing mainboard semantics.

## Non-goals / invariants

- Do not merge the Lighting Memory Bus and PLIO/QLIO into one fabric.
- Do not invent a permanent CPU-visible PLIO register ABI before the host-controller project settles.
- Do not hide byte-enable loss by widening accesses.
- Do not create a private mainboard RAM implementation when the standard `BlockRamBackend` already provides it.
- Do not duplicate `MemoryController` logic to support another backend.
- Do not let memory-backend selection alter CPU-side or QLIO-side board interfaces.
- Do not require PLIO BR to deassert between successful manager transactions; grant epochs are bounded by BG, not BR.
- Do not copy whole implementations from LightingChips or LightingSimulation merely to avoid an unstable dependency.
- Do not connect LightingSimulator until `MainboardFPGA` works as an independently verified hardware composition.
