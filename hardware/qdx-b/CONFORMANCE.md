# QDX-B v0.5 first-controller conformance

The first QDX-B controller targets the complete **mandatory base profile**. The physical disk/LDL implementation is the only hardware component deliberately replaced by a fake backend.

| Requirement | First controller |
|---|---|
| one SQ/CQ pair | QDX-A core |
| namespace(s) | 2 fake namespaces |
| 512-byte logical blocks | yes, namespace 1 |
| 1024-byte logical blocks | yes, namespace 2 |
| NOP | yes |
| IDENTIFY_CONTROLLER | yes, 64 B |
| IDENTIFY_NAMESPACE | yes, 64 B |
| READ | yes |
| WRITE | yes |
| WRITE_DURABLE | yes |
| FLUSH | yes |
| GET_HEALTH | yes, 64 B standardized structure |
| direct contiguous buffers | yes |
| SG 1..16 entries | yes |
| QDX-B 16-byte completion format | yes |
| tag preservation | yes |
| namespace/LBA validation | yes |
| DMA fault reporting | yes |
| write staging before media modification | yes |
| reset cancels endpoint state | yes |
| CQ/Notification ordering | inherited from QDX-A |
| optional integrity engine | **not advertised** |
| optional QDX-BA | **not advertised** |
| real LDL media | **fake backend in this branch** |

## Initial performance limits

`max_transfer_blocks = 1`. This is an advertised implementation limit, not an ABI change. One 512-byte block uses eight 16-word PLIO bursts; one 1024-byte block uses sixteen.

The controller still implements SG up to the mandatory 16 entries. Segment boundaries are honored and only the requested block byte count is transferred.

## Validation layers

1. Rust QDX-B profile tests: commands, direct buffers, SG, persistence, durability, health/identify, status errors and DMA faults.
2. Bluespec direct-buffer profile fixture.
3. Bluespec SG fixture.
4. Rust physical-card `WRITE_DURABLE` path.
5. Bluespec physical-card `WRITE_DURABLE` path.
6. Exact ordered `QDXBCARDTRACE` diff between Rust and Bluespec.

## Later work, not a missing base-profile requirement

- CRC64_QDX1 integrity extension and `IDENTIFY_INTEGRITY`.
- QDX-BA accelerated multi-target operations.
- replacement of `FakeMedia` by an LDL-facing disk controller.
- raising `max_transfer_blocks` above one and overlapping commands.
