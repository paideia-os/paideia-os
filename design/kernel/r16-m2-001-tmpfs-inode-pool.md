---
issue: 579
milestone: R16.M2 (tmpfs — in-memory VFS backend)
subsystem: 12 — tmpfs
topic: tmpfs inode pool declaration (R16-M2-001)
freeze-discipline: strict (inode offsets frozen for the entire R16.M2 series;
  #580–#584 dentry / lookup / create / write / read modules encode these
  offsets as immediates in SIB+disp addressing)
blocks:
  - "#580 (tmpfs_root_init — writes VNODE_TYPE_DIR into slot 1's `type` at +0)"
  - "#581 (tmpfs_lookup — walks dentry list, reads name at +144, parent at +176)"
  - "#582 (tmpfs_create — bitmap alloc, insert into parent dentry list)"
  - "#583 (tmpfs_write — indexes page_ptrs at +16 + 8*i)"
  - "#584 (tmpfs_read — same indexing, plus `size` bound at +8)"
touching:
  - src/kernel/core/fs/tmpfs/inode.pdx           (new module — pool + bitmap + slot helper)
  - src/kernel/boot/kernel_main.pdx              (witness block ~35 LOC)
  - tools/boot_stub.S                            (2 message strings)
  - tests/r14b/expected-boot-r14b-loader.txt     (marker: "R16 TMPFS INODE POOL OK")
  - tests/r15/expected-boot-r15-ring3.txt        (marker)
  - tests/r15/expected-boot-r15-process.txt      (marker)
  - design/kernel/r16-m2-001-tmpfs-inode-pool.md (this doc)
