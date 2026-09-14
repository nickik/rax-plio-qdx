# PLIO-TX electrical-buffer component contract

PLIO-TX is the electrical transmission/reception block between PTI logic levels and the PLIO-E backplane.

The name describes a logical component; a 1978 implementation may use one custom bipolar part, several bipolar/TTL transceivers, or a small family of parts.

## Responsibilities

- provide required backplane drive current/fanout;
- provide receive thresholds and logic-level conversion;
- provide bidirectional/tri-state behavior for shared paths;
- enter safe high-impedance state when PTI output enable is inactive or reset requires it;
- meet PLIO-E loading, timing, and turnaround requirements.

## Non-responsibilities

PLIO-TX does not:

- calculate/check parity;
- know transaction spaces;
- arbitrate;
- generate ACK/ERR;
- perform DMA;
- know QLI or QDX.

Digital Rust/Bluespec tests may model PLIO-TX as transparent buffers with enable/turnaround behavior. Electrical correctness requires separate PLIO-E analysis.