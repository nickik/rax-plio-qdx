# Roadmap

## v0.1 architecture freeze candidates

- [ ] Confirm 8 logical slots.
- [ ] Confirm 32 MiB geographic slot windows.
- [ ] Confirm 5 MHz required / 10 MHz optional clock profiles.
- [ ] Confirm one transaction per bus grant in the baseline protocol.
- [ ] Confirm 4 DMA windows per bus-manager slot.
- [ ] Confirm one level-triggered normal IRQ per slot.
- [ ] Confirm four interrupt classes in the central controller.
- [ ] Confirm QDX one-SQ/one-CQ baseline.
- [ ] Confirm QDX-B 32-byte command / 16-byte completion formats.
- [ ] Confirm 16-entry maximum scatter/gather list.

## Simulator MVP

- [x] host memory model
- [x] DMA-window translation
- [x] normal interrupt class selection
- [x] QDX-B contiguous-buffer READ/WRITE
- [x] completion generation and IRQ assertion
- [ ] explicit PLIO address/data phase machine
- [ ] bus request/grant state machine
- [ ] fair rotating round-robin arbitration
- [ ] wait states and timeout
- [ ] worker MMIO model
- [ ] scatter/gather execution
- [ ] namespace identify structures
- [ ] queue-full behavior
- [ ] device fault/reset tests

## Microkernel integration

- [ ] model user/kernel mode and normal-IRQ deferral
- [ ] model fast IPC path with zero interrupt checks
- [ ] model slow bounded operations
- [ ] model explicit long-operation preemption points
- [ ] evaluate 16I register ABI message-word count
- [ ] measure IRQ latency versus preemption-point work threshold

## Later extensions — do not pull into v0.1 prematurely

- multi-word PLIO bursts
- additional queue pairs
- advanced DMA mapping/IOMMU
- message-signalled interrupts
- peer-to-peer PLIO transfers
- device ROM bytecode
- PLIO bridge standard
- multiprocessor interrupt routing
