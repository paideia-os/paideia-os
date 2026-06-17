# PaideiaOS — Audit: Jail Audit Records

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Audit record format for jail events. Addresses JAIL-O11.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| JR-D1 | Record per jail-start, jail-stop, capability-denial, budget-violation | Standard |
| JR-D2 | Sampled high-frequency events (per audit/sampling.md) | Pragmatic |

---

## 1. Record format

```capnp
struct JailAuditRecord {
  timestamp @0 :UInt64;
  jailId @1 :JailId;
  jailType @2 :enum { wasm, vm };
  event @3 :enum { start, stop, cap_denied, budget_exceeded, crashed };
  details @4 :Data;
}
```

---

## 2. Events recorded

| Event | Always logged? |
|---|---|
| Jail start | Yes |
| Jail stop | Yes |
| Capability denial | Yes |
| Memory budget exceeded | Yes |
| I/O budget exceeded | Yes (sampled if frequent) |
| Crash | Yes |
| Normal WASI calls | Sampled per audit/sampling.md |

---

## 3. Open issues

| ID | Issue |
|---|---|
| JR-O1 | Aggregation views for operators. |

---

*End of document.*
