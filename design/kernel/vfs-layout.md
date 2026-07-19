---
issue: 570
milestone: R16.M1 (VFS abstract layer — superblock/inode/dentry/vnode)
subsystem: 11 — VFS abstract layer
topic: VFS vnode struct layout freeze (R16-M1-001)
freeze-discipline: strict (parallels #543 task_struct freeze)
blocks:
  - "#571 (vnode_pool[256] slab — depends on VNODE_SIZE = 64)"
  - "#572 (vnode_alloc / vnode_free — depend on hot-field offsets)"
  - "#573 (vfs_super_ops table — depends on VOPS_PTR_OFFSET)"
  - "#574 (path resolver — depends on TYPE_OFFSET / PARENT_IDX_OFFSET / NAME_SLOT_OFFSET)"
  - "#575 (vfs_open — depends on REFCOUNT_OFFSET for hold/put)"
  - "R16.M2 tmpfs backend — pins BACKEND_PTR_OFFSET semantics"
touching:
  - design/kernel/vfs-layout.md         (this doc)
related:
  - design/kernel/task-struct-layout.md  (#543/#564 — same freeze discipline; parent-doc idiom)
  - design/kernel/r15-m5-007-fd-table-embed.md (#549 — fd slot will grow into *vnode at R16.M3)
  - design/milestones/r14b-tactical-plan.md §Subsystem 11 (line 1193 — VFS contract)
---

# VFS vnode struct layout — 64-byte freeze (R16-M1-001, #570)

## 1. Overview

This document freezes the on-line layout of `struct vnode` at **exactly
64 bytes** — one L1 cache line on every x86_64 microarchitecture we
target — for the entire R16 series. The freeze is strict: no field
may be added, removed, resized, or moved without a **layout re-freeze
issue** that bumps a schema constant and re-runs every consumer's
witness.

The discipline parallels `design/kernel/task-struct-layout.md`
(#543 pinned `task_struct`; #564 pinned the `regs_save` sub-region):
downstream call sites encode offsets as immediates in SIB+disp
addressing (`mov rax, [rdi + rsi*64 + OFFSET]`), and any offset drift
silently corrupts kernel state. The freeze exists to make that drift
impossible without a rebuild event.

The 64-byte target is a hard requirement:

- **Cache-line alignment.** `_vnode_pool[VNODE_MAX=256]` (#571) is a
  16 KiB `.bss` array. At 64 B / vnode, each vnode is one full L1D
  line, no straddling. A read of any field is exactly one cache-line
  fill; a hot vnode fits entirely in L1D with no partial-line
  spill.
- **Index arithmetic is a single shift.** `_vnode_pool[i]` lowers
  to `lea rax, [_vnode_pool + rcx*64]` — one instruction, no
  imul. A 48- or 72-byte vnode would force `imul` (no SIB scale =
  48/72), inflating the base-address computation to 3+ instructions
  and defeating `vnode_hold`/`vnode_put` as one-liners at R16.M1-002.
- **Pool sizing is predictable.** VNODE_MAX × VNODE_SIZE = 256 × 64
  = 16384 bytes = 4 pages. Fits one 2 MiB huge-page carve-out with
  128× headroom for R17 growth of VNODE_MAX to ~32 K vnodes.
- **Sub-line coverage of hot ops.** `vnode_hold` (refcount++) and
  `vops` dispatch land inside the first 32 bytes; the second half is
  cold (reserved for R17 timestamps). A 90 %-workload access pattern
  touches only the first half-line.

## 2. Field layout table (frozen)

Offsets, sizes, and semantics below are frozen by this issue. Every
consumer module imports the constants from `src/kernel/core/fs/vnode.pdx`
(one source of truth); no scattered offset literals.

| Offset | Size | Field              | Type   | Frozen by | Notes                                                                                                            |
|--------|------|--------------------|--------|-----------|------------------------------------------------------------------------------------------------------------------|
| +0     | 1    | `type`             | u8     | #570      | `VNODE_TYPE_{FREE=0, REG=1, DIR=2, SYMLINK=3, CHRDEV=4, BLKDEV=5, FIFO=6, SOCK=7}`. FREE=0 → slot unused (matches zero-init). |
| +1     | 1    | `flags`            | u8     | #570      | R16.M1 uses bit 0 (`VNODE_FLAG_VALID`). Bits 1..7 reserved for R17 (`CACHED`, `DIRTY`, `MOUNTPT`, `LOCKED`, `RO`). |
| +2     | 2    | `mode`             | u16    | #570      | Unix rwxrwxrwx (12 bits: 3×3 perm + suid/sgid/sticky). Type nibble stored separately at `+0` — do not fold.       |
| +4     | 2    | `refcount`         | u16    | #570      | In-memory hold/put counter. Frees vnode at 0. u16 caps live refs at 65 535 — well beyond R16 FD_TABLE_MAX = 32 × NPROC. |
| +6     | 2    | `link_count`       | u16    | #570      | On-disk (or tmpfs-logical) hard-link count. Frees backend storage at 0 (independent of `refcount`).               |
| +8     | 2    | `parent_idx`       | u16    | #570      | Index into `_vnode_pool[256]`. Sentinel `0xFFFF` = root or detached. u16 matches VNODE_MAX headroom to 65 K.       |
| +10    | 2    | `name_slot_idx`    | u16    | #570      | Index into `_name_slab` (R16.M1-004). Sentinel `0xFFFF` = unnamed (root, anonymous pipe, socketpair).             |
| +12    | 2    | `uid`              | u16    | #570      | Owner user id. u16 gives 65 K users — Pareto-adequate for R16/R17. Grows to u32 at R18 (multi-tenant) via re-freeze. |
| +14    | 2    | `gid`              | u16    | #570      | Owner group id. Same sizing rationale as `uid`.                                                                  |
| +16    | 8    | `size`             | u64    | #570      | File size in bytes. u64 covers tmpfs (64 KiB cap R16.M2) and any future block-backed backend without re-freeze.   |
| +24    | 8    | `ops_ptr`          | u64    | #570      | Pointer to `vnode_ops` vtable (`_tmpfs_vops`, `_devfs_vops`, `_procfs_vops`). Hot: every read/write/close dispatch. |
| +32    | 8    | `backend_ptr`      | u64    | #570      | Backend-owned opaque. tmpfs: pointer to inline-block header. devfs: dev_t packed as `(major<<32)\|minor`. procfs: task idx. |
| +40    | 8    | `_reserved_mtime`  | u64    | (open)    | R17: modification time (ns since boot or ns since UTC epoch — freeze at R17-M1).                                 |
| +48    | 8    | `_reserved_atime`  | u64    | (open)    | R17: access time (or `ctime` — R17 chooses; only one of the two lives here, the other in the shadow structure).  |
| +56    | 8    | `_reserved_c`      | u64    | (open)    | R17: `block_count` OR `generation` (NFS-style stale-handle detection) OR `mount_ptr` for MOUNTPT vnodes.          |

**Total struct extent: [+0, +64) — 15 fields, exactly 64 bytes, one L1 cache line.**

Slot #0 in `_vnode_pool` is reserved (its `type == VNODE_TYPE_FREE == 0`
matches zero-init and doubles as the "invalid vnode" sentinel that
`vnode_alloc` never returns; callers may test `vn_idx != 0` in place
of a NULL check).

## 3. Constants exported by `src/kernel/core/fs/vnode.pdx`

The following constants are the **single source of truth** for offset
arithmetic. No `.pdx` file outside this module may embed a numeric
offset for these fields.

```
// Size + pool
VNODE_SIZE              : u64 = 64          // MUST equal sizeof(struct vnode)
VNODE_ALIGN             : u64 = 64          // L1 cache line
VNODE_MAX               : u64 = 256         // pool slot count (#571)

// Field offsets (hot half, [+0, +32))
VNODE_TYPE_OFFSET       : u64 = 0
VNODE_FLAGS_OFFSET      : u64 = 1
VNODE_MODE_OFFSET       : u64 = 2
VNODE_REFCOUNT_OFFSET   : u64 = 4
VNODE_LINK_COUNT_OFFSET : u64 = 6
VNODE_PARENT_IDX_OFFSET : u64 = 8
VNODE_NAME_SLOT_OFFSET  : u64 = 10
VNODE_UID_OFFSET        : u64 = 12
VNODE_GID_OFFSET        : u64 = 14
VNODE_SIZE_OFFSET       : u64 = 16
VNODE_OPS_PTR_OFFSET    : u64 = 24

// Field offsets (cold half, [+32, +64))
VNODE_BACKEND_PTR_OFFSET: u64 = 32
VNODE_RESERVED_A_OFFSET : u64 = 40   // R17 mtime
VNODE_RESERVED_B_OFFSET : u64 = 48   // R17 atime/ctime
VNODE_RESERVED_C_OFFSET : u64 = 56   // R17 block_count/generation/mount_ptr

// Type discriminants
VNODE_TYPE_FREE         : u8  = 0
VNODE_TYPE_REG          : u8  = 1
VNODE_TYPE_DIR          : u8  = 2
VNODE_TYPE_SYMLINK      : u8  = 3
VNODE_TYPE_CHRDEV       : u8  = 4
VNODE_TYPE_BLKDEV       : u8  = 5
VNODE_TYPE_FIFO         : u8  = 6
VNODE_TYPE_SOCK         : u8  = 7

// Flag bits (bit 0 only at R16.M1)
VNODE_FLAG_VALID        : u8  = 0x01
VNODE_FLAG_CACHED       : u8  = 0x02   // reserved R17
VNODE_FLAG_DIRTY        : u8  = 0x04   // reserved R17
VNODE_FLAG_MOUNTPT      : u8  = 0x08   // reserved R17
VNODE_FLAG_LOCKED       : u8  = 0x10   // reserved R17
VNODE_FLAG_RO           : u8  = 0x20   // reserved R17

// Sentinels
VNODE_IDX_NONE          : u16 = 0xFFFF // parent_idx / name_slot_idx = "none"
VNODE_IDX_ROOT          : u16 = 1      // slot 0 = FREE sentinel; root lives at 1
```

`VNODE_SIZE == 64` is asserted by a compile-time witness — a `.bss`
reservation of `VNODE_SIZE * VNODE_MAX` (16384 B) that must match
`sizeof(_vnode_pool)` after #571 lands. If any future field
resize breaks the 64-byte invariant, the pool array size drifts and
the boot-time layout witness (§6) fails loudly.

## 4. Design rationale — why these fields, why these offsets

### 4.1 Field selection (11 semantic fields + 4 reserved)

Each of the user-brief-required fields maps to exactly one slot in the
frozen layout:

| Brief field                     | Slot in layout                         | Sizing rationale                                                                                                        |
|---------------------------------|----------------------------------------|-------------------------------------------------------------------------------------------------------------------------|
| type                            | `+0` (u8)                              | 8 discriminants named + 248 spare; u8 is Pareto-adequate.                                                              |
| mode                            | `+2` (u16)                             | 12 bits used; u16 leaves 4 spare bits for R17 ACL indicators. u8 would be tight.                                        |
| uid, gid                        | `+12`, `+14` (u16 each)                | 65 K users/groups covers R16/R17 (single-tenant). u32 grow-out documented in §7.                                        |
| size                            | `+16` (u64)                            | u64 avoids re-freeze when a future block-backed backend (R18+) supports >4 GiB files. tmpfs cap of 64 KiB uses low 17 bits. |
| link_count                      | `+6` (u16)                             | u16 covers 65 K hard links; POSIX minimum LINK_MAX is 8; u32 would be waste.                                          |
| refcount                        | `+4` (u16)                             | u16 covers NPROC (R16: 32) × FD_TABLE_MAX (R16.M5: 32) = 1024 with 64× headroom.                                        |
| parent_vnode_idx                | `+8` (u16)                             | Index (not pointer) — 8 B saved, and VNODE_MAX=256 fits u16 with 255× headroom for R17 growth.                          |
| backend-specific data ptr       | `+32` (u64)                            | Opaque to VFS; each backend interprets its 8 bytes (tmpfs: pointer; devfs: packed dev_t; procfs: task index).           |
| backend ops vtable ptr          | `+24` (u64)                            | Hot dispatch — every `vfs_read`/`vfs_write`/`vfs_close` reads this field once.                                          |
| name                            | `+10` (u16 name_slot_idx into slab)    | 8-byte name-slab index costs 2 B (not 8) and decouples name storage from vnode layout. Inline-name variant rejected §5.  |
| reserved (mtime, atime, ctime,  | `+40`, `+48`, `+56` (u64 × 3)          | 24 B reserved region absorbs R17 additions without re-freeze. Cold half of the cache line.                              |
| block count, etc.)              |                                        |                                                                                                                         |

### 4.2 Offset ordering — hot / cold split at +32

The 64-byte line is split at +32 into a hot half and a cold half:

- **Hot half `[+0, +32)`**: `type` (path resolution predicate),
  `mode` (permission gate), `refcount` (hold/put — every fd op),
  `size` (read/write bounds check), `ops_ptr` (indirect dispatch —
  every read/write/close). These fields are touched on nearly every
  VFS call.
- **Cold half `[+32, +64)`**: `backend_ptr` (touched only by backend
  ops after dispatch — one line after ops_ptr load, so still hot on
  L1 hit) and the three R17 reserved timestamp slots (touched only
  by `stat()` and future `atime` updates).

Rationale: on a partial-line miss (rare, only when the vnode has
been evicted between operations), the hot half's fields arrive
first, and the ops-dispatch path resumes on the earlier byte-slot
fill rather than waiting for the full 64-byte line. On dense pool
scans (`vnode_alloc` linear search), we touch only `type` at `+0`
of each vnode — 256 iterations × 1 byte = one cache-line prefetch
per 64 vnodes, so the scan spends 4 lines' worth of L1D on the
whole pool.

### 4.3 Compact packing yields exact 64

The naive "one field per u64" packing (8 fields × 8 B = 64 B)
matches the target but wastes bits: `type` occupies 1/8 of its
slot, `refcount` 1/4 of its slot. Compact packing uses u8/u16 for
narrow fields and reclaims 20 B for the 24 B R17-reserved region:

```
Naive     : type=8 mode=8 uid=8 gid=8 size=8 ops=8 backend=8 refcount=8 → 64 B, no reserved
Compact   : (type|flags|mode|refcount|link_count|parent|name|uid|gid) = 16 B packed
          + size=8 + ops_ptr=8 + backend_ptr=8 + reserved=24         → 64 B, 24 B reserved
```

Compact packing is the freeze — the naive layout was rejected because
it left zero headroom for R17's timestamp fields, forcing an
immediate re-freeze in the next milestone.

### 4.4 Why index-not-pointer for `parent_idx` and `name_slot_idx`

Storing `parent` as `u16` (index into `_vnode_pool`) costs 2 B and
consumes 6 B less than a `u64 parent_ptr`. Dereference cost is one
extra `lea rax, [_vnode_pool + rcx*64]` (single SIB+disp
instruction — no imul because `VNODE_SIZE == 64` is a power of two).
The 6 B saved is exactly what makes room for `link_count`, `uid`,
`gid`, `name_slot_idx` in the hot half.

The same argument applies to `name_slot_idx`: a `u16` index into a
separate `_name_slab` costs 2 B; a `u64` pointer would cost 8 B and
either eliminate `link_count`/`uid`/`gid` or push a field into the
cold half.

## 5. Alternatives considered (rejected)

### 5.1 Inline name in vnode (8-16 B)

**Proposal.** Reserve 16 B of the vnode for an inline name (up to 15
chars + NUL). Rejected because:

- 16 B is 25 % of the line — displaces `uid`, `gid`, `link_count`.
- Names longer than 15 chars still need a slab entry, so we would
  carry both the inline field and the slab index (or a mode bit
  discriminator), further inflating the layout.
- The tactical plan (§Subsystem 11 line 1193 onwards) treats names
  as a slab-owned concern; the vnode is a resource descriptor, not
  a name container.

**Decision.** All names live in `_name_slab` (R16.M1-004);
`name_slot_idx` is the only in-vnode name presence.

### 5.2 8-byte inline union (backend inlines small state)

**Proposal.** Use `backend_ptr`'s 8 B as a union — pointer for tmpfs,
inline `dev_t` for devfs, inline task-index for procfs. Adopted
implicitly: the field is `u64` and each backend interprets those 8
bytes. No layout change — this is a semantic freeze, not a
structural one. Documented as backend contract in each backend's
design doc (R16.M2 tmpfs, R17 devfs).

### 5.3 Timestamps in hot half, reserved slots in cold half

**Proposal.** Move `_reserved_mtime` into `[+0, +32)` for faster
`stat()` and push a hot field (`link_count`?) into cold. Rejected —
`stat()` is not on the read/write hot path; it is called
occasionally. The R17 designer may revisit if benchmarks show
`stat()` dominating.

### 5.4 128-byte vnode (two cache lines)

**Proposal.** Give up on the 64-B target; use 128 B for more R17
headroom (ACLs, xattrs, extended flags). Rejected — doubles pool
memory (32 KiB → 32 KiB is fine, but the L1D locality argument
weakens: half the fields land in the second line, causing partial
misses for common op sequences). Postponed to R19 (extended
attributes) as a **layout re-freeze** event, not a routine
resize.

### 5.5 Shadow structure for cold fields (`_vnode_shadow[256]`)

**Proposal.** Move the 24 B reserved region to a parallel array
`_vnode_shadow[256]` indexed by the same vnode idx; free 24 B in
the main vnode for more R16 hot fields. **Deferred** to R17. At
R16.M1 there are no more hot fields to add; the 24 B reserved
region is exactly the headroom the R17 timestamp freeze will
consume. If R17 needs still more, the shadow structure is the
canonical next step.

## 6. Layout witness — compile-time assertion

The freeze is verified at boot by a witness block that lands with
`#571` (vnode_pool). Its shape (pinned here so #571 does not have to
re-argue it):

```asm
; ============================================================
; R16-M1-001 (#570): vnode layout witness — offset check.
; Runs once at boot, between the R15 witnesses and the R16.M1-002 pool witness.
; ============================================================

; Verify VNODE_SIZE * VNODE_MAX == sizeof(_vnode_pool).
; If the assertion holds, the layout is 64 B per slot (or the pool array
; was resized in lockstep — either way, indices are correct).

lea rdi, [rip + _vnode_pool];
lea rsi, [rip + _vnode_pool_end];
sub rsi, rdi;                    ; rsi = pool size in bytes
mov rcx, 64;                     ; VNODE_SIZE
imul rcx, 256;                   ; VNODE_SIZE * VNODE_MAX = 16384
cmp rsi, rcx;
jne vnode_layout_fail;

; Verify offset of `type` == 0 (probe first vnode).
mov al, byte [rdi + 0];          ; VNODE_TYPE_OFFSET

; Verify offset of `ops_ptr` == 24 (probe reserved sentinel written by boot).
mov rax, qword [rdi + 24];       ; VNODE_OPS_PTR_OFFSET
cmp rax, 0;                      ; freshly-zeroed pool → ops_ptr is 0
jne vnode_layout_fail;

lea rdi, [rip + vnode_layout_ok_msg];
call uart_puts;
jmp vnode_layout_done;

vnode_layout_fail:
    lea rdi, [rip + vnode_layout_fail_msg];
    call uart_puts;

vnode_layout_done:
```

Fingerprint marker (contains-in-order in
`tests/r14b/expected-boot-r14b-loader.txt` at R16.M1):

```
R16 VNODE LAYOUT OK
```

## 7. Invariants

### 7.1 Size invariant

`sizeof(struct vnode) == 64` for the entire R16 series and any
follow-on R17.M1 timestamp freeze. Any change to the field set is a
**layout re-freeze issue**, not an edit to this doc.

### 7.2 Slot-0 reserved

`_vnode_pool[0]` has `type == VNODE_TYPE_FREE == 0` forever.
`vnode_alloc` skips index 0 so a zero return value can serve as
"invalid vnode" without conflicting with a real allocation.

### 7.3 Sentinel `0xFFFF` for u16 indices

`parent_idx == 0xFFFF` means "root or detached"; `name_slot_idx ==
0xFFFF` means "unnamed" (root vnode, anonymous pipe, socketpair).
No live vnode ever has index 0xFFFF (VNODE_MAX = 256 << 0xFFFF).

### 7.4 refcount semantics

`refcount` counts in-memory holds (fd table entries, walker
transients). `link_count` counts on-backend hard links.
`vnode_free` is called only when **both** reach zero:

```
if (--refcount == 0 && link_count == 0) { ops->close(vn); slot->type = FREE; }
if (--link_count == 0 && refcount == 0) { ops->close(vn); slot->type = FREE; }
```

R16.M1-007 (`vfs_close`, #576) implements the first branch;
`vfs_unlink` (R16.M4) implements the second.

### 7.5 ops_ptr non-NULL for live vnodes

Every vnode with `type != VNODE_TYPE_FREE` has a valid `ops_ptr`.
`vnode_alloc` sets it before setting `type`; `vnode_free` clears
`type` before clearing `ops_ptr`. This ordering is captured as a
partial order in `src/kernel/core/fs/vnode.pdx` (R16.M1-002).

### 7.6 Freeze discipline

This layout is frozen with the same discipline as
`design/kernel/task-struct-layout.md`:

- No downstream `.pdx` file may hard-code a numeric offset for
  any field. Every access uses the constant from
  `src/kernel/core/fs/vnode.pdx` (§3).
- Any field change is a **new layout-freeze issue** that (a) bumps
  a `VNODE_LAYOUT_VERSION` constant, (b) updates this doc's field
  table, (c) re-runs the boot witness (§6), and (d) rebuilds every
  witness in the R16 series against the new offsets.

## 8. R17+ growth plan (documented, not committed)

The 24-byte reserved region absorbs the following without re-freeze:

- **R17.M1 stat times.** `mtime` at `+40`, `atime` (or `ctime`) at
  `+48`. The choice between `atime` and `ctime` in `+48` is R17.M1's
  call — the R16 freeze reserves both offsets but pins neither
  semantic.
- **R17.M2 block accounting.** `block_count` at `+56` — for
  du/df/quota once a block-backed backend lands.
- **R17.M3 mount points.** `mount_ptr` at `+56` — for MOUNTPT vnodes
  (mutually exclusive with `block_count`; the discriminator is the
  `MOUNTPT` flag bit in `flags[0]`).

Once the 24-B region is fully consumed, the next expansion is the
shadow-structure route (§5.5), not a widening of the vnode.

## 9. Cross-references

- Issue: paideia-os#570
- Milestone: R16.M1 (VFS abstract layer)
- Downstream consumers: #571 (vnode_pool), #572 (vnode_alloc/free),
  #573 (vfs_super_ops), #574 (path resolver), #575 (vfs_open),
  #576 (vfs_close), #577 (vfs_read/write), #578 (vfs smoke)
- Sibling freeze doc: `design/kernel/task-struct-layout.md` (#543,
  #564) — same discipline, same offset-freeze contract
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 11 (line 1193) — VFS design contract
- Related: `design/kernel/r15-m5-007-fd-table-embed.md` (#549) —
  fd slot grows from opaque `u64` to `*vnode` at R16.M3, at which
  point every fd slot points at one of these 64-byte vnodes.
