# PaideiaOS — Audit: Log Structure

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Audit log on-disk structure. Addresses FS-O10.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| AUD-D1 | Audit log is itself an FS file | Self-describing |
| AUD-D2 | Append-only with PQ-signed epoch boundaries | Tamper-evident |
| AUD-D3 | Each entry is a typed record per schema registry | Standard |
| AUD-D4 | Epoch length: 1 hour default; configurable | Standard |

---

## 1. On-disk structure

```
Audit log: /system/audit/log.pdaudit
  Epoch 0 (1 hour from FS init)
    Entry 0
    Entry 1
    ...
    Epoch summary: BLAKE3 of entries, PQ-signed by release-line
  Epoch 1
    ...
```

---

## 2. Entry structure

```capnp
struct AuditEntry {
  timestamp @0 :UInt64;
  category @1 :AuditCategory;
  actor @2 :ActorId;
  operation @3 :Text;
  payload @4 :Data;       # category-specific
  prevHash @5 :BLAKE3;    # of previous entry (chain)
}
```

The prevHash linkage forms a chain; tampering with one entry invalidates all subsequent.

---

## 3. Replay

For attestation: the audit log can be replayed to verify a specific event occurred (entries' chain hash matches signed epoch).

---

## 4. Open issues

| ID | Issue |
|---|---|
| AUD-O1 | Audit-log rotation when full. |
| AUD-O2 | External archive offload. |

---

*End of document.*
