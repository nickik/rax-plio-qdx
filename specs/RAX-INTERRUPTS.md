# RAX / PLIO Interrupt Integration v0.1

**Status:** Draft integration note

## 1. Goals

The RAX microkernel is optimized for very short kernel paths and deliberately avoids normal asynchronous interruption of most kernel execution.

PLIO therefore separates:

- **normal device interrupts**, which are deferred while the CPU is in kernel mode,
- **critical platform interrupts**, which may interrupt kernel mode.

The four PLIO interrupt classes affect ordering among normal pending device interrupts. They are not four CPU interrupt privilege levels.

## 2. Physical signals to the CPU

The platform provides two direct controller-to-CPU signals:

```text
NORMAL_IRQ
CRITICAL_IRQ
```

`NORMAL_IRQ` is asserted whenever at least one enabled PLIO normal interrupt source is pending.

`CRITICAL_IRQ` is reserved for platform emergencies such as machine-check, power-fail, or watchdog events. Ordinary PLIO devices do not control it.

## 3. Normal interrupt controller state

For each PLIO slot the controller maintains:

```text
enabled
class: 0..3
pending/synchronized IRQ state
masked-by-kernel
```

The controller chooses the highest-class pending source and uses rotating round-robin among equal-class sources.

## 4. CPU behavior

### User mode

If `NORMAL_IRQ` is asserted and normal interrupts are enabled, the CPU enters the kernel interrupt vector.

### Kernel mode

Normal interrupt delivery is disabled.

`NORMAL_IRQ` remains physically observable as a pending summary.

A future RAX `BIP target` (Branch if Interrupt Pending) instruction may directly sample this summary signal. PLIO does not require the instruction; it only requires the electrical/controller signal.

### Critical interrupt

`CRITICAL_IRQ` may vector while in either user or kernel mode.

The critical path must not execute ordinary driver, QDX, scheduler, or capability operations. It is an emergency/platform mechanism.

## 5. Kernel interrupt policy

The expected kernel policy is:

- IPC fast path: no normal IRQ poll,
- short slow paths: normally no IRQ poll,
- long/restartable kernel loops: explicit normal IRQ poll at bounded work intervals,
- kernel exit: service pending normal IRQs before returning to user mode when appropriate.

This allows common IPC to avoid an interrupt-controller transaction.

## 6. Device delivery

When a PLIO slot interrupt is selected, the kernel:

1. masks that PLIO source in the controller,
2. signals the user-space driver's interrupt notification object,
3. schedules according to normal thread priority rules.

The driver:

1. drains QDX completions or services device state,
2. acknowledges/clears the device cause so `IRQ[n]*` deasserts,
3. invokes the kernel interrupt-complete operation.

The kernel then unmasks the source.

## 7. Four classes

Suggested defaults:

| Class | Name | Typical use |
|---:|---|---|
| 3 | urgent | scheduling/timing-sensitive controller |
| 2 | high | GNET receive/high-rate communications |
| 1 | normal | QDX-B storage completion |
| 0 | background | terminal/printer/management |

Class is configured by privileged platform software. A device cannot elevate itself.
