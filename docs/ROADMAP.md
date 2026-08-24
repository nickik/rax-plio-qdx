# Roadmap

## Architecture freeze candidates

- [ ] Confirm 8 logical slots.
- [ ] Confirm 32 MiB geographic slot windows.
- [ ] Confirm 5 MHz required / 10 MHz optional clock profiles.
- [x] Adopt **one transaction per bus grant**, where one transaction may be a bounded 1/4/8/16-word host-memory DMA burst.
- [x] Adopt **1/4/8/16-word 32-bit DMA bursts** in the PLIO baseline.
- [x] Limit one burst to **16 longwords / 64 bytes** before arbitration resumes.
- [x] Keep programmed MMIO and notification writes single-beat in the baseline.
- [x] Adopt **16 protected DMA capability channels per bus-manager slot**.
- [x] Adopt **4-bit generation tags** in device-visible DMA addresses for stale-reference rejection.
- [x] Adopt 32-bit DMA handle layout: `channel[31:28] | generation[27:24] | offset[23:0]`.
- [x] Reject dedicated per-slot IRQ lines.
- [x] Adopt **PLIO message-signalled normal notifications** through a fixed controller aperture.
- [ ] Confirm 4 notification channels per slot.
- [ ] Confirm four controller-assigned normal notification classes.
- [ ] Confirm QDX one-SQ/one-CQ baseline.
- [ ] Confirm QDX-B 32-byte command / 16-byte completion formats.
- [ ] Confirm 16-entry maximum scatter/gather list.

## Simulator MVP

- [x] host memory model
- [x] DMA protection/translation model
- [x] generation-tagged DMA handle model
- [x] stale DMA-reference rejection after revoke/rebind
- [x] baseline burst-length encoding model
- [x] functional full-range validation for 1/4/8/16-word DMA bursts
- [x] normal notification class selection
- [x] QDX-B contiguous-buffer READ/WRITE
- [x] QDX completion generation and notification
- [ ] explicit PLIO address/data phase machine
- [ ] bus request/grant state machine
- [ ] fair rotating round-robin arbitration
- [ ] explicit 1/4/8/16-beat burst state machine
- [ ] re-arbitrate after every completed/aborted burst
- [ ] per-beat wait states, `ACK*`, `ERR*`, and timeout
- [ ] active-burst DMA revocation/interlock behavior
- [ ] model controller-owned NOTIFY transactions as real single-beat bus cycles
- [ ] worker MMIO model
- [ ] scatter/gather execution split into bounded PLIO bursts
- [ ] namespace identify structures
- [ ] queue-full behavior
- [ ] device fault/reset tests
- [ ] DMA capability revocation test at cycle level
- [ ] generation mismatch and generation-wrap/reset tests at cycle level
- [ ] measure PLIO-5 payload throughput for 1/4/8/16-word transfers
- [ ] measure notification latency behind maximum-length DMA bursts

## Microkernel integration

- [ ] model user/kernel mode and normal-notification deferral
- [ ] model capability-controlled bind/revoke of DMA channels
- [ ] model generation return from DMA binding and safe channel reuse
- [ ] model revocation completion while a burst is active
- [ ] model driver notification capabilities
- [ ] model fast IPC path with zero device-event checks
- [ ] model slow bounded operations
- [ ] model explicit long-operation preemption points
- [ ] evaluate SIA register ABI message-word count
- [ ] measure notification latency versus preemption-point work threshold

## Later extensions — do not pull into baseline prematurely

- worker-side/MMIO block transfers
- burst lengths greater than 16 longwords
- additional queue pairs
- more than sixteen DMA capability channels if measured workloads require them
- wider generation tags or extended DMA handles if long-lived workloads require them
- peer-to-peer PLIO transfers
- device ROM bytecode
- PLIO bridge standard
- multiprocessor notification routing
