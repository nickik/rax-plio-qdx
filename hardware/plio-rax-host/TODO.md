# PLIO RAX host adapter TODO

## Goal

Build a real synthesizable PLIO host controller in both Bluespec and Rust, using the existing PLIO v0.6 protocol implementation and the existing test-peer state machines as the starting point.

The end state is a host controller that can sit between a RAX CPU/memory complex and the real PLIO backplane implementation:

```text
RAX CPU / privileged host control
              |
       RaxPlioHostAdapter
              |
          PLIOHostCore
        /       |       \
 worker-MMIO    DMA    notification
    engine     engine      engine
              |
       HostMemoryPort
              |
       memory controller
              |
================ PLIO =================
 slot 0      slot 1      ... slot 7
```

The same Rust model and later the Verilated Bluespec implementation should be usable by LightingSimulation, replacing its current transaction-level PLIO device shortcut while leaving the RAX-specific CPU/memory attachment outside the generic PLIO bus protocol.

## Existing code to reuse

Do not start from a blank state machine.

- `hardware/testbench/rust/src/lib.rs::TestPeer` already models:
  - host-injected worker address/data phases;
  - worker ACK/ERR handling;
  - bus request/grant sequencing;
  - DMA address and data phases;
  - wait states and partial transfer faults;
  - controller-local notification transactions.
- QDX-A/QDX-B physical card tests already exercise realistic manager traffic against a host-like peer.
- `plio-logical-model` already defines the canonical logical bus images and parity helpers.
- PLIO-TX/QIC tests define the physical timing/ownership rules the host must obey.
- `specs/PLIO.md` already defines rotating round-robin arbitration, 256-clock per-phase timeout, complete-burst DMA validation, partial-transfer semantics, parity, notification transactions, and grant lifetime.
- `specs/PLIO-RAX.md` already defines the geographic worker windows, host-controller CSR reservation, capability ownership, notification interrupt, and non-coherent-memory assumptions.

The implementation should evolve the proven test-peer behavior into production host logic rather than maintaining a second independent interpretation of the bus.

---

## Architectural decision 1: split generic PLIO controller from RAX attachment

Implement two layers even if they initially live in the same crate/package.

### `PLIOHostCore`

Host-architecture-independent PLIO logic:

- physical/logical PLIO bus state machine;
- worker transaction execution once given `(slot, offset, width, read/write, data)`;
- rotating round-robin arbitration over eight `BR` inputs;
- exactly one granted manager transaction at a time;
- HOST_DMA decode and capability validation;
- DMA burst progress and partial-fault accounting;
- CONTROLLER-space notification acceptance;
- parity generation/checking;
- 256-clock phase timeout;
- bus reset and fault diagnostics.

It must not know RAX CPU physical MMIO addresses, RAX interrupt vectors, or the implementation details of the memory controller.

### `RaxPlioHostAdapter`

RAX-specific attachment:

- decode `0xF000_0000..0xFFFF_FFFF` into `(slot, slot_offset)`;
- expose privileged host-controller CSRs at `0xEFFF_F000..0xEFFF_FFFF`;
- translate CPU load/store requests into worker transactions;
- expose `NOTIFY_PENDING_INTERRUPT`;
- own privileged DMA bind/revoke programming;
- bridge `PLIOHostCore` memory requests to the RAX memory-controller interface.

This keeps `PLIOHostCore` reusable in Rust tests, hardware simulation, and non-RAX hosts.

---

## Architectural decision 2: memory-controller boundary

The host adapter must not directly index an array or assume a specific RAM implementation.

Define a small ready/valid request-response interface. PLIO DMA is always naturally aligned 32-bit longwords, so the PLIO-facing memory boundary can deliberately stay 32-bit even if the real memory controller is wider.

Conceptual Bluespec types:

```text
typedef enum { HostMemRead, HostMemWrite } HostMemOp;

typedef struct {
    HostMemOp op;
    Bit#(32)  physicalAddress;
    Bit#(32)  writeData;
} HostMemRequest;

typedef struct {
    Bool      ok;
    Bit#(32)  readData;
    HostMemFault fault;
} HostMemResponse;
```

Conceptual interface:

```text
interface HostMemoryPort;
    method Bool requestReady;
    method Action request(HostMemRequest req);
    method Bool responseValid;
    method HostMemResponse response;
    method Action consumeResponse;
endinterface
```

