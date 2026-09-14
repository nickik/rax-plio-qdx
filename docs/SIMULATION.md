# Simulating PLIO and QDX

A bus/device architecture like PLIO/QDX is easiest to validate in layers. Do not begin with RTL.

## Layer 1 — executable architectural model

The repository includes functional models for:

- host memory,
- PLIO DMA capability channels and generation tags,
- complete-range burst validation,
- PLIO transaction-space constants and bus-local PLIO Notification offsets,
- RAX host-profile geographic MMIO mapping,
- QDX canonical little-endian integer encoding,
- notification class selection,
- one QDX-B controller,
- QDX submission/completion rings,
- QDX-B READ/WRITE commands.

The Layer-1 functional model operates on already-decoded transactions. It does **not** model the electrical `AD[31:0]`/`PAR[3:0]` wires and therefore does not claim to validate PLIO parity behavior. Parity belongs to the cycle-level model below.

Run:

```bash
python -m unittest discover -s tests -v
python -m sim.plio_sim.scenario
```

## Layer 2 — cycle-level PLIO model

The next simulator should model every PLIO clock edge and signal state.

Represent at least:

```text
CLK
AD[31:0]
PAR[3:0]
SPACE[1:0]
AS*
RD
BE[3:0]
BLEN[1:0]
DS*
ACK*
ERR*
SEL[7:0]*
BR[7:0]*
BG[7:0]*
```

There is intentionally **no `IRQ[7:0]` bus signal**.

The cycle model must distinguish transaction spaces:

```text
WORKER      host-injected slot-relative MMIO
HOST_DMA    protected host-memory DMA
CONTROLLER  bus-local PLIO Notification/controller operation
RESERVED
```

A single-beat transaction is approximately:

```text
IDLE
 -> ARBITRATE/INJECT
 -> ADDRESS
 -> DATA_WAIT
 -> ACK | ERROR | TIMEOUT
 -> IDLE
```

A DMA burst extends DATA_WAIT through 1, 4, 8, or 16 acknowledged longword beats before the grant is released and arbitration runs again.

### Capability timing rule

Before DMA beat 0 the model must validate the complete requested burst extent against:

```text
source slot
channel
generation
bounds
direction permission
```

The model must also support revocation interlock during an active burst so later beats cannot continue after authority is revoked.

### Parity timing rule

PLIO v0.6 requires **odd byte-lane parity** on the multiplexed address/data bus:

```text
PAR0 protects AD[7:0]
PAR1 protects AD[15:8]
PAR2 protects AD[23:16]
PAR3 protects AD[31:24]
```

The cycle-level simulator must therefore:

- generate and check all four parity bits during every address phase;
- generate and check all four parity bits on every 32-bit DMA data beat;
- check only the selected byte lanes for 8/16-bit worker transactions;
- model address/write-data parity failures as rejected transactions with `ERR*` where possible;
- model read-data parity failure as a failed transaction whose affected beat is discarded;
- check parity independently on every beat of 1/4/8/16-word bursts;
- support deterministic parity fault injection on a chosen address phase, data beat, and byte lane.

Parity is error detection only; the simulator must not silently correct corrupted data.

### PLIO Notification timing rule

A **PLIO Notification** is a real one-beat transaction:

```text
SPACE = CONTROLLER
AD = 0x0 / 0x4 / 0x8 / 0xC
```

issued by a granted manager. It is not a write to a RAX CPU physical address.

The RAX host profile separately models how controller pending/claim state reaches the CPU/kernel. Aggregate eligible pending state is presented to the RAX CPU as:

```text
NOTIFY_PENDING_INTERRUPT
```

That signal/condition is host-internal and must never be modeled as a PLIO card/backplane pin.

### Metrics to collect

- clocks per worker MMIO transaction,
- clocks per 512-byte and larger disk DMA,
- payload efficiency for BLEN 1/4/8/16,
- arbitration wait per manager,
- maximum PLIO Notification delay behind a 64-byte burst,
- host MMIO latency under DMA load,
- PLIO Notification-to-kernel-observation latency,
- bus utilization,
- wait-state and timeout behavior,
- parity-error detection latency,
- revoke-to-no-further-access latency.

### Important workloads

1. QDX-B sequential read/write using repeated 16-longword bursts.
2. Two storage controllers contending for PLIO.
3. GNet + storage contention.
4. Graphics/DSP DMA + latency-sensitive PLIO Notification traffic.
5. CPU worker MMIO while DMA controllers request the bus.
6. class-3 PLIO Notification arriving while class-1 is pending.
7. notification request arriving immediately after another device starts a maximum burst.
8. DMA attempted after channel revocation.
9. revocation during an active burst.
10. PLIO Notification arriving while a source is masked, then delivered after unmask.
11. RAX CPU address decoding to `(slot, slot_offset)` without placing the CPU physical address on PLIO.
12. Inject bad address parity and verify the transfer is rejected before data phase.
13. Inject bad parity on each beat position of a 16-longword DMA burst and verify the corrupted beat is never committed as valid data.
14. Verify byte/halfword worker accesses check parity only on enabled byte lanes.

## Layer 3 — system/microkernel simulator

Add a minimal host execution/event model rather than a complete CPU initially.

For the RAX profile, model events including IPC call/reply, page fault, normal PLIO Notification, `NOTIFY_PENDING_INTERRUPT`, critical platform event, kernel preemption point, and kernel exit.

Keep the RAX CPU-facing claim/vector behavior outside the generic PLIO card model.

## Layer 4 — RTL reference

Only after the cycle model stabilizes should RTL be built.

Recommended first RTL blocks:

1. PLIO arbiter,
2. transaction-space/address decoder,
3. burst-length latch / beat counter,
4. transaction timeout engine,
5. byte-lane parity generation/checking and parity fault reporting,
6. controller-local PLIO Notification decoder/state,
7. DMA capability lookup/bounds/generation/permission logic,
8. RAX host-profile worker-MMIO mapper.

The QDX-B controller may remain behavioral initially.

## Layer 5 — physical/electrical work

PLIO-E requires separate validation of:

- 3U/6U Eurocard backplane geometry,
- 96-position connector loading,
- TTL output loading,
- connector capacitance,
- trace length and stubs,
- ground distribution,
- clock skew,
- bus turnaround,
- termination,
- setup/hold margins,
- PLIO-5 and PLIO-10 operation on the same pinout.

The intended progression remains:

```text
Markdown standards
   <-> functional model
          <-> cycle traces
                 <-> RTL
                        <-> PLIO-E electrical timing model
```
