# Bluespec PLIO-QIC implementation TODO

Implement this incrementally. The Rust QIC is the behavioral oracle. Do **not** build the entire QIC in one change.

The Bluespec core should use abstract PLIO and semantic QLI interfaces first:

```text
abstract PLIO <-> Bluespec QIC core <-> semantic QLI
                       |
                 later adapters
                  PTI / QLI-16
```

Every phase below must compile, simulate, and pass Rust/Bluespec differential tests before starting the next phase.

## Phase 0 — synchronize supporting contracts

- [ ] Add semantic `mmio_cancel` to the Bluespec QLI/NakedDevice interface.
- [ ] Test that Bluespec NakedDevice drops a pending MMIO response on cancel and becomes ready again.
- [ ] Add the corresponding QLI-16 cancel encoding before physical QLI-16 integration.
- [ ] Keep Rust and Bluespec canonical support-component vectors identical.
- [ ] Define one common cycle-trace text format for QIC differential testing.

### Tests

- NakedDevice request -> pending response -> cancel -> ready.
- reset and cancel are distinct operations.
- existing QLI/NakedDevice conformance remains green.

## Phase 1 — QIC shell, reset, and worker address phase

Implement only:

- QIC module/interface definitions;
- abstract PLIO input/output records;
- abstract QLI input/output methods/records;
- `Idle` state;
- reset/quiescent behavior;
- worker address recognition and validation;
- worker address ACK/ERR.

Do not implement worker data, DMA, or Notification yet.

### Tests

- reset drives no BR/AS/DS/AD/PAR/ACK/ERR.
- unselected WORKER cycle is ignored.
- non-WORKER selected cycle is ignored as a worker.
- valid 8/16/32-bit worker addresses ACK.
- invalid 25-bit address, bad BE/alignment, non-single BLEN, missing/bad address parity ERR.
- no QLI MMIO request is emitted during address phase.
- Rust and Bluespec cycle traces match exactly for these cases.

## Phase 2 — worker MMIO data path

Add:

- worker write-data receive path;
- latched BE and address state;
- worker read/write QLI request handshake;
- QLI response handling;
- PLIO read-data parity generation;
- worker wait states;
- 256-clock data-phase timeout;
- `mmio_cancel` after an accepted local request times out.

### Tests

- complete 8/16/32-bit reads through QLI.
- complete 8/16/32-bit writes through QLI.
- write parity checks use **latched** BE even if data-phase BE pins differ.
- QLI request remains stable until accepted.
- QLI response backpressure becomes PLIO wait.
- ReadOk -> data/parity + ACK.
- WriteOk -> ACK.
- Error/type mismatch -> ERR.
- timeout before QLI acceptance withdraws the unaccepted request.
- timeout after QLI acceptance produces PLIO ERR + QLI `mmio_cancel`.
- reset at every worker sub-state returns safely to idle.
- exact Rust/BSV cycle trace match.

## Phase 3 — bus request/grant and manager address phase

Add only the common outbound-manager machinery:

- pending manager-work selection;
- Notification-over-new-DMA priority at idle;
- BR request;
- BG acquisition;
- manager address phase;
- address ACK/ERR/wait/256-clock timeout;
- one-transaction-per-grant bookkeeping;
- grant-loss detection.

No DMA data or Notification data yet.

### Tests

- before BG, BR may assert but AS/DS/AD/PAR/SPACE are not driven.
- after BG, address/control/parity are stable until ACK/ERR/timeout.
- no data phase begins before address ACK.
- address ERR terminates with correct local result.
- address timeout terminates and releases manager activity.
- BG loss before address completion is detected.
- after a transaction, another request requires a fresh grant.
- Notification wins only at an idle scheduling boundary.
- Rust/BSV trace match.

## Phase 4 — HOST_TO_DEVICE DMA read path

Add:

- all 1/4/8/16 burst lengths;
- manager `RD=1`, `BE=1111`, correct BLEN;
- DS generation per requested read beat;
- target ACK/wait/ERR handling;
- read-data parity checking;
- one-word QLI read buffer;
- exact acknowledged-progress accounting;
- final buffered-word drain after bus ownership is no longer needed.

