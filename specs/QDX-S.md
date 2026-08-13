# QDX-S v0.1 — Streaming Devices

**Status:** Draft

QDX-S is the basic queued abstraction for sequential byte or record streams: tape, serial links, audio/sample devices, scanners, instrumentation, and similar producers/consumers.

## Base operations

```text
READ
WRITE
FLUSH
IDENTIFY
STATUS
SPACE
REWIND
```

`READ` transfers the next bytes/record from the stream to host memory. `WRITE` appends bytes/records from host memory. `SPACE` advances over a specified number of records/blocks where the medium supports positioning. `REWIND` returns a positionable stream to its beginning.

A QDX-S controller may represent one or more stream endpoints.

QDX-S does not define codecs, files, editing, mixing, compression policy, retransmission policy, or application protocol semantics.

## Capability reporting

Devices advertise only operations they implement. A simple serial endpoint may expose READ, WRITE, IDENTIFY, STATUS. A tape controller may additionally expose FLUSH, SPACE, and REWIND.
