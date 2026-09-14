# Non-product PLIO testbench peer

This component exists solely to test peripheral-side QIC behavior without implementing the production host controller.

It is deliberately not a PLIO architectural endpoint specification.

## Required capabilities

- inject one WORKER MMIO read/write toward a selected card;
- observe BR and return BG with configurable delay;
- respond to HOST_DMA reads/writes with deterministic data;
- accept/record CONTROLLER transactions such as PLIO Notification;
- generate ACK, wait states, ERR, timeout, and deterministic parity faults;
- record wire-level cycle traces.

## Explicit omissions

It does not implement:

- RAX CPU addressing;
- DMA capability lookup/translation;
- real multi-slot arbitration policy;
- host interrupt routing;
- notification claim/mask policy;
- cache/memory behavior beyond deterministic test data.

The first version may support exactly one card/slot and grant every valid request immediately.