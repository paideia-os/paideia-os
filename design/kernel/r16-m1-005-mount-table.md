---
issue: 574
milestone: R16.M1 (VFS abstract layer — superblock/inode/dentry/vnode)
subsystem: 11 — VFS abstract layer
topic: Static mount_table[8] + mount / mount_root_vnode / mount_lookup primitives (R16-M1-005)
freeze-discipline: strict (per-entry layout and slot-0 = root convention are frozen for
  the entire R16 series; MOUNT_MAX = 8 is soft-frozen — a bump to 16/32 is a
  freeze-bump issue with a re-run witness)
blocks:
  - "#575 (vfs_open — uses mount_root_vnode() as the start anchor for absolute paths)"
  - "#580 (R16.M2 tmpfs root init — first real mount() with a live backend vops table)"
  - "R17.M-x (path_resolve cross-mount descent — extends the regular-component step
    with a mount_lookup call before every vops_lookup)"
touching:
  - src/kernel/core/fs/mount.pdx                (new module — table storage + 3 primitives + witness fixtures)
  - src/kernel/boot/kernel_main.pdx             (witness block ~70 LOC)
  - tools/boot_stub.S                           (2 message strings)
  - tests/r14b/expected-boot-r14b-loader.txt    (marker: "R16 MOUNT TABLE OK")
  - tests/r15/expected-boot-r15-ring3.txt       (marker: "R16 MOUNT TABLE OK")
  - tests/r15/expected-boot-r15-process.txt     (marker: "R16 MOUNT TABLE OK")
  - design/kernel/r16-m1-005-mount-table.md     (this doc)
related:
  - design/kernel/vfs-layout.md                 (#570 — pins VNODE_TYPE_DIR=2,
    VNODE_PARENT_IDX_OFFSET=+8, VNODE_IDX_NONE=0xFFFF, VNODE_FLAG_MOUNTPT=0x08)
  - design/kernel/r16-m1-003-vops.md            (#572 — vops table shape;
    mount() sets up a per-fs vops pointer via the same discipline)
  - design/kernel/r16-m1-004-path-resolver.md   (#573 — path_resolve is the
    submount-path resolver; mount() calls it for non-root mounts)
  - src/kernel/core/fs/vnode_pool.pdx           (#571 — mount() calls vnode_alloc
    for the new fs's root vnode; witness calls vnode_free to reclaim a slot after
    the pool-exhaustion witness leaves the pool at OOM)
  - design/milestones/r14b-tactical-plan.md    §Subsystem 11 item 5 (mount table
    contract line 1256)
---

# R16-M1-005 — mount table + primitives (`mount`, `mount_root_vnode`, `mount_lookup`, #574)

## 1. Scope

Ship the static in-kernel **mount table** — a fixed-size array of 8 mount
entries — and three primitives that operate on it:

- `mount(path_ptr, backend_type) -> u16` — install a filesystem at
  `path_ptr` under the given backend type; return the slot index or
  `0xFFFF` on failure.
