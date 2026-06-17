# PaideiaOS — Filesystem: Cross-FS Copy via Merkle Subtree Transfer

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Efficient copy between two PaideiaOS FS instances via Merkle subtree sharing. Addresses FS-O9.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| CFS-D1 | Merkle subtree-aware copy | Efficient |
| CFS-D2 | If destination has matching extent (by hash), skip the transfer | Dedup |
| CFS-D3 | Otherwise transfer the extent and reference it | Standard |

---

## 1. Algorithm

```
Source: snapshot S1
Target: snapshot S2 (initially empty or partial)

For each Merkle node in S1 (root downward):
  if node.hash is in S2's extent store:
    reference it; skip subtree
  else:
    if leaf: transfer leaf bytes
    if internal: recurse on children
```

---

## 2. Benefit

For incremental backups: if S1 and S2 share many extents, the transfer is sub-linear in size.

---

## 3. Open issues

| ID | Issue |
|---|---|
| CFS-O1 | Cross-FS reference (when source has unique extent, the destination needs the bytes). |
| CFS-O2 | Authentication of incoming extents. |

---

*End of document.*
