# NakedCard physical fault hardening

This branch is the final verification layer before the first real QDX card implementation.

The tested tower is:

```text
PLIO backplane
      |
   PLIO-TX
      | PTI
     QIC
      |
  QLI-16 pins
      |
 NakedDevice / protocol probe
```

## Differential gates

`hardware/scripts/test-naked-card-physical.sh` is the canonical validation command.

It requires both Rust and Bluespec to agree at three boundaries:

1. `Q16TRACE`: exact stateful QLI-16 slot/semantic differential.
2. `STRESSTRACE`: deterministic 4096-cycle legal QLI-16 stress test with waits, simultaneous bidirectional sources, turnaround and periodic reset.
3. `NAKEDTRACE` / `FAULTTRACE`: full physical-card externally visible transaction/fault milestones through QIC + QLI-16 + PLIO-TX.

The stress generator is deterministic, uses a fixed initial LFSR state, retains source payloads while backpressured, and compares a rolling checksum of every physical QLI-16 slot plus semantic handshakes.

## New full physical fault matrix

The Rust and Bluespec complete-card fixtures both cover:

- manager address waits;
- DMA data waits;
- D2H target error at progress 0, 1 and 3;
- H2D target error at progress 0, 1 and 3;
- H2D bad parity at progress 0, 1 and 3;
- exact `words_completed` on every above failure;
- DMA manager-address timeout;
- DMA data timeout;
- Notification address failure followed by retry;
- Notification completion only after successful PLIO data ACK;
- QLI-16 final-token backpressure and stable held token;
- malformed QLI-16 sticky fault and reset recovery;
- PLIO-TX reset tri-state even when the QIC side requests drive/response/request.

## Existing directed lower-level regression retained

The complete validation ladder also runs the QIC regression oracle, which already directly covers:

- grant loss during DMA and exact `ProtocolError` completion;
- worker-MMIO total data-phase timeout;
- accepted worker MMIO timeout producing semantic `MMIO_CANCEL`;
- reset forcing all QIC bus drives inactive;
- manager-address timeout;
- local DMA producer starvation timeout;
- Notification address/data timeout, error and grant-loss behavior in the Phase-6 differential fixture.

Those cases remain mandatory regressions even where the current complete-card `FAULTTRACE` fixture does not duplicate the exact failure at the outer PLIO pins.

## Merge criterion

Do not call this verification complete until the pinned Bluespec compiler has actually run the ladder and:

- Rust tests pass;
- Bluesim fixtures pass;
- `Q16TRACE` matches exactly;
- `STRESSTRACE` matches exactly;
- `NAKEDTRACE` matches exactly;
- `FAULTTRACE` matches exactly.

GitHub Actions being queued is not evidence of success.
