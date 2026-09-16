# PLIO-RAX host-controller contract

**Status: implemented through the current PLIO host-core milestones.**

This directory contains the generic PLIO host-controller implementation used by the RAX integration. The PLIO bus protocol remains host-independent: RAX-specific CPU physical addresses and interrupt-vector semantics belong in the host profile, not in the generic bus protocol.

## Responsibilities

The host controller is responsible for:

- injecting host-originated WORKER MMIO transactions;
- arbitrating peripheral `BR[n]` requests with rotating round-robin fairness;
- driving at most one `BG[n]` at a time;
- enforcing exactly one manager transaction per grant epoch;
- validating and translating HOST_DMA capability handles;
- bridging accepted DMA beats to the host memory interface;
- accepting CONTROLLER-space PLIO Notification transactions;
- maintaining notification pending/configuration state;
- reporting timeout, parity, protection, reset, revoke, and memory-path faults;
- ensuring host-originated WORKER traffic never overlaps an active bus-manager grant.

## Grant epochs and continuous BR

A continuous assertion of `BG[n]` is one **grant epoch** and authorizes that slot to originate at most one PLIO manager transaction.

A manager transaction completes when its final data beat is acknowledged, or when it terminates by `ERR`, timeout, reset, protection failure, or another abort condition.

At that boundary the host controller MUST end the current grant epoch by deasserting `BG[n]`. It MUST do so independently of the current value of `BR[n]`.

A peripheral with more work MAY keep `BR[n]` asserted continuously. Continuous `BR[n]` means only "consider me in subsequent arbitration"; it does not extend the previous grant epoch and it is not a completion handshake.

There MUST be at least one sampled PLIO clock for which the completed slot observes `BG[n]` deasserted before that slot can receive a later grant epoch. The controller then rearbitrates from the current `BR` levels. The same continuously asserted `BR` may therefore win again after the mandatory BG-low boundary.

The host MUST NOT wait for `BR[n]` to deassert before withdrawing `BG[n]` after a completed transaction.

## Worker/manager mutual exclusion

`BR` does not make a peripheral a bus manager; only an active `BG` grant epoch does.

The host MAY inject a WORKER transaction while one or more peripherals have pending `BR` requests, provided no `BG` is active. A pending card may therefore be selected as a worker before its manager request is granted.

Once a manager grant epoch is active, host-originated WORKER transactions MUST wait until that manager transaction terminates and the grant epoch ends.

A queued WORKER request has host-side priority when the controller returns to its idle/arbitration boundary. This does not revoke or consume pending peripheral `BR`; the peripheral remains eligible when arbitration resumes.

## Successful DMA completion

For a successful HOST_DMA transaction, the final acknowledged PLIO data beat is the bus-transaction completion boundary. The host may expose the DMA completion to its internal consumer at that point and MUST end the manager grant epoch immediately afterward.

Device-local work that happens after the final PLIO beat, such as QIC-to-device delivery of a buffered read word or a local completion handshake, is not part of the completed PLIO grant epoch and MUST NOT cause the host to keep `BG` asserted.

Errors and aborts likewise terminate the current grant epoch; already acknowledged beats are not rolled back.

## Implementation parity

The Rust M4 host-core model and Bluespec `PLIOHostCore` are required to expose equivalent PLIO-visible grant, ACK/ERR, DMA, worker, timeout, reset, and fault behavior. Deterministic and seeded Rust/Bluesim differential tests are the implementation oracle.