### Tests

- 1/4/8/16 successful bursts.
- waits on every possible beat position.
- ERR at beat 0/middle/final.
- bad parity at beat 0/middle/final: corrupted word never reaches QLI.
- local `dma_read_ready` backpressure.
- bounded timeout while holding a non-final acknowledged word locally.
- final ACKed word may drain after BG withdrawal.
- no AD/PAR drive by QIC during read data beats.
- completion held until `dma_completion_ready`.
- Rust/BSV trace match.

## Phase 5 — DEVICE_TO_HOST DMA write path

Add:

- QLI write-word acceptance;
- one-word local buffer;
- AD/PAR generation;
- DS/ACK/wait/ERR sequencing;
- all burst sizes;
- bounded local-producer stall handling.

### Tests

- 1/4/8/16 successful bursts.
- exact data/parity for every beat.
- target wait does not duplicate/lose a local word.
- ERR partial-progress accounting.
- local producer delay before first and middle beats.
- local producer stall reaches TIMEOUT rather than pinning BG forever.
- no extra beat after requested count.
- Rust/BSV trace match.

## Phase 6 — PLIO Notification

Add:

- channel validation;
- `SPACE=CONTROLLER` address phase;
- offsets 0/4/8/C;
- `RD=0`, `BE=1111`, `BLEN=1`;
- address and zero advisory-data parity;
- one data beat;
- completion-based `notification_ready`;
- retry after ERR/timeout/grant loss.

### Tests

- channels 0..3 produce exact address/control/parity.
- ready never asserts on enqueue, arbitration, or address ACK.
- ready asserts only when the data beat is ACKed.
- address/data waits.
- address/data ERR and timeout leave the request retryable.
- active DMA is never preempted by Notification.
- fresh idle arbitration gives Notification priority over a new DMA request.
- Rust/BSV trace match.

## Phase 7 — global safety/invariants

Add assertions/checkers where Bluespec makes them practical.

### Required invariants

- manager AS/DS/AD/PAR/control drive implies BG.
- worker ACK/ERR/data drive occurs only for an active selected worker transaction.
- ACK and ERR are never asserted together by QIC.
- AS and DS are never asserted together.
- manager never originates `SPACE=WORKER`.
- DMA always uses BE=1111 and burst <=16.
- Notification always uses one beat.
- exactly one manager transaction per grant.
- active DMA is never preempted.
- reset wins over all other state transitions.
- no QDX state exists in QIC.

### Fault sweep

For every major state, inject:

- reset;
- BG loss where meaningful;
- ERR;
- timeout;
- parity error where QIC is receiver;
- QLI backpressure.

Compare terminal state and local completion/cancel behavior with Rust.

## Phase 8 — differential conformance harness

The final pre-Verilog gate is not merely "both suites pass". Run identical scripted cycle stimuli through Rust and Bluesim and compare, cycle by cycle:

```text
cycle
PLIO inputs
QLI inputs
QIC PLIO outputs
QIC QLI outputs
state/event markers (debug only)
```

Canonical scripts must include:

- worker read/write happy paths;
- every worker transfer width;
- every DMA length/direction;
- address waits/errors/timeouts;
- data waits/errors/timeouts;
- parity faults;
- QLI stalls;
- grant loss;
- reset at each state family;
- Notification priority/retry;
- back-to-back transactions requiring fresh grants.

Only after exact differential traces pass should the module be considered the hardware reference.

## Phase 9 — generated Verilog smoke gate

After the abstract Bluespec QIC is complete:

- [ ] generate Verilog with pinned BSC;
- [ ] synthesize with Yosys without PTI/QLI-16 first;
- [ ] inspect inferred state/register/FIFO structure;
- [ ] ensure there are no unintended large RAMs or FPGA-only constructs hidden in the QIC core;
- [ ] only then wrap with PTI and QLI-16 for the iCE40 path.

FPGA pinout, PLIO-TX electrical behavior, and production host-controller logic remain separate workstreams.
