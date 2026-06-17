# PaideiaOS — Filesystem: Persistent-Memory Buffer Pool

**Status:** Draft v0.1 (phase 3+)
**Date:** 2026-06-17
**Scope:** Using persistent memory (PMem) for the FS buffer pool. Addresses FS-O11.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| PMB-D1 | If PMem is available, use it for the FS buffer pool | Performance |
| PMB-D2 | Buffer pool entries are PMem-typed (per MEM-Q10) | Type-safe |
| PMB-D3 | Transactions commit faster with PMem (clwb + sfence is much cheaper than disk sync) | Performance |
| PMB-D4 | Phase 3+ feature | Scope |

---

## 1. Performance benefit

- Transaction commits go to PMem before disk → fast commit acknowledgment.
- Background flush from PMem to disk.
- Effective commit latency: ~10 µs (vs ~100 ms for SLH-DSA-128s signature + disk write).

---

## 2. Recovery

After a crash, the PMem buffer pool is replayed:
- Identify any committed-to-PMem transactions not yet flushed to disk.
- Apply them to disk.
- Resume normal operation.

---

## 3. Open issues

| ID | Issue |
|---|---|
| PMB-O1 | PMem size budgeting — typically a fraction of system RAM. |
| PMB-O2 | Hybrid PMem + DRAM management. |

---

*End of document.*
