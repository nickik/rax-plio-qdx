# Lighting PLIO0 in the Mainboard

## Goal

`MainboardFPGA` owns the Lighting platform unit made from the CPU-facing
memory path, `MemoryController`, and the PLIO host controller. A CPU board
and the eight physical cards remain external peers.

The implementation MUST use the already frozen Lighting PLIO0 profile. It
MUST NOT add a second PLIO ABI, a Rust-side controller, or a CPU-direct card
path.

```text
CPU board -> MainboardFPGA -> MemoryController -> RAM
                  |                    ^
                  +-> PLIO0 host -------+
                         |       |
                      worker    protected DMA
                         |
                    eight card slots
```

## M6.6a — CPU physical PLIO0 decode

- [ ] Decode the existing Lighting PLIO0 aperture at `0xffe00000` in the
  production Mainboard CPU path.
- [ ] Preserve normal RAM traffic through `MemoryController`; PLIO0 accesses
  MUST NOT reach the external RAM backend.
- [ ] Make aligned 32-bit controller-register reads/writes complete through
  the normal CPU `BUS_REQ/REQ/READY|ERROR` protocol.
- [ ] Reject unsupported width, alignment, reserved-offset, and malformed
  command accesses as CPU-visible faults.
- [ ] Keep reset atomic across CPU response state, PLIO0 state, host worker,
  DMA capability state, notification state, and MemoryController state.

## M6.6b — existing IOchannel worker mapping

- [ ] Implement the frozen eight IOchannel map registers and 64 KiB windows.
- [ ] Translate a CPU window access into one selected, slot-relative PLIO
  worker transaction through the existing `PLIOHostCore` worker state machine.
- [ ] Hold the CPU response until the worker completes; preserve worker width,
  byte lanes, parity, ACK/ERR, and timeout behavior.
- [ ] Prove that a real QDX-B configuration read is reached only through the
  CPU -> Mainboard -> PLIO worker -> card-pin path.

## M6.6c — DMA, notifications, and claim

- [ ] Implement the frozen per-slot DMA capability CSR table as a staged
  base/length/control interface to `PLIOHostCore` bind/revoke.
- [ ] Implement notification enable/mask/class configuration and claim/data
  registers through the same host controller state.
- [ ] Prove a card-originated DMA transfer reaches RAM only through
  `MemoryController` and that a CPU claim clears exactly one eligible PLIO
  Notification.

## M6.6d — hardware proof and Lighting integration

- [ ] Add a focused Bluesim proof covering CPU controller access, IOchannel
  worker access, protected DMA, notification, claim, reset, and RAM isolation.
- [ ] Run the affected M6, PLIO host, Bluespec, Rust, and P0 gates.
- [ ] Freeze the exact green `rax-plio-qdx` SHA.
- [ ] Repin LightingSimulation and run the existing guest QDX-B/Pico sequence
  through `LightingBoardMachine` with a generic physical card slot.

## Invariants

- `MainboardFPGA` is the sole PLIO arbitration/protocol authority.
- `MemoryController` remains the sole CPU/PLIO RAM transaction path.
- Worker MMIO is single-beat; PLIO DMA remains bounded full-word traffic.
- Cards receive only registered `PlioIn` images and emit next-epoch drives.
- CPU-visible PLIO0 is a Lighting host-profile mapping, not a universal PLIO
  address-map change.
