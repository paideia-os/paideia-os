# PaideiaOS — Audit: Sampling Policy for High-Frequency Events

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Sampling policy for high-frequency audit events. Addresses AC-O11 and related.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| SMP-D1 | Default: log all events | Default-safe |
| SMP-D2 | High-frequency categories sampled at 1:100 by default | Pragmatic |
| SMP-D3 | All capability-check failures always logged | Security-critical |
| SMP-D4 | Sampling configurable per category | Tunable |

---

## 1. Sampled categories

| Category | Default sample rate |
|---|---|
| OSL timer reads | 1:1000 |
| OSL port polls | 1:1000 |
| DNS cache hits | 1:100 |
| Schedule decisions | 1:100 |
| Memory pressure level changes | 1:1 (always) |
| Capability denials | 1:1 (always) |
| Driver lifecycle transitions | 1:1 (always) |

---

## 2. Anti-sampling

Suspicious patterns trigger temporary 1:1 logging:
- Repeated capability denials.
- Rapid restart cycles.
- Memory-pressure spikes.

---

## 3. Open issues

| ID | Issue |
|---|---|
| SMP-O1 | Per-process sampling overrides. |

---

*End of document.*
