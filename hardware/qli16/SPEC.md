# QLI-16 physical encoding study

**Status: exploratory; not frozen.**

QLI-16 is a possible low-pin-count physical encoding of the semantic QLI contract for a late-1970s QIC package.

It MUST NOT add semantics beyond QLI.

The initial design hypothesis is a multiplexed 16-bit local datapath plus a small number of type/handshake pins. Exact pins, transaction codes, and timing are intentionally deferred until package and bandwidth analysis is complete.

## Required analysis before freeze

- QIC package target and realistic signal-pin budget;
- PTI pin cost first, including power/ground/clock/reset;
- local-side pins remaining;
- bandwidth required to sustain PLIO-5 worst-case 32-bit traffic;
- whether a 16-bit local path therefore requires approximately twice the PLIO data-beat rate;
- comparison against an 8-bit or 32-bit local datapath;
- buffering cost if local bandwidth is lower than peak PLIO bandwidth.

The eventual Rust model must encode/decode complete QLI operations. The eventual Bluespec bridge must prove that substituting QLI-16 changes timing only, not QLI-visible behavior.