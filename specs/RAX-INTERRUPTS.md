# RAX / PLIO Notification and CPU Interrupt Integration v0.4

**Status:** Draft integration note

## 1. Goals

The RAX/Cosmic microkernel is optimized for short kernel paths and deliberately avoids normal asynchronous preemption of most kernel execution.

PLIO therefore separates:

- **PLIO Notifications** — normal device notifications sent as bus-local PLIO controller transactions and normally deferred during kernel execution,
- **critical platform events** — machine-check, power-fail, watchdog, and similar conditions outside ordinary PLIO Notification handling that may interrupt kernel execution.

There are no dedicated device-to-controller interrupt wires on PLIO.

The canonical device-to-host term is **PLIO Notification**. PLIO specifications should not describe this mechanism as MSI or an MSI-like interrupt mechanism.

## 2. PLIO Notification signalling

A normal device event is one single-beat PLIO controller-local transaction defined by `PLIO.md`:

```text
SPACE = CONTROLLER
BLEN  = 00
AD    = 0x0000_0000 + 4 * notification_channel
```

These are bus-local controller offsets, not RAX CPU physical addresses.

The central controller derives source identity from the currently granted bus manager. The PLIO Notification therefore does not carry a trusted slot identity.

For each physical slot, four notification channels are available. Privileged software configures each channel's enable/mask/class state.

## 3. Controller state

For each `(slot, channel)` the controller maintains:

```text
enabled
class: 0..3
pending
masked
```

A PLIO Notification write sets `pending`. Repeated writes may coalesce while pending.

The controller chooses the highest-class enabled/unmasked pending source and uses rotating round-robin among equal-class sources.

The class is host policy. A device cannot elevate itself.

## 4. CPU-facing integration

PLIO itself defines no CPU interrupt vector and no device interrupt pins.

The RAX host profile exposes one aggregate CPU-side interrupt condition named:

```text
NOTIFY_PENDING_INTERRUPT
```

`NOTIFY_PENDING_INTERRUPT` is asserted by the RAX PLIO controller whenever at least one enabled, unmasked normal PLIO Notification is pending and eligible for delivery.

This is an **internal host-controller-to-CPU condition**, not a PLIO card/backplane signal. A later RAX implementation may integrate the same architectural condition without a literal package pin or board trace.

A future SIA/RAX `BIP target` (Branch if Interrupt Pending) instruction may sample `NOTIFY_PENDING_INTERRUPT` directly. PLIO does not require that instruction.

Critical platform events are handled separately by platform/machine-check logic and are not ordinary PLIO Notifications.

## 5. CPU behavior

### User mode

If `NOTIFY_PENDING_INTERRUPT` is asserted and normal asynchronous delivery is enabled, the CPU enters the kernel's normal device-event vector.

### Kernel mode

Normal asynchronous PLIO Notification delivery is normally deferred.

`NOTIFY_PENDING_INTERRUPT` remains observable. Long or restartable kernel operations may explicitly test it at bounded preemption points.

### Critical platform event

Critical platform handling may occur in user or kernel mode. It must not execute ordinary driver, QDX, scheduler, or capability operations; it is an emergency/platform mechanism.

## 6. Claim and delivery

When the kernel services normal device events it asks the PLIO host controller to **claim** the next source through privileged host-side controller state defined by the RAX platform profile.

Claiming MUST atomically:

1. select the highest-priority enabled/unmasked `(slot, channel)`,
2. return that source identity,
3. clear that source's pending bit.

The kernel may then mask the source and signal the user-space driver's notification object.

The driver drains QDX completions or services device state, then invokes the kernel notification-complete operation. The kernel unmasks the source.

If a new PLIO Notification arrived while the source was masked, `pending` remains set and becomes deliverable immediately after unmask. This is the no-lost-wakeup rule.

## 7. Four classes

Suggested defaults:

| Class | Name | Typical use |
|---:|---|---|
| 3 | urgent | scheduling/timing-sensitive controller |
| 2 | high | GNet receive/high-rate communications |
| 1 | normal | QDX-B storage completion |
| 0 | background | terminal/printer/management |

Class is configured by privileged host software, not by the device notification.

## 8. Capability relationship

The kernel may represent a device's right to receive/deliver notification as a capability associated with a PLIO slot/channel. A user-space driver can receive a notification object without receiving authority to reprogram controller class, source identity, or CPU routing.

This mirrors DMA capability channels: PLIO enforces a small hardware authority table while Cosmic exposes higher-level capability objects to software.

## 9. RAX host address separation

The RAX host-controller CSR reservation is defined by `PLIO-RAX.md` and is CPU-visible privileged state only.

A PLIO card MUST NOT know or write the RAX `0xEFFF_F000` host-controller CSR address. Card signalling is entirely through the bus-local `SPACE=CONTROLLER` PLIO Notification transaction above.
