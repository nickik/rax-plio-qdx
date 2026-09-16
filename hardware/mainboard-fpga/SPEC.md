# Mainboard FPGA v0.1 composition specification

**Status:** experimental composition boundary. The dependent PLIO host, memory controller, and Lighting CPU-board interfaces are still evolving.

## 1. Scope

The Mainboard FPGA is the machine-side integration point between:

1. one Lighting CPU-module memory-bus master;
2. the RAX/Lighting PLIO host controller;
3. eight PLIO/QDX physical card-cycle ports;
4. one host-memory controller; and
5. one replaceable memory backend.

PLIO remains a peripheral bus. The Lighting Memory Bus remains the processor/memory bus. This module MUST NOT make CPU memory traffic into ordinary PLIO card traffic.

## 2. Lighting CPU-module boundary

The CPU side follows Lighting Memory Bus v0.1 semantics:

- `BUS_REQ` requests ownership and remains asserted through the transfer;
- `BUS_GRANT` grants ownership;
- the CPU asserts `REQ` only after observing `BUS_GRANT`;
- `REQ` and the payload remain stable until completion;
- `ADDR`, `WRITE_DATA`, `BE`, and `WRITE` form the payload;
- `READY` completes successfully;
- `ERROR` completes unsuccessfully;
- `READ_DATA` is meaningful on a successful read.

The mainboard MUST retain a CPU grant between the `BUS_REQ` arbitration cycle and the later `REQ` cycle. Once `REQ` is accepted, it MUST retain CPU ownership until the memory-controller response completes. A newly arriving PLIO DMA request MUST NOT steal either a held CPU grant or an active CPU transfer.

If a malformed/test master drops `BUS_REQ` before asserting `REQ`, the mainboard may cancel the unused grant so PLIO cannot be deadlocked indefinitely. The real Lighting `ModuleBusAdapter` does not do this during a normal transaction.

Because `advance()` is registered, a completed CPU `REQ` sample can still be present in the input pipeline on the cycle in which `READY`/`ERROR` becomes externally visible. The mainboard MUST remember that the request was already accepted and MUST NOT accept it again. It rearms CPU request acceptance only after a subsequently processed cycle observes `REQ=0`.

### Temporary byte-enable restriction

The current in-repository `MemoryControllerIfc.hostRequest` accepts only `(write, address, writeData)` and therefore cannot preserve arbitrary `BE[3:0]` semantics. Until that controller is extended, the mainboard MUST accept only `BE=0xf`. Any other `BE` MUST complete with `ERROR` and MUST NOT reach the memory backend.

This restriction is temporary and is not a change to the Lighting Memory Bus specification.

## 3. PLIO/QDX slots

The mainboard exposes eight slot-cycle inputs of type `PlioIn` and consumes eight card drives of type `BackplaneDrive`.

That is the same physical-cycle boundary used by `mkQDXBCard`:

```text
mainboard.plioSlots(...)[n]
          |
          v
card.startCycle(PlioIn)
          |
          v
card.backplane : BackplaneDrive
          |
          +--------------------------> mainboard next cycle
```

The conversion from `BackplaneDrive` to the logical `PlioOut` image required by `PLIOHostCore` belongs in the mainboard adapter. QDX cards MUST NOT need a host-specific adapter.

### Registered physical-cycle contract

`advance()` captures one complete physical board-cycle image into the FPGA boundary. Internal rules consume that image on a following FPGA clock. The registered boundary is intentional: external CPU/card/backend simulation logic must not form a same-cycle combinational scheduling path through mainboard arbitration.

Each submitted image MUST be consumed exactly once. The implementation therefore carries an input epoch and a processed epoch. A newly submitted image toggles the input epoch; reset or the normal PLIO-host advance commits that epoch after processing. If a detailed card model takes many simulator clocks to finish one physical PLIO cycle, the mainboard MUST remain idle during those clocks rather than replaying its previous card image.

The boundary MUST also sustain one newly submitted image per FPGA clock. Processing image N and registering image N+1 in the same clock is legal; normal register semantics keep the two images distinct.

For a physical card integration harness, the image supplied to `advance()` after `card.cycleDone` MUST be the newly completed `card.backplane` image, not the image that was used to launch that card cycle.

## 4. Shared host memory

Both the CPU and PLIO DMA reach the same `MemoryController` host port. v0.1 permits one accepted memory transaction at a time.

Arbitration is round-robin at transaction boundaries:

- if only the CPU waits, CPU wins;
- if only PLIO DMA waits, PLIO wins;
- if both wait and no CPU grant is already held, `preferCpu` selects the winner;
- after a CPU completion, PLIO receives preference;
- after a PLIO completion, CPU receives preference;
- a previously issued CPU `BUS_GRANT` overrides that preference until the CPU starts or abandons its transfer.

PLIO DMA protection, capability generations, burst semantics, and notification behavior remain responsibilities of `PLIOHostCore`.

## 5. Pluggable memory backend

`mkMainboardFPGA` owns `MemoryController` but does not own the memory cells. It exposes the controller's backend request/response handshake:

```text
requestValid
write
address[31:0]
writeData[31:0]
requestReady

responseReady
responseValid
fault
readDataValid
readData[31:0]
```

A system MAY connect this seam to:

- inferred FPGA BRAM;
- an SRAM/SDRAM/DDR adapter;
- a board-specific external-memory controller;
- a simulator RAM model;
- a host/file-backed simulation adapter.

Backend choice MUST NOT alter the CPU, PLIO, DMA-capability, or QDX-visible semantics. Arbitrary backend request or response wait states are legal.

## 6. Interrupt boundary

The CPU-module interrupt aggregate is:

- `plioIrq = PLIOHostCore.claimValid`;
- `timerIrq = platform timer input`;
- `machineFault = platform machine-fault input`.

Individual PLIO cards do not receive dedicated CPU interrupt wires.

## 7. Temporary privileged control seam

The final CPU-visible host-controller register block is not yet frozen. v0.1 therefore passes these operations directly through the composition interface:

- worker MMIO request injection;
- DMA bind/revoke and generation inspection;
- worker and DMA completion inspection;
- notification configuration;
- notification claim.

These methods MUST be treated as an integration/test seam, not as the future software ABI.

## 8. Reset

Reset MUST reset the memory controller, clear active CPU/PLIO memory ownership, cancel any CPU grant that has not yet become an active transfer, clear the accepted-CPU-request latch, restore CPU-first arbitration preference, and drive PLIO host reset through `PLIOHostCore.advance`/`drive`.

The selected memory backend MUST reset its **transaction-protocol state** synchronously with the mainboard so a response belonging to a cancelled pre-reset transaction cannot appear after reset. Reset is not required to destroy RAM contents. A BRAM, external-memory, or simulator adapter may therefore preserve memory cells while clearing request/response state.

## 9. v0.1 verification targets

The focused mainboard verification MUST establish at least:

1. the real Lighting two-phase `BUS_REQ -> BUS_GRANT -> REQ` sequence works;
2. a CPU grant is retained from arbitration through `REQ` and throughout target wait states;
3. CPU full-word write reaches the selected backend;
4. CPU full-word read returns backend data unchanged;
5. arbitrary backend request/response delay does not change the result;
6. an explicit backend fault becomes Lighting `ERROR` while grant is retained through completion;
7. a partial CPU access fails locally without modifying or reaching backend memory;
8. reset cancels an outstanding mainboard/backend request and a later transaction works normally;
9. backend RAM contents may survive reset while transaction state is cleared;
10. a PLIO DMA request cannot steal a CPU bus that was already granted, even when round-robin preference currently favors PLIO;
11. the waiting PLIO DMA proceeds after the CPU transaction completes;
12. the PLIO DMA read reaches the same backend through `PLIOHostCore`;
13. the slot adapter returns the PLIO ACK/data produced by the host controller;
14. DMA completion remains visible through the mainboard;
15. an idle board does not invent a PLIO interrupt;
16. each submitted registered board-cycle image is consumed exactly once, including when no subsequent image arrives for many FPGA/simulator clocks;
17. a separate integration test instantiates the real `mkQDXBCard` against the mainboard slot boundary and feeds each newly completed physical card image back to the mainboard;
18. the mainboard core elaborates to Verilog and passes a synthesis sanity check without requiring an embedded RAM implementation.
