# PLIO QIC iCE40 Reference Implementation TODO

## Purpose

Build a small, synthesizable FPGA reference implementation of the **PLIO bus-interface logic** that a late-1970s custom QDX/PLIO interface IC could provide.

The FPGA project is a hardware reference and conformance vehicle, not a change to the architecture. **PLIO terminates at the QIC; QDX remains above PLIO.** A QDX device engine connects to the QIC through a deliberately simple local interface.

The implementation should preserve the repository's 1978-class architectural constraints even though it runs on a modern iCE40 FPGA.

## Design goals

- [ ] Implement the PLIO-5 baseline at **5 MHz** first.
- [ ] Keep PLIO-10 as a later timing target without changing the baseline RTL interface.
- [ ] Keep the QIC small enough that its structure remains plausible as a late-1970s NMOS/ULA/custom-logic design.
- [ ] Do not use FPGA-only architectural features to hide complexity that would have required substantial 1978 silicon.
- [ ] Keep large buffers and tables external to the conceptual QIC unless there is a strong reason otherwise.
- [ ] Keep physical backplane line drivers/receivers outside the conceptual QIC boundary.
- [ ] Make the RTL trace-comparable to the Python cycle-level PLIO model.
- [ ] Treat the Python cycle model and normative PLIO specification as the behavioral reference.

## Phase 0 — prerequisites / architecture freeze

Do not freeze RTL behavior until these PLIO simulator items are complete enough to serve as a golden model.

- [ ] Explicit `SPACE` / address / data phase machine exists in the Python model.
- [ ] Bus request/grant behavior is modeled.
- [ ] Rotating round-robin arbitration is modeled at the controller side.
- [ ] Mandatory re-arbitration after each transaction/burst is modeled.
- [ ] 1/4/8/16-longword DMA bursts are modeled cycle-by-cycle.
- [ ] Per-beat ACK / ERR / wait behavior is modeled.
- [ ] Timeout behavior is modeled.
- [ ] `SPACE=CONTROLLER` PLIO Notification is modeled as a real single-beat transaction.
- [ ] Active-burst DMA revoke/interlock semantics are frozen.
- [ ] PLIO-5 clock/timing assumptions are frozen sufficiently for RTL.
- [ ] PLIO-E electrical pin directions and active levels needed by RTL are frozen.

## Phase 1 — repository/tool flow

Create a self-contained open-source iCE40 build flow.

- [ ] Add `rtl/` directory.
- [ ] Add `rtl/plio_qic/` for reusable QIC RTL.
- [ ] Add `rtl/boards/` for board-specific wrappers only.
- [ ] Add `rtl/tb/` for RTL testbenches if needed in addition to Python-driven tests.
- [ ] Add `fpga/ice40/` for constraints, build scripts, and bitstream targets.
- [ ] Use synthesizable SystemVerilog with a conservative subset supported by Yosys.
- [ ] Add Yosys synthesis flow.
- [ ] Add nextpnr-ice40 place-and-route flow.
- [ ] Add Project IceStorm bitstream generation.
- [ ] Add a single command such as `make ice40` or equivalent.
- [ ] Add `make synth` target that reports logic-cell, FF, RAM, and maximum-frequency estimates.
- [ ] Add `make rtl-test` target.
- [ ] Add generated build products to `.gitignore`.
- [ ] Document exact open-source tool dependencies and supported versions/ranges.
- [ ] Ensure simulation tests do not require an FPGA board.

## Phase 2 — define the conceptual QIC boundary

The QIC should terminate PLIO and expose a simpler local device-side interface.

- [ ] Define PLIO-facing ports directly from the normative PLIO signal set.
- [ ] Define a local worker request/response interface for MMIO accesses.
- [ ] Define a local DMA-request interface allowing the device engine to request protected host-memory transfers.
- [ ] Define a local PLIO Notification request interface.
- [ ] Define reset and device-fault interface.
- [ ] Define status/error reporting.
- [ ] Keep QDX SQ/CQ parsing **outside** the QIC.
- [ ] Keep block, network, graphics, and DSP command semantics **outside** the QIC.
- [ ] Document which functions are expected to have been on the hypothetical late-1970s custom IC versus external RAM/transceivers.

Suggested conceptual split:

```text
                   PLIO backplane
                        |
                external transceivers
                        |
                 +--------------+
                 |   PLIO QIC   |
                 |--------------|
                 | bus protocol |
                 | arbitration* |
                 | DMA sequencer|
                 | notification |
                 | error logic  |
                 +------+-------+
                        |
                 simple local IF
                        |
                 +------+-------+
                 | QDX/device   |
                 | engine       |
                 +--------------+

* Worker-side QIC implements request/grant participation; central arbitration
  remains in the PLIO host controller.
```

## Phase 3 — worker-side QIC MVP

Implement the reusable interface that would live on a normal PLIO card.

### Reset and identity

