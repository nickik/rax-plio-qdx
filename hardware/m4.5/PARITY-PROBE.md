# Temporary Phase-3 parity validation note

Protocol invariant under validation: notification channel 2 uses controller address `0x00000008`; with PLIO odd byte-lane parity (`PAR0` protects `AD[7:0]`), the required parity nibble is `0xE`.
