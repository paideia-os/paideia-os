# PaideiaOS — Filesystem: Phase-1 Boot FS

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Phase-1 write-once log filesystem used during kernel bring-up. Addresses FS-O13.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| P1FS-D1 | Write-once append-only log structure | Simplest possible |
| P1FS-D2 | No CoW, no B-epsilon, no HAMT | Phase 2 features |
| P1FS-D3 | No compression, no encryption | Phase 2 |
| P1FS-D4 | Single writer (kernel) | No concurrency |
| P1FS-D5 | Reads from any boot | Persistence |
| P1FS-D6 | BLAKE3 verification on read | Integrity |

---

## 1. On-disk format

```
Block 0: Superblock
   magic           : "P1FS"
   version         : 1
   log_head_block  : u64 (next-to-write)
   log_tail_block  : u64 (oldest valid)
   total_blocks    : u64

Blocks 1..N: Log entries
   entry_size      : u32
   entry_hash      : BLAKE3 (32 bytes)
   entry_data      : bytes

Block N+1..M: Reserved
```

Each entry is the unit of write. Entries are appended; old entries are never overwritten (until the log fills, at which point the FS is read-only).

---

## 2. Operations

```nasm
; Append an entry.
; Inputs: RDI = bytes ptr, RSI = length
; Output: RAX = entry id (or -1 on full)
extern p1fs_append

; Read an entry by id.
; Inputs: RDI = entry id, RSI = output buffer, RDX = buffer length
; Output: RAX = bytes read
extern p1fs_read

; Iterate entries from head.
; Output: RAX = next entry id (or -1)
extern p1fs_next
```

3 entry points. No directories, no paths, no permissions.

---

## 3. Use during phase 1

Phase 1 uses this for:
- Storing boot logs.
- Storing the audit log.
- Storing initial driver configurations.
- Reading kernel images (the loader stores the kernel as an entry).

Phase 2 replaces this with the full CoW filesystem.

---

## 4. Migration to phase 2

When phase 2 lands:
1. The CoW filesystem is brought online.
2. Existing entries can be migrated: each entry becomes a CoW file.
3. The phase-1 superblock is invalidated; the disk transitions to phase 2 layout.
4. A migration test verifies all phase-1 entries survive.

---

## 5. Open issues

| ID | Issue |
|---|---|
| P1FS-O1 | Log size budget — depends on disk size. |
| P1FS-O2 | Migration tool — must be written before phase 2 ships. |
| P1FS-O3 | Compaction in case of write-pressure — not in scope. |

---

*End of document.*
