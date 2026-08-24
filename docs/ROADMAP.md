# Roadmap

## Architecture freeze candidates

- [ ] Confirm 8 logical slots.
- [ ] Confirm 32 MiB geographic slot windows.
- [ ] Confirm 5 MHz required / 10 MHz optional clock profiles.
- [ ] Confirm one transaction per bus grant in the baseline protocol.
- [ ] Confirm **4 protected DMA capability channels per bus-manager slot**.
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
- [x] normal notification class selection
- [x] QDX-B contiguous-buffer READ/WRITE
- [x] QDX completion generation and notification
- [ ] explicit PLIO address/data phase machine
- [ ] bus request/grant state machine
- [ ] fair rotating round-robin arbitration
- [ ] model controller-owned NOTIFY transactions as real bus cycles
- [ ] wait states and timeout
- [ ] worker MMIO model
- [ ] scatter/gather execution
- [ ] namespace identify structures
- [ ] queue-full behavior
- [ ] device fault/reset tests
- [ ] DMA capability revocation test at cycle level

## Microkernel integration

- [ ] model user/kernel mode and normal-notification deferral
- [ ] model capability-controlled bind/revoke of DMA channels
- [ ] model driver notification capabilities
- [ ] model fast IPC path with zero device-event checks
- [ ] model slow bounded operations
- [ ] model explicit long-operation preemption points
- [ ] evaluate SIA register ABI message-word count
- [ ] measure notification latency versus preemption-point work threshold

## Later extensions — do not pull into baseline prematurely

- multi-word PLIO bursts
- additional queue pairs
- more than four DMA capability channels if measured workloads require them
- peer-to-peer PLIO transfers
- device ROM bytecode
- PLIO bridge standard
- multiprocessor notification routing
