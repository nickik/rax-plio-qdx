# CPU validation and qualified-read integration receipt

Base: `c0b02d978b16aaf4dccc9310d5f1971a696436a9`.
Bluespec: 2026.01, build `9bd39e6f`. Tests use fresh isolated source builds.

```
PATH=<bsc>/bin:$PATH make -C hardware/mainboard-fpga \
  test-validation test-qualified test-byte-enable BSC=<bsc>/bin/bsc
```

- `test-validation`: 11 cases cover valid read/write validation, alignment and BE faults, controller/worker MMIO rejection, backend range-fault propagation, and qualified-write/validation/reserved/MMIO rejection. Worker selected/address/data strobes remain inactive; DMA generation and backend-memory sentinel remain unchanged.
- `test-qualified`: 8 cases cover valid instruction BE3/12 and page-table BE15 reads, invalid kinds, incompatible BE, and otherwise-valid instruction misalignment.
- `test-byte-enable`: all ten existing byte masks and request-backpressure stability remain covered, with explicit default data kind and validation false.

Validation requests carry zero write data; backends must classify bounds and permissions without target access. These tests use a bounded classification responder, not a production RAM/ROM implementation. HardwareCpuBoard must separately test its concrete memory backend and transport. BSC's inherited action-shadowing warnings remain; no always-false-rule warning is accepted.

The candidate contains CPU/backend host compatibility only. PLIO wire encoding, DMA arbitration, and QDX card/endpoint/media behavior are unchanged.
