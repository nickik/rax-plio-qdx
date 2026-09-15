# QIC + PLIO-TX integration verification

Status: executable integration contract for the first stacked QIC/PLIO-TX verification MR.

## Purpose

This test proves that the already executable QIC logical behavior survives the frozen PTI v0.1 narrow interface and the transistor-independent PLIO-TX model. It is deliberately a verification adapter, not a new architectural layer.

```text
QLI semantic stimulus
        |
       QIC
        |
   logical PLIO image
        |
  PTI slot adapter
        | PTI v0.1
     PLIO-TX
        |
 PLIO backplane image
```

QLI-16 pin serialization is outside this MR; QLI semantics have already been frozen and tested separately. The next NakedCard integration may place QLI-16 above the QIC.

## Important timing rule

The existing QIC Rust/Bluespec phase models are PLIO-cycle models, while PTI has two ordered slots per PLIO cycle. The integration harness therefore expands a logical QIC output image into PTI slot activity before advancing the logical QIC cycle. This preserves QIC semantics while making every externally visible PLIO drive pass through the real PTI encoding and PLIO-TX latches/enables.

This is a verification construction. A later synthesizable unified QIC will schedule these PTI slots internally.

## Drive expansion

A logical PLIO output image is presented through PLIO-TX as follows.

- `BR` maps directly to `bus_request`.
- worker `ACK/ERR` map through `RESP_DRIVE` and the dedicated PT_ACK/PT_ERR pair.
- if shared control is required, a CONTROL token is loaded with the exact SPACE/AS/RD/BE/BLEN/DS image and drive-control intent.
- if AD/PAR is required, DATA_LO then DATA_HI load the exact 32-bit + 4-bit image.
- an IDLE slot precedes a new `TX_DRIVE` assertion.
- after the required latches are committed, `TX_DRIVE` exposes the requested subgroups on the backplane.
- deassertion is immediate.

Receive expansion uses TX_TO_QIC DATA_LO/DATA_HI to obtain one coherent AD/PAR sample. SEL, BG, ACK and ERR use their dedicated PTI paths and are not serialized.

## Required scenarios

The Rust and Bluespec integration traces MUST cover at least:

1. worker MMIO read including selected worker address ACK and returned read data/parity;
2. worker MMIO write including received data/parity and completion ACK;
3. HOST_TO_DEVICE DMA including address, one wait, data receive, local delivery and completion;
4. DEVICE_TO_HOST DMA including local producer word, stable driven data/parity through a target wait, ACK and completion;
5. Notification including CONTROLLER address, zero data beat and completion-based `notification_ready`;
6. target ERR with exact DMA partial progress;
7. bad incoming parity rejected before local delivery;
8. reset while output state is live, proving PLIO-TX immediately disables all drives;
9. PTI turnaround/IDLE rules with no protocol fault in all legal scenarios.

## Differential trace

Canonical line prefix:

```text
QTXTRACE|v1|
```

Each scenario emits externally observable backplane drive state plus QLI-visible QIC output and terminal status. Rust and Bluesim output MUST compare byte-for-byte after filtering to `QTXTRACE|v1` lines.

The integration test is not allowed to bypass PLIO-TX when checking AD/PAR/control/ACK/ERR/BR. A test that compares only the QIC logical `PlioOut` is not an integration test.
