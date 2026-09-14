# PLIO-RAX host-controller internal interface

**Status: deferred. No implementation work in the current phase.**

This directory exists only to reserve the boundary between a future production PLIO host controller and the RAX CPU/memory system.

The generic PLIO protocol must not acquire RAX physical addresses or interrupt-vector semantics while this work is deferred.

When resumed, this specification will cover host-internal worker-MMIO injection, host-memory DMA access, privileged DMA capability mapping, and notification-pending exposure to RAX. None of that is required for NakedCard/QIC validation.