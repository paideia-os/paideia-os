# PaideiaOS — Network: BBRv3 Congestion Control

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** BBRv3 implementation reference and integration. Addresses NET-O2.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| BBR-D1 | BBRv3 as default TCP congestion control | Per NET-D2 / pillar 7 |
| BBR-D2 | CUBIC available as per-connection alternative | Compatibility |
| BBR-D3 | Implementation tracks Google's open-source BBRv3 (Linux kernel patches) | Mature implementation |

---

## 1. BBRv3 properties

- Probes bandwidth and RTT independently.
- Avoids bufferbloat by pacing.
- Recovers from packet loss without entering deep congestion avoidance.
- Performance roughly 2-25× better than CUBIC on lossy or long-RTT paths.

---

## 2. Implementation

The implementation follows the Google BBRv3 specification (Cardwell et al., 2016+) with PaideiaOS-specific:
- Pacer integration with the wait-free IPC slot-cap economy (the pacer's rate translates to slot-cap availability).
- Per-flow state in the TCP connection table.
- AVX-512 vectorized loss/RTT samples processing.

---

## 3. Per-connection algorithm selection

```paideia-as
let conn : TcpConnect = ...
conn.set_congestion_control(BBRv3)  // default
// or
conn.set_congestion_control(CUBIC)  // compat
```

---

## 4. Open issues

| ID | Issue |
|---|---|
| BBR-O1 | BBRv3 patent landscape — check Google's licensing. |
| BBR-O2 | Tuning parameters for specific deployments. |

---

*End of document.*
