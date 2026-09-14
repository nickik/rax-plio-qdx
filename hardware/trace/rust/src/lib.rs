#![forbid(unsafe_code)]

pub const PHASE0_TRACE_VECTOR: &str = "TRACE|v1|c=0000002a|pi=0.1.0.1.00000100.1.7.1.0.1.1.f.0.0.0.0|qi=1.0.0.00000000.0.0.00000000.0.1.0.00000000.1.0.0|po=0.0.00000000.0.0.0.0.0.0.0.0.0.0.0|qo=0.0.00000000.0.0.00000000.0.0.0.0.00000000.0.0.0.00.0|ev=worker_address";

pub fn phase0_trace_vector() -> &'static str {
    PHASE0_TRACE_VECTOR
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trace_vector_is_ascii_and_space_free() {
        assert!(PHASE0_TRACE_VECTOR.is_ascii());
        assert!(!PHASE0_TRACE_VECTOR.contains(' '));
        assert!(PHASE0_TRACE_VECTOR.starts_with("TRACE|v1|"));
    }

    #[test]
    fn trace_vector_has_canonical_field_order() {
        let fields: Vec<_> = PHASE0_TRACE_VECTOR.split('|').collect();
        assert_eq!(fields.len(), 8);
        assert_eq!(fields[0], "TRACE");
        assert_eq!(fields[1], "v1");
        assert!(fields[2].starts_with("c="));
        assert!(fields[3].starts_with("pi="));
        assert!(fields[4].starts_with("qi="));
        assert!(fields[5].starts_with("po="));
        assert!(fields[6].starts_with("qo="));
        assert!(fields[7].starts_with("ev="));
    }
}