- [ ] Deterministic reset state.
- [ ] No bus drive before reset release and valid grant/state.
- [ ] Slot identity supplied externally or by board wrapper as required by PLIO-E.
- [ ] Expose implementation/version ID only through non-normative debug logic unless specified by PLIO.

### Arbitration participation

- [ ] Bus request generation.
- [ ] Grant acceptance.
- [ ] Never start a transaction without a valid grant.
- [ ] Release ownership after exactly one PLIO transaction/burst.
- [ ] Verify mandatory re-arbitration after every transaction.
- [ ] Assertions for illegal drive without grant.

### Worker MMIO

- [ ] Decode `SPACE=WORKER` transaction directed at the local slot.
- [ ] Present slot-relative worker address to the local interface.
- [ ] Implement read response.
- [ ] Implement write acceptance.
- [ ] Implement local wait insertion.
- [ ] Implement local worker error response.
- [ ] Verify programmed MMIO remains single-beat.

### Host-memory DMA

- [ ] Generate `SPACE=HOST_DMA` transactions.
- [ ] Support 1-longword burst.
- [ ] Support 4-longword burst.
- [ ] Support 8-longword burst.
- [ ] Support 16-longword burst.
- [ ] Carry the 32-bit device-visible DMA handle/address unchanged as specified.
- [ ] Increment sequential burst offsets correctly.
- [ ] Stop after the granted bounded transaction.
- [ ] Handle per-beat wait states.
- [ ] Handle per-beat ERR.
- [ ] Handle timeout/abort indication from the bus contract.
- [ ] Report completion/failure to the local device engine.
- [ ] Do not implement page-table walking or a modern IOMMU in the QIC.

### PLIO Notification

- [ ] Generate `SPACE=CONTROLLER` PLIO Notification writes.
- [ ] Support all baseline notification offsets/channels once frozen.
- [ ] Keep notification writes single-beat.
- [ ] Queue or backpressure a local notification request while the worker is waiting for a grant.
- [ ] Verify that source identity is not supplied as trusted device data.
- [ ] Verify a notification cannot encode an arbitrary CPU vector or host physical address.

### Error handling

- [ ] Detect illegal/unexpected PLIO phase ordering.
- [ ] Detect transaction timeout.
- [ ] Return the QIC to an idle/recoverable state after an error.
- [ ] Expose sticky diagnostic error state to the local device engine or debug interface.
- [ ] Add assertions preventing simultaneous incompatible drive states.

## Phase 4 — PLIO host-controller reference RTL

A worker QIC alone cannot test a real shared bus. Add a minimal controller-side RTL reference separately from the reusable worker chip.

- [ ] Implement 8-slot request/grant inputs/outputs.
- [ ] Implement rotating round-robin arbitration.
- [ ] Grant at most one transaction at a time.
- [ ] Force re-arbitration after every single-beat transaction or bounded burst.
- [ ] Decode PLIO transaction spaces.
- [ ] Implement worker-slot MMIO routing.
- [ ] Implement protected host-DMA capability validation.
- [ ] Implement 16 DMA capability channels per slot.
- [ ] Validate source slot + channel + generation + offset + complete length + direction before beat 0.
- [ ] Implement active-burst revoke/interlock behavior exactly as frozen in the spec.
- [ ] Implement controller-local PLIO Notification pending state.
- [ ] Implement timeout/error termination.
- [ ] Keep RAX CPU physical-address mapping in a separate RAX wrapper/profile module.

## Phase 5 — simulation and conformance

### Golden-trace comparison

- [ ] Define a machine-readable PLIO transaction trace format shared by Python and RTL tests.
- [ ] Run identical transaction scenarios against the Python cycle model and RTL.
- [ ] Compare arbitration decisions.
- [ ] Compare bus phase ordering.
- [ ] Compare burst lengths and beat addresses.
- [ ] Compare waits/timeouts/errors.
- [ ] Compare PLIO Notification timing.
- [ ] Compare reset/recovery behavior.

### Required test scenarios

- [ ] Single worker MMIO read.
- [ ] Single worker MMIO write.
- [ ] Worker-inserted wait states.
- [ ] Worker error response.
- [ ] 1-beat DMA read/write.
- [ ] 4-beat DMA read/write.
- [ ] 8-beat DMA read/write.
- [ ] 16-beat DMA read/write.
- [ ] Maximum burst followed by waiting notification.
- [ ] Two workers contending for the bus.
- [ ] All 8 workers continuously contending.
- [ ] Verify rotating fairness.
- [ ] Verify no worker retains the bus across transactions.
- [ ] Invalid DMA channel.
- [ ] Stale DMA generation.
- [ ] DMA range overrun.
- [ ] Wrong-direction DMA.
- [ ] Revocation before transaction.
- [ ] Revocation during active burst.
- [ ] Bus timeout.
- [ ] Reset while idle.
- [ ] Reset while requesting.
- [ ] Reset/recovery after bus fault.

### Formal/lightweight property checks