Rust should mirror the same semantics with an explicit request/response state machine rather than an atomic `read32()`/`write32()` shortcut in the reference model.

### Required semantics

- only one PLIO memory beat needs to be outstanding initially;
- host memory may stall for an arbitrary number of cycles;
- PLIO ACK for a DMA write beat occurs only after the memory path accepts/commits the write;
- PLIO read data/ACK occurs only after the memory response is available;
- a host-memory fault terminates the PLIO burst with ERR;
- already acknowledged PLIO beats are never rolled back;
- reset cancels an outstanding memory request from the PLIO controller's point of view; no stale response may later complete a new transaction;
- the bridge must be replaceable later by a pipelined/cache-aware memory fabric without changing PLIO bus semantics.

Do not put cache-coherence policy in PLIOHostCore. Cache visibility remains a RAX software/platform responsibility.

---

## Architectural decision 3: DMA capability table

Implement the normative per `(slot, channel)` table in the host controller.

Baseline dimensions:

```text
8 slots x 16 DMA channels
```

Each entry contains:

```text
host_physical_base : 32 bits
length             : 32 bits
allow_device_read  : 1 bit
allow_device_write : 1 bit
generation         : 4 bits
valid              : 1 bit
active              : 1 bit / active-burst interlock
```

Device-visible DMA handle remains:

```text
[31:28] channel
[27:24] generation
[23:0]  offset
```

Address phase must validate the *whole burst* before ACK:

- valid entry;
- generation match;
- 32-bit alignment;
- burst extent inside `length`;
- required direction permission;
- no overflow crossing the 24-bit offset space.

### Bind/revoke

First implementation can allow bind/revoke only while that exact `(slot, channel)` has no active burst.

On revoke/rebind:

- invalidate old mapping;
- advance generation modulo 16;
- stale handles must fail;
- define and test generation-wrap behavior before allowing wrap to silently resurrect stale handles.

Generation-wrap policy should be explicit in the RAX host-controller CSR spec, not hidden in the bus engine.

---

## Architectural decision 4: CPU/worker request boundary

Do not have the CPU directly wiggle PLIO bus signals.

Define a queued internal worker request interface:

```text
slot
offset
width = 8/16/32
read/write
write_data
```

with a response containing:

```text
ok / device_error / parity_error / timeout
read_data
```

Initial implementation may allow only one outstanding CPU worker transaction.

Important ordering rule:

- a CPU worker transaction and a card bus-manager transaction cannot own the PLIO bus simultaneously;
- arbitration chooses between pending host worker injection and requested peripheral manager traffic at transaction boundaries;
- once a transaction starts it runs to ACK/ERR/timeout before another transaction begins.

Host worker traffic must not permanently starve manager requests. Define an explicit fairness policy. Preferred baseline:

- finish current transaction;
- if any `BR` is pending, service one rotating-round-robin manager transaction;
- then allow host worker injection;
- repeat.

This gives DMA/notification progress even under heavy CPU MMIO.

---

## Architectural decision 5: notification state

Implement four notification channels per slot.

Controller state:

```text
pending[8][4]
enable[8][4]
mask[8][4]
class[8][4]
data[8][4]   // reserve even if baseline QDX currently writes zero
```

A granted card performs one `SPACE=CONTROLLER` write to `4 * channel`.

The controller:

- validates channel/address/control/parity;
- ACKs accepted notification;
- sets pending state for the trusted currently granted slot;
- releases grant after that transaction;
- asserts aggregate `NOTIFY_PENDING_INTERRUPT` when an enabled/unmasked source is pending.

The RAX CSR claim operation must atomically return `(slot, channel, class)` and clear exactly that pending source.

---

# Implementation milestones

## M0 — freeze interfaces and convert `TestPeer` into the executable oracle

- [ ] Extract/restate the reusable host-side state machine from `TestPeer` without changing behavior.
- [ ] Define Rust public types for worker requests/responses, memory requests/responses, DMA table entries, notifications, faults, and bus-cycle input/output.
- [ ] Define matching Bluespec types/interfaces.
- [ ] Decide exact arbitration priority between host worker traffic and manager requests.
- [ ] Decide exact timeout counters and when counting begins/resets.
- [ ] Decide generation-wrap policy.
- [ ] Document reset semantics for bus, DMA mappings, notification pending state, and outstanding host-memory request.
- [ ] Add a trace format such as `PLIOHOSTTRACE|v1` before implementing RTL.

Acceptance:

