# Simulating PLIO and QDX

A bus/device architecture like PLIO/QDX is easiest to validate in layers. Do not begin with RTL.

## Layer 1 — executable architectural model

The repository includes a Python model for:

- host memory,
- PLIO DMA capability channels,
- aggregate protected DMA translation,
- four-class message-notification selection,
- one QDX-B controller,
- QDX submission/completion rings,
- QDX-B READ/WRITE commands.

This model answers questions such as:

- Can a user-space driver operate using mapped queue memory + doorbells?
- Does an inaccessible channel/offset fail cleanly?
- Can revoking a DMA capability stop further device access?
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
DS*
ACK*
ERR*
SEL[7:0]*
BR[7:0]*
BG[7:0]*
```

There is intentionally **no `IRQ[7:0]` bus signal**.

Each transaction becomes an explicit state machine:

```text
IDLE
 -> ARBITRATE
 -> ADDRESS
 -> DATA_WAIT
 -> ACK | ERROR | TIMEOUT
 -> IDLE
```

The cycle model must represent three manager transaction destinations:

1. PLIO worker MMIO,
2. protected host-memory DMA through a capability channel,
3. controller-owned `NOTIFY` aperture.

### Metrics to collect

- clocks per MMIO transaction,
- clocks per 512-byte disk DMA,
- arbitration wait time per manager,
- host MMIO latency under DMA load,
- NOTIFY transaction latency under bus load,
- notify-to-kernel-observation latency,
- utilization,
- timeout/fault behavior.

### Important workloads

1. QDX-B sequential read/write.
2. Two storage controllers contending for PLIO.
3. GNet + storage contention.
4. CPU MMIO while DMA controllers request the bus.
5. class-3 notification arriving while class-1 is pending.
6. notification arriving during a fast IPC kernel path.
7. DMA attempted after channel revocation.
8. notification arriving while a source is masked, then delivered after unmask.

## Layer 3 — system/microkernel simulator

Add a minimal RAX execution/event model rather than a complete CPU initially.

A thread has mode, priority, register message words, address-space identifier, and runnable/blocked state.

Model events including IPC call/reply, page fault, normal PLIO notification, critical platform event, kernel preemption point, and kernel exit.

This allows measurement of how long a normal device event can be deferred without adding a poll to the IPC fast path.

## Layer 4 — RTL reference

Only after the cycle model stabilizes should RTL be built.

Recommended first RTL blocks:

1. PLIO arbiter,
2. slot decoder,
3. transaction timeout engine,
4. notification controller,
5. DMA capability-channel lookup/bounds/permission logic.

The QDX-B controller may remain behavioral at first.

## Layer 5 — timing/electrical work

Later engineering must separately model TTL output loading, connector capacitance, trace length/stubs, clock skew, bus turnaround, termination, and setup/hold margins.

The intended progression remains:

```text
Markdown spec
   <-> Python executable model
          <-> cycle traces
                 <-> RTL
                        <-> electrical timing model
```
