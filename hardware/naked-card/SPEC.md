# NakedCard validation fixture

NakedCard is the smallest useful peripheral-card fixture.

It exists to prove PLIO-QIC + QLI behavior before any real device or QDX logic is introduced.

Conceptually:

```text
PLIO <-> [PLIO-TX] <-> PTI <-> QIC <-> QLI <-> NakedDevice
```

Early semantic tests may bypass PLIO-TX/PTI and connect the Rust QIC directly to the testbench peer.

## NakedDevice behavior

- worker-only;
- never requests DMA;
- never requests PLIO Notification;
- contains no QDX capability/logic;
- responds to the standard configuration area through QLI MMIO;
- accepts a write to `DEVICE_CONTROL` as a no-op test write;
- unsupported worker addresses return QLI error;
- reset returns it to the same stateless ready configuration.

Test vendor/device/signature values are fixture values, not architecture assignments, until PLIO configuration constants are formally frozen.

## Definition of first NakedCard success

Using the non-product PLIO testbench peer:

1. host/test peer selects the card and performs a configuration read;
2. QIC converts PLIO WORKER cycle to QLI request;
3. NakedDevice returns data;
4. QIC returns correct PLIO data/parity/ACK;
5. unsupported offset produces ERR rather than hanging;
6. programmable NakedDevice response delay produces PLIO wait states;
7. reset leaves all QIC/PTI outputs safe.

No host controller or QDX implementation is required.