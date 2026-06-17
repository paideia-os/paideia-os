# PaideiaOS — Kernel: TME-MK Key-ID Management

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** TME-MK key-id issuance, recycling, and verification. Addresses MEM-O9.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| TMK-D1 | Supervisor issues key-ids | Authority |
| TMK-D2 | Key-id space: 64 IDs typical (Intel SDM Vol. 3D) | Hardware limit |
| TMK-D3 | LRU recycling when full | Standard |
| TMK-D4 | Descriptor's key-id verified at runtime via TME-MK MSR | Pillar 6 |

---

## 1. Issuance

`request_tme_mk_key_id()` → key_id from the supervisor's pool. Key-id is bound to the requesting process / AS.

## 2. Verification

When a process accesses an encrypted region, the kernel verifies the descriptor's key-id matches the process's authorized set.

## 3. Recycling

When a process exits without explicitly releasing, the supervisor's GC reclaims; key-id may be reassigned to a new process after a grace period.

## 4. Open issues

| ID | Issue |
|---|---|
| TMK-O1 | Key-id exhaustion handling (only 64 IDs). |

---

*End of document.*
