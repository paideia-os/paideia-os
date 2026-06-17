# PaideiaOS — Filesystem: Snapshot Retention and GC

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Snapshot pinning, retention policy, and garbage collection. Addresses FS-O8.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| GC-D1 | Snapshots are explicitly pinned via `SnapshotCap` | Per FS doc §4.3 |
| GC-D2 | Unpinned snapshots are GC'd by background walker | Standard |
| GC-D3 | GC reclaims unreferenced extents | Merkle DAG-based |
| GC-D4 | GC is incremental; does not block reads/writes | Performance |
| GC-D5 | Per-snapshot retention policies (supervisor-driven) | Flexibility |

---

## 1. Snapshot pinning

A snapshot capability pins its root pointer. The root cannot be GC'd while the cap is held.

```paideia-as
fn snapshot_create(root : DirCap, label : String) -> SnapshotCap
```

Multiple processes can hold the same `SnapshotCap` (affine, shareable per CAP-Q7).

---

## 2. Retention policies

The supervisor's policy decides default retention:
- Hourly snapshots: retain last 24.
- Daily snapshots: retain last 7.
- Weekly snapshots: retain last 4.
- Monthly snapshots: retain last 6.

Policies are configurable per-FS.

---

## 3. GC algorithm

```
1. Identify reachable extents:
   For each active root + each pinned snapshot root:
     Walk Merkle DAG; mark each touched extent.
2. Identify unreachable extents:
   For each extent in storage:
     If not marked: unreachable.
3. Reclaim unreachable extents:
   For each unreachable extent:
     Free back to pool.
4. Audit log records: count freed, bytes freed.
```

The walk is incremental; GC runs in the background at low priority.

---

## 4. Reference counting (optimization)

To avoid full DAG walks, the FS maintains per-extent refcounts:
- Increment on inclusion in any root or snapshot.
- Decrement on snapshot deletion or root supersession.
- Refcount 0 = reclaimable.

Periodically (e.g., monthly), a full DAG walk reconciles refcounts in case of drift.

---

## 5. Snapshot deletion

```paideia-as
fn snapshot_delete(snap : SnapshotCap) -> unit
```

Consumes the cap; releases the pin. GC will reclaim extents at next pass.

---

## 6. Open issues

| ID | Issue |
|---|---|
| GC-O1 | The reference-counting integrity — when does the full walk happen? |
| GC-O2 | Tunable GC priority — when storage is full, prioritize GC. |
| GC-O3 | Snapshot-naming policy — labels must be unique within a directory. |

---

*End of document.*
