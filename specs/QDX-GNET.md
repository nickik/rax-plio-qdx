# QDX-GNET v0.2 — GNet Frame I/O

**Status:** Draft

## 1. Purpose

QDX-GNET is the base queued interface for a GNet endpoint controller. It carries one complete, opaque GNet frame between host DMA memory and a selected physical GNet port.

It inherits QDX v0.5 queue transport, little-endian control structures, PLIO protected DMA, and PLIO Notification completion rules. Frame bytes are network payload bytes and are never byte-swapped.

A controller may expose one or more ports. The first hardware target is a **two-port endpoint card**. Its ports are independently usable host interfaces; the base profile performs no port-to-port forwarding and contains no routing table.

## 2. Scope boundary

QDX-GNET terminates at the GNet frame/link boundary. The card performs its local DLP/link work, including link credit handling and link reset, but it does not interpret or modify GDP, GCTL, GTS, or application payloads.

The profile does not define routing, forwarding, hop-limit updates, reliable transport, sessions, naming, authentication, or network policy. A router-class card is a separate future profile.

## 3. Required capabilities

A base controller MUST support:

- one QDX SQ/CQ pair;
- RECEIVE, TRANSMIT, IDENTIFY_CONTROLLER, IDENTIFY_PORT, STATUS, SET_ADDRESS, and SET_FILTER;
- one or more independently reported ports;
- direct contiguous DMA buffers;
- host-visible completion and PLIO Notification;
- reset cancellation of in-flight operations;
- link status and error counters.

The two-port reference card MUST expose ports 0 and 1. It MUST allow simultaneous work on both ports, subject only to documented shared DMA and queue arbitration.

## 4. Submission descriptor

Every QDX-GNET command is a 32-byte little-endian descriptor.

| Offset | Size | Field | Meaning |
|---:|---:|---|---|
| `0x00` | 1 | `opcode` | operation |
| `0x01` | 1 | `flags` | operation flags |
| `0x02` | 1 | `port` | physical port number |
| `0x03` | 1 | reserved | zero |
| `0x04` | 4 | `tag` | host-selected command tag |
| `0x08` | 4 | `data_addr` | DMA capability address of data/control buffer |
| `0x0C` | 4 | `data_len` | buffer length in bytes |
| `0x10` | 4 | `command_arg` | opcode-specific argument, otherwise zero |
| `0x14` | 12 | reserved | zero |

Reserved fields MUST be written zero and ignored by a v0.2 controller.

`port` MUST name an implemented port for port-specific commands. A device rejects an invalid port with `INVALID_PORT`.

## 5. Opcodes

| Opcode | Name | Meaning |
|---:|---|---|
| `0x00` | `NOP` | completion-only test operation |
| `0x01` | `IDENTIFY_CONTROLLER` | write controller information to `data_addr` |
| `0x02` | `IDENTIFY_PORT` | write selected-port information to `data_addr` |
| `0x03` | `STATUS` | write current selected-port status to `data_addr` |
| `0x10` | `RECEIVE` | post one host receive buffer for the selected port |
| `0x11` | `TRANSMIT` | transmit exactly one frame from host memory on the selected port |
| `0x12` | `SET_ADDRESS` | set the selected port link address from a control buffer |
| `0x13` | `SET_FILTER` | set selected-port acceptance flags from `command_arg` |

## 6. Frame transfer rules

For `TRANSMIT`, `data_addr` identifies a device-readable buffer containing exactly `data_len` frame bytes. The controller MUST reject zero-length and oversized frames before transmitting any byte.

For `RECEIVE`, `data_addr` identifies a device-writable buffer of `data_len` bytes. The operation remains pending until one accepted frame arrives, link reset cancels it, or a device/DMA fault occurs. The controller writes no more than `data_len` bytes. A received frame larger than the posted buffer is dropped, increments the selected port's oversize-drop counter, and completes the posted RECEIVE with `BUFFER_TOO_SMALL` and the actual frame length in `info`.

A controller MUST retain received frames only in bounded per-port hardware storage. If no posted RECEIVE can accept a frame, it drops the frame and increments `rx_no_buffer_drops`; it MUST NOT use unbounded host-side storage.

## 7. Completion descriptor

Every QDX-GNET completion is 16 bytes, little-endian.