- Rust interface tests compile;
- no bus behavior changes yet;
- every unresolved semantic choice above is written down.

## M1 — Rust PLIO bus engine, worker MMIO only

- [ ] New Rust host-controller model derived from `TestPeer`.
- [ ] Implement Idle -> WorkerAddress -> WorkerData -> completion.
- [ ] 8/16/32-bit naturally aligned accesses.
- [ ] proper `SEL`, WORKER space, BE, BLEN=1.
- [ ] address/data wait states.
- [ ] worker ERR.
- [ ] read-data parity validation.
- [ ] address/data 256-cycle timeout.
- [ ] reset during every phase with no stale completion.

Tests:

- [ ] one NakedCard read/write through QIC + PLIO-TX;
- [ ] all widths and byte enables;
- [ ] wait states 0/1/many/255;
- [ ] timeout at boundary;
- [ ] worker error;
- [ ] bad read parity;
- [ ] reset during address and data phases.

## M2 — Rust arbitration and notifications

- [ ] eight request inputs.
- [ ] rotating round-robin grant selection.
- [ ] grant belongs to exactly one slot.
- [ ] exactly one transaction per grant.
- [ ] re-arbitrate if BR remains asserted.
- [ ] CONTROLLER-space notification transaction.
- [ ] notification pending/enable/mask/class state.
- [ ] claim operation.
- [ ] aggregate interrupt condition.
- [ ] host-worker vs manager fairness.

Tests:

- [ ] all eight slots request simultaneously;
- [ ] repeated requester cannot starve others;
- [ ] deasserted request before grant;
- [ ] malformed CONTROLLER transaction;
- [ ] notification wait/error/timeout;
- [ ] repeated notification coalescing;
- [ ] claim ordering and mask/enable behavior.

## M3 — Rust DMA capability and memory-port engine

- [ ] 8 x 16 capability table.
- [ ] bind/revoke/generation.
- [ ] complete-burst validation before address ACK.
- [ ] H2D/device-read DMA for 1/4/8/16 words.
- [ ] D2H/device-write DMA for 1/4/8/16 words.
- [ ] explicit asynchronous HostMemoryPort requests/responses.
- [ ] arbitrary memory wait states.
- [ ] memory fault -> PLIO ERR.
- [ ] write-data parity error rejection.
- [ ] read data parity generation.
- [ ] exact partial-progress behavior.
- [ ] active-burst revoke interlock.
- [ ] stale-generation rejection.

Tests:

- [ ] every burst length and both directions;
- [ ] all permission combinations;
- [ ] first/last legal byte range;
- [ ] crossing range fails before beat 0;
- [ ] stale generation;
- [ ] unbound channel;
- [ ] misalignment;
- [ ] host-memory wait on every beat;
- [ ] host-memory fault at each beat index;
- [ ] bad device write parity at each beat index;
- [ ] reset during memory request and response wait;
- [ ] revoke before/after/in active burst.

## M4 — Bluespec PLIOHostCore matching the Rust oracle

- [ ] Implement the same worker FSM.
- [ ] Implement rotating round-robin arbiter.
- [ ] Implement manager transaction decoder.
- [ ] Implement notification controller state.
- [ ] Implement capability RAM/register array.
- [ ] Implement DMA/memory bridge one beat outstanding.
- [ ] Implement parity and timeout logic.
- [ ] Implement reset cancellation/stale-response suppression.
- [ ] Ensure mutually exclusive state ownership to avoid ambiguous BSC writes.

Validation:

- [ ] Bluesim tests for every M1-M3 scenario;
- [ ] standalone Verilog generation;
- [ ] exact Rust <-> Bluesim `PLIOHOSTTRACE|v1` differential on deterministic scenarios;
- [ ] randomized invariant test with fixed seeds.

## M5 — RaxPlioHostAdapter CPU-side attachment

- [ ] Geographic decode of `0xF000_0000..0xFFFF_FFFF`.
- [ ] slot = address[27:25].
- [ ] slot offset = address[24:0].
- [ ] privileged host CSR block at `0xEFFF_F000..0xEFFF_FFFF`.
- [ ] controller ID/version/status/control.
- [ ] DMA bind/revoke CSR layout.
- [ ] per-slot/channel generation readback.
- [ ] notification pending/enable/mask/class/claim/data CSR layout.
- [ ] error status + diagnostic info.
- [ ] `NOTIFY_PENDING_INTERRUPT` output.
- [ ] CPU request backpressure while a worker transaction is active.