- `mount_root_vnode() -> u16` — return the root filesystem's root vnode
  index. Called by `path_resolve` (via `vfs_open` at #575) as the start
  vnode for absolute paths.
- `mount_lookup(vnode_idx) -> u16` — given a vnode index, return the
  index of the mounted filesystem's root if the vnode is a mountpoint;
  otherwise return the input unchanged (identity fallthrough).
  Consumed by path_resolve's descent step at R17+ to cross mount
  boundaries.

At R16.M1 this issue does **not** install a real backend. It ships
the substrate — table storage, the three primitives, and a witness
that exercises the bootstrap path (`mount("/", TMPFS)` allocates a
new vnode for the root filesystem, records it in slot 0, and makes
it retrievable via `mount_root_vnode()`). The real backend install
happens at R16.M2 (`#580` tmpfs root init), which passes a fully
populated `_tmpfs_vops` table and populates the root vnode's
`ops_ptr` slot.

Out of scope (deliberately deferred):

- **A real backend on any slot.** `mount()` writes only the mount
  entry and the mounted fs's root vnode's `type` + `parent_idx`
  fields. The `ops_ptr` slot on that vnode stays `0` (which
  `vops_read` / `vops_write` / etc. handle by returning
  `VOPS_ERR_NOT_SUPPORTED` per r16-m1-003-vops.md §2.2). R16.M2
  wires up `_tmpfs_vops` for slot 0's root vnode after this issue lands.
- **Extended flags** (`MOUNT_FLAG_RO`, `MOUNT_FLAG_NOSUID`,
  `MOUNT_FLAG_NOEXEC`, `MOUNT_FLAG_NODEV`, `MOUNT_FLAG_BIND`). All
  reserved in the flag byte's high bits; no behavior wired at R16.M1.
- **umount / re-mount**. Read-only mount table at R16.M1. A single
  boot-time root mount is the whole demo requirement. R18+ adds a
  `sys_umount` syscall and re-mount semantics under a new freeze issue.
- **Cross-mount descent in path_resolve.** The resolver at #573 does
  not call `mount_lookup`. The extension lands as a **path_resolve
  amendment** in the R17 series (r14b-tactical-plan.md §Subsystem 11
  item 5 note on the `VNODE_FLAG_MOUNTPT` bit). This issue provides
  the primitive; the resolver-side integration is one issue away.
- **Per-mount refcounts.** A live mount at R16 is pinned for the
  lifetime of the boot. No `mount_hold`/`mount_put`. The
  `_reserved` u16 slot in each entry reserves the bit real estate for
  R17's refcount, but this issue does not touch it.

## 2. Mount entry layout — frozen (8 bytes per entry × 8 entries = 64 B)

The table is a `[u64; 8]` in `.bss`, `@align(64)` (one L1D cache
line — the entire table fits in a single line for hot access by
`mount_root_vnode` and `mount_lookup`).

Each entry packs five fields into one 8-byte u64 slot:

| Bit range | Size | Field                     | Type | Notes                                                                                                                    |
|-----------|------|---------------------------|------|--------------------------------------------------------------------------------------------------------------------------|
| [0, 16)   | u16  | `mountpoint_vnode_idx`    | u16  | Index (in `_vnode_pool[256]`) of the directory vnode where this fs is grafted. `0` for slot 0 (root has no mountpoint above). |
| [16, 32)  | u16  | `root_vnode_idx`          | u16  | Index of the mounted filesystem's own root vnode. Allocated by `mount()` via `vnode_alloc`; `type` is set to `VNODE_TYPE_DIR = 2`. |
| [32, 40)  | u8   | `backend_type`            | u8   | Discriminant: `NONE=0` (empty), `TMPFS=1`, `DEVFS=2`, `PROCFS=3`, `TTY=4`. `0` doubles as the "slot free" sentinel and matches zero-init. |
| [40, 48)  | u8   | `flags`                   | u8   | Bit 0: `MOUNT_FLAG_VALID = 0x01`. Bit 1: `MOUNT_FLAG_ROOT = 0x02` (this slot is the root mount). Bits 2..7: reserved for R17. |
| [48, 64)  | u16  | `_reserved`               | u16  | R17 growth. Slot index into a per-fs data pool (`_tmpfs_root_ptr`, etc.), or a per-mount refcount, or a flags overflow.        |

**Total table extent: 64 B — one L1D cache line, fits under
`@align(64)`.**

The five-field u64 packing is deliberate: a single-instruction load
of an entry brings the whole record into a register, and every field
access is a shift+mask on that register (2-3 instructions total)
without a second memory reference. `mount_lookup`'s hot inner loop
touches one u64 per iteration, and 8 iterations touch one cache line.

### 2.1 Why one u64 per entry (not `[u8; 64]` with SIB narrow moves)

Two encoder-shape choices:

- **`[u64; 8]` with shift/mask field extraction.** Load the whole
  entry into a register with `mov rax, [base + idx*8]` (one
  instruction, proven encoder pattern per
  `src/kernel/core/fs/vnode_pool.pdx` `_vnode_bitmap` loads).
  Field extract via `shr + and` (2 instructions per field).
- **`[u8; 64]` with narrow moves.** Individual byte / word loads
  via `mov_b` / `mov_w`, which paideia-as supports for the
  `[base + disp]` shape (per r16-m1-004-path-resolver.md §6.1
  encoder-verification pass).

The `[u64; 8]` shape wins on two counts:

1. **Simpler encoder surface.** Every store site uses the standard
   `mov [base + idx*8], reg` form. Narrow moves with a base+index
   shape (`mov_w [r8 + rcx*8], reg`) are not verified in paideia-as
   as of this writing — the path-resolver only uses the
   `[base + disp]` shape (r16-m1-004-path-resolver.md §6.1 explicitly
   flags the `[base + idx*scale + disp]` register-source form as
   unsupported for narrow moves). Building each entry as a packed
   u64 in a register and writing it in one shot sidesteps the
   entire narrow-store question.
2. **Single-load semantics.** `mount_lookup` reads three fields
   (`backend_type`, `mountpoint_idx`, `root_idx`) per entry. With
   `[u64; 8]`, that's one load followed by two `shr + and` extracts
   — the whole record is in the register the moment we've decided
   whether to inspect it. With `[u8; 64]`, three separate narrow
   loads at three different displacements per iteration.

The tradeoff is a small amount of shift/mask arithmetic in
`mount()`'s entry-construction phase (see §5) — the packed u64 is
built in a register, then stored with one `mov [base + idx*8], reg`.
This is exactly the pattern used in `vnode_pool.pdx`
`vnode_alloc` for the bitmap-word write-back.

### 2.2 Why slot 0 is the root mount (pinned convention)

`_root_mount_slot = 0` is a **pinned invariant**. Rationale:

- **Zero-cost `mount_root_vnode()`.** The function loads
  `_mount_table[0]`, shifts right by 16, and masks. No table scan.
- **Zero-cost detection of "is root mounted."** The `backend_type`
  byte at `[+4]` (bits 32-39 of entry 0) is `0` iff no root is
  mounted. `mount()` detects the bootstrap case as "slot 0's
  backend byte is zero" without a separate boolean flag.
- **Boot ordering discipline.** The first `mount()` call always
  fills slot 0 (bootstrap case; see §5). Submounts always take slots
  1..7. The invariant matches the linear-scan free-slot search
  starting from index 0.

R17 may allow re-mounting the root (pivot-root style). Doing so is a
**freeze-bump event** — this doc pins the slot-0-is-root invariant
for the whole R16 series.

### 2.3 The `_reserved` u16 slot — R17 headroom

Bits [48, 64) of each entry are reserved. Three claimants (in
priority order):

- **R17 per-mount refcount.** A u16 counts live open()s or path
  resolutions under this mount. `umount` fails while refcount > 0.
- **R17 per-fs data-pool slot index.** For tmpfs: index into
  `_tmpfs_super_pool[8]` holding per-fs state (root inode
  pointer, block allocator state, etc.). Alternative to `backend_ptr`
  in a per-vnode slot.
- **R17 mount-options overflow.** If flags outgrows one byte
  (`MOUNT_FLAG_RO | MOUNT_FLAG_NOSUID | MOUNT_FLAG_NOEXEC |
  MOUNT_FLAG_NODEV | MOUNT_FLAG_BIND | MOUNT_FLAG_SYNC |
  MOUNT_FLAG_NOATIME | MOUNT_FLAG_STRICTATIME` = 8 bits at
  saturation; a 9th flag needs this slot).

R17 will resolve the three-way contention. R16.M1 pins the slot for
"some future u16" without semantic commitment.

## 3. Signatures and semantics

All three primitives are Pdx `unsafe` lambdas in the
`Mount` module. Signatures pin argument-register conventions.

### 3.1 `mount(path_ptr, backend_type) -> u16`

```
mount : (path_ptr : u64, backend_type : u64) -> u64 !{mem} @{}
  rdi = path_ptr (null-terminated ASCII path)
  rsi = backend_type (u64 with low 8 bits used; must be in [1, 4])
  → rax = mount slot idx (u16 in low 16 bits) on success
  → rax = 0xFFFF (MOUNT_IDX_NONE) on failure
```

**Failure modes** (all collapse to `rax = 0xFFFF`):

- `backend_type` outside `[1, 4]`.
- Mount table full (all 8 slots have `backend_type != 0`).
- Submount case (`slot != 0`) with `path_resolve` returning 0
  (bad path).
- `vnode_alloc` OOM.

**Behavior branches** on which slot is being filled:

- **Bootstrap (slot 0 is empty).** `path_ptr` is nominally `"/"`
  but not validated at R16.M1 — the caller is trusted to pass
  `"/"` on the very first mount. `mountpoint_vnode_idx` is set to
  `0` (no parent above root). A new root vnode is allocated via
  `vnode_alloc`. `flags` bit 1 (`MOUNT_FLAG_ROOT`) is set in
  addition to `MOUNT_FLAG_VALID`.
- **Submount (slot ∈ [1, 7]).** `path_ptr` is resolved via
  `path_resolve(path_ptr, mount_root_vnode(), 0)`. On success the
  returned vnode is the mountpoint; a new root vnode is allocated
  for the mounted fs; `flags` gets only `MOUNT_FLAG_VALID`. On
  `path_resolve` returning 0 (bad path), mount fails.

The mounted fs's root vnode is minimally initialized by `mount()`:

- `type` (+0) = `VNODE_TYPE_DIR = 2`.
- `parent_idx` (+8) = `VNODE_IDX_NONE = 0xFFFF` — the mount root is
  "detached" from the parent-fs's tree perspective. R17's
  cross-mount `..` support will re-thread this by inspecting the
  mount entry's `mountpoint_idx` instead of following `parent_idx`.
- `ops_ptr` (+24) = `0` (deliberately left null; R16.M2 wires up
  `_tmpfs_vops`). Any consumer that dispatches through `vops_read`
  etc. on this vnode receives `VOPS_ERR_NOT_SUPPORTED` per
  r16-m1-003-vops.md §2.2 — safe failure semantic.

### 3.2 `mount_root_vnode() -> u16`

```
mount_root_vnode : () -> u64 !{mem} @{}
  → rax = _mount_table[0].root_vnode_idx (u16 in low 16 bits)
  → rax = 0 if no root has been mounted yet
```

Leaf function (no nested call). Load `_mount_table[0]`, shift
right by 16, mask to u16. Total: 4 instructions.

Consumed by `vfs_open` (#575) as the second argument to
`path_resolve` for absolute paths. Once R16.M2 populates a
real backend, this becomes the start of every `sys_open` walk.

**Rationale for `mount_root_vnode() → 0` on "not mounted":** matches
the "slot-0 reserved as invalid vnode" discipline from
vfs-layout.md §7.2. Callers may test `rax == 0` in place of a
NULL check without conflating "no root mounted" with "root is
vnode 0" — vnode 0 is never a live index.

### 3.3 `mount_lookup(vnode_idx) -> u16`

```
mount_lookup : (vnode_idx : u64) -> u64 !{mem} @{}
  rdi = vnode_idx (u64 with low 16 bits used)
  → rax = traversed vnode idx (u16 in low bits) if a mount entry
    matches; the input vnode_idx unchanged otherwise (identity
    fallthrough).
```

Semantics: scan all 8 mount entries. For each entry with
`backend_type != 0`, check two match conditions:

1. `entry.mountpoint_vnode_idx == vnode_idx` — the input vnode
   is a mountpoint directory in the parent fs; return the mounted
   fs's root vnode (cross-mount descent).
2. `entry.root_vnode_idx == vnode_idx` — the input vnode already
   *is* a mounted fs's root; return the same idx (self-loop /
   idempotent identity).

If no entry matches: return `vnode_idx` unchanged.

Both match conditions are unified — both return
`entry.root_vnode_idx`. Rationale: this makes `mount_lookup`
**idempotent** — calling it twice is the same as calling it once,
so callers may invoke it liberally at every path-descent step
without a preceding "am I already at a mount root?" check.

The self-loop for the root fs's root (sub-test D in §6.4) drops
out of the general rule with no special case: at boot the root fs
is the only live mount, and `mount_lookup(root_vnode_idx)` matches
condition 2 (input equals the entry's root_idx) and returns the
same idx.

**Failure discipline:** `mount_lookup` has no fail path. It is
total — every input either matches an entry (returns the entry's
root) or returns unchanged. Consumers never need an error branch.

### 3.4 Register discipline — `mount()` prologue

`mount()` makes nested calls to `vnode_alloc`, `path_resolve`,
`vnode_slot`, and `mount_root_vnode`. It is not a leaf. Prologue
pushes five callee-saved registers (`rbx`, `r12`, `r13`, `r14`,
`r15`); the odd count shifts `rsp mod 16` from `8` (dispatcher
entry, per SysV) to `0`, exactly what SysV requires at nested call
sites. No `sub rsp, 8` alignment pad is needed around inner calls —
the prologue already lands us on 16-byte alignment.

This mirrors the `path_resolve` prologue discipline
(r16-m1-004-path-resolver.md §2.3) exactly.

Loop-invariant register plan:

| Reg | Role                                                                                          |
|-----|-----------------------------------------------------------------------------------------------|
| rbx | `root_vnode_idx` — the newly-allocated vnode index for the mounted fs's root.                 |
| r12 | `mountpoint_vnode_idx` — 0 in the bootstrap case; `path_resolve` result in the submount case. |
| r13 | slot idx — the u64 slot in `_mount_table` we're filling.                                      |
| r14 | `backend_type` — copied from `rsi` at prologue, preserved across nested calls.                |
| r15 | `path_ptr` — copied from `rdi` at prologue, preserved across nested calls.                    |

`mount_root_vnode` and `mount_lookup` are leaves; no callee-save
touched, no prologue.

## 4. Constants exported by `src/kernel/core/fs/mount.pdx`

Single source of truth for offset arithmetic and discriminants.
Downstream consumers (`vfs_open` #575, tmpfs root init #580, path
resolver cross-mount R17) encode these as immediates via re-import
from this module.

```
// Table geometry (frozen for R16 series)
MOUNT_ENTRY_SIZE          : u64 = 8         // one u64 per entry
MOUNT_MAX                 : u64 = 8         // slot count
MOUNT_TABLE_BYTES         : u64 = 64        // MOUNT_ENTRY_SIZE * MOUNT_MAX
MOUNT_ROOT_SLOT           : u64 = 0         // slot 0 = root fs (pinned)

// Per-entry field bit ranges (for shift/mask extraction)
MOUNT_MOUNTPOINT_SHIFT    : u64 = 0
MOUNT_ROOT_SHIFT          : u64 = 16
MOUNT_BACKEND_SHIFT       : u64 = 32
MOUNT_FLAGS_SHIFT         : u64 = 40
MOUNT_RESERVED_SHIFT      : u64 = 48

MOUNT_U16_MASK            : u64 = 0xFFFF
MOUNT_U8_MASK             : u64 = 0xFF

// Backend discriminants
MOUNT_BACKEND_NONE        : u64 = 0         // empty slot; matches zero-init
MOUNT_BACKEND_TMPFS       : u64 = 1
MOUNT_BACKEND_DEVFS       : u64 = 2         // reserved for R17
MOUNT_BACKEND_PROCFS      : u64 = 3         // reserved for R17
MOUNT_BACKEND_TTY         : u64 = 4         // reserved for R17

// Flag bits
MOUNT_FLAG_VALID          : u64 = 0x01
MOUNT_FLAG_ROOT           : u64 = 0x02      // this slot is _root_mount_slot
// bits 0x04..0x80 reserved for R17 (RO, NOSUID, NOEXEC, NODEV, BIND, ...)

// Sentinels — mirror vfs-layout.md §7.2 discipline
MOUNT_IDX_NONE            : u64 = 0xFFFF    // mount() failure sentinel
VNODE_IDX_NONE            : u64 = 0xFFFF    // mirror for parent_idx write

// Vnode field mirrors (frozen by vfs-layout.md §3; not re-frozen here)
VNODE_TYPE_OFFSET         : u64 = 0
VNODE_TYPE_DIR            : u64 = 2
VNODE_PARENT_IDX_OFFSET   : u64 = 8
```

## 5. `mount()` algorithm — five phases

### 5.1 Prologue

```asm
push rbx; push r12; push r13; push r14; push r15    ; rsp%16 = 0

mov r15, rdi                                          ; r15 = path_ptr
mov r14, rsi                                          ; r14 = backend_type
```

### 5.2 Validate backend_type

```asm
cmp r14, 1
jb  mount_fail
cmp r14, 4
ja  mount_fail
```

Any value in `[1, 4]` passes. `0` (NONE) is not a legal mount
argument — passing 0 asks to install a slot with the "empty"
discriminant, which breaks the free-slot scan invariant.

### 5.3 Find the first free slot (linear scan)

```asm
lea r9, [rip + _mount_table]
xor rcx, rcx                                          ; rcx = candidate slot
scan_free:
    cmp rcx, 8                                        ; MOUNT_MAX
    jae mount_fail
    mov rax, [r9 + rcx*8]                             ; load entry u64
    shr rax, 32                                       ; extract backend byte range
    and rax, 0xFF
    cmp rax, 0                                        ; MOUNT_BACKEND_NONE
    je  found_slot
    add rcx, 1
    jmp scan_free
found_slot:
    mov r13, rcx                                      ; r13 = slot idx
```

Linear scan from 0. Slot 0 is picked first on the bootstrap call
(all slots empty), matching the pinned root-mount convention.

### 5.4 Resolve the mountpoint

```asm
cmp r13, 0
jne resolve_submount

; Bootstrap: mountpoint_idx = 0, path is nominally "/"
xor r12, r12
jmp alloc_root

resolve_submount:
call mount_root_vnode                                 ; rax = root fs's root idx
mov  rsi, rax
mov  rdi, r15                                         ; path_ptr
xor  rdx, rdx                                         ; cwd = 0 (irrelevant for absolute)
call path_resolve                                     ; rax = mountpoint idx or 0
cmp  rax, 0
je   mount_fail
mov  r12, rax                                         ; r12 = mountpoint idx
```

The bootstrap case does not call `path_resolve` — there is no
root vnode to resolve against yet. The submount case calls
`path_resolve` with the current root as the anchor.

### 5.5 Allocate the mounted fs's root vnode + minimally initialize it

```asm
alloc_root:
call vnode_alloc
cmp  rax, 0xFFFF                                      ; VNODE_ALLOC_OOM
je   mount_fail
mov  rbx, rax                                         ; rbx = new root vnode idx

; Set type = VNODE_TYPE_DIR and parent_idx = VNODE_IDX_NONE
mov  rdi, rbx
call vnode_slot                                       ; rax = &vnode[root]
mov  rcx, 2                                           ; VNODE_TYPE_DIR
mov  [rax + 0], rcx                                   ; writes u64 (safe: slot was zeroed by vnode_free)
mov  rcx, 0xFFFF                                      ; VNODE_IDX_NONE
mov  [rax + 8], rcx                                   ; parent_idx = detached
```

The u64-width writes are safe because `vnode_free` zeros the whole
64-byte slot before returning it to the free pool
(`vnode_pool.pdx` `vnode_free`). The witness explicitly frees a slot
before calling `mount()` to guarantee this precondition (§6.1).

`ops_ptr` (offset +24) is deliberately left at zero. R16.M2 wires
it to `_tmpfs_vops` for the root mount's root vnode; until then,
any `vops_*` call on this vnode returns
`VOPS_ERR_NOT_SUPPORTED` per r16-m1-003-vops.md §2.2 (safe
failure).

### 5.6 Pack the entry and store it

Build the u64 entry value in `rax` by shifting/OR-ing the fields:

```asm
; entry_u64 = mp_idx | (root_idx << 16) | (backend << 32) | (flags << 40)

and  r12, 0xFFFF                                      ; sanitize mp_idx (u16)
and  rbx, 0xFFFF                                      ; sanitize root_idx (u16)
and  r14, 0xFF                                        ; sanitize backend (u8)

mov  rax, rbx
shl  rax, 16
or   rax, r12                                         ; rax = mp | (root << 16)

mov  rcx, r14
shl  rcx, 32
or   rax, rcx                                         ; add backend at bits 32..40

; Compute flags: MOUNT_FLAG_VALID always; MOUNT_FLAG_ROOT if slot 0
mov  rcx, 1                                           ; MOUNT_FLAG_VALID
cmp  r13, 0
jne  no_root_flag
or   rcx, 2                                           ; MOUNT_FLAG_ROOT
no_root_flag:
shl  rcx, 40
or   rax, rcx                                         ; add flags at bits 40..48

; Store the packed entry
lea  r9, [rip + _mount_table]
mov  [r9 + r13*8], rax                                ; SIB scale-8, proven encoder pattern

; Return slot idx
mov  rax, r13
jmp  mount_done
```

The `mov [r9 + r13*8], rax` shape is proven by
`vnode_pool.pdx` `vnode_alloc` (`mov [r8 + rcx*8], r9`) — no
encoder gap.

### 5.7 Epilogue

```asm
mount_fail:
    mov  rax, 0xFFFF                                  ; MOUNT_IDX_NONE

mount_done:
    pop  r15; pop r14; pop r13; pop r12; pop rbx
    ret
```

## 6. Test canary — R16 MOUNT TABLE OK

The witness runs in `kernel_main` immediately after the path_resolve
witness (§5 of r16-m1-004-path-resolver.md) so it inherits an
initialized vnode pool with slot metadata written for the path
witness's tree. Four sub-tests, one marker.

### 6.1 Preamble — free a vnode slot for `mount()` to allocate

**Problem.** The vnode_pool witness (r16-m1-002-vnode-pool.md §5)
fills the pool to OOM as its final sub-test. All 256 slots are
allocated at the point our witness runs. `mount()` calls
`vnode_alloc`, which would return the OOM sentinel `0xFFFF` and
force `mount()` to fail.

**Fix.** Before sub-test B (`mount("/", TMPFS)`), free a slot to
make room:

```asm
mov  rdi, 100                                         ; arbitrary interior slot
call vnode_free                                       ; zeros the slot + clears bitmap bit
```

Slot 100 is picked out of the "path witness overwrote 1, 2, 3
directly" range, and out of the "vnode_pool fill_loop allocated
sequentially" range beginning at 4. It has never been touched by
any prior witness, so its BSS bytes are the zero from load-time.
`vnode_free` re-zeroes the slot as a redundant safety measure.

After the free, `vnode_alloc` will return slot 100 (the low-first
bitmap scan finds it before scanning past 100). `mount()` uses that
slot for the fs's root vnode. The u64-width writes in `mount()` §5.5
are safe against zero-initialized slot memory.

**Why not restructure the vnode_pool witness to leave headroom?**
Doing so weakens the OOM discipline in that witness — the whole
point of its fill_loop is to prove the OOM sentinel behavior. The
one-line explicit-free workaround is strictly local to the mount
witness and does not touch any other witness's contract.

### 6.2 Sub-test A — `_mount_table[0]` initially zero

Runs before the free-slot preamble. Reads `_mount_table[0]` as a
u64 and asserts equality with 0.

```asm
lea  rax, [rip + _mount_table]
mov  rax, [rax]
cmp  rax, 0
jne  mount_witness_fail
```

Proves: BSS zero-init reaches the mount table; no prior witness has
touched it; slot 0 starts empty (backend byte at bits 32..40 is 0 →
`MOUNT_BACKEND_NONE`).

### 6.3 Sub-test B — `mount("/", TMPFS)` returns 0

After the preamble frees slot 100:

```asm
lea  rdi, [rip + witness_path_slash]                  ; "/" (reused from #573)
mov  rsi, 1                                           ; MOUNT_BACKEND_TMPFS
call mount
cmp  rax, 0                                           ; MOUNT_ROOT_SLOT
jne  mount_witness_fail
```

Proves:
- `mount()` finds slot 0 as the first empty slot.
- The bootstrap branch triggers (does not call `path_resolve`).
- `vnode_alloc` succeeds (slot 100 is returned from the preamble's
  free).
- The entry is packed correctly and stored at `_mount_table[0]`.
- The return value is the slot idx (0), not the vnode idx (100).

### 6.4 Sub-test C — `mount_root_vnode()` returns the mounted fs's root

```asm
call mount_root_vnode
mov  r12, rax                                         ; save for sub-test D
cmp  rax, 0
je   mount_witness_fail                               ; must be a real vnode idx
cmp  rax, 0xFFFF
je   mount_witness_fail                               ; not the OOM sentinel

; Verify it equals _mount_table[0].root_idx directly
lea  rax, [rip + _mount_table]
mov  rax, [rax]
shr  rax, 16
and  rax, 0xFFFF
cmp  rax, r12
jne  mount_witness_fail
```

Proves:
- `mount_root_vnode` reads the correct field (bits 16..32 of entry 0).
- The value matches what `mount()` installed (the vnode idx returned
  by `vnode_alloc` — expected to be 100, but the test does not pin
  the specific idx).

### 6.5 Sub-test D — `mount_lookup(root_idx)` returns root_idx (self-loop)

```asm
mov  rdi, r12                                         ; root vnode idx
call mount_lookup
cmp  rax, r12
jne  mount_witness_fail
```

Proves:
- `mount_lookup` iterates the mount table without crashing.
- The self-loop rule (input equals an entry's `root_idx` → return
  the same idx) fires for the root fs's root vnode.
- `mount_lookup` is idempotent for anyone starting at the root.

### 6.6 Marker

On all four sub-tests green:

```
R16 MOUNT TABLE OK
```

Fingerprint added to:
- `tests/r14b/expected-boot-r14b-loader.txt` (immediately after
  `R16 PATH RESOLVE OK`)
- `tests/r15/expected-boot-r15-ring3.txt` (same position)
- `tests/r15/expected-boot-r15-process.txt` (same position)

## 7. Alternatives considered (rejected)

### 7.1 Struct-of-arrays instead of packed u64

**Proposal.** Split the table into parallel arrays: `_mount_mp[8]:
[u16; 8]`, `_mount_root[8]: [u16; 8]`, `_mount_backend[8]: [u8; 8]`,
`_mount_flags[8]: [u8; 8]`. Field access is a direct narrow load
at the appropriate array's base+idx.

**Rejected.** Four separate BSS symbols instead of one; four
cache lines instead of one for a cold table walk; encoder-wise, the
narrow moves with a `[base + idx*scale + disp]` shape aren't verified
(r16-m1-004-path-resolver.md §6.1 flags this exact gap). The packed
u64 sidesteps every one of those concerns with 2-3 extra
shift/mask instructions in `mount()`'s entry construction — a cost
paid once per `mount()` call, which is O(mount count) = 1 at R16.

### 7.2 8-slot mount table sized to 128 B (2 cache lines) for symmetry with vnode

**Proposal.** Size each entry to 16 B for R17 growth room (per-mount
refcount, backend_ptr, mount_time_ns).

**Rejected.** The `_reserved` u16 slot at bits [48, 64) already
holds R17's most-likely growth (per-mount refcount). Doubling the
entry size doubles table memory (128 B) and would push a scan across
two cache lines. R17 or R18 may bump entry size to 16 B if a
concrete field lands (backend_ptr for TTY, mount_time_ns for
`stat`), but at R16.M1 there is no consumer.

### 7.3 `_root_mount_slot` as a runtime variable (not pinned to 0)

**Proposal.** Store a mutable `_root_mount_slot: u64` in BSS that
`mount_root_vnode` indirects through. Allows pivot-root by updating
the variable.

**Rejected.** Pivot-root is an R18+ feature. At R16.M1 the pinned
convention buys a single-instruction faster `mount_root_vnode` and
a compile-time invariant (slot 0 is root, forever) that we do not
need to weaken until pivot-root has a concrete consumer.

### 7.4 `mount_lookup` returns 0 for "not a mountpoint"

**Proposal.** Distinguish "not a mountpoint" (return 0) from "is a
mountpoint" (return the traversed idx). Callers gate on the return
value.

**Rejected.** The identity-fallthrough (return input unchanged) is
strictly cheaper for the caller: `path_resolve` at R17 will call
`mount_lookup` at every regular-component step. With identity
fallthrough, `path_resolve` unconditionally assigns
`cur = mount_lookup(cur)` — one instruction more per component.
With the 0-fail alternative, `path_resolve` needs a `cmp/je` before
the assignment. Total instruction count is worse for the 0-fail
alternative, and the semantic is uglier (a caller has to know that
"I'm at a non-mountpoint" and "I'm at a mountpoint whose target is
vnode 0" don't collide — which requires understanding the vnode-0
sentinel discipline).

### 7.5 `mount()` takes `root_vnode_idx` as a third argument

**Proposal.** `mount(path, backend_type, root_vnode_idx) -> u16`.
Caller allocates the vnode and passes it in. `mount()` never calls
`vnode_alloc`.

**Rejected.** Splits the mount responsibility awkwardly — the
caller needs to know the backend's discipline for what to write into
the vnode before handing it off. Encapsulating the allocation + type
initialization inside `mount()` keeps the abstraction consistent
across backends: any caller passes a path and a type, and the mount
table records the outcome.

The exception: the R16.M1 witness has the vnode pool exhausted at
its runtime. That is solved locally by the free-slot preamble
(§6.1), not by splitting `mount()`'s API.

### 7.6 Growable mount table via a pointer to a heap slab

**Proposal.** `_mount_table_ptr: u64` points to a slab allocated
via `phys_alloc` on first mount, growing as more mounts arrive.

**Rejected.** No R16 workload approaches 8 mounts. Static [u64; 8]
in BSS is 64 B — negligible. Growth to N > 8 is a freeze-bump event
at R18+ if any workload demands it.

## 8. Invariants

### 8.1 Slot 0 is the root mount (pinned for R16 series)

`_mount_table[0]` is either empty (`backend_type = 0`) or contains
the root filesystem. No submount ever lands at slot 0. Enforced by
the linear-scan-from-0 policy in `mount()` and the `MOUNT_FLAG_ROOT`
bit that only slot 0 receives.

### 8.2 Zero-init sentinel

`_mount_table[i].backend_type == 0` iff slot `i` is empty. Matches
BSS zero-init discipline; no separate "occupied" boolean.

### 8.3 `mount_root_vnode() == 0` iff no root mounted

The u16 idx `0` is reserved as the "invalid vnode" sentinel by
vfs-layout.md §7.2. `mount_root_vnode` returning `0` is safe to
interpret as "no root mounted" (`_mount_table[0].root_vnode_idx == 0`,
which happens only when the entry is empty — a live entry always
has a non-zero root idx from `vnode_alloc`).

### 8.4 `mount_lookup` is total and idempotent

Every input maps to a valid vnode idx (either the input or a
traversed target). Applying `mount_lookup` twice yields the same
result as applying it once. Enforced by the fact that a traversed
target is itself an entry's `root_vnode_idx`, which matches
condition 2 (self-loop) on a second call.

### 8.5 Entry layout is frozen

The five-field packing at the bit ranges pinned in §2 is frozen
for the R16 series. Any change is a **new layout-freeze issue**
that (a) bumps a `MOUNT_LAYOUT_VERSION` constant, (b) updates §2's
table, (c) re-runs the witness against the new offsets.

### 8.6 `mount()` never partially initializes an entry

Either the whole entry is written (success return) or nothing is
written (failure return). Enforced by building the entry u64 in a
register and storing it in one instruction (§5.6). No half-written
state is ever visible.

### 8.7 `mount()` never leaks a vnode on failure

Failure paths that occur *before* `vnode_alloc` (validate,
scan-full, `path_resolve` fail) do not touch the vnode pool.
Failure paths *at* `vnode_alloc` return before the vnode is used.
There is no failure path *after* `vnode_alloc` succeeds — the
entry-packing and store phases cannot fail. If R17 adds a
post-alloc failure mode (e.g., mount options validation), a
`vnode_free` cleanup step must be added.

## 9. Encoder verification

All encoder shapes used by this module are proven in prior R16.M1
issues. No new encoder gaps expected — matches the tactical plan's
"encoder gaps: none" statement for item 5.

| Shape                                       | Proven by                                                                    |
|---------------------------------------------|------------------------------------------------------------------------------|
| `mov rax, [base + idx*8]`                   | `vnode_pool.pdx` `vnode_alloc` (`mov r9, [r8 + rcx*8]`)                       |
| `mov [base + idx*8], reg`                   | `vnode_pool.pdx` `vnode_alloc` (`mov [r8 + rcx*8], r9`)                       |
| `mov rax, [base]` / `mov [base], reg`       | `fd_table.pdx` and every other kernel module                                 |
| `shr reg, imm8` / `shl reg, imm8`           | `vnode_pool.pdx` `vnode_free` (`shr rax, 6`; `shl rax, 6`)                    |
| `and reg, imm32`                            | `vnode_pool.pdx` `vnode_free` (`and rcx, 63`)                                 |
| `or reg, imm8`                              | Standard instruction; no encoder gap                                          |
| `cmp reg, imm8/32` and `je/jne/ja/jb/jae`   | Every kernel module                                                          |
| `push reg` / `pop reg`                      | `path.pdx` `path_resolve` prologue                                            |
| `call rel32` for nested calls               | `path.pdx` `path_resolve` calls `vnode_slot`, `vops_lookup`                   |
| `lea rax, [rip + label]`                    | Every kernel module                                                          |

No narrow-move shapes (`mov_b`, `mov_w`) are used in this module —
the u64-per-entry design deliberately avoids the one gap
(r16-m1-004-path-resolver.md §6.1) that would surface otherwise.

## 10. Growth plan (R16.M2 and beyond)

- **R16.M2 (#580 tmpfs root init).** After the R16.M1 witness lands,
  the R16.M2 root-init sequence calls `mount("/", MOUNT_BACKEND_TMPFS)`
  in production kernel init (not in a witness), then locates the
  root vnode via `mount_root_vnode()` and populates its `ops_ptr`
  slot with `&_tmpfs_vops`. From that moment forward,
  `vops_lookup` / `vops_read` / etc. on the root vnode dispatch into
  the tmpfs backend.
- **R17.M-x (path_resolve cross-mount descent).** After a
  successful `vops_lookup` returns a child vnode, `path_resolve`
  calls `mount_lookup(child_idx)` before assigning `cur = child_idx`.
  If the child is a mountpoint, `cur` becomes the mounted fs's root
  and the next component resolves against that fs. Total addition
  to `path_resolve`: ~4 instructions per regular-component step.
- **R17.M-y (per-mount refcount).** The `_reserved` u16 slot
  becomes an in-mount refcount. `mount_hold(idx)` / `mount_put(idx)`
  primitives land alongside `sys_umount`. A live mount (refcount > 0)
  refuses to umount.
- **R17.M-z (submount).** First real second-mount lands as
  `/dev` (devfs) or `/proc` (procfs). Exercises the submount
  branch of `mount()` (§5.4 `resolve_submount`) that is written but
  not exercised by the R16.M1 witness.
- **R18+ (sys_umount, pivot_root, chroot).** All three require
  weakening the "slot 0 is pinned root" invariant (§8.1) via a
  freeze-bump. `_root_mount_slot` becomes a runtime variable that
  `mount_root_vnode` indirects through.

## 11. Cross-references

- Issue: paideia-os#574
- Milestone: R16.M1 (VFS abstract layer)
- Upstream: #570 (vnode layout freeze — pins `VNODE_TYPE_DIR = 2`,
  `VNODE_PARENT_IDX_OFFSET = +8`, `VNODE_IDX_NONE = 0xFFFF`), #571
  (`vnode_alloc`, `vnode_free`, `vnode_slot`), #572 (`vops_read` etc.
  handle null ops_ptr on the mount root vnode — safe failure until
  R16.M2 wires the backend), #573 (`path_resolve` for submount
  path resolution).
