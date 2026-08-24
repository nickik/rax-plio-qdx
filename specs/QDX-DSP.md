# QDX-DSP v0.1 — Digital Signal Processing

**Status:** Draft

QDX-DSP is the queued profile for asynchronous signal-processing accelerators. It is intended for audio, communications, filtering, transforms, instrumentation, and other block-oriented workloads where a device repeatedly consumes buffers, performs substantial computation, and produces buffers or state.

QDX-DSP is separate from QDX-S. QDX-S models stream endpoints such as tape, serial links, scanners, and audio I/O. QDX-DSP models a computational worker that transforms data already represented in host memory.

## 1. Architectural model

A QDX-DSP device receives work through the normal QDX submission queue and publishes normal QDX completions.

The baseline data path is:

```text
host input buffers
       |
       | PLIO capability-scoped DMA
       v
   QDX-DSP device
       |
 optional local SRAM
       |
 DSP arithmetic/control
       |
       | PLIO capability-scoped DMA
       v
host output buffers
```

The device MUST NOT receive unrestricted host physical addresses. All queue entries, input buffers, output buffers, coefficient/state blocks, and parameter blocks use device-visible PLIO DMA addresses.

Local SRAM, coefficient RAM, register files, FIFOs, and microcode stores are device implementation details unless explicitly exposed by a later optional profile.

## 2. Ownership model

A capability-based RAX system SHOULD normally grant a QDX-DSP device and its DMA bindings to a service process such as an audio, modem, or signal-processing server rather than to every application.

Applications may transfer or share memory capabilities with that server. The server submits QDX-DSP commands and owns synchronization with any QDX-S audio or communications endpoint.

This ownership policy is not required by the wire protocol, but the profile is designed so a microkernel can isolate DSP authority from ordinary applications.

## 3. Base operations

QDX-DSP v0.1 defines the following transport-level operations:

```text
IDENTIFY
LOAD_PROGRAM
RUN
RESET_CONTEXT
```

`IDENTIFY` reports profile revision, DSP execution-format identifier, supported sample/data formats, local-memory limits visible to software if any, maximum buffer counts/sizes, alignment rules, and optional features.

`LOAD_PROGRAM` loads or selects a DSP program/kernel into a device execution context. The program format is identified by `IDENTIFY`; QDX-DSP does not require all DSP implementations to share one machine ISA.

`RUN` executes a previously loaded/selected program over one or more capability-scoped host buffers and an optional parameter/state block.

`RESET_CONTEXT` stops work associated with the selected execution context and returns it to its initial state.

A fixed-function QDX-DSP device MAY implement `LOAD_PROGRAM` as selection among ROM-resident kernels rather than writable instruction memory.

## 4. RUN command model

A `RUN` command identifies an execution context and references a compact descriptor or parameter block containing:

```text
program/context id
input buffer address(es)
input byte count(s)
output buffer address(es)
output byte count(s)
parameter/state block address and length
operation flags
```

All addresses are device-visible PLIO DMA addresses.

The exact number of simultaneously referenced buffers is implementation/profile dependent and is reported by `IDENTIFY`. A minimal implementation MUST support at least one input buffer and one output buffer.

A device MUST bounds-check all DMA through the PLIO capability mechanism and MUST report a QDX DMA fault if a required access is rejected.

## 5. Programs and kernels

QDX-DSP standardizes submission, protected memory access, execution contexts, and completion. It deliberately does not standardize one universal DSP instruction set in v0.1.

An implementation may therefore be:

- a programmable DSP with downloadable code,
- a microcoded signal processor,
- a fixed-function accelerator exposing ROM kernels,
- or a later compatible DSP generation with a different internal ISA.

Drivers and higher-level servers are responsible for selecting a program image or kernel compatible with the execution-format identifier reported by `IDENTIFY`.

Portable application APIs SHOULD sit above this level and express operations such as mixing, filtering, synthesis, transforms, or codec work without exposing the DSP machine ISA directly.

## 6. Ordering and completion

QDX-DSP v0.1 commands execute in submission-queue order unless `IDENTIFY` explicitly advertises an optional independent-context execution feature.

For the baseline ordered mode, completion of command N implies completion of all earlier commands in the same queue.

The host-selected 32-bit QDX tag is returned unchanged in the completion.

Normal completion notification follows QDX core rules: completions are written to the CQ before notification, CQ empty -> non-empty normally generates a PLIO message-signalled notification, and polling is always legal.

## 7. Streaming and double buffering

A QDX-DSP implementation SHOULD be able to overlap host DMA and computation when its hardware permits it. Typical server software may keep multiple `RUN` commands queued so that one buffer is being processed while another is transferred.

Example:

```text
buffer A: DSP processing
buffer B: input DMA
buffer C: previous result consumed by host/device
```

Any private local SRAM used for this pipeline remains an implementation detail. Increasing its capacity or bandwidth MUST NOT require a different host programming model.

## 8. Relationship to QDX-S

QDX-S represents an I/O stream endpoint. QDX-DSP represents computation.

A typical audio path may therefore be:

```text
application/shared buffers
        |
   audio server
        |
   QDX-DSP   -- mix/filter/synthesize --> processed buffers
        |
   QDX-S     -- move samples ----------> DAC/audio endpoint
```

A product MAY combine QDX-DSP and QDX-S functions in one physical controller, but they remain logically distinct profiles so that computation and endpoint semantics do not become entangled.

## 9. Non-goals

QDX-DSP v0.1 does not define:

- a universal DSP machine ISA,
- an audio file format,
- a mixer/user-interface policy,
- codec standards,
- scheduling policy among applications,
- cache coherence,
- unrestricted device access to host physical memory.

Those belong to implementation-specific program formats, higher-level servers, or later optional profiles.
