# PaideiaOS — Kernel: Memory Pressure Escalation

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Detailed protocol for `MemoryPressure` effect escalation. Addresses MEM-O5.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| MP-D1 | Three pressure levels: low, medium, critical | Graduated response |
| MP-D2 | Each level has its own response handler | Specific actions per level |
| MP-D3 | Supervisor's response is auditable | Visibility |

---

## 1. Pressure levels

| Level | Trigger | Response |
|---|---|---|
| Low | Free memory < 30% | Background eviction; pager flushes clean pages |
| Medium | Free memory < 15% | Aggressive eviction; drop CoW snapshots; revoke speculative reservations |
| Critical | Free memory < 5% | Supervisor kills non-essential processes per policy |

---

## 2. Escalation

When allocation fails at the pager level, the kernel raises `MemoryPressure`. The supervisor decides escalation based on:
- Free memory %
- Allocation rate
- Process priorities
- Reserved supervisor budget

---

## 3. In-flight IPC

When the supervisor revokes a capability while in-flight on IPC:
- Per IPC §9.5 (reclaim flow), the capability enqueues on the reclaim channel.
- The IPC primitive's slot remains valid; the receiver gets a stale-tag failure.
- Sender's next operation sees `ChannelDead`.

---

## 4. Open issues

| ID | Issue |
|---|---|
| MP-O1 | Detailed kill-victim selection algorithm. |
| MP-O2 | Supervisor's reserved budget sizing. |

---

*End of document.*
