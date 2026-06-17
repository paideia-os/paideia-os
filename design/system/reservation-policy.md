# PaideiaOS — System: Reserved-Core Reservation Policy

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Boot-time policy for `reserved_core_cap` grants. Addresses SCH-O3.

---

## 0. Policy file format

`/system/reservation-policy.toml`:

```toml
[network_stack]
condition = "cores >= 8"
target = "highest-numbered P-core"
exclusive = true

[audio_engine]
condition = "platform == 'laptop' && audio_high_priority"
target = "first E-core"
exclusive = true

[real_time_app]
condition = "user-specified"
target = "user-specified"
exclusive = true
```

---

## 1. Evaluation

At boot:
1. Read policy.
2. For each entry, check condition.
3. If satisfied, mint `reserved_core_cap` for target CPU.
4. Pass to the named consumer (network stack, audio engine, etc.).

---

## 2. Defaults

| Total cores | Network stack | Audio | Real-time |
|---|---|---|---|
| ≤ 4 | No | No | No |
| 5–7 | No | No | No |
| ≥ 8 | Yes | If laptop + audio | If user-configured |

---

## 3. Open issues

| ID | Issue |
|---|---|
| RV-O1 | Multi-NIC: one reserved core per NIC? |

---

*End of document.*
