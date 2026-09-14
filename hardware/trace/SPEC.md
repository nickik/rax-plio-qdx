# PLIO validation trace contract

Rust and Bluespec tests need a common deterministic comparison format.

The first trace format should be line-oriented and versioned. Each row represents one sampled PLIO clock edge and should contain at least:

```text
cycle, reset, ad, par, space, as, rd, be, blen, ds, ack, err, sel, br, bg
```

Later optional decoded annotations may identify the current phase, but wire state is authoritative.

Requirements:

- hexadecimal fixed-width values;
- explicit active-low signal values, not prose such as "asserted";
- no timestamps dependent on wall-clock time;
- stable field ordering;
- no QDX fields;
- Rust and Bluespec must be able to emit byte-for-byte comparable traces for the same deterministic scenario once scheduling is aligned.
