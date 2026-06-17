# PaideiaOS — Audit: Record Format

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Common audit record format used across the system. Addresses CAP-O10.

---

## 0. Common record header

```capnp
struct AuditRecordHeader {
  timestamp @0 :UInt64;
  category @1 :AuditCategory;
  actor @2 :ActorId;
  prevHash @3 :BLAKE3;       # chain
}
```

Each category has its own payload schema (jail, capability, IPC, driver, etc.).

---

## 1. Categories

| Category | Source |
|---|---|
| `capability` | Capability ops (mint, retype, revoke, seal, unseal) |
| `driver_lifecycle` | Driver transitions |
| `ipc_channel` | Channel construction, death, handoff |
| `jail` | WASM/VM jail events (per jail-records.md) |
| `boot` | Boot path measurements |
| `release` | Release operations |
| `policy_decision` | Supervisor decisions |
| `memory` | Memory pressure events |
| `network` | Major network events (TLS handshakes, etc.) |
| `fs` | Filesystem transactions |

---

## 2. Per-category schemas

Each category's payload schema is in its respective subsystem doc.

---

## 3. Open issues

| ID | Issue |
|---|---|
| ARF-O1 | Extension fields — schema evolution for the audit log. |

---

*End of document.*
