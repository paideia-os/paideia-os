# PaideiaOS — Network: Far-Memory Implementation Hooks

**Status:** Draft v0.1 (phase 3+)
**Date:** 2026-06-17
**Scope:** D12 disaggregated/far memory implementation via network stack. Addresses MEM-O12 / NET-equivalent.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| FM-D1 | Far memory accessed via RDMA-equivalent protocol over network | Standard |
| FM-D2 | Pager fetches/evicts pages from far memory pool | Transparent |
| FM-D3 | Phase 3+ feature | Scope |

---

## 1. Architecture

```
   Process
     | references far memory
     v page fault
   Pager
     | sends RDMA fetch request
     v
   Far memory server (on another host)
     | returns page bytes
     v
   Pager installs page in local memory
   Process resumes
```

---

## 2. Protocol

- RDMA over Converged Ethernet (RoCE) or InfiniBand for low latency.
- TCP fallback for compatibility.
- Page-level granularity.

---

## 3. Open issues

| ID | Issue |
|---|---|
| FM-O1 | RDMA hardware support — requires specific NICs. |
| FM-O2 | Consistency model. |

---

*End of document.*
