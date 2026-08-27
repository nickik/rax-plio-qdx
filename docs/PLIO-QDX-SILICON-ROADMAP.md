# PLIO / QDX First-Generation Silicon Roadmap

**Status:** implementation strategy, 1977–1980

## 1. Principle

The first PLIO/QDX products must not wait for a complete family of full-custom NMOS chips.

The preferred implementation sequence is:

```text
architectural specification
        |
TTL/MSI breadboard + prototype card
        |
Ferranti bipolar ULA production logic
        |
volume-stable functions migrate to AMI NMOS
```

Ferranti ULA is used as a **fast-turn semi-custom bridge technology**. External TTL bus transceivers, counters, RAM, ROM, analog circuitry, and line drivers remain separate where that is cheaper or electrically preferable.

The ULA generation freezes functions and interfaces; the later NMOS generation reduces package count, board area, power, and cost without changing PLIO/QDX/LDL software contracts.

## 2. Named first-generation devices

### PLIO-P1 — peripheral-side PLIO interface

**Technology:** Ferranti bipolar ULA + external TTL transceivers/parity parts  
**Design start:** 1977  
**Engineering prototypes:** early 1978  
**Production qualification:** 1978

Functions:

- PLIO worker-cycle decode;
- PLIO bus-manager request/grant sequencing;
- transaction-space control;
- ACK/ERR generation;
- PLIO Notification sequencing;
- interface registers;
- mandatory `PAR[3:0]` parity generation/checking;
- clean local interface to QDMA and control processor.

The 32-bit electrical data path uses ordinary octal/bidirectional TTL bus transceivers rather than consuming ULA output pins unnecessarily.

**Successor:** `PLIO-P2`, AMI NMOS, target 1979–1980. `PLIO-P2` is intended to become the common merchant peripheral-side PLIO interface part.

---

### QDMA-1 — QDX queue / DMA engine

**Technology:** one or two Ferranti ULA devices plus external MSI counters/latches  
**Design start:** 1977  
**Engineering prototypes:** 1978  
**Production:** 1978–1979

Functions:

- SQ descriptor fetch sequencing;
- CQ completion write sequencing;
- PLIO capability-handle DMA burst generation;
- buffer-RAM address generation;
- transfer byte/block counters;
- scatter/gather stepping;
- completion ordering;
- PLIO Notification request to PLIO-P1;
- control/status interface to the 6502.

QDMA-1 is deliberately a **data-plane sequencer**, not a full storage CPU. QDX-B command interpretation, scheduling, error policy, and device-specific translation remain primarily in 6502 firmware.

**Successor:** `QDMA-2`, AMI NMOS, target 1980; may integrate more QDX descriptor handling and the integrity engine.

---

### QCRC-1 — QDX integrity engine

**Technology:** Ferranti bipolar ULA  
**Design start:** 1978  
**Engineering prototypes:** late 1978  
**Production option:** 1979

Functions:

- streaming `CRC64_QDX1` calculation;
- expected-checksum compare;
- calculated-checksum result registers;
- byte-count tracking;
- handshake with QDMA/shared buffer.

QCRC-1 allows QDX-B checksum verification/calculation while payload bytes are already moving through controller memory. It does not own checksum metadata.

A first controller may omit QCRC-1 if checksum acceleration misses schedule; QDX-B correctness still has a software fallback. Production storage controllers should add it as soon as practical.

**Successor:** fold into `QDMA-2` or another AMI NMOS storage-control device.

---

### LDL-H1 — one-port host-side LDL engine

**Technology:** Ferranti bipolar ULA + external differential PHY  
**Design start:** 1977  
**Engineering prototypes:** 1978  
**Production:** 1978–1979

One ULA services one radial LDL port.

Functions:

- H2D serializer/source clock;
- D2H deserializer/source-clock receive;
- LDL frame sync;
- LDL CRC16;
- command/data/status framing;
- port state machine;
- FIFO/buffer handshake;
- error/attention registers.

A four-disk controller uses four LDL-H1 devices initially.

**Successor:** `LDL-H4`, four-port AMI NMOS or larger ULA implementation, target 1979–1980.

---

### LDL-D1 — drive-side LDL endpoint

**Technology:** Ferranti bipolar ULA + drive PCB logic/6502/ROM/RAM/analog electronics  
**Joint design:** DEC Storage Architecture + lead drive partner  
**Design start:** 1977–1978  
**Engineering prototypes:** 1978–1979  
**Production:** with first partner LDL drive

Functions:

- LDL serial/framing engine;
- CRC16;
- command/status interface;
- LBA/sector sequencing assist;
- health/event capture interface;
- read/write data-path handshake;
- interface to drive control processor and formatter.

`LDL-D1` is a merchant DEC part manufactured through Ferranti. Third-party drive companies may buy it, but the LDL standard does **not** require its use.

**Successor:** `LDL-D2`, AMI NMOS, target 1980 onward, integrating more buffering and control while retaining exact LDL wire compatibility.

---

### MBX-1 — MASSBUS front-end

**Technology:** Ferranti bipolar ULA + MASSBUS line transceivers/MSI registers  
**Design start:** 1977  
**Engineering prototypes:** 1978  
**Production:** 1978–1979

Functions:

- MASSBUS register-cycle sequencing;
- unit-select/control decode;
- data-path handshake;
- formatter/status translation assist;
- buffer handoff to QDMA;
- error capture.

MBX-1 lets the same QDX-B/QDMA controller architecture front legacy MASSBUS disks while new disks move toward LDL/LDLe.

MASSBUS tape semantics are not part of the first QDX-B/MASSBUS disk card; tape uses a QDX-S-oriented product.

## 3. First-generation storage card building blocks

### QDX-B / LDL card

```text
PLIO
 |
PLIO-P1 + TTL transceivers/parity
 |
QDMA-1 -------- QCRC-1
 |                 |
shared buffer/cache RAM
 |
6502 + ROM/SRAM
 |
4 x LDL-H1 + differential PHY
 |
4 radial LDL disks
```

### QDX-B / MASSBUS card

```text
PLIO
 |
PLIO-P1 + TTL transceivers/parity
 |
QDMA-1 -------- QCRC-1
 |                 |
shared buffer/cache RAM
 |
6502 + ROM/SRAM
 |
MBX-1 + MASSBUS transceivers
 |
MASSBUS disk chain
```

The two products intentionally share PLIO-P1, QDMA-1, QCRC-1, firmware infrastructure, cache design, diagnostics, and QDX-B ABI.

## 4. Timeline

```text
1977
    PLIO-P1 architecture and ULA mapping
    QDMA-1 architecture
    LDL-H1 architecture
    MBX-1 architecture
    TTL/MSI reference cards

1978
    PLIO-P1 engineering qualification
    QDMA-1 engineering qualification
    LDL-H1 first production revision
    MBX-1 first production revision
    first QDX-B/LDL and QDX-B/MASSBUS controller cards
    QCRC-1 design/prototype

1979
    QCRC-1 production
    LDL-D1 partner-drive production
    LDL-H4 integration project
    PLIO-P2 AMI NMOS project
    QDMA-2 AMI NMOS project

1980
    PLIO-P2 volume qualification
    QDMA-2 / checksum integration
    LDL-H4 volume qualification
    LDL-D2 NMOS cost reduction
    ULA remains useful for prototype, low-volume, and fast-turn variants
```

## 5. Ownership

- **DEC PLIO Architecture:** PLIO-P1/P2 functional contract, parity behavior, conformance.
- **DEC Storage Architecture:** QDMA/QCRC storage use, LDL-H/D, MBX functional boundaries.
- **Western Digital / DEC Chip Group:** QDMA/LDL-H/MBX digital architecture and firmware partnership after acquisition.
- **Ferranti:** first-generation ULA master-slice implementation and production under DEC-owned logic design/resale rights.
- **AMI / Silicon Forge:** volume NMOS successors.
- **National Semiconductor:** PLIO transceivers/parity/TTL support and optional merchant second-source work.
- **MOS Technology:** 6502 control processor.
- **Mostek:** buffer/cache DRAM where competitive.
- **Intersil:** SRAM and later CMOS revisions.
- **Calma:** IC/PCB layout and verification flow.

## 6. Compatibility rule

> **No ULA-to-NMOS migration may require an operating-system driver change, a QDX descriptor change, or an LDL wire-protocol change.**

The whole point of the roadmap is to ship the architecture early and integrate it later.