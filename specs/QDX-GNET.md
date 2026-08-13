# QDX-GNET v0.1 — GNET Frame I/O

**Status:** Draft

QDX-GNET is the basic queued device abstraction for a GNET network interface.

## Base operations

```text
RECEIVE
TRANSMIT
IDENTIFY
STATUS
SET_ADDRESS
SET_FILTER
```

`RECEIVE` supplies a host buffer for the next accepted GNET frame. `TRANSMIT` sends one frame from host memory. `SET_ADDRESS` configures the local link address. `SET_FILTER` configures basic receive acceptance such as local, broadcast, or promiscuous reception.

A controller may expose more than one physical GNET port.

QDX-GNET deliberately stops at the frame/link boundary. It does not define routing, reliable transport, sessions, RPC, naming, authentication, file service, printing, or application protocols.

## Capability reporting

A minimal controller advertises RECEIVE, TRANSMIT, IDENTIFY, and STATUS. Optional base capabilities include programmable address and receive filtering.
