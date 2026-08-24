# RAX / PLIO Notification and Interrupt Integration v0.2

**Status:** Draft integration note

## 1. Goals

The RAX/Cosmic microkernel is optimized for short kernel paths and deliberately avoids normal asynchronous preemption of most kernel execution.

PLIO therefore separates:

- **normal device notifications**, sent as PLIO bus messages and normally deferred during kernel execution,
- **critical platform events**, such as machine-check/power-fail/watchdog conditions, which are outside ordinary PLIO device notification and may interrupt kernel execution.

There are no dedicated device-to-controller interrupt wires on PLIO.

## 2. Device signalling

A normal device event is a PLIO write to the controller-owned notification aperture defined by `PLIO.md`.

The central controller derives source identity from the currently granted bus manager. The message therefore does not carry a trusted slot identity.

For each physical slot, up to four notification channels are available. Privileged software configures each channel's enable/mask/class state.

## 3. Controller state

For each `(slot, channel)` the controller maintains:

```text
enabled
class: 0..3
pending
masked
```

A notification write sets `pending`. Repeated writes may coalesce while pending.

The controller chooses the highest-class enabled/unmasked pending source and uses rotating round-robin among equal-class sources.

The class is host policy. A device cannot elevate itself.

## 4. CPU-facing integration

PLIO itself defines no device interrupt pins.

The PLIO controller exposes an aggregate `normal_notification_pending` condition to the CPU/memory complex. In a TTL RAX implementation this may be an internal controller-to-CPU signal; in later implementations it may be integrated differently. It is **not part of the PLIO card/backplane interface**.

A future SIA/RAX `BIP target` (Branch if Interrupt Pending) instruction may sample the aggregate condition directly. PLIO does not require that instruction.

Critical platform events are handled separately by platform/machine-check logic and are not ordinary PLIO messages.

## 5. CPU behavior

### User mode

If a normal device notification is pending and normal asynchronous delivery is enabled, the CPU enters the kernel's normal device-event vector.

### Kernel mode

Normal asynchronous device delivery is normally deferred.

The aggregate pending state remains observable. Long or restartable kernel operations may explicitly test it at bounded preemption points.

### Critical platform event

Critical platform handling may occur in user or kernel mode. It must not execute ordinary driver, QDX, scheduler, or capability operations; it is an emergency/platform mechanism.

## 6. Claim and delivery

When the kernel services normal device events it asks the controller to **claim** the next source.

Claiming MUST atomically:

1. select the highest-priority enabled/unmasked `(slot, channel)`,
2. return that source identity,
3. clear that source's pending bit.

The kernel may then mask the source and signal the user-space driver's notification object.

The driver drains QDX completions or services device state, then invokes the kernel interrupt/notification-complete operation. The kernel unmasks the source.

If a new device message arrived while the source was masked, `pending` remains set and becomes deliverable immediately after unmask. This is the required no-lost-wakeup rule.

## 7. Four classes

Suggested defaults:

| Class | Name | Typical use |
|---:|---|---|
| 3 | urgent | scheduling/timing-sensitive controller |
| 2 | high | GNet receive/high-rate communications |
| 1 | normal | QDX-B storage completion |
| 0 | background | terminal/printer/management |

Class is configured by privileged platform software, not by the device message.

## 8. Capability relationship

The kernel may represent a device's right to notify as a capability associated with a PLIO slot/channel. A user-space driver can receive a notification object without receiving authority to reprogram the controller's class, source identity, or CPU routing.

This mirrors DMA capability channels: the controller enforces a small hardware authority table while Cosmic exposes higher-level capability objects to software.
