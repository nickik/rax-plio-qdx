# Rust PLIO-QIC audit

**Status:** audited against PLIO v0.6, QLI v0.1, PLIO-E, PTI v0.1, and the non-product PLIO test peer before Bluespec QIC work.

The Rust model in `rust/` is the executable architectural reference for the peripheral-side QIC. This audit checks the QIC as a chip boundary in both directions:

```text
PLIO backplane <- PTI / PLIO-TX <- QIC -> QLI -> card-local logic
```

The QIC core is intentionally written against abstract PLIO and QLI signals. PTI and QLI-16 remain boundary adapters and MUST NOT alter QIC protocol semantics.

## 1. External PLIO-side contract

The audited Rust QIC now matches these PLIO rules:

- responds as a worker only to selected `SPACE=WORKER` transactions;
- checks 25-bit slot-relative address legality, natural 8/16/32-bit transfer encoding, `BLEN=1`, and full address parity;
- ACKs a valid worker address phase and ERRs an invalid address phase;
- latches address-phase controls for the data phase rather than depending on later bus values;
- checks worker write parity only on the byte lanes selected by the latched byte enable;
- generates read-data parity and returns ACK/ERR only as the selected worker;
- requests bus-manager ownership with BR and drives no manager address/data before BG;
- performs exactly one manager transaction per grant;
- emits only `HOST_DMA` or `CONTROLLER` transactions as a manager, never `WORKER`;
- holds manager address/control stable until address ACK/ERR/timeout;
- does not begin DMA/Notification data until address ACK;
- uses `BE=1111` and all baseline `BLEN` values for DMA;
- implements both DMA directions and 1/4/8/16-word bursts;
- generates/checks odd parity on every 32-bit DMA beat;
- honors per-beat ACK/ERR/wait and the 256-clock timeout;
- reports exact acknowledged partial progress on failed DMA;
- treats loss of BG during unfinished manager bus work as a protocol error;
- may drain an already-ACKed final host-to-device word locally after BG is withdrawn;
- emits Notification as one `SPACE=CONTROLLER`, `RD=0`, `BE=1111`, `BLEN=1` write to `4*channel`;
- uses zero Notification write data, which is legal because PLIO makes the payload advisory;
- releases manager activity on reset and drives the shared bus inactive.

## 2. Internal QLI-side contract

The audited Rust QIC now matches these QLI rules:

- QLI exposes no slot identity, host physical address, CPU vector, CPU target, or QDX semantics;
- one worker-MMIO request and one DMA transaction may be outstanding;
- MMIO request payload remains stable until `mmio_ready`;
- MMIO response is consumed only when the enclosing PLIO data beat is active;
- if an accepted MMIO request outlives the PLIO timeout, the QIC asserts `mmio_cancel` so the endpoint cannot retain a stale response;
- DMA request acceptance transfers responsibility for exactly one PLIO DMA transaction to the QIC;
- host-to-device words are buffered and delivered in order;
- device-to-host words are accepted through bounded one-word buffering;
- local DMA stalls cannot retain a PLIO grant indefinitely;
- DMA completion reports PLIO-visible progress, is held under backpressure, and survives after bus ownership is released;
- Notification is completion-based: `notification_ready` means the PLIO Notification data beat was ACKed;
- Notification wins over a simultaneously offered new DMA request at an idle boundary but never preempts active DMA;
- reset cancels retained QLI state without manufacturing a DMA completion.

## 3. Audit corrections made before Bluespec

The audit found and corrected three real issues:

1. **Address-phase handshake was underspecified/under-modeled.** PLIO defines ACK/ERR for the current address/data beat and a timeout per outstanding address/data beat. The Rust QIC previously advanced from a manager address phase after one clock without waiting for ACK. The model now waits for address ACK/ERR/timeout; valid worker addresses are explicitly ACKed.
2. **Accepted MMIO had no cancellation path.** A local endpoint could accept an MMIO request, PLIO could time out before the response arrived, and the endpoint could then retain a stale response forever. QLI now has `mmio_cancel`, and the Rust QIC asserts it on that abort path.
3. **Worker write parity combinational checking used the current bus BE instead of the latched address-phase BE.** The QIC now uses the latched byte-enable, matching PLIO's address-phase control semantics.

The existing PLIO signal table already defines `ACK*` as accepting the current address/data beat and the timeout rule applies to an outstanding address/data beat. The Rust model now follows that interpretation. The address-phase prose should still be made explicit before Bluespec Phase 1 so the rule is not left implicit.

## 4. Explicit non-responsibilities

These are intentionally not bugs in the peripheral QIC:

- rotating-round-robin arbitration policy is in the host PLIO controller;
- DMA capability lookup, generation validation, bounds checking, translation, and revocation interlock are in the host controller;
- host-memory ordering implementation is outside the QIC, although the QIC preserves its own transaction order;
- host Notification pending/mask/class/claim logic is in the controller/host profile;
- PLIO electrical thresholds, drive current, termination, and backplane timing are PLIO-TX/PLIO-E responsibilities;
- PTI and QLI-16 serialization are adapters around the abstract QIC core;
- QDX is entirely above QLI.

## 5. Remaining boundary work before physical FPGA integration

The abstract QIC is suitable as the Rust behavioral reference for Bluespec. Physical integration still needs:

- explicit PLIO prose for successful address-phase ACK before data;
- QLI-16 encoding for `mmio_cancel`;
- full PTI control-image/turnaround adapter implementation, not only payload packing;
- explicit mapping of abstract manager-drive versus worker-response enables into PTI/PLIO-TX;
- electrical PLIO-E timing/turnaround validation;
- later iCE40 wrapper and pin constraints.

None of those should be folded into the core QIC state machine.
