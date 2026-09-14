# PLIO-E implementation boundary

**Status:** companion index.

The normative physical profile is `../../specs/PLIO-E.md`.

This directory exists so hardware-validation work has an explicit place for:

- connector/backplane loading calculations;
- line-driver/receiver assumptions;
- termination and stub constraints;
- clock skew and setup/hold budgets;
- PLIO-5/PLIO-10 electrical validation;
- PTI-to-real-transceiver mapping.

Electrical behavior is not to be faked as ordinary synthesizable Bluespec logic. Rust may later host calculators/models; analog/electrical assumptions remain documented separately.
