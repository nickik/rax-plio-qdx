# QDX-GNETA v0.1

Draft optional acceleration extension to QDX-GNET.

Possible capabilities:

```text
MULTI_TRANSMIT
RECEIVE_ANY
COPY_FRAME
BATCH_RX
BATCH_TX
QUEUED_COMMANDS
```

`MULTI_TRANSMIT` sends one host frame to several explicitly named ports or destinations. `RECEIVE_ANY` accepts completion from any one of several selected ports. `COPY_FRAME` forwards an accepted frame from one port to another without staging the payload through host RAM. `BATCH_RX` and `BATCH_TX` reduce host interaction for groups of frames. `QUEUED_COMMANDS` permits deeper controller scheduling.

All are optional accelerations. Software must be able to reproduce the operation using ordinary QDX-GNET receive/transmit commands.

QDX-GNETA does not define routing tables, reliable transport, congestion control, RPC, naming, authentication, files, or application protocol policy.
