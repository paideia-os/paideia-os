# PaideiaOS — Kernel: CXL.mem Bias-Mode Performance

**Status:** Draft v0.1 (phase 3+)
**Date:** 2026-06-17
**Scope:** CXL.mem bias-mode transition performance characterization. Addresses MEM-O11.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| CXL-D1 | Host-bias mode: host CPU caches; standard semantics | Default |
| CXL-D2 | Device-bias mode: device has exclusive ownership | For accelerator-heavy workloads |
| CXL-D3 | Transition: explicit operation; not implicit | Per MEM-Q10 |

---

## 1. Cost

- Host → device bias: flush host cache lines (TBD cycles per cache line).
- Device → host bias: invalidate device cache (TBD).
- Round-trip: ~1-10 µs for a typical region.

---

## 2. Use case

- Host writes data, transitions to device-bias.
- Device processes (high throughput on device side).
- Device transitions back to host-bias.
- Host reads results.

---

## 3. Open issues

| ID | Issue |
|---|---|
| CXL-O1 | Concrete numbers when hardware available. |
| CXL-O2 | CXL 3.0 multi-host scenarios. |

---

*End of document.*