Do not expose raw RAX host physical addresses on the PLIO backplane.

## M6 — concrete memory-controller adapter

The PLIO core's `HostMemoryPort` stays stable. Add a separate bridge to the chosen RAX memory-controller bus.

- [ ] document the actual RAX memory-controller request/response protocol;
- [ ] adapt 32-bit PLIO requests to native memory width;
- [ ] support backpressure;
- [ ] propagate access/bus faults;
- [ ] define uncached/non-coherent DMA visibility contract;
- [ ] decide whether PLIO DMA participates in normal memory arbitration as another master or through a dedicated DMA port;
- [ ] test CPU and PLIO contention against the memory controller;
- [ ] ensure a stalled PLIO memory request cannot deadlock CPU access needed to service the device driver.

Preferred architectural direction: PLIO is another ordinary non-coherent memory master behind the memory controller/arbitration fabric, not a special path that bypasses memory protection/DRAM timing logic.

## M7 — real-card integration acceptance

Use the host adapter against existing real hardware models rather than purpose-built peers.

- [ ] Host adapter + NakedCard full physical stack.
- [ ] Host adapter + QDX-A card.
- [ ] Host adapter + QDX-B card.
- [ ] program QDX queue registers from the host worker interface.
- [ ] bind DMA channels through host CSR interface.
- [ ] execute QDX-B NOP/IDENTIFY/READ/WRITE/WRITE_DURABLE/FLUSH.
- [ ] receive and claim PLIO Notification.
- [ ] compare final host RAM, queue indices, completions, notifications, and media state against Rust model.
- [ ] multi-card arbitration test with at least QDX-B plus another requesting manager.

Acceptance target:

```text
RAX-side worker request
        -> PLIOHostCore
        -> PLIO backplane
        -> PLIO-TX -> QIC -> QLI-16 -> QDX-A -> QDX-B
        -> DMA request back over PLIO
        -> PLIOHostCore capability translation
        -> HostMemoryPort
        -> test memory controller
        -> completion + notification back to RAX side
```

No testbench peer may synthesize DMA data or ACK manager traffic in this final acceptance path; the host adapter itself must do it.

## M8 — simulation-consumption boundary

After M7 is stable, expose a clean simulation API that LightingSimulation can consume without duplicating PLIO policy.

- [ ] Rust host model crate is reusable directly.
- [ ] Bluespec host + card path has a flattened Verilator-friendly top.
- [ ] cycle input/output types are stable and versioned.
- [ ] simulation memory adapter implements the exact same HostMemoryPort contract.
- [ ] software host model and RTL host model can run identical traces.

Only after this point should LightingSimulation replace its current simplified `PlioController` / software-card path.

---

# Required invariants

- [ ] At most one bus owner/transaction is active.
- [ ] At most one `BG` is asserted.
- [ ] A grant authorizes exactly one transaction.
- [ ] Trusted source slot always comes from the grant, never card-supplied data.
- [ ] Host worker transaction is never interleaved with manager transaction beats.
- [ ] DMA address ACK implies the complete requested burst is valid.
- [ ] No memory beat occurs before successful DMA address validation.
- [ ] PLIO ACK of a D2H write beat implies host-memory acceptance/commit.
- [ ] H2D data is not exposed until the corresponding memory read completes.
- [ ] Partial bursts report only acknowledged beats as completed.
- [ ] Bad parity data is never committed to host memory.
- [ ] Reset produces no stale worker, DMA, memory, or notification completion afterward.
- [ ] Revoked/stale DMA handles cannot access memory.
- [ ] CPU physical address bits above slot offset never leak onto PLIO WORKER addresses.
- [ ] Notification source identity cannot be forged by a card.
- [ ] Continuous CPU worker traffic cannot starve manager traffic.
- [ ] Continuous manager traffic cannot permanently starve CPU worker traffic.

# First implementation step

Do **M0 only first**.

In particular, before writing the Bluespec controller:

1. promote `TestPeer` semantics into a production-quality Rust host-controller interface;
2. freeze `HostMemoryPort`, worker request/response, capability-entry, fault, arbitration, reset, and trace contracts;
3. write focused tests for those contracts;
4. only then implement M1 worker-MMIO behavior.

This preserves the project pattern already working well for QIC, QLI-16, QDX-A, and QDX-B: Rust executable oracle first, Bluespec differential second.