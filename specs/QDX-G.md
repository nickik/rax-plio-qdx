# QDX-G v0.1 — 2D Graphics

**Status:** Draft

QDX-G is the queued graphics profile for asynchronous 2D acceleration. It is designed for the baseline RAX workstation model where the framebuffer and other graphics surfaces MAY live in ordinary host memory and are accessed through PLIO DMA capability channels.

QDX-G does not require a private graphics-memory address space, a dedicated VRAM controller, or a CPU-local accelerator bus. A motherboard graphics implementation and a plug-in PLIO card use the same QDX-G software contract.

## 1. Architectural model

A QDX-G device is an asynchronous graphics worker. Software submits drawing commands through the normal QDX submission queue and receives normal QDX completions.

The baseline data path is:

```text
host RAM surface
      ^
      | PLIO capability-scoped DMA
      v
   QDX-G device
      |
  optional private SRAM
      |
  2D graphics datapath
```

The device MUST NOT receive unrestricted host physical addresses. Every queue, source surface, destination surface, pattern, font, or parameter buffer referenced by a QDX-G command uses a device-visible PLIO DMA address and is therefore limited by the slot's DMA capability bindings.

Local SRAM, line buffers, FIFOs, and similar memories inside or beside the graphics device are implementation details. Their size, banking, and timing MUST NOT be part of the portable QDX-G programming model.

## 2. Shared-memory graphics

The base profile MUST support graphics surfaces in host RAM. This allows the CPU and QDX-G device to operate on the same surface without maintaining separate system-memory and video-memory copies.

PLIO is not cache coherent. Before a QDX-G command consumes host-written surface data, software MUST perform the platform-defined operation that makes those writes visible to PLIO DMA. Before the CPU consumes QDX-G-written data, software MUST perform the corresponding completion/visibility operation required by the platform cache model.

A later QDX-G implementation MAY contain private framebuffer or VRAM. Private memory is an optional implementation/profile extension; it is not required by QDX-G v0.1.

## 3. Ownership model

Normal applications SHOULD NOT own the physical QDX-G device directly. A capability-based RAX system SHOULD normally grant the QDX-G device, its DMA bindings, and its notification endpoint to a display server.

Applications communicate with that server using IPC and shared memory. The server decides whether an operation is cheaper to execute on the CPU or to submit to QDX-G.

This policy is outside the QDX-G wire protocol, but the profile is intentionally designed to support an X/NeWS-like display-server architecture.

## 4. Base operations

QDX-G v0.1 defines the following base operations:

```text
IDENTIFY
FILL_RECT
COPY_RECT
ROP_RECT
DRAW_LINE
MONO_EXPAND
```

`IDENTIFY` reports profile revision, supported pixel formats, supported raster operations, maximum dimensions, alignment requirements, and optional acceleration features.

`FILL_RECT` writes a constant pixel or pattern value to a rectangular destination.

`COPY_RECT` copies a rectangular region from a source surface to a destination surface. Source and destination MAY refer to the same surface. Implementations MUST define overlap-safe behavior when overlap support is advertised.

`ROP_RECT` applies an advertised boolean raster operation to source and destination pixels over a rectangle.

`DRAW_LINE` draws a clipped integer-coordinate line using an advertised pixel/raster operation.

`MONO_EXPAND` expands a 1-bit source mask or glyph into destination pixels using foreground/background parameters. This operation is intended for fonts, icons, and masks.

A conforming minimal implementation MUST implement `IDENTIFY`, `FILL_RECT`, `COPY_RECT`, and at least the basic source-copy raster operation. Other operations MAY be absent and are reported through `IDENTIFY`.

## 5. Surface description

A host-memory surface reference contains, directly or through a parameter block:

```text
base        device-visible PLIO DMA address
stride      bytes between scan lines
width       logical width in pixels
height      logical height in pixels
format      advertised QDX-G pixel format
```

The required baseline format is packed 1-bit monochrome. Indexed 2-bit, 4-bit, and 8-bit formats MAY be advertised by later or higher-end devices.

Commands also contain source/destination coordinates and rectangle dimensions as required by the operation.

The worker MUST reject a command whose declared surface geometry would cause it to access bytes outside the referenced DMA capability region.

## 6. Ordering and completion

QDX-G v0.1 commands execute in submission-queue order. The device MUST NOT make a later command visible before all writes of earlier commands are complete.

This deliberate restriction makes graphics fences cheap: completion of command N implies that all earlier QDX-G commands have completed and their destination writes have been issued to host memory.

The host-selected 32-bit QDX tag is returned unchanged in the completion.

Normal completion notification follows QDX core rules: the device writes the completion queue first and normally sends a PLIO message-signalled notification only on CQ empty -> non-empty transition. Polling is always legal.

## 7. Device-private working memory

A device MAY use private SRAM to stage tiles, scan lines, glyphs, patterns, or intermediate raster results. It MAY overlap DMA of one tile with processing of another.

Software MUST NOT depend on a specific amount of private SRAM. A later device with more or faster SRAM should improve performance without changing the QDX-G command contract.

## 8. Scanout

QDX-G v0.1 does not require the graphics worker to own display scanout.

In the baseline shared-memory workstation, a separate system display engine MAY scan a framebuffer directly from host RAM while QDX-G accelerates updates to that framebuffer.

A later graphics device MAY add private VRAM and scanout, but that is an extension above the base QDX-G contract.

## 9. Non-goals

QDX-G v0.1 does not define:

- a window system or compositor policy,
- a PostScript/NeWS language,
- fonts or text layout,
- a 3D pipeline,
- textures or Z buffers,
- a general-purpose GPU ISA,
- cache coherence,
- a private VRAM architecture.

Those facilities may be layered above or added by later profiles without changing the QDX queue and PLIO capability model.