| Offset | Size | Field | Meaning |
|---:|---:|---|---|
| `0x00` | 4 | `tag` | submitted tag |
| `0x04` | 2 | `status` | completion status |
| `0x06` | 1 | `port` | command port |
| `0x07` | 1 | `flags` | completion flags |
| `0x08` | 4 | `bytes_done` | bytes transmitted or delivered |
| `0x0C` | 4 | `info` | opcode/status-specific information |

The normal QDX CQ empty-to-non-empty notification rule applies. Completion and all reported DMA bytes MUST be host-visible before the PLIO Notification is observable.

## 8. Completion status

| Status | Name |
|---:|---|
| `0x0000` | `SUCCESS` |
| `0x0001` | `INVALID_OPCODE` |
| `0x0002` | `INVALID_FIELD` |
| `0x0003` | `INVALID_PORT` |
| `0x0004` | `NOT_READY` |
| `0x0005` | `DMA_FAULT` |
| `0x0006` | `BUFFER_TOO_SMALL` |
| `0x0007` | `LINK_DOWN` |
| `0x0008` | `LINK_RESET` |
| `0x0009` | `QUEUE_ERROR` |
| `0x000A` | `INTERNAL_ERROR` |

For a `BUFFER_TOO_SMALL` RECEIVE, `bytes_done` is zero and `info` is the actual received frame length. For link/DMA failures, `bytes_done` reports only bytes whose required host-DMA visibility was completed.

## 9. Identify and status buffers

`IDENTIFY_CONTROLLER` writes exactly 64 bytes:

| Offset | Size | Field |
|---:|---:|---|
| `0x00` | 2 | profile revision (`0x0002`) |
| `0x02` | 1 | port count |
| `0x03` | 1 | controller flags |
| `0x04` | 4 | maximum frame bytes |
| `0x08` | 4 | capability bits |
| `0x0C` | 4 | per-port RX FIFO capacity in bytes |
| `0x10` | 16 | model identifier |
| `0x20` | 16 | serial identifier |
| `0x30` | 16 | reserved zero |

`IDENTIFY_PORT` and `STATUS` each write exactly 64 bytes:

| Offset | Size | Field |
|---:|---:|---|
| `0x00` | 1 | port number |
| `0x01` | 1 | link state |
| `0x02` | 2 | negotiated link flags |
| `0x04` | 8 | link address |
| `0x0C` | 4 | maximum frame bytes |
| `0x10` | 4 | RX frames |
| `0x14` | 4 | TX frames |
| `0x18` | 4 | RX no-buffer drops |
| `0x1C` | 4 | RX oversize drops |
| `0x20` | 4 | link/CRC fault count |
| `0x24` | 4 | reset count |
| `0x28` | 24 | reserved zero |

Counters saturate at their maximum values. Link state is `DOWN`, `TRAINING`, `UP`, or `RESETTING`.

## 10. Address and filter controls

`SET_ADDRESS` reads an 8-byte link address from `data_addr`. It MUST complete only after the selected port has applied the new address; changing the address cancels no already-accepted RECEIVE or TRANSMIT operation.

`SET_FILTER` uses `command_arg`:

| Bit | Name | Meaning |
|---:|---|---|
| 0 | `ACCEPT_LOCAL` | accept frames addressed to this port |
| 1 | `ACCEPT_BROADCAST` | accept link broadcast |
| 2 | `PROMISCUOUS` | accept all valid link frames |
| 3..31 | reserved | zero |

The reset default is `ACCEPT_LOCAL | ACCEPT_BROADCAST`.

## 11. Reset, ordering, and faults

Reset immediately stops DMA and link transmission, discards local FIFOs, clears transient link-credit state, disables notification, and cancels outstanding commands. Software reinitializes normal QDX queues before re-enabling the controller.

Commands for different ports may complete out of order. For one port, a RECEIVE or TRANSMIT completion reports that command's own terminal state; this profile does not promise stronger ordering.

DMA capability, generation, bounds, direction, and full-extent checks are mandatory. A descriptor/control/data DMA failure completes `DMA_FAULT` where the CQ remains writable; inability to publish CQ entries places the device in the normal QDX `FAULT` state.

## 12. Hardware reference card

The first hardware implementation is a two-port PLIO QDX-GNET endpoint card. For each port it contains independent bounded RX/TX FIFOs, DLP/link state, link reset, credit state, and counters. The shared QDX/DMA front end arbitrates only host-side memory and PLIO activity.

The Rust model and Bluespec card MUST expose the same observable QDX/MMIO, DMA, completion, notification, link-state, reset, and counter behaviour. Neither model may substitute a host-networking shortcut for the card's queue and link boundary.
