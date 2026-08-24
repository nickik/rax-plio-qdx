# Simulating PLIO and QDX

A bus/device architecture like PLIO/QDX is easiest to validate in layers. Do not begin with RTL.

## Layer 1 — executable architectural model

The repository includes a Python model for:

- host memory,
- PLIO DMA capability channels,
- aggregate protected DMA translation,
- generation-tagged DMA handles,
- baseline 1/4/8/16-word DMA burst validation,
- four-class message-notification selection,
- one QDX-B controller,
- QDX submission/completion rings,
- QDX-B READ/WRITE commands.

This model answers questions such as:

- Can a user-space driver operate using mapped queue memory + doorbells?
- Does an inaccessible channel/offset fail cleanly?
- Can revoking a DMA capability stop further device access?
- Does a burst validate its complete capability extent before transfer?
- Are only the baseline 1/4/8/16-word burst lengths accepted?
- Does the controller identify a notification source from bus ownership rather than trusting device data?
- Does QDX publish completion memory before notifying?
- Does one notification correctly represent many CQ entries?

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

A single-beat transaction becomes:

```text
IDLE
 -> ARBITRATE
 -> ADDRESS
 -> DATA_WAIT
 -> ACK | ERROR | TIMEOUT
 -> IDLE
```

A burst transaction becomes:

```text
IDLE
 -> ARBITRATE
 -> ADDRESS + full-range capability check
 -> DATA_WAIT beat 0
 -> ACK -> DATA_WAIT beat 1
 -> ...
 -> ACK final beat | ERROR | TIMEOUT
 -> RELEASE
 -> ARBITRATE/IDLE
```

`BLEN` decodes to exactly 1, 4, 8, or 16 32-bit data beats. The grant remains active for the transaction but MUST be withdrawn after the final beat or abort so rotating round-robin arbitration gets another opportunity.

The cycle model must represent three manager transaction destinations:

1. PLIO worker MMIO — single beat only,
2. protected host-memory DMA through a capability channel — 1/4/8/16-beat burst,
3. controller-owned `NOTIFY` aperture — single beat only.

### Burst-specific rules to model

- address and `BLEN` are latched in the address phase,
- burst DMA is naturally 32-bit aligned and uses full-word byte enables,
- generation/bounds/permission checks cover the entire burst before beat 0,
- translated host address increments by four after each acknowledged beat,
- every data beat may insert wait states,
- `ERR*` or timeout aborts the remaining beats,
- already acknowledged data beats are not rolled back,
- channel revocation while a burst is active must prevent later beats from using a revoked mapping,
- a manager may leave `BR` asserted for more work but must compete for a new grant after every burst.

### Metrics to collect

- clocks per MMIO transaction,
- clocks and payload efficiency for 1/4/8/16-word DMA bursts,
- clocks per 512-byte disk DMA using repeated 16-word bursts,
- arbitration wait time per manager,
- host MMIO latency under DMA load,
- NOTIFY transaction latency under bus load,
- worst-case NOTIFY latency behind one 16-word burst,
- notify-to-kernel-observation latency,
- utilization,
- timeout/fault behavior.

### Important workloads

1. QDX-B sequential read/write using 16-word payload bursts.
2. Two storage controllers contending for PLIO and re-arbitrating every 64 bytes.
3. GNet + storage contention.
4. CPU MMIO while DMA controllers request the bus.
5. class-3 notification arriving while class-1 is pending.
6. notification request arriving during a maximum-length DMA burst.
7. notification arriving during a fast IPC kernel path.
8. DMA attempted after channel revocation.
9. channel revocation during an active burst.
10. notification arriving while a source is masked, then delivered after unmask.

## Layer 3 — system/microkernel simulator

Add a minimal RAX execution/event model rather than a complete CPU initially.

A thread has mode, priority, register message words, address-space identifier, and runnable/blocked state.

Model events including IPC call/reply, page fault, normal PLIO notification, critical platform event, kernel preemption point, and kernel exit.

This allows measurement of how long a normal device event can be deferred without adding a poll to the IPC fast path.

## Layer 4 — RTL reference

Only after the cycle model stabilizes should RTL be built.

Recommended first RTL blocks:

1. PLIO arbiter and grant-retention logic,
2. slot decoder,
3. `BLEN` decoder and 4-bit burst beat counter,
4. sequential DMA address incrementer,
5. transaction/per-beat timeout engine,
6. notification controller,
7. DMA capability-channel lookup/bounds/permission/generation logic.

The QDX-B controller may remain behavioral at first.

## Layer 5 — timing/electrical work

Later engineering must separately model TTL output loading, connector capacitance, trace length/stubs, clock skew, bus turnaround, termination, setup/hold margins, and the two added `BLEN` control traces.

The intended progression remains:

```text
Markdown spec
   <-> Python executable model
          <-> cycle traces
                 <-> RTL
                        <-> electrical timing model
```
