# Mainboard FPGA

This directory is the composition point for a future single-FPGA Lighting/RAX mainboard.

It is intentionally useful before every dependency is stable. The first version wires together the existing PLIO host core, the in-progress memory controller, the Lighting CPU-module memory-bus boundary, eight PLIO/QDX card slots, and a replaceable memory-backend seam. It does **not** collapse those protocols into one bus.

## Intended system shape

```text
                       Lighting CPU board
                              |
                    Lighting Memory Bus
                              |
                    +---------+---------+
                    |   Mainboard FPGA  |
                    |                   |
                    | memory arbiter    |
                    |       |           |
                    | MemoryController  |
                    |       |           |
                    |       +-----------------> pluggable memory backend
                    |                   |        - FPGA BRAM
                    | PLIOHostCore      |        - external SDRAM/SRAM
                    |       |           |        - simulator/file-backed RAM
                    +-------+-----------+
                            |
                 8 physical PLIO/QDX slots
                    |       |       |
                 QDX-B    QDX-G    other cards
```

The slot-facing type is deliberately compatible with the physical-cycle boundary used by `mkQDXBCard`: the board drives `PlioIn` to each card and consumes each card's `BackplaneDrive` result.

## Registered board-cycle boundary

`MainboardFPGA.advance()` is a synchronous FPGA boundary, not a combinational shortcut. Each successful call enqueues one complete physical board-cycle image into a backpressured `mkLFIFOF`. Internal arbitration, memory-controller, and PLIO-host rules consume the oldest queued image on a following FPGA clock and dequeue it only after that image has been processed.

A submitted image is therefore consumed **exactly once**. If the FIFO is full, `advance()` is not ready and the producer must retain its current physical-cycle result until the board can accept it. Processing image N and enqueueing image N+1 in the same FPGA clock is legal; the FIFO keeps those images distinct. If a detailed peripheral model spends many simulator clocks completing one physical card cycle, the mainboard does not replay the previous image while it waits.

Test harnesses must not inspect state written by processing a newly submitted image in the same edge as the `advance()` call. Lighting Memory Bus requests remain level-valid through completion; the board tracks an accepted CPU `REQ` until a later sampled cycle observes it deasserted, preventing the completion cycle from being interpreted as a second transaction through the input pipeline.

## PLIO grant epochs

The mainboard inherits PLIO v0.6 arbitration semantics from the repository-standard `PLIOHostCore`. One continuous `BG[n]` assertion authorizes exactly one manager transaction. When that transaction completes, the host withdraws `BG[n]` and the slot must observe at least one sampled BG-low cycle before a later grant epoch may begin.

A card is explicitly allowed to keep `BR[n]` asserted continuously across that boundary. The mainboard must not wait for BR to fall, synthesize a BR-low gap, or replay/suppress card images to manufacture a grant boundary. Continuous BR simply participates in fresh arbitration after the mandatory BG-low boundary.

The P0 PLIO response smoke specifically proves the registered-board case: the final DMA beat is enqueued and consumed, BG becomes low while BR remains high, and the same slot can subsequently receive a fresh grant.

## Current files

- `bluespec/MainboardFPGA.bsv` — board composition, registered cycle boundary, PLIO-card adaptation, CPU/PLIO memory arbitration, backend seam, host-management pass-through.
- `bluespec/LightingMemoryBusCompat.bsv` — temporary compatibility copy of the small LightingChips memory-bus structures.
- `bluespec/TbMainboardFPGA.bsv` — focused CPU-memory, reset, arbitration, backend and PLIO-DMA composition test.
- `bluespec/TbMainboardQDXBIntegration.bsv` — real `mkQDXBCard` physical-cycle integration test.
- `SPEC.md` — current boundary and deliberate limitations.
- `TODO.md` — work to do as the dependent projects stabilize.

## Deliberate limitations

The current `MemoryController` does not yet carry byte enables. The mainboard therefore accepts only full-word (`BE=0xf`) Lighting-memory transactions and returns `ERROR` for partial accesses rather than silently widening them.

The CPU-visible PLIO host register mapping is also not frozen. `workerValid/workerRequest`, DMA binding, notification configuration, and claim operations remain direct privileged composition methods for now. They are seams, not the eventual software ABI.

The memory cells are *not* instantiated by `mkMainboardFPGA`. A system harness chooses the backend. This is intentional: the same mainboard logic should work with FPGA-local memory, an external memory controller, or a simulation adapter backed by a file/host memory.

## Dependency policy

Mainboard work must track the repository-standard PLIO/QIC implementation rather than copying or pinning private versions. The P0 final review is based directly on current `rax-plio-qdx/main`, including the current PLIO v0.6 grant-epoch fixes.

Do not copy large implementations across repositories. `LightingMemoryBusCompat.bsv` exists only because the cross-repository Bluespec dependency is not stable yet. Once LightingChips exposes a stable shared package, replace the compatibility copy and prove the interfaces are identical.
