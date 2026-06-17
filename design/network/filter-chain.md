# PaideiaOS — Network: Packet Filter Chain Ordering

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Ordering and policy for the packet-filter chain. Addresses NET-O3.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| FIL-D1 | Filters form an explicit chain with documented priority | Predictability |
| FIL-D2 | Each filter has a numeric priority (0–999, lower = earlier) | Standard |
| FIL-D3 | Filters at the same priority run in registration order | Tie-breaking |
| FIL-D4 | First filter to return `Drop` short-circuits | Standard |
| FIL-D5 | `Accept` continues to next filter; final outcome is the last decision | Documented |
| FIL-D6 | Supervisor maintains the canonical chain | Authority |

---

## 1. Chain configuration

```toml
[filters.inbound]
order = [
  { name = "drop_invalid", priority = 10 },
  { name = "rate_limit", priority = 50 },
  { name = "stateful_inspection", priority = 100 },
  { name = "application_specific", priority = 500 },
  { name = "log_all", priority = 999 },
]

[filters.outbound]
order = [
  ...
]
```

---

## 2. Conflict resolution

When two filters at the same priority disagree:
- The registration order breaks the tie.
- The chain logs a warning the first time this happens.

---

## 3. Audit

Every filter decision is logged (when the audit-filter is in the chain).

---

## 4. Open issues

| ID | Issue |
|---|---|
| FIL-O1 | The default chain — what's preinstalled. |
| FIL-O2 | Migration: changing a filter's priority without disrupting traffic. |
| FIL-O3 | Per-interface chains vs global. |

---

*End of document.*
