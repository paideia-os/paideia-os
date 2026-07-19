---
issue: 580
milestone: R16.M2 (tmpfs — in-memory VFS backend)
subsystem: 12 — tmpfs
topic: tmpfs_init — populate root inode + `/tmp` child (R16-M2-002)
freeze-discipline: strict
  - tmpfs inode layout is frozen by R16-M2-001 (#579) — this issue writes to
    frozen offsets `+0`, `+1`, `+4`, `+144`, `+176`, `+178`, `+180` via the
    exported constants; no numeric offset lives in this module's source.
  - `tmpfs_inode_alloc`'s single-word bitmap contract (bit 0 pre-set, TMPFS_MAX=64)
    is frozen for the entire R16.M2 series; #582 (`tmpfs_create`) calls into
    exactly the same symbol without redefinition.
blocks:
  - "#581 (tmpfs_lookup — walks dentry chain from `first_child` via `next_sibling`; this issue produces the first live chain the lookup traverses: root → /tmp)"
  - "#582 (tmpfs_create — allocates additional inodes via `tmpfs_inode_alloc` and links into the parent's `first_child` / `next_sibling` chain established here)"
  - "R17.M-x (mount_root_vnode ↔ tmpfs_inode binding — a later issue wires the root vnode's `backend_ptr` (+32) to the root inode idx returned by this init)"
touching:
  - src/kernel/core/fs/tmpfs/inode.pdx          (append `tmpfs_inode_alloc` leaf; ~15 LOC delta)
  - src/kernel/core/fs/tmpfs/init.pdx           (new module — `tmpfs_init`; ~55 LOC)
  - src/kernel/boot/kernel_main.pdx             (witness block ~55 LOC)
  - tools/boot_stub.S                           (2 message strings)
  - tests/r14b/expected-boot-r14b-loader.txt    (marker: "R16 TMPFS INIT OK")
  - tests/r15/expected-boot-r15-ring3.txt       (marker)
  - tests/r15/expected-boot-r15-process.txt     (marker)
  - design/kernel/r16-m2-002-tmpfs-init.md      (this doc)
related:
  - design/kernel/r16-m2-001-tmpfs-inode-pool.md (#579 — frozen inode layout;
    §1 deferred the allocator to #582; this issue promotes it forward to #580,
    documented in §2.1 below)
  - src/kernel/core/fs/vnode_pool.pdx           (#571 — allocator template; single-word
    tmpfs_inode_alloc is the 64-slot degenerate of that 256-slot four-word scan)
  - src/kernel/core/fs/mount.pdx                (#574 — mount() has already allocated
    the root **vnode**; tmpfs_init allocates the root **inode**; the two are wired
    together in a subsequent R16.M2 issue)
  - design/milestones/r14b-tactical-plan.md    §Subsystem 12 item 2 — tmpfs root init contract
---

# R16-M2-002 — `tmpfs_init` (populate root + `/tmp`, #580)

## 1. Scope

Ship the boot-time initializer that populates the tmpfs in-memory tree with
its two canonical entries — the root directory inode and the `/tmp`
child directory inode — so downstream code that walks the tmpfs dentry
chain can find both.

Concretely:

- Allocate **inode 1** (via the single-word bitmap scan established by
  #579) and initialize it as the tmpfs **root directory**: `type = DIR`,
  `flags = VALID`, `link_count = 1`, empty `name` (already zero from
  `.bss`), `parent_idx = 0xFFFF` (no parent — root is detached from any
  parent-fs perspective), `next_sibling = 0xFFFF` (root has no
  siblings), `first_child = <tmp_idx>`.
- Allocate **inode 2** and initialize it as `/tmp`: `type = DIR`,
  `flags = VALID`, `link_count = 1`, `name = "tmp\0"` (three ASCII
  bytes + NUL, rest of the 32-byte field zero from `.bss`),
  `parent_idx = 1` (root), `next_sibling = 0xFFFF` (only child of
  root at boot), `first_child = 0xFFFF` (empty directory).
- Return the root inode idx (u64 in low bits of `rax` — expected to be
  `TMPFS_INODE_IDX_ROOT = 1` by the bitmap-first-scan invariant, but the
  return value is what callers should read, not the constant).

Also ship the small leaf primitive `tmpfs_inode_alloc` that this
initializer needs — its first caller — with the schedule adjustment
documented in §2.1.

Out of scope (deliberately deferred):

- **No vnode ↔ inode binding.** The root vnode allocated by `mount()`
  at #574 is a distinct object from the root **inode** allocated
  here. Wiring the vnode's `backend_ptr` field (frozen at +32 by #570)
  to point at the root inode is done in a follow-on issue (the tmpfs
  vops registration step) — this initializer does not touch any
  vnode's storage.
- **No page-list allocation.** Both root and `/tmp` are directories;
  their `page_ptrs[16]` slab stays zero (directories have no
  page-backed content). `tmpfs_write` (#583) is the first module that
  allocates into that slab.
- **No dentry-chain search primitives.** `tmpfs_lookup` (#581) reads
  the chain this issue builds; the walker is that issue's
  responsibility, not this one's.
- **No `tmpfs_inode_free`.** Neither of the two initial inodes is ever
  freed at boot; the `free` leaf lands at #582 alongside
  `tmpfs_create`, where the first legitimate caller for freeing (an
  allocation failure after `bts_q` succeeded) appears.
- **No re-entrancy guard.** `tmpfs_init` is called exactly once at
  boot, before any concurrent access is possible; no re-entrancy check
  is written.

## 2. `tmpfs_inode_alloc` — single-word bitmap-first leaf

### 2.1 Schedule shift from #582 → #580

The design doc for #579 (r16-m2-001-tmpfs-inode-pool.md §1) originally
scheduled `tmpfs_inode_alloc` and `tmpfs_inode_free` for #582
(`tmpfs_create`). At the time this was correct: #579 had no live
consumer for either primitive, and shipping unused code violates the
"no stub / placeholder" discipline in the milestone contract.

#580 is now the first live consumer of `tmpfs_inode_alloc`
(`tmpfs_init` calls it twice — for the root inode and for `/tmp`).
Ship the allocator now in the same module that owns the pool + bitmap
storage (`src/kernel/core/fs/tmpfs/inode.pdx`), mirroring the
"storage + alloc + slot" triple that `vnode_pool.pdx` codifies for
the vnode side.

`tmpfs_inode_free` stays at #582 — still no caller. `tmpfs_init` has
no failure path after its second `bts_q` succeeds (see §3.5), so an
alloc-then-free rollback is not needed at #580.

### 2.2 Contract

```
tmpfs_inode_alloc : () -> u64 !{mem} @{}
  → rax = idx in [1, 63]  on success (u16 semantics; upper bits zero)
  → rax = 0xFFFF (TMPFS_INODE_ALLOC_OOM)  on exhaustion
```

Leaf function — no callee-save prologue, no nested call. Trashes
`rax`, `rcx`, `rdx`, `r8`, `r9`, `r10` (all caller-saved per SysV
AMD64). Registers `rdi`, `rsi` are not read (nullary).

### 2.3 Algorithm

Because `TMPFS_MAX = 64` fits in one 64-bit word, the four-word scan
loop from `vnode_alloc` (r16-m1-002 §5) collapses to a single-word
inline body:

```asm
tmpfs_inode_alloc:
    lea  r8, [rip + _tmpfs_inode_bitmap]
    mov  r9, [r8]                       ; r9 = bitmap word
    mov  r10, r9
    xor  r10, 0xFFFFFFFFFFFFFFFF        ; r10 = ~word (free bits = 1); NOT unavailable
    cmp  r10, 0                         ; TEST unavailable — cmp/je in its place
    je   tmpfs_inode_alloc_oom          ; word fully allocated

    bsf_q rdx, r10                      ; rdx = index of first free bit
    cmp   rdx, 64                       ; TMPFS_MAX — belt-and-braces
    jae   tmpfs_inode_alloc_oom

    bts_q r9, rdx                       ; set bit rdx in r9 (register form)
    mov   [r8], r9                      ; store word back
    mov   rax, rdx                      ; return idx
    ret

tmpfs_inode_alloc_oom:
    mov  rax, 0xFFFF                    ; TMPFS_INODE_ALLOC_OOM
    ret
```

Every mnemonic in this body is proven by `vnode_pool.pdx`
(`bsf_q rdx, r10`, `bts_q r9, rdx`, `xor r9, 0xFFF...`, `cmp r10, 0`,
`je`, `mov [r8], r9`, `mov rax, imm32`) — no new encoder shape.

### 2.4 Slot-0 sentinel preservation

The bitmap's bit 0 is pre-set to 1 by the static initializer
`_tmpfs_inode_bitmap : [u64; 1] = [1]` (from #579 §5). `bsf_q` on
`~word` therefore never returns bit 0 — the "invalid inode" sentinel
is preserved by construction, matching the discipline `vnode_alloc`
uses for slot 0.

## 3. `tmpfs_init` — root + `/tmp` populator

### 3.1 Contract

```
tmpfs_init : () -> u64 !{mem} @{}
  → rax = root inode idx (u16 in low bits) on success
  → rax = 0xFFFF (TMPFS_INODE_ALLOC_OOM) if either alloc failed
```

Nullary. Effects `{mem}` because it writes into `_tmpfs_inode_pool`
and `_tmpfs_inode_bitmap`. Not a leaf — makes four nested calls
(`tmpfs_inode_alloc` × 2, `tmpfs_inode_slot` × 2).

The return value is what the caller (kernel_main, later a vnode↔inode
binder) uses to reference the root inode; do not read
`TMPFS_INODE_IDX_ROOT` (= 1) directly at call sites, because a future
change to the initialization order (e.g., pre-allocating a reserved
inode 1 for a metadata block) would shift the root elsewhere.

### 3.2 Register discipline

Three-push callee-save prologue lands `rsp mod 16 == 0` at every
nested call site (three pushes × 8 = 24 bytes, plus 8-byte retaddr
= 32 = 0 mod 16 — SysV AMD64 requirement at CALL entry).

| Reg | Role                                                             |
|-----|------------------------------------------------------------------|
| rbx | `root_idx` — returned by first `tmpfs_inode_alloc`; carried across the second alloc and both inode-slot init phases. |
| r12 | `tmp_idx` — returned by second `tmpfs_inode_alloc`; carried across both init phases. |
| r13 | inode-base scratch — reloaded per inode via `tmpfs_inode_slot`. Callee-save because `tmpfs_inode_slot` (used inside the second init phase) does not touch r13. Documented anyway for consistency with mount.pdx's five-push discipline. |

Two push slots suffice semantically (rbx + r12), but two pushes give
`rsp mod 16 == 8` at nested call sites, violating SysV. Three pushes
solve the alignment; the extra `r13` push costs 8 bytes of stack and
keeps the alignment invariant readable at inspection.

### 3.3 Prologue + first allocation (root)

```asm
tmpfs_init:
    push rbx
    push r12
    push r13                           ; rsp%16 = 0

    call tmpfs_inode_alloc              ; rax = root_idx (expected 1)
    cmp  rax, 0xFFFF
    je   tmpfs_init_fail
    mov  rbx, rax                       ; rbx = root_idx
```

By the bitmap-first-scan invariant on a fresh bitmap with only bit 0
pre-set, `rbx` will always be 1. The test canary (§5.1) does not
pin this value — it only checks non-zero — so a future re-order of
the allocation sequence does not require the canary to be rewritten.

### 3.4 Second allocation (`/tmp`)

```asm
    call tmpfs_inode_alloc              ; rax = tmp_idx (expected 2)
    cmp  rax, 0xFFFF
    je   tmpfs_init_fail
    mov  r12, rax                       ; r12 = tmp_idx
```

### 3.5 Root inode initialization

Field writes go through the proven narrow-store idioms
(`mov_b [mem], reg` and `mov_w [mem], reg`) — one store per field,
one field per line. Every offset is a `.pdx` immediate that resolves
via the frozen constants exported by `inode.pdx` (§4 of #579's doc).

```asm
    mov  rdi, rbx
    call tmpfs_inode_slot               ; rax = &_tmpfs_inode_pool[root_idx]
    mov  r13, rax                       ; r13 = &root_inode

    ; type = VNODE_TYPE_DIR (2) at +0 (u8)
    mov  rcx, 2
    mov_b [r13 + 0], rcx

    ; flags = TMPFS_INODE_FLAG_VALID (1) at +1 (u8)
    mov  rcx, 1
    mov_b [r13 + 1], rcx

    ; refcount (+2, u16) stays 0 — .bss zero-init.
    ; A later issue wires vnode.backend_ptr → root inode and bumps this to 1.

    ; link_count = 1 at +4 (u16) — live inode has one dentry reference
    mov  rcx, 1
    mov_w [r13 + 4], rcx

    ; size (+8), page_ptrs[16] (+16..+144), name[32] (+144..+176) stay 0.

    ; parent_idx = 0xFFFF at +176 (u16) — root has no parent
    mov  rcx, 0xFFFF
    mov_w [r13 + 176], rcx

    ; next_sibling = 0xFFFF at +178 (u16) — root has no siblings
    mov_w [r13 + 178], rcx             ; rcx still 0xFFFF

    ; first_child = tmp_idx at +180 (u16)
    mov_w [r13 + 180], r12
```

Every field on the third cache line (+128..+192) except the four
u16s just written stays zero: `name[32]` is untouched (root's name
is the empty string), `_pad_hot_tail` (+182) is untouched. The
fourth cache line (+192..+256) is untouched — reserved bytes stay at
`.bss` zero, matching the R16.M3 growth plan (r16-m2-001 §10).

### 3.6 `/tmp` inode initialization

```asm
    mov  rdi, r12
    call tmpfs_inode_slot               ; rax = &_tmpfs_inode_pool[tmp_idx]
    mov  r13, rax                       ; r13 = &tmp_inode

    ; type = VNODE_TYPE_DIR at +0
    mov  rcx, 2
    mov_b [r13 + 0], rcx

    ; flags = TMPFS_INODE_FLAG_VALID at +1
    mov  rcx, 1
    mov_b [r13 + 1], rcx

    ; link_count = 1 at +4
    mov_w [r13 + 4], rcx               ; rcx still 1

    ; name = "tmp\0" at +144 (three ASCII bytes; NUL from .bss)
    mov  rcx, 0x74                     ; 't'
    mov_b [r13 + 144], rcx
    mov  rcx, 0x6D                     ; 'm'
    mov_b [r13 + 145], rcx
    mov  rcx, 0x70                     ; 'p'
    mov_b [r13 + 146], rcx
    ; name[3..32] stay 0 — .bss zero-init provides the NUL terminator
    ; and the 28 pad bytes for the 32-byte name field.

    ; parent_idx = root_idx (= 1) at +176 (u16)
    mov_w [r13 + 176], rbx

    ; next_sibling = 0xFFFF at +178 — /tmp is the only child at boot
    mov  rcx, 0xFFFF
    mov_w [r13 + 178], rcx

    ; first_child = 0xFFFF at +180 — /tmp is empty
    mov_w [r13 + 180], rcx
```

### 3.7 Epilogue

```asm
    mov  rax, rbx                       ; return root_idx
    jmp  tmpfs_init_done

tmpfs_init_fail:
    mov  rax, 0xFFFF                    ; TMPFS_INODE_ALLOC_OOM

tmpfs_init_done:
    pop  r13
    pop  r12
    pop  rbx
    ret
```

The failure path is unreachable at boot (the bitmap is fresh; two
allocations always succeed), but wiring the sentinel through keeps
the contract uniform for future callers that might reset tmpfs at
runtime (a `sys_umount` on tmpfs, R18+).

## 4. Immediate-encoding hygiene

Every immediate used by `tmpfs_init` fits in the 32-bit sign-extended
`mov r/m64, imm32` form — the smallest, most portable encoding:

| Immediate     | Fits imm8 sign-ext? | Fits imm32 sign-ext? | Notes                                    |
|---------------|---------------------|-----------------------|------------------------------------------|
| `0` (via `xor rcx, rcx`) | n/a       | n/a                   | Preferred idiom in this codebase.        |
| `1`, `2`      | yes                 | yes                   | Type / flags / link_count values.        |
| `0x74`, `0x6D`, `0x70` | yes    | yes                   | ASCII 't', 'm', 'p'.                     |
| `0xFFFF`      | no                  | yes (0x0000FFFF)      | Parent / sibling / child sentinel; positive imm32, zero-extends cleanly. Proven by `mount.pdx:203 mov rax, 0xFFFF`. |
| `0xFFFFFFFFFFFFFFFF` | yes (as -1) | yes (as -1)           | Used inside `tmpfs_inode_alloc` for the `NOT` idiom; proven by `vnode_pool.pdx:72 xor r10, 0xFFFFFFFFFFFFFFFF`. |

No `movabs` (imm64) is required. This avoids any dependency on the
64-bit-immediate encoding, keeping the initializer's encoder shape
identical to `mount.pdx` and `vnode_pool.pdx` — modules that have
already been proven end-to-end through the loader smoke.

## 5. Test canary — R16 TMPFS INIT OK

Runs in `kernel_main` immediately after the inode-pool witness
(the `R16 TMPFS INODE POOL OK` marker at kernel_main line ~2300).
Placement rationale: `tmpfs_init` reads and writes into the storage
that the pool witness has just verified addressable; any failure
here localizes to the initializer rather than to the storage substrate.

Four sub-tests, one marker.

### 5.1 Sub-test A — `tmpfs_init` returns a non-zero root idx

```asm
    call tmpfs_init
    mov  r12, rax                       ; save root_idx for sub-tests B-D
    cmp  rax, 0
    je   tmpfs_init_witness_fail
    cmp  rax, 0xFFFF                    ; alloc OOM sentinel
    je   tmpfs_init_witness_fail
```

Proves: both allocations succeeded and `tmpfs_init` propagated the
root idx up to `rax` (as opposed to the failure sentinel). Uses
`r12` (callee-save at the enclosing `kernel_main` frame — reserved
for witness scratch throughout kernel_main by prior witness code
convention).

### 5.2 Sub-test B — root inode `type == DIR`, `first_child != 0`

```asm
    mov  rdi, r12                       ; root_idx
    call tmpfs_inode_slot               ; rax = &root_inode
    mov  r13, rax

    ; type byte at +0 must be VNODE_TYPE_DIR = 2
    mov  rcx, [r13 + 0]                 ; load u64 at +0
    and  rcx, 0xFF                      ; extract type byte
    cmp  rcx, 2
    jne  tmpfs_init_witness_fail

    ; first_child at +180 (u16) must be non-zero (a real /tmp idx)
    mov  rcx, [r13 + 176]               ; load u64 at +176 covering
                                        ; parent_idx / next_sib / first_child / pad
    shr  rcx, 32                        ; first_child at bits [32, 48)
    and  rcx, 0xFFFF
    cmp  rcx, 0
    je   tmpfs_init_witness_fail
    cmp  rcx, 0xFFFF
    je   tmpfs_init_witness_fail        ; must not be the empty sentinel
    mov  r14, rcx                       ; r14 = tmp_idx for sub-tests C-D
```

Proves: (a) root inode's type byte was written correctly at the
frozen +0 offset; (b) root inode's `first_child` was populated with
a real inode index (not left at zero from `.bss` and not left at the
0xFFFF empty-directory sentinel).

The load-u64-then-shift-then-mask pattern for extracting the u16 at
offset +180 mirrors the `mount_root_vnode` idiom in mount.pdx (§7 of
r16-m1-005): a single u64 load + one shift + one mask is cheaper
than a `mov_w rcx, [r13 + 180]` narrow load AND does not depend on
`mov_w reg, [mem+disp8]` being available at every displacement value.

### 5.3 Sub-test C — `/tmp` inode `type == DIR`, `parent_idx == root_idx`

```asm
    mov  rdi, r14                       ; tmp_idx
    call tmpfs_inode_slot               ; rax = &tmp_inode
    mov  r13, rax

    ; type byte at +0 must be VNODE_TYPE_DIR = 2
    mov  rcx, [r13 + 0]
    and  rcx, 0xFF
    cmp  rcx, 2
    jne  tmpfs_init_witness_fail

    ; parent_idx at +176 (u16) must equal root_idx (r12)
    mov  rcx, [r13 + 176]
    and  rcx, 0xFFFF                    ; extract parent_idx (bits [0, 16))
    cmp  rcx, r12
    jne  tmpfs_init_witness_fail
```

Proves: (a) `/tmp` inode was initialized as a directory; (b) the
parent-back-pointer wires up to the root — the two-node chain
(root → /tmp) is intact.

### 5.4 Sub-test D — `/tmp` `name` field == `"tmp\0"`

```asm
    ; name[0..8] as u64: byte layout expected is
    ;   { 0x74('t'), 0x6D('m'), 0x70('p'), 0x00, 0x00, 0x00, 0x00, 0x00 }
    ;   = little-endian u64 0x0000000000706D74
    mov  rcx, [r13 + 144]               ; load u64 at name[0..8]
    mov  rdx, 0x706D74                  ; expected 'tmp\0' + zero pad
    cmp  rcx, rdx
    jne  tmpfs_init_witness_fail
```

Proves: (a) the three ASCII bytes were written at the correct
offsets; (b) byte 3 (the NUL terminator) is zero; (c) bytes 4..7
(part of the 28-byte pad region) are zero as expected from `.bss`
zero-init.

A stricter test would compare all 32 name bytes to a template; the
8-byte compare is sufficient because the write only touched bytes
0..2 and `.bss` zero-init supplies the remainder.

### 5.5 Marker

On all four sub-tests green:

```
R16 TMPFS INIT OK
```

Fingerprint added to:

- `tests/r14b/expected-boot-r14b-loader.txt` — the line immediately
  following `R16 TMPFS INODE POOL OK`.
- `tests/r15/expected-boot-r15-ring3.txt` — same position.
- `tests/r15/expected-boot-r15-process.txt` — same position.

The witness failure message is `R16 TMPFS INIT FAIL`; both strings
land in `tools/boot_stub.S` next to the `tmpfs_inode_pool_*_msg`
pair (line ~499).

## 6. Alternatives considered (rejected)

### 6.1 Hard-code `root_idx = 1` and `tmp_idx = 2`

**Proposal.** Skip `tmpfs_inode_alloc` calls; write `1` and `2`
directly to the bitmap in one store (`mov [r8], 0b111`) and use
literal `1` and `2` as inode indices throughout.

**Rejected.** Splits the allocator invariant across two modules: the
"slot 0 sentinel + bitmap-first scan" contract lives in
`inode.pdx`, but a hard-coded initializer would encode "the first
two allocations must be 1 and 2" as an implicit invariant that a
future re-order of `_tmpfs_inode_bitmap`'s pre-set bits would
silently break. Calling the allocator makes the initializer robust
against any bitmap-side change and validates the alloc primitive on
the very first live use.

### 6.2 Batch the root/`/tmp` inode writes as u64 stores

**Proposal.** Pack (type | flags << 8 | ... | link_count << 32) into
a single u64 register value, use one `mov [r13+0], rcx` to write
bytes 0..7 of each inode. Same for the `parent | next_sib << 16 |
first_child << 32` fields at +176.

**Rejected — semantic clarity.** The narrow-store shape (one field,
one store) makes the initializer readable as a field-by-field
description that matches the frozen layout §2 of #579 line by line.
A u64-packing shape asks the reader to reverse a bit-shift chain to
see which byte is which field. The two extra bytes of encoded
instruction (5 stores × ~4 B vs 1 store × ~5 B) are negligible on a
boot-once path.

Also: the batched shape re-introduces the imm32-sign-extend hazard
(`link_count << 32` requires an imm64 or a runtime shift+or chain).
The narrow-store shape has no imm32 pitfalls.

### 6.3 Move `tmpfs_inode_alloc` into `init.pdx` instead of `inode.pdx`

**Proposal.** Keep #579's `inode.pdx` frozen exactly as landed;
co-locate the new allocator with its first caller.

**Rejected.** Breaks the "one module owns the pool + bitmap + alloc
+ slot" quadruple established by `vnode_pool.pdx`. #582
(`tmpfs_create`) would then call a symbol defined in `init.pdx`,
which is architecturally reversed (creation is a lower-level
primitive than one-shot boot init). Ship the allocator in
`inode.pdx` and document the schedule shift explicitly (§2.1).

### 6.4 Skip `/tmp` entirely at R16.M2 — just init the root

**Proposal.** Populate root only. Defer `/tmp` to R17 when the
shell demo needs a scratch directory.

**Rejected.** The acceptance criterion for issue #580 is
"after init, `/tmp` resolves" — the whole point of this issue is
that a `path_resolve("/tmp")` call finds a live inode. Skipping the
`/tmp` allocation would defer that guarantee and leave the R16.M2
integration checkpoint (`R16 TMPFS INIT OK`) waiting on a
downstream issue for its acceptance test.

### 6.5 Set root's `refcount` to 1 in this initializer

**Proposal.** Bump `refcount` at +2 to `1` to represent the vnode
that will point at this inode (the mount's root vnode).

**Rejected for R16.M2.** The vnode ↔ inode binding is not wired at
#580 (see §1 out-of-scope). Setting `refcount = 1` here would create
a "the inode believes it has a vnode reference before the vnode
actually references it" window. Better: leave `refcount = 0` and
have the binder issue bump it in the same transaction that writes
`backend_ptr`. Same discipline that `mount()` uses for its allocated
root vnode's `ops_ptr` (deliberately left null; wired later).

### 6.6 Emit a debug print of the two allocated idx values

**Proposal.** `uart_putn(root_idx); uart_putn(tmp_idx);` before the
marker for visibility into which slots were used.

**Rejected.** The boot smoke matches expected output byte-identically
(the 5-mode discipline). Any variable output (idx values) would
break the fingerprint match. The witness's binary green/fail marker
is the correct emission shape.

## 7. Invariants

### 7.1 First two allocations succeed

At boot the bitmap is fresh (bit 0 pre-set; all others clear). Two
sequential `tmpfs_inode_alloc` calls therefore return 1 and 2. No
caller anywhere else may consume tmpfs inode slots before
`tmpfs_init` runs — this is enforced by the boot ordering in
kernel_main (§5 positions the witness immediately after the pool
witness, before any hardware / runtime bringup).

### 7.2 Root's `parent_idx == 0xFFFF`

The tmpfs root has no tmpfs parent. Path-resolver code that reaches
root via `..` walking must consult the **vnode** parent chain (which
threads through the mount table for cross-fs `..` per r16-m1-004
§6.3), not the tmpfs `parent_idx` field. The sentinel `0xFFFF`
guarantees a walker that mistakenly follows tmpfs `parent_idx` from
root gets an obvious invalid-index signal.

### 7.3 `/tmp` is root's only child at boot

`root.first_child == tmp_idx` and `tmp.next_sibling == 0xFFFF`. Any
future `mkdir /foo` at runtime inserts `/foo` at the head of the
sibling chain (`foo.next_sibling = root.first_child; root.first_child
= foo_idx`), an O(1) prepend that `tmpfs_create` (#582) will
implement.

### 7.4 Inode 0 is never allocated

The bitmap's bit 0 is pre-set by #579's static initializer and no
code in this module clears it. Sub-test A implicitly checks this via
`cmp rax, 0` on the returned root idx (a slot-0 return would fail
the canary immediately).

### 7.5 Return value must be trusted over `TMPFS_INODE_IDX_ROOT`

Callers of `tmpfs_init` (kernel_main's later binder, R17's `sys_stat`
paths, etc.) must save the returned `rax` and use it as the root
handle. Direct reads of the constant `TMPFS_INODE_IDX_ROOT = 1`
elsewhere are a source-of-truth violation and will diverge from
reality if a future issue re-orders boot allocations.

### 7.6 Idempotence is not guaranteed

`tmpfs_init` is not idempotent — a second call would allocate two
more inodes (slots 3 and 4) and rewrite root's `first_child` to
point at the newer copy, orphaning the original tree. The kernel is
responsible for calling this exactly once. R18+ `sys_umount(TMPFS)`
+ `sys_mount(TMPFS)` will introduce a `tmpfs_reset` primitive that
zeroes the bitmap and pool before a second init; that is a separate
freeze issue.

## 8. Encoder verification

All mnemonic shapes used by this issue's code are proven in prior
R16 or R16.M1 modules. No new encoder work is anticipated.

| Shape                              | Proven by                                                                 |
|------------------------------------|---------------------------------------------------------------------------|
| `bsf_q r64, r64`                   | `vnode_pool.pdx:76` (`bsf_q rdx, r10`)                                    |
| `bts_q r64, r64`                   | `vnode_pool.pdx:85` (`bts_q r9, rdx`)                                     |
| `xor r64, imm64` (via imm8 -1)     | `vnode_pool.pdx:72` (`xor r10, 0xFFFFFFFFFFFFFFFF`)                        |
| `mov r64, imm32`                   | `mount.pdx:186` (`mov rcx, 1`)                                            |
| `mov r64, [rip + sym]`             | `mount.pdx:236` (`mov rax, [rip + _mount_table]`)                         |
| `mov [r64 + disp8], r64`           | `mount.pdx:196` (`mov [r9 + r13*8], rax`)                                 |
| `mov_b [r64 + disp8], r64`         | `path.pdx:141` (`mov_b [r14 + 0], rax`)                                   |
| `mov_w [r64 + disp8], r64`         | `vfs_open.pdx:130` (`mov_w [rdi + 4], rcx`)                               |
| `lea r64, [rip + sym]`             | `mount.pdx:120` (`lea r9, [rip + _mount_table]`)                          |
| `call sym`                         | Ubiquitous.                                                               |
| `cmp r64, imm8/32`                 | Ubiquitous.                                                               |
| `push` / `pop r64`                 | `mount.pdx:103–107, 206–210`                                              |

The `mov_w [r13 + 178]`, `mov_w [r13 + 180]` writes at disp8 offsets
above 127 (178, 180) still fit the `disp8` encoding — the RFC-checked
range is `[-128, 127]` — so these actually require `disp32`. This is
proven by `mount.pdx:196` (`mov [r9 + r13*8], rax`) which uses SIB
addressing but not disp32-past-127; a direct proof is needed for
`mov_w [reg + disp32], reg`. Confirmed via `vfs_open.pdx:135` and
similar large-disp writes in `vnode` layouts up to +56 — but +176
and +180 are novel. See §8.1 for the mitigation.

### 8.1 disp32 verification for `mov_w [r13 + 176]`, `mov_w [r13 + 180]`

Displacements 176, 178, 180 all exceed the imm8 range and require
`disp32` encoding in the ModR/M byte. The two shapes below are
grep-proven:

- `mov [reg + disp32], reg64`: `path.pdx` writes into
  `_path_component_buf + 64+` via `mov_b [r14 + 0], rax` after
  `r14` has been advanced past 128. The direct `disp32` immediate
  path is not explicitly grepped but the equivalent `add r14, 1`
  then `mov_b [r14 + 0], rax` pattern side-steps the encoder
  question by keeping `disp8 = 0`. This is the same pattern we
  fall back to below.

If the initial implementation attempt trips a disp32 encoder gap on
the `mov_w [r13 + 178]` shape, the mitigation is to slide `r13`
forward via `add r13, 176; mov_w [r13 + 0], rcx; add r13, 2;
mov_w [r13 + 0], rcx; ...` — a re-shape that keeps every store at
`disp8 = 0`, identical to `path.pdx`'s established idiom. This
adds three `add r13, imm8` instructions and eliminates the disp32
question entirely. Documented here so a downstream verification
failure has a canned fix without a fresh design pass.

## 9. Cross-references

- Issue: paideia-os#580
- Milestone: R16.M2 (tmpfs — in-memory VFS backend)
- Upstream: paideia-os#579 (R16-M2-001 — frozen inode layout + storage +
  slot helper); paideia-os#578 (R16.M1 VFS OK integration checkpoint).
- Downstream consumers:
  - #581 (`tmpfs_lookup` — walks the root → /tmp chain built here)
  - #582 (`tmpfs_create` — calls the same `tmpfs_inode_alloc`
    promoted from #582 to #580 by §2.1; inserts new children at
    `root.first_child` via head-prepend)
  - A follow-on R16.M2 issue (vnode↔inode binder — reads the return
    value of `tmpfs_init` and writes it into root vnode's
    `backend_ptr` field at +32 per r16-m1 layout)
- Sibling init pattern: `mount.pdx` `mount()` initializes the root
  **vnode** identically (type=DIR, parent_idx=0xFFFF, ops_ptr=null);
  `tmpfs_init` mirrors the discipline for the root **inode**.
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 12 item 2 — "Initialize root inode = directory, then
  `/tmp` as child. Acceptance: after init, `/tmp` resolves."
