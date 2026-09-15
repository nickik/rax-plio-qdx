# QLI-16 Notification completion amendment

This amendment is normative for QLI-16 v0.1 and closes the missing physical representation of semantic `notification_ready`.

The `NOTIFICATION` token class is directional:

```text
LDIR=1  device -> QIC   Notification request
LDIR=0  QIC -> device   Notification completion
```

Both directions use the same payload:

```text
LD[1:0]  channel (0..3)
LD[15:2] = 0
```

A device->QIC Notification request is transport-accepted when its request token receives `LACK`. This acceptance does **not** mean the semantic Notification has completed. The QIC-side endpoint retains the request internally and continues presenting the semantic `notification_request` to the QIC until PLIO completes it.

Only after the corresponding PLIO CONTROLLER data beat is ACKed may the QIC endpoint emit the opposite-direction `NOTIFICATION` completion token for the same channel. Acceptance of that completion token produces semantic `notification_ready` at the device endpoint.

The request and completion therefore form:

```text
device                       QIC
   |                           |
   |-- NOTIFICATION(ch) ------>|
   |<--------- LACK -----------|   transport accepted only
   |                           |
   |       PLIO transaction    |
   |                           |
   |<-- NOTIFICATION(ch) ------|   semantic completion
   |----------- LACK --------->|
   | notification_ready        |
```

Rules:

- request direction is always device->QIC;
- completion direction is always QIC->device;
- completion channel MUST equal the retained request channel;
- reserved payload bits MUST be zero in both directions;
- reset discards a retained request or pending completion without synthesizing `notification_ready`;
- a duplicate request while the same request is retained is not a second semantic Notification;
- this amendment consumes no new token type and no package pin.
