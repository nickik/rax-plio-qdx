# Roadmap

## Architecture freeze candidates

- [ ] Confirm 8 logical peripheral slots.
- [ ] Confirm 32 MiB slot-relative worker windows.
- [x] Move host CPU physical address placement out of universal PLIO into host profiles.
- [x] Preserve RAX `0xF000_0000..0xFFFF_FFFF` geographic MMIO mapping in `PLIO-RAX.md`.
- [x] Adopt transaction-space selector for `WORKER`, `HOST_DMA`, `CONTROLLER`, and reserved space.
- [ ] Confirm 5 MHz required / 10 MHz optional clock profiles.
- [x] Adopt one transaction per grant, where a transaction may be a bounded 1/4/8/16-word host-memory DMA burst.
- [x] Limit one burst to 16 longwords / 64 bytes before arbitration resumes.
- [x] Keep programmed MMIO and notification writes single-beat.
- [x] Adopt 16 protected DMA capability channels per bus-manager slot.
- [x] Adopt 4-bit generation tags in device-visible DMA addresses.
- [x] Adopt 32-bit DMA handle layout: `channel[31:28] | generation[27:24] | offset[23:0]`.
- [x] Reject dedicated per-slot IRQ lines.
- [x] Make normal notification a **bus-local `SPACE=CONTROLLER` transaction** rather than a host physical-address write.
- [ ] Confirm 4 notification channels per slot.
- [ ] Confirm four controller-assigned normal notification classes.
- [x] Adopt canonical **little-endian QDX control structures** independent of host CPU byte order.
- [ ] Confirm QDX one-SQ/one-CQ baseline.
- [ ] Confirm QDX-B 32-byte command / 16-byte completion formats.
- [ ] Confirm 16-entry maximum scatter/gather list.
- [x] Adopt **PLIO-E 3U Eurocard / 96-position DIN 41612-style P1** as baseline plug-in mechanics.
- [ ] Freeze PLIO-E detailed electrical loading/termination limits for PLIO-5 and PLIO-10.

## Host profiles

- [x] RAX geographic MMIO profile.
- [x] RAX privileged PLIO host-controller CSR reservation.
- [x] RAX normal-notification integration separated from bus-local card signalling.
- [ ] Define generic host-profile conformance requirements.
- [ ] Create one non-RAX example host profile to prove CPU/address-map independence.

## Simulator MVP

- [x] host memory model
- [x] DMA protection/translation model
- [x] generation-tagged DMA handle model
- [x] stale DMA-reference rejection after revoke/rebind
- [x] functional 1/4/8/16-word burst extent validation
- [x] transaction-space constants and bus-local notification offsets
- [x] RAX host MMIO encode/decode model
- [x] QDX canonical little-endian encode/decode helpers
- [x] normal notification class selection
- [x] QDX-B contiguous-buffer READ/WRITE
- [x] QDX completion generation and notification
- [ ] explicit PLIO `SPACE`/address/data phase machine
- [ ] bus request/grant state machine
- [ ] fair rotating round-robin arbitration
- [ ] cycle-level 1/4/8/16-beat DMA bursts
- [ ] model controller-local NOTIFY transactions as real bus cycles
- [ ] wait states and timeout
- [ ] worker MMIO model using slot-relative offsets
- [ ] scatter/gather execution
- [ ] namespace identify structures
- [ ] queue-full behavior
- [ ] device fault/reset tests
- [ ] active-burst capability revocation test at cycle level
- [ ] generation mismatch and wrap/reset tests at cycle level

## Microkernel integration

- [ ] model user/kernel mode and normal-notification deferral
- [ ] model capability-controlled bind/revoke of DMA channels
- [ ] model generation return from DMA binding and safe channel reuse
- [ ] model driver notification capabilities
- [ ] model RAX host-controller claim/mask interface separately from PLIO card protocol
- [ ] model fast IPC path with zero device-event checks
- [ ] model explicit long-operation preemption points
- [ ] measure notification latency versus maximum 64-byte active burst

## Physical/electrical work

- [x] choose Eurocard mechanics instead of a DEC-proprietary card format
- [x] choose 96-position three-row P1 connector
- [x] assign P1 pins including grounds, `SPACE`, `BLEN`, slot arbitration, and power
- [ ] validate current per-pin supply allocation against expected high-power storage/graphics cards
- [ ] model TTL output loading, connector capacitance, trace length/stubs, clock skew, and termination
- [ ] verify PLIO-10 margins without changing the PLIO-E pinout
- [ ] design reference 4/8-slot PLIO-E backplanes

## Later extensions — do not pull into baseline prematurely

- additional queue pairs
- more than sixteen DMA capability channels if measured workloads require them
- wider generation tags or extended DMA handles if long-lived workloads require them
- peer-to-peer peripheral transfers
- device ROM bytecode
- hot insertion
- multiprocessor notification routing inside host profiles
- faster/new physical layer that preserves QDX and capability semantics