Where practical with the open-source flow:

- [ ] At most one bus driver/master is active at a time in the test system.
- [ ] A worker never drives a transaction without grant.
- [ ] A grant cannot cover more than one transaction.
- [ ] A DMA burst never exceeds 16 longwords.
- [ ] MMIO is never converted into a burst.
- [ ] PLIO Notification is always single-beat.
- [ ] No DMA data beat occurs before complete-range validation succeeds.
- [ ] A revoked mapping cannot authorize a later beat/new burst contrary to the frozen revoke semantics.
- [ ] Reset always returns bus outputs to safe inactive state.

## Phase 6 — iCE40 hardware target

Start with a board/device that provides enough GPIO to exercise the logical interface without pretending its 3.3 V pins are the final PLIO electrical layer.

- [ ] Select the first iCE40 development board/device.
- [ ] Prefer abundant GPIO and easy logic-analyzer access over minimum FPGA size for the first hardware target.
- [ ] Keep the reusable QIC independent of board-specific pin mappings.
- [ ] Add board constraint file.
- [ ] Generate a stable 5 MHz PLIO test clock from the board clock or use an external clock input.
- [ ] Add external/loopback test wrapper representing PLIO transceivers.
- [ ] Add visible heartbeat/error indication for board bring-up only.
- [ ] Verify synthesis and place/route at 5 MHz with substantial timing margin.
- [ ] Record logic-cell/FF/RAM use.
- [ ] Record maximum post-route clock estimate, but do not change the architectural PLIO clock from FPGA results alone.

## Phase 7 — physical two-node / multi-node test rig

- [ ] Design a safe low-voltage FPGA test interconnect; do not directly claim it is PLIO-E electrical conformance.
- [ ] Connect one controller FPGA to one worker QIC FPGA.
- [ ] Exercise MMIO transactions in hardware.
- [ ] Exercise all DMA burst lengths in hardware.
- [ ] Exercise PLIO Notification in hardware.
- [ ] Inject wait states.
- [ ] Inject errors/timeouts.
- [ ] Capture bus waveforms with a logic analyzer.
- [ ] Add a second worker and verify arbitration.
- [ ] Expand to enough workers to stress fairness if practical.
- [ ] Compare captured transaction traces with simulator traces.

## Phase 8 — QDX demonstration behind the QIC

Only after the PLIO QIC is stable, add a small QDX engine to prove that QDX composes cleanly above it.

- [ ] Implement minimal one-SQ/one-CQ QDX device engine behind the local QIC interface.
- [ ] Use canonical little-endian QDX structures.
- [ ] Implement a tiny RAM-backed QDX-B block device.
- [ ] Fetch a submission entry by PLIO DMA.
- [ ] Execute READ/WRITE against FPGA-local block RAM or a simulation backing store.
- [ ] Write a completion entry by PLIO DMA.
- [ ] Generate PLIO Notification after completion.
- [ ] Verify the QDX engine contains no PLIO electrical/arbitration assumptions.
- [ ] Verify the QIC contains no QDX opcode/queue semantics.

## Phase 9 — historical implementation accounting

Use FPGA synthesis as a correctness tool, not as a direct 1978 transistor-count estimate.

- [ ] Produce a conceptual gate/register/RAM inventory for the QIC.
- [ ] Separate logic that maps plausibly to late-1970s NMOS/custom logic from FPGA-specific infrastructure.
- [ ] Estimate external SRAM required for buffering/state.
- [ ] Estimate external bipolar transceivers required for a real PLIO-E implementation.
- [ ] Identify logic that could be split into two ULAs if a single late-1970s die is too ambitious.
- [ ] Define a hypothetical `QIC-1` 5 MHz NMOS implementation target.
- [ ] Keep optional 10 MHz support out of the historical baseline until the 5 MHz design is characterized.

## CI

- [ ] Run RTL lint/syntax checks on every change.
- [ ] Run RTL simulation/conformance tests on every change.
- [ ] Run iCE40 synthesis in CI.
- [ ] Run nextpnr timing check for the 5 MHz target in CI.
- [ ] Fail CI if the reference QIC no longer meets 5 MHz.
- [ ] Publish utilization/timing summary in CI logs.
- [ ] Do not require physical FPGA hardware for CI.

## Definition of first success

The first useful milestone is reached when:

- [ ] one controller RTL instance and one worker QIC instance run at a modeled 5 MHz;
- [ ] worker MMIO read/write works;
- [ ] 1/4/8/16-longword protected DMA transactions work;
- [ ] PLIO Notification works;
- [ ] waits, errors, timeout, and reset are tested;
- [ ] RTL traces match the Python cycle model for the same scenarios;
- [ ] the worker QIC synthesizes and routes successfully for an iCE40 target with comfortable 5 MHz timing margin;
- [ ] a minimal QDX-B RAM-disk demo can operate behind the QIC without QDX logic leaking into the PLIO QIC.
