# Simulating PLIO and QDX

A bus/device architecture like PLIO/QDX is easiest to validate in layers. Do not begin with a transistor- or RTL-level model.

## Layer 1 — executable architectural model

The repository includes a Python model for:

- host memory,
- PLIO DMA windows,
- aggregate bus transaction/cycle accounting,
- four-class interrupt selection,
- one QDX-B controller,
- QDX submission/completion rings,
- QDX-B READ/WRITE commands.

This model answers architectural questions quickly:

- Can a user-space driver operate using only mapped queue memory + doorbells?
- Does an inaccessible DMA address fail cleanly?
- Does the controller write data before publishing a completion?
- Does one level IRQ correctly represent many CQ entries?
- Can a controller expose multiple namespaces without changing PLIO?

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
IRQ[7:0]*
```

Each transaction becomes an explicit state machine:

```text
IDLE
 -> ARBITRATE
 -> ADDRESS
 -> DATA_WAIT
 -> ACK | ERROR | TIMEOUT
 -> IDLE
```

For a read, the model must change ownership of `AD[31:0]` between address and data phases. This lets tests catch bus-contention mistakes.

### Metrics to collect

- clocks per MMIO transaction,
- clocks per 512-byte disk DMA,
- arbitration wait time per manager,
- host MMIO latency under DMA load,
- IRQ-to-kernel-observation latency,
- utilization,
- timeout/fault behavior.

### Important workloads

1. QDX-B sequential read/write.
2. Two storage controllers contending for PLIO.
3. GNET + storage contention.
4. CPU MMIO while a DMA controller repeatedly requests the bus.
5. IRQ class 3 arriving while class 1 is pending.
6. IRQ arriving during a fast IPC kernel path.
7. Long kernel operation polling `NORMAL_IRQ` only every N work units.

## Layer 3 — system/microkernel simulator

Add a minimal RAX execution/event model rather than a complete CPU initially.

A thread has:

```text
mode: user/kernel
priority
register message words
address-space identifier
state: runnable/blocked
```

Model events:

```text
IPC call
IPC reply
page fault
normal IRQ
critical IRQ
kernel preemption point
kernel exit
```

This allows us to measure the architectural question that matters most for the RAX microkernel:

> How long can a normal PLIO interrupt be deferred without adding a poll to the IPC fast path?

The simulator should produce distributions and worst-case bounds for different kernel-work limits.

## Layer 4 — RTL reference

Only after the cycle model stabilizes should Codex build RTL.

Recommended first RTL blocks:

1. PLIO arbiter.
2. slot decoder.
3. transaction timeout engine.
4. interrupt controller.
5. DMA-window comparator/translator.

The QDX-B controller may remain behavioral at first.

Use a standard HDL simulator such as Icarus Verilog or Verilator when available. The HDL testbench should consume the same transaction traces as the Python model.

## Layer 5 — timing/electrical work

Protocol simulation cannot prove a 1978 backplane will meet timing.

Later engineering must separately model:

- TTL output loading,
- connector capacitance,
- trace length/stubs,
- clock skew,
- bus turnaround,
- termination,
- setup/hold margins.

A SPICE or transmission-line model is the appropriate tool for this layer, not the Python architectural simulator.

## Why this staged approach matters

Most protocol mistakes are architectural, not electrical. They are cheaper to find in a deterministic reference model.

The intended progression is:

```text
Markdown spec
   <-> Python executable model
          <-> cycle traces
                 <-> RTL
                        <-> electrical timing model
```

Each lower layer should be checked against the simpler layer above it.
