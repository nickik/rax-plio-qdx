# M6 hardware CPU verification boundary

M6 deliberately drives the production `LightingBusMasterDrive` interface rather than a test-only CPU request API.

The future Lighting Compute Board / hardware CPU must connect at this same boundary. M6 therefore treats the CPU side as a physical bus master and verifies only externally meaningful protocol behavior:

- `busRequest` arbitration and `busGrant` retention;
- active `request` lifetime;
- address, write data and byte-enable preservation;
- completion and fault routing;
- no dependence on testbench scheduling for arbitration policy;
- behavior while the memory backend applies backpressure;
- reset/stale-response isolation.

M6 tests may inspect `debug*` methods to assert internal invariants, but they must create CPU traffic only through `LightingBusMasterDrive` and observe architectural CPU results only through `LightingBusInputs`.

This is the replacement rule for the later hardware CPU: changing the traffic source from a synthetic bus master to the Lighting Compute Board must not require changing Mainboard arbitration, MemoryController semantics, or the M6 expected traces.
