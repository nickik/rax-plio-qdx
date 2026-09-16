# Mainboard FPGA TODO

The project is intentionally staged around stable boundaries rather than pretending every dependent block is final.

## M0 — composition scaffold

- [x] Create a separate `hardware/mainboard-fpga` component.
- [x] Instantiate the existing `PLIOHostCore`.
- [x] Instantiate the in-progress `MemoryController`.
- [x] Expose eight physical card-cycle ports compatible with the `mkQDXBCard` boundary.
- [x] Add the Lighting Memory Bus compatibility boundary.
- [x] Arbitrate CPU and PLIO DMA onto the same memory controller.
- [x] Expose the memory-controller backend as a replaceable system seam.
- [x] Preserve the PLIO notification aggregate as the CPU's `plioIrq`.
- [x] Add a focused composition testbench.

## M1 — stabilize memory semantics

- [ ] Extend `MemoryControllerIfc` with byte enables.
- [ ] Remove the temporary `BE=0xf` restriction from the mainboard.
- [ ] Add byte/halfword/unaligned-policy tests matching LightingChips.
- [ ] Define memory-backend reset and fault timing precisely.
- [ ] Add at least one synthesizable FPGA-BRAM backend.
- [ ] Add an external-memory adapter example with wait states.
- [ ] Add a simulator/file-backed backend in the simulator integration layer.
- [ ] Prove all three backends produce the same architectural traces.

## M2 — stabilize the Lighting board dependency

- [ ] Replace `LightingMemoryBusCompat.bsv` with a shared/pinned LightingChips package.
- [ ] Add a compile-time/interface-equivalence gate before deleting the compatibility copy.
- [ ] Connect an actual Lighting CPU-module FPGA model, not a hand-written bus master.
- [ ] Verify reset, arbitration delay, target error, and lost-grant behavior end-to-end.
- [ ] Add main ROM as a peer Lighting-memory-bus target once the machine address map is frozen.

## M3 — stabilize PLIO host integration

- [ ] Replace direct `workerValid/workerRequest` injection with the final privileged host register block.
- [ ] Map DMA bind/revoke and notification claim/configuration through that register block.
- [ ] Keep the generic PLIO protocol free of Lighting/RAX physical-address policy.
- [ ] Add all eight slots to a multi-card simulation with independent request traffic.
- [ ] Run the same system image with zero, one, and several card FPGA models.
- [ ] Add reset during active card traffic and active DMA.

## M4 — FPGA build targets

- [ ] Define a synthesizable top-level pin wrapper for one target FPGA board.
- [ ] Separate simulation-only methods/debug state from the hardware pin boundary.
- [ ] Add clocks/reset synchronizers at the board wrapper, not inside protocol cores.
- [ ] Synthesize with FPGA BRAM first.
- [ ] Synthesize with an external-memory controller second.
- [ ] Record LUT/FF/BRAM usage and timing.

## M5 — system composition

- [ ] Provide a manifest/configuration format describing CPU board, mainboard, memory backend, and 0–8 cards.
- [ ] Teach LightingSimulation to instantiate this exact board/card composition.
- [ ] Run one guest/software image unchanged across fast models and FPGA-derived models.
- [ ] Add QDX-B as the first real card configuration.
- [ ] Later add network/graphics/other QDX cards without changing mainboard semantics.

## Non-goals for the scaffold

- Do not merge the Lighting Memory Bus and PLIO into one fabric.
- Do not invent a permanent CPU-visible PLIO register ABI before the host-controller project settles.
- Do not hide byte-enable loss by widening accesses.
- Do not force the mainboard to contain a particular RAM implementation.
- Do not copy whole implementations from LightingChips or LightingSimulation merely to avoid an unstable dependency.