related:
  - design/kernel/vfs-layout.md                  (#570 — sibling pool freeze idiom; VNODE_TYPE_{FREE,REG,DIR} constants are shared)
  - src/kernel/core/fs/vnode_pool.pdx            (#571 — mirror the bitmap-first + slot-0-sentinel pattern this module follows)
  - design/kernel/r16-m1-003-vops.md             (#572 — every tmpfs vop reached via vops dispatcher will index this pool)
  - design/milestones/r14b-tactical-plan.md      §Subsystem 12 (line 1298 — tmpfs design contract; §Subsystem 12.B.1 = this issue)
---

# R16-M2-001 — tmpfs inode pool declaration (#579)

## 1. Scope

Freeze the **on-line layout of `struct tmpfs_inode`** at exactly **256
bytes** and declare the static storage — a `[u64; 2048]` slab in `.bss`
plus a 1-word occupancy bitmap in `.data` — for the R16.M2 tmpfs
backend. No allocator, no ops, no page-list traversal here: this issue
ships the container and the boot witness that proves its size and
addressability.

Every subsequent R16.M2 issue (#580 root init → #584 read) will
encode field offsets from §2 as SIB+disp immediates and index the pool
via `[base + idx*256]` (single-shift form). If any offset drifts, the
downstream module misaddresses its target and the boot witness for
that module fails loudly — the freeze is what makes that failure
mode local rather than silent.

Out of scope (deferred by design):

- **No allocator.** `tmpfs_inode_alloc` / `tmpfs_inode_free` land at
  #582 (`tmpfs_create`). The bitmap is declared here with slot-0's
  bit pre-set (sentinel discipline mirrors `_vnode_bitmap` in
  #571), but no `bsf_q` / `bts_q` code is written until the first
  caller needs it.
- **No dentry list.** Directory contents (name → inode idx) are a
  separate concern owned by #580–#582. This issue does not decide
  the dentry layout; it only reserves the `parent_idx` back-pointer
  used by directory traversal.
- **No page-list machinery.** `page_ptrs[16]` are declared as raw
  `u64` slots; the semantic "each slot is a physical-page frame
  address, `0` = unallocated" is contract material for #583
  (`tmpfs_write`), not enforced here.
- **No vnode ↔ tmpfs_inode binding.** The vnode's `backend_ptr` at
  `+32` (frozen by #570 §2) will point at a `tmpfs_inode` slot,
  but the pointer assignment happens in #580 (root init) and #582
  (create). This issue guarantees the storage exists; it does not
  wire it into the VFS lattice.

## 2. Inode layout — frozen (256 B per slot, 15 fields, 4 cache lines)

The layout parallels vfs-layout.md §2 (vnode 64 B freeze) with the same
discipline: hot fields in low half, cold/reserved in high half,
single-shift indexing.

| Offset | Size | Field           | Type   | Notes                                                                                                            |
|--------|------|-----------------|--------|------------------------------------------------------------------------------------------------------------------|
| +0     | 1    | `type`          | u8     | Shares constants with vnode (`VNODE_TYPE_{FREE=0, REG=1, DIR=2, ...}`) — an inode's `type` is what the vnode's `type` copies at bind time. FREE=0 matches zero-init. |
| +1     | 1    | `flags`         | u8     | Bit 0 = `TMPFS_INODE_FLAG_VALID`. Bits 1..7 reserved (R16.M3 grows `DIRTY`, `LOCKED`).                            |
| +2     | 2    | `refcount`      | u16    | In-memory hold counter (dentry references + vnode references). Frees the inode when it reaches 0 AND `link_count` == 0. |
| +4     | 2    | `link_count`    | u16    | Directory-entry references (hard links). tmpfs has no `link(2)` at R16.M2, so this is always 1 for live inodes; the field is reserved so R17 can grow `link` support without a re-freeze. |
| +6     | 2    | `_reserved_hot` | u16    | Reserved. R16.M3 candidate: `mode` (POSIX permission bits — currently derived from `type` at open time). |
| +8     | 8    | `size`          | u64    | File size in bytes. u64 covers R16.M2 cap (64 KiB) and any R18 grow-out. Read/write bounds check reads this field. |
| +16    | 128  | `page_ptrs[16]` | u64×16 | Each slot is a physical-page frame address returned by `phys_alloc(0)`. Slot `i` is unallocated iff `page_ptrs[i] == 0`. Covers 16 × 4 KiB = 64 KiB — the R16.M2 file cap. |
| +144   | 32   | `name[32]`      | u8×32  | NUL-padded name. 32 bytes = 31 chars + NUL — comfortably above the POSIX minimum NAME_MAX = 14 and matches the tactical plan's "dir max entries 64" / "file max 64 KiB" sizing. |
| +176   | 2    | `parent_idx`    | u16    | Index into `_tmpfs_inode_pool[64]`. Sentinel `0xFFFF` = root or detached (mirrors `VNODE_IDX_NONE`). u16 has 1024× headroom over TMPFS_MAX = 64. |
| +178   | 2    | `next_sibling`  | u16    | Intrusive singly-linked dentry list — `parent`'s children form a chain by walking `_tmpfs_inode_pool[cur].next_sibling` until `0xFFFF`. Directory operations touch this field; regular files leave it at `0xFFFF`. |
| +180   | 2    | `first_child`   | u16    | Head of the child-inode chain (directories only). `0xFFFF` = empty directory. Regular-file inodes leave this at `0xFFFF`. |
| +182   | 2    | `_pad_hot_tail` | u16    | Explicit tail pad closing the third cache line at +184. Reserved.                                                |
| +184   | 8    | `_reserved_a`   | u64    | R16.M3 candidate: `mtime` (ns since boot).                                                                       |
| +192   | 64   | `_reserved_b[8]`| u64×8  | 64 B fourth cache line, wholly reserved. R16.M3 / R17 growth: `atime`, `ctime`, `uid`, `gid`, `mode`, `xattr_ptr`, `block_count`, `generation`. Growth into this line is a **new-field freeze issue**, not a re-freeze of §2. |

**Total struct extent: [+0, +256) — 15 semantic + reserved slots, exactly 256 bytes, 4 L1 cache lines.**

Slot #0 in `_tmpfs_inode_pool` is reserved (its `type == 0 == FREE`
matches zero-init and doubles as the "invalid inode" sentinel that
`tmpfs_inode_alloc` never returns; callers may test `inode_idx != 0`
in place of a NULL check). Root inode lives at index 1 (mirrors
`VNODE_IDX_ROOT = 1` in vfs-layout.md).

### 2.1 Alignment

Pool declared `@align(64)` so every 256-byte slot lands on a
cache-line boundary AND every slot is 4-line-aligned. Indexing is
`[base + idx*256]` — see §3.2.

## 3. Sizing decision — 256 vs 192

The user brief flagged both 192 (177 bytes semantic + 15 pad) and 256
(177 semantic + 79 pad) as candidates. This section documents why the
freeze picks **256**.

### 3.1 Structural — single-shift indexing

The vnode_pool established the pattern: pool slot size = `2^k` so
indexing lowers to one instruction:

```
; VNODE_SIZE = 64:  base + idx*64  →  lea rax, [rip + _vnode_pool] ; shl rdi, 6 ; add rax, rdi
```

At 256 the same pattern holds with `shl rdi, 8`. At 192 the
computation becomes:

```
; TMPFS_INODE_SIZE = 192 (rejected):
mov  rax, rdi           ; keep idx
shl  rdi, 7             ; idx * 128
shl  rax, 6             ; idx * 64
add  rdi, rax           ; idx * 192
add  rdi, [base]        ; final
```

That's 4 instructions for what 256 does in 2. The tmpfs vops (read,
write, lookup, create) each begin with an inode-slot address
computation; a 4-vs-2 instruction cost on every op call is measurable
under a shell workload. Encoder alternative — `imul r64, r64, 192`
(imm8 form) — is one instruction, but `imul` isn't in the currently
validated MNEMONIC table for this codebase (grep confirms none of
`src/kernel/core/**.pdx` uses `imul r64,r64,imm`; taking on encoder
validation for one instruction to save four pages of `.bss` is a bad
trade against R16.M2's sprint budget).

### 3.2 Freeze headroom — reserving a full 4th line

At 256 B / slot the fourth cache line ([+192, +256)) is 64 B wholly
reserved. This mirrors vfs-layout.md §2's 24 B reserved region and
serves the same purpose: R16.M3 (`mtime` / `atime` / `ctime`) and R17
(`uid` / `gid` / `mode` / `xattr_ptr`) grow into the reserved region
without triggering a **layout re-freeze**. At 192 B / slot the
reserved region is 15 bytes (§2's `_pad_hot_tail` + a single
`_reserved_a` u64), which is not enough for R16.M3's three timestamp
fields — so 192 forces a re-freeze at R16.M3.

The freeze-discipline argument dominates the 4 KiB memory argument
below.

### 3.3 Memory — 4 KiB savings does not matter

- 64 inodes × 256 B = 16 384 B = 4 pages.
- 64 inodes × 192 B = 12 288 B = 3 pages.

The 4 KiB saved at 192 is negligible: physical RAM budget for
paideia-os R16 is not constrained (buddy allocator carves 256 MiB+),
and one page saved on the tmpfs pool doesn't relieve any pressure.

Contrast: on the vnode side, 64 B per line WAS the whole point
(single L1 line per vnode, hot-path field colocation). tmpfs inodes
are not hot in the same way — path resolution goes through the
vnode's ops_ptr, not through the tmpfs inode directly. The tmpfs
inode is warm-at-best (read/write into `page_ptrs`, occasional
directory-scan through `next_sibling`).

### 3.4 Decision

**INODE_SIZE = 256** is frozen. Rejection of 192 is documented so a
future engineer reopening this decision sees the freeze-discipline
reasoning explicitly.

## 4. Constants exported by `src/kernel/core/fs/tmpfs/inode.pdx`

Single source of truth for offset arithmetic. No `.pdx` file outside
this module may embed a numeric offset for a tmpfs inode field.

```
// Size + pool
TMPFS_INODE_SIZE          : u64 = 256
TMPFS_INODE_ALIGN         : u64 = 64
TMPFS_MAX                 : u64 = 64
TMPFS_INODE_POOL_BYTES    : u64 = 16384        // TMPFS_MAX * TMPFS_INODE_SIZE
TMPFS_INODE_BITMAP_WORDS  : u64 = 1            // TMPFS_MAX / 64
TMPFS_INODE_IDX_ROOT      : u64 = 1
TMPFS_INODE_IDX_NONE      : u64 = 0xFFFF
TMPFS_INODE_ALLOC_OOM     : u64 = 0xFFFF

// Field offsets — hot half (first 3 lines: [0, 192))
TMPFS_INODE_TYPE_OFFSET       : u64 = 0
TMPFS_INODE_FLAGS_OFFSET      : u64 = 1
TMPFS_INODE_REFCOUNT_OFFSET   : u64 = 2
TMPFS_INODE_LINK_COUNT_OFFSET : u64 = 4
TMPFS_INODE_SIZE_OFFSET       : u64 = 8
TMPFS_INODE_PAGES_OFFSET      : u64 = 16       // page_ptrs[16] base
TMPFS_INODE_NAME_OFFSET       : u64 = 144      // name[32] base
TMPFS_INODE_PARENT_OFFSET     : u64 = 176
TMPFS_INODE_NEXT_SIB_OFFSET   : u64 = 178
TMPFS_INODE_FIRST_CHILD_OFFSET: u64 = 180

// Cold half ([192, 256)) — reserved; no exported names yet.

// Constants shared with vnode (§2 imports these — do not redefine locally):
//   VNODE_TYPE_FREE = 0
//   VNODE_TYPE_REG  = 1
//   VNODE_TYPE_DIR  = 2

// Local flag bits
TMPFS_INODE_FLAG_VALID    : u8  = 0x01
```

## 5. Storage declarations

```
// _tmpfs_inode_pool[64] × 256 B = 16 384 B = 4 pages.
// As u64 array: TMPFS_INODE_POOL_BYTES / 8 = 2048 u64.
// @align(64): every 256-B slot lands on a 4-line boundary.
pub let mut _tmpfs_inode_pool   : [u64; 2048] = uninit @align(64)

// One-word occupancy bitmap. Bit 0 pre-set so tmpfs_inode_alloc
// (#582) never returns slot 0 — the reserved "invalid inode"
// sentinel. Same discipline as _vnode_bitmap in vnode_pool.pdx.
pub let mut _tmpfs_inode_bitmap : [u64; 1] = [1]
```

Bitmap uses `[u64; 1]` (not scalar) for shape-parity with
`_vnode_bitmap` — the bitmap-scan idiom (`lea r8, [rip + bitmap]; mov
r9, [r8 + rcx*8]`) is identical across pool modules.

## 6. Slot-address helper — one-liner

Every downstream module needs `idx → &_tmpfs_inode_pool[idx]`. Ship
it once, in this module, following the `vnode_slot` shape from
`vnode_pool.pdx`:

```
pub let tmpfs_inode_slot : (u64) -> u64 !{} @{} =
  fn (idx: u64) -> unsafe {
    effects: {},
    capabilities: {},
    justification: "R16-M2-001 (#579): idx → &_tmpfs_inode_pool[idx*256].
      SIB scale caps at 8 so *256 requires shl 8 + add (three-instruction
      body). No bounds check — caller has validated idx via a
      tmpfs_inode_alloc round-trip (#582) or via a #570-frozen index
      field on a live vnode / dentry chain.",
    block: {
      lea rax, [rip + _tmpfs_inode_pool];
      shl rdi, 8;                      // idx * 256
      add rax, rdi;
      ret
    }
  }
```

Shipping `tmpfs_inode_slot` in this issue (instead of deferring to
#582) keeps all inode-address computation behind a single symbol —
matching the vnode/vnode_pool split.

## 7. Boot witness — R16 TMPFS INODE POOL OK

Lands in `kernel_main.pdx` immediately after the `R16 VFS OK`
integration marker (line ~2264, before `wrmsr` for GS_BASE). Runs
after the R16.M1 vnode lattice is proven so a witness failure here
localizes to R16.M2 storage, not to VFS.

Three sub-tests + one marker. Deliberately lightweight — this issue
only proves the pool is declared and addressable; allocator behavior
is proven by the #582 witness.

### 7.1 Sub-test A — bitmap slot-0 sentinel is set

```asm
; Load bitmap word 0, isolate bit 0.
mov rax, [rip + _tmpfs_inode_bitmap]
and rax, 1
cmp rax, 1
jne tmpfs_inode_pool_witness_fail
```

Proves: `.data` initialization for `_tmpfs_inode_bitmap = [1]`
survived link + load. If bit 0 were 0, `tmpfs_inode_alloc` (#582)
would eventually return slot 0 and downstream sentinel checks (`idx !=
0`) would misclassify a real allocation as "invalid."

### 7.2 Sub-test B — slot 0's `type` is FREE (0)

```asm
lea rdi, [rip + _tmpfs_inode_pool]
mov al, byte [rdi + 0]            ; TMPFS_INODE_TYPE_OFFSET
cmp al, 0                          ; VNODE_TYPE_FREE
jne tmpfs_inode_pool_witness_fail
```

Proves: pool is in `.bss` (zero-init). If any linker quirk placed the
pool in `.data` with garbage init, slot 0's type would be non-zero and
the sentinel-slot discipline would break.

### 7.3 Sub-test C — slot 63 is addressable via `shl 8` indexing

```asm
; Compute &_tmpfs_inode_pool[63] and probe type byte.
mov rdi, 63
call tmpfs_inode_slot              ; rax = &_tmpfs_inode_pool[63]
mov al, byte [rax + 0]             ; TMPFS_INODE_TYPE_OFFSET
cmp al, 0                          ; VNODE_TYPE_FREE
jne tmpfs_inode_pool_witness_fail
```

Proves: (a) `tmpfs_inode_slot` computes the last-slot address without
overrun (i.e., the pool contains at least 64 × 256 bytes), and (b)
`.bss` zero-init covers the whole pool, not just the first slot.

Sub-test C effectively encodes the "pool size == TMPFS_MAX ×
TMPFS_INODE_SIZE" invariant without needing an `_end` symbol: if the
pool were shorter, the probe would either land in adjacent `.bss`
(likely zero and pass — false negative) OR land in `.rodata`/other
sections (page fault — hard fail). Combined with the compile-time
`[u64; 2048]` shape (2048 × 8 = 16384 = TMPFS_MAX × TMPFS_INODE_SIZE),
the invariant is guaranteed link-time and probed run-time.

### 7.4 Marker

On all three sub-tests green:

```
R16 TMPFS INODE POOL OK
```

Fingerprint added to all three expected-boot text files
(`tests/r14b/expected-boot-r14b-loader.txt`,
`tests/r15/expected-boot-r15-ring3.txt`,
`tests/r15/expected-boot-r15-process.txt`) on the line immediately
following `VFS OK`.

## 8. Alternatives considered (rejected)

### 8.1 INODE_SIZE = 192 (compact packing)

Rejected in §3. Documented explicitly so the reasoning survives a
future "reopen the size question" discussion.

### 8.2 Inline dentry list per directory (fixed-size children array)

**Proposal.** Skip `next_sibling` / `first_child` intrusive-list
fields; give each directory inode an inline `children[16]` u16 array
inside the +192..+256 reserved region.

**Rejected.** Fixed-size children caps directory fan-out at 16 (the
tactical plan targets 64), forcing overflow to spill into a separate
data structure whose freeze would live somewhere else — the same
information split into two places is exactly what the freeze
discipline exists to prevent. Intrusive lists cost 4 bytes per
directory entry and scale to arbitrary fan-out at the price of one
extra pointer-chase per lookup step.

### 8.3 Separate name slab (parallel to R16.M1's `_name_slab`)

**Proposal.** Store names in a shared `_tmpfs_name_slab` and put a
`u16 name_slot_idx` in the inode — mirrors vfs-layout.md §5.1.

**Rejected for R16.M2.** vnode chose slab-external names because
VNODE_SIZE=64 was tight — 32 B of inline name would displace
`refcount`, `uid`, `gid`. tmpfs_inode has 256 B and no comparable
pressure: 32 B of inline name is 12.5 % of the slot with no field
displacement. Deferring the slab avoids a second freeze
(_name_slab layout) that no R16.M2 caller currently needs.
Reconsider at R17 if a `rename(2)` op wants copy-free name moves.

### 8.4 8-page files (32 pointers × 128 KiB max)

**Proposal.** Grow `page_ptrs[16]` → `page_ptrs[32]`, cap files at
128 KiB.

**Rejected.** The tactical plan (§Subsystem 12 line 1306) explicitly
sizes the R16.M2 file cap at 64 KiB. Larger files land at R18 with an
indirect-block scheme (single-indirect, double-indirect) rather than
by growing the direct-pointer count — same shape as classic UFS.
Growing to 32 direct pointers now would consume the R17 timestamp
region without buying us anything the shell demo needs.

### 8.5 Union `page_ptrs` with directory children storage

**Proposal.** Since a directory has no page-backed content and a
regular file has no children, overlay `page_ptrs[16]` with
`children[64]` u16 array using the `type` discriminator.

**Rejected for R16.M2.** Union-of-structs is a re-freeze landmine —
any future field addition to the DIR variant has to fit inside the
REG variant's 128-byte page-pointer region. Explicit
`first_child`/`next_sibling` fields cost 4 bytes for regular files
and 4 bytes for directories, and both variants can grow
independently.

## 9. Invariants

### 9.1 Fixed size + fixed offsets

`TMPFS_INODE_SIZE == 256` for the entire R16.M2 series. Any field
resize, addition, or reordering is a **new layout-freeze issue** that
(a) bumps a `TMPFS_INODE_LAYOUT_VERSION` constant, (b) updates §2's
table, (c) re-runs the witness (§7), and (d) rebuilds every consumer
(#580–#584) against the new offsets.

### 9.2 Slot-0 reserved

`_tmpfs_inode_pool[0]` has `type == 0` (FREE) forever.
`tmpfs_inode_alloc` (#582) skips index 0 so a zero return value
serves as "invalid inode" without conflicting with a real
allocation.

### 9.3 Sentinel `0xFFFF` for u16 indices

`parent_idx == 0xFFFF` = root or detached. `next_sibling == 0xFFFF`
= end of sibling chain. `first_child == 0xFFFF` = empty directory or
regular file. TMPFS_MAX = 64 << 0xFFFF; no live inode ever has index
0xFFFF.

### 9.4 Type-shared with vnode

`TMPFS_INODE_TYPE_OFFSET` and vnode's `+0 type` byte carry
identical semantics (`VNODE_TYPE_FREE` / `REG` / `DIR` constants
apply to both). At bind time (`tmpfs_lookup` / `tmpfs_create`) the
tmpfs_inode's type byte is copied verbatim into the vnode's type
slot. Keeping the constants shared avoids a divergent
enumeration.

### 9.5 Bitmap sentinel

`_tmpfs_inode_bitmap[0] & 1 == 1` at all times. Neither
`tmpfs_inode_alloc` nor `tmpfs_inode_free` (#582) may clear bit 0.
The witness (§7.1) probes this invariant on the initial state; a
future #582 witness will re-probe it after alloc/free cycles.

### 9.6 Freeze discipline

Downstream modules import constants from
`src/kernel/core/fs/tmpfs/inode.pdx` (§4). No hard-coded numeric
offsets anywhere else — the freeze exists to make offset drift
impossible without a rebuild event.

## 10. Growth plan (R16.M3 and beyond)

The 64-byte reserved region ([+192, +256)) absorbs the following
without re-freeze:

- **R16.M3 — mtime**: `+192` (u64, ns since boot). Freed up by
  `_reserved_a` at +184 first if we choose the hot-half slot for
  the most-accessed timestamp.
- **R17.M1 — mode**: use `_reserved_hot` at +6 (u16 — 12 permission
  bits + type nibble + suid/sgid/sticky).
- **R17.M2 — uid, gid**: `+200` and `+202` (u16 each), inside the
  cold reserved region.
- **R17.M3 — atime, ctime**: `+208`, `+216` (u64 each).
- **R18.M1 — xattr_ptr**: `+224` (u64) — points into an xattr slab.
- **R18.M2 — indirect page block**: `+232` (u64) — pointer to a
  page of `u64` page pointers, for files > 64 KiB.

Once the cold region is fully consumed (all 64 bytes assigned), the
next expansion is a **shadow structure** (parallel array indexed by
the same inode idx) — same escape hatch as vfs-layout.md §8.

## 11. Cross-references

- Issue: paideia-os#579
- Milestone: R16.M2 (tmpfs — in-memory VFS backend)
- Upstream: none within R16.M2. Depends on R16.M1's frozen
  `VNODE_TYPE_*` constants (importable from
  `src/kernel/core/fs/vnode.pdx`).
- Downstream consumers: #580 (root init — writes DIR into slot 1),
  #581 (lookup — walks `next_sibling`, reads `name`), #582 (create —
  allocator, insert into `first_child`/`next_sibling`), #583 (write —
  indexes `page_ptrs`), #584 (read — same indexing + `size` bound).
- Sibling pool doc: `src/kernel/core/fs/vnode_pool.pdx` (#571) — same
  bitmap-first + slot-0-sentinel + `_slot` helper triple.
- Sibling freeze doc: `design/kernel/vfs-layout.md` (#570) — same
  freeze-discipline; same hot-cold split idiom.
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 12 (line 1298) — tmpfs design contract; issue register
  §12.B.1 is this issue.
- Encoder verification: `shl r64, imm8` and `mov [rip+sym], r64` are
  landed encoder features (used throughout `vnode_pool.pdx` and
  every R16.M1 module — no new encoder work required for this
  issue). The `_reserved_hot`/`_reserved_a`/`_reserved_b` reservations
  are declared implicitly via the pool's total size — no separate
  reservation directive needed.