- Downstream consumers: #575 (`vfs_open` — uses `mount_root_vnode()`
  as the start anchor), #580 (R16.M2 tmpfs root init — first
  production `mount()` call), R17 path_resolve extension
  (uses `mount_lookup` for cross-mount descent).
- Sibling freeze docs: `design/kernel/r16-m1-004-path-resolver.md`
  §2.3 (same 5-push prologue discipline for nested calls),
  `design/kernel/r16-m1-003-vops.md` §7.1 (same "layout re-freeze
  is a new issue" discipline).
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 11 item 5 (line 1256) — pins the file location
  (`src/kernel/core/fs/mount.pdx`), the AC ("root vnode is tmpfs"
  — the AC is partially met at R16.M1 by installing the mount
  entry; the "is tmpfs" clause is completed at R16.M2 when
  `_tmpfs_vops` is wired to the root vnode's `ops_ptr` slot).
- Encoder verification: every shape used here is proven in prior
  R16.M1 modules (§9); no paideia-as gap surfaces.

---

## Amended by R17-M0-665

**Change**: mount() now wires the root vnode's ops_ptr (+24) and backend_ptr (+32) directly in the alloc_root block, using backend_ops_table and backend_root_inode dispatch helpers.

**Previous AC status**: The AC ("root vnode is tmpfs") was only *partially* met at R16.M1: the mount entry was installed, but ops_ptr was left at zero and populated by witness pre-wires in R16.M3.

**New status**: The AC is now *fully* met at R16.M1 (mount time). The root vnode is wired with ops_ptr and backend_ptr atomically during mount(), eliminating all witness pre-wires and the R16.M2 deferral.
