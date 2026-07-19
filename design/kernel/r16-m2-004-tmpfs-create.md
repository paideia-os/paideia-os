---
issue: 582
milestone: R16.M2 (tmpfs — in-memory VFS backend)
subsystem: 12 — tmpfs
topic: tmpfs_create — allocate + populate + insert-at-head (R16-M2-004)
freeze-discipline: strict
  - tmpfs inode layout frozen by R16-M2-001 (#579); this issue writes into
    the frozen offsets `+0` (type), `+1` (flags), `+2` (refcount), `+4`
    (link_count), `+8` (size), `+144..+176` (name[32]), `+176`
    (parent_idx), `+178` (next_sibling), `+180` (first_child) via the
    exported constants from `inode.pdx`. No numeric offset is embedded
    outside that module.
  - `tmpfs_create` signature `(u64, u64, u64, u64) -> u64` is frozen for
    the whole R16.M2 series; downstream #583 (`tmpfs_unlink`) will be its
    inverse and depends on the "insert-at-head returns new_idx" contract
    to build its own remove-from-chain probe.
  - Insert-at-head chain discipline (new.next_sibling ← dir.first_child;
    dir.first_child ← new_idx) is the invariant every child chain in the
    pool obeys. R16.M3 (`tmpfs_vops`) and later R17 (`readdir`) both walk
    child chains under this invariant.
blocks:
  - "#583 (`tmpfs_unlink` — inverse; must scan the sibling chain to
    locate the target and splice it out. Relies on the invariant that
    every reachable child was inserted at head by this issue's writer.)"
  - "R16.M3 tmpfs vops table (`tmpfs_vops` — registers a wrapper adapting
    `tmpfs_create(dir_inode_idx, name_ptr, name_len, type)` to the vops
    shape `(dir_vnode_ptr, name_ptr, type)` by reading the vnode's
    `backend_ptr` (+32) as the inode idx and computing name_len via a
    strnlen probe.)"
  - "R17 readdir/iterator syscall — depends on chain terminator being
    `next_sibling == 0xFFFF` for every inserted child, an invariant
    written by this issue and never mutated afterward (except by unlink)."
touching:
  - src/kernel/core/fs/tmpfs/create.pdx           (new module — `tmpfs_create`; ~140 LOC)
  - src/kernel/boot/kernel_main.pdx               (witness block ~110 LOC)
  - tools/boot_stub.S                             (2 witness name strings + 2 message strings; ~15 LOC)
  - tests/r14b/expected-boot-r14b-loader.txt      (marker: "R16 TMPFS CREATE OK")
  - tests/r15/expected-boot-r15-ring3.txt         (marker)
  - tests/r15/expected-boot-r15-process.txt       (marker)
  - design/kernel/r16-m2-004-tmpfs-create.md      (this doc)
related:
  - design/kernel/r16-m2-001-tmpfs-inode-pool.md  (#579 — frozen layout §2;
    every field offset this module writes is exported by inode.pdx)
  - design/kernel/r16-m2-002-tmpfs-init.md        (#580 — the exact
    register + narrow-store pattern this module reuses; §3.2 alignment
    discipline; §4 field-by-field write recipe)
  - design/kernel/r16-m2-003-tmpfs-lookup.md      (#581 — the pre-check
    probe used here for name-collision detection; §2 contract "0 = miss"
    is exactly the "no collision" reply we want)
  - src/kernel/core/fs/mount.pdx                  (#571 — `VNODE_TYPE_DIR = 2`
    constant we type-gate against; same file freezes `VNODE_TYPE_REG = 1`
    which is the type the witness passes to create "/tmp/x")
  - design/milestones/r14b-tactical-plan.md       §Subsystem 12 item 4 —
    "Alloc inode from pool, insert into parent's dentry list. Acceptance:
    create /tmp/x; subsequent lookup returns it."
---

# R16-M2-004 — `tmpfs_create` (inode alloc + insert-at-head, #582)

## 1. Scope

Ship the tmpfs directory-mutation primitive that turns a `(dir_idx,
name, type)` triple into a live child inode threaded onto the
directory's sibling chain. Given a parent directory index, a byte
buffer with a name and its length, and a vnode type, `tmpfs_create`:

1. Type-gates the parent inode (must be `VNODE_TYPE_DIR`),
2. Pre-probes for name collision via `tmpfs_lookup`,
3. Allocates a fresh inode from the R16-M2-001 pool,
4. Populates its fields byte-by-byte per the frozen layout,
5. Copies the caller's name into the +144 field,
6. Splices the new inode at the head of the parent's `first_child`
   chain,
7. Returns the new inode index.

Concretely:

- **Enter** with `rdi = dir_inode_idx` (u64 with u16 semantics),
  `rsi = name_ptr` (u64, points at a byte buffer), `rdx = name_len`
  (u64; caller-supplied length, capped internally at 31), `rcx = type`
  (u64 with u8 semantics; one of `VNODE_TYPE_REG = 1`, `VNODE_TYPE_DIR
  = 2`, or a future type). No bounds pre-check on `dir_inode_idx` —
  callers reach us only through a live index (initially from #580's
  `tmpfs_init` return, later from vnode.backend_ptr via the vops
  adapter).
- **Type gate.** Load the directory inode's `type` byte at `+0`; if it
  is not `VNODE_TYPE_DIR`, return `0` **without allocating** anything.
  This ordering matters: if we allocated first and only discovered the
  parent was a non-directory afterward, we would leak an inode (no
  `tmpfs_inode_free` primitive lands until #583). Type-checking first
  is zero-cost defensively and avoids the leak entirely.
- **Collision probe.** Call `tmpfs_lookup(dir_idx, name_ptr)`; if it
  returns non-zero, a child with that name already exists and we return
  `0`. Again, this happens **before** allocation to preserve the pool.
  The tmpfs_lookup call uses NUL-terminated names, but our caller
  passes a length; §5.2 discusses the terminator-vs-length mismatch and
  why it is safe (callers arriving via `path_resolve` always have
  NUL-terminated names).
- **Allocation.** Call `tmpfs_inode_alloc` (leaf primitive from #580);
  on OOM (return `0xFFFF`), propagate `0` as our own error.
- **Population.** Via `tmpfs_inode_slot(new_idx)`, obtain the inode
  pointer and store each field at its frozen offset: `type` (u8),
  `flags = VALID` (u8), `refcount = 1` (u16), `link_count = 1` (u16),
  `size = 0` (u64 — explicit zero to defend against future slot reuse
  after #583's free lands), `name[]` (byte copy of `name_ptr`, up to 31
  bytes plus explicit NUL), `parent_idx = dir_idx` (u16), and
  `first_child = 0xFFFF` (u16, empty).
- **Insert-at-head.** Via `tmpfs_inode_slot(dir_idx)`, obtain the
  directory pointer. Load the u64 at `+176` (covering `parent_idx |
  next_sibling | first_child | pad`) and extract `first_child` via `shr
  32 + and 0xFFFF` (same idiom as `tmpfs_lookup` §4.2). Write that
  extracted index into new inode's `next_sibling` at `+178` (narrow
  store). Overwrite the directory's `first_child` at `+180` with
  `new_idx` (narrow store). The chain now runs `dir → new_idx →
  (old_first_child) → … → 0xFFFF`.
- **Return** `new_idx` in `rax`.

Out of scope (deliberately deferred):

- **No `tmpfs_inode_free` on failure.** All error paths (bad type,
  collision, alloc OOM) return before the allocation happens, so no
  free is needed. If a future extension adds a step that could fail
  **after** alloc (e.g., a page allocator for `page_ptrs[]` at first
  write), the free primitive from #583 will land first, and this
  module's error paths will grow a call to it. Ordered correctly for
  R16.M2.
- **No vnode-side dispatch.** `tmpfs_create` is the tmpfs-layer
  primitive; the vops-side function `vops_create(dir_vn, name_ptr,
  type)` is dispatched by `vops.pdx` (#572) and reaches this writer
  via an adapter registered in the tmpfs vops table at R16.M3. That
  adapter reads the vnode's `backend_ptr` (+32) as `dir_inode_idx` and
  synthesizes `name_len` via a strnlen probe (or the path_resolver
  passes a length alongside the name, TBD at R16.M3 design time). This
  issue does not wire the adapter or the table.
- **No page allocation.** For `VNODE_TYPE_REG` files, the
  `page_ptrs[16]` field at +16..+144 stays all-zero (via the invariant
  that R16.M2 has no `tmpfs_inode_free` yet, so freshly-allocated slots
  are still `.bss`-clean; §7.3 discusses the future-proofing needed
  once free lands). Actual page allocation for regular file storage
  happens at first `tmpfs_write`, which lands post-R16.M2.
- **No timestamp population.** The tmpfs inode layout (§2 of #579's
  doc) does not include `atime` / `mtime` / `ctime` fields — timestamps
  will be added when the disk-fs backend lands at R18+ and semantics
  need to be preserved across mount/unmount. tmpfs at R16.M2 is a pure
  in-memory scratchpad.
- **No permission / owner bits.** No `uid`, `gid`, or `mode` fields
  exist in the tmpfs inode at R16.M2. When capability-gated file
  access lands (R17+ under the syscall subsystem), these will be added
  alongside a capability-carrying `create` variant.
- **No mid-chain insertion.** Insert-at-head is chosen for O(1) insert
  cost. Callers cannot request a specific position. Directory ordering
  is therefore reverse-insertion-order, which `readdir` will reflect at
  R17 (documented as an intentional non-guarantee).

## 2. Contract

```
tmpfs_create : (u64, u64, u64, u64) -> u64 !{mem} @{}
  → rax = new_idx in [1, 63]   on success  (u16 semantics; upper bits zero)
  → rax = 0                    on failure  (bad type, collision, OOM)
```

Nullary on capabilities at R16.M2 (see §1 out-of-scope). `!{mem}`
because we mutate the frozen `_tmpfs_inode_pool` slab (the new inode's
fields + the parent's `first_child` lane).

**Non-leaf.** Makes nested calls to `tmpfs_inode_slot` (twice: once
for the directory pointer at type-gate + insert, once for the new
inode pointer at populate), `tmpfs_lookup` (once for the collision
probe), and `tmpfs_inode_alloc` (once for the allocation). This forces
a callee-save prologue and `rsp mod 16 == 0` alignment discipline at
every nested call site.

**Failure collapse.** All four failure modes (parent not a directory,
name collision, allocation OOM, and any future post-alloc failure)
collapse to `rax = 0`. Callers that need to distinguish must probe
independently — but no such caller is planned in the R16 series. The
vops layer will translate `0` to `-EEXIST` / `-ENOTDIR` / `-ENOSPC`
based on ambient state when it grows POSIX-shaped error semantics at
R18+.

**Idempotence:** not idempotent. Calling `tmpfs_create` twice with the
same `(dir_idx, name)` triple returns `new_idx` the first time and `0`
the second time (collision probe catches the duplicate).

**Ordering guarantee:** the caller of tmpfs_create observes either
(a) the new inode fully populated **and** threaded into the parent's
chain, or (b) no state change at all. There is no intermediate window
in which the new inode is allocated-but-not-threaded that another
caller could observe, because tmpfs at R16.M2 is single-threaded (the
scheduler is not yet in the kernel critical path; concurrent tmpfs
mutation lands at R17 alongside the FS lock design).

## 3. Register discipline

### 3.1 Push plan — 5 pushes

Five-push callee-save prologue: `rbx`, `r12`, `r13`, `r14`, `r15`. On
SysV AMD64, `rsp mod 16 == 8` at prologue entry (call instruction
pushed the return address from a 16-aligned rsp). Five pushes add `5 *
8 = 40` bytes, so `rsp mod 16 == (8 + 40) mod 16 == 48 mod 16 == 0` at
every nested call site. Matches the alignment requirement.

An alternative 3-push plan (matching `tmpfs_init` and `tmpfs_lookup`)
was considered and rejected: this function has **four** caller-supplied
arguments (dir_idx, name_ptr, name_len, type) that all need to survive
nested calls (see §3.3), plus `new_idx` which needs to persist from
allocation through the final return. That is five persistent
quantities; a 3-push plan would force two of them to reload from
memory (which is not possible for `type` — the caller does not stash
it anywhere the callee can find). Five pushes are the minimum for a
zero-reload discipline.

| Reg | Role                                                                 |
|-----|----------------------------------------------------------------------|
| rbx | `dir_idx` — caller's arg1, saved on entry. Read three times: at the type-gate `tmpfs_inode_slot(dir_idx)` call, at the collision-probe `tmpfs_lookup(dir_idx, name_ptr)` call, and at the insert-time `tmpfs_inode_slot(dir_idx)` call. Also read once for the store to new inode's `parent_idx` at +176. Must survive every nested call. |
| r12 | `name_ptr` — caller's arg2, saved on entry. Read at the collision-probe call site and at the name-copy loop. Must survive every nested call. |
| r13 | `name_len` — caller's arg3, saved on entry. Read only inside the name-copy loop as the byte-count budget. Must survive every nested call (specifically `tmpfs_inode_alloc` and the first `tmpfs_inode_slot`). |
| r14 | `new_idx` — result of `tmpfs_inode_alloc`, saved into r14 the moment it lands. Read at the second `tmpfs_inode_slot(new_idx)` call, at the final `mov_w [dir_ptr + 180], r14` insert-at-head write, and at the `mov rax, r14` return. Must survive the intervening calls to `tmpfs_inode_slot` and the field-store sequence. |
| r15 | **Morphing role.** Initially holds `type` (caller's arg4) so the byte can be stored into new inode's `+0` field after allocation. **Once that store completes, r15 is repurposed to hold `new_ptr`** — the base pointer for every subsequent field store (+1 through +180 on the new inode) and the load-base for the insert-time read of new inode's `+178`. The morph point is a single instruction: `mov_b [rax + 0], r15` (uses r15 as type source) immediately followed by `mov r15, rax` (repurpose to new_ptr). |

### 3.2 Why the r15 morph, not a 6th push

A cleaner-looking design would push a 6th register to hold `new_ptr`
separately from `type`. Rejected for two reasons:

1. **Alignment.** 6 pushes gives `rsp mod 16 == 8` at nested call
   sites, breaking the SysV rule. Would need a `sub rsp, 8` pad before
   every `call`, costing four extra instructions in a function whose
   only novel work is field stores + a bounded copy loop.
2. **Type is single-use.** After being stored into `[new_ptr + 0]`,
   `type` is semantically dead. Holding a dead value in a callee-save
   register wastes the register. The morph reuses r15's storage lot
   for two disjoint value lifetimes, which is exactly the pattern
   `tmpfs_lookup` uses for `r13` (holds `cur_ptr` fresh each
   iteration).

### 3.3 Why not fewer registers via type-in-memory

A 4-push variant could stash `type` in a temporary memory slot (e.g., a
scratch byte in `.bss`) instead of using r15. Rejected:

- Introduces a new `.bss` symbol just for this function, polluting the
  linker's symbol table with a private scratchpad.
- Reads/writes to global memory are strictly slower than register
  moves.
- Loses the elegant morph pattern (r15 = type → new_ptr) that lets us
  use a single register slot for two disjoint value lifetimes.
- Adds an ordering hazard: any concurrent tmpfs_create (once R17
  concurrency lands) would race on the scratch slot. Using a
  callee-save register keeps the value in the function's own frame.

### 3.4 Scratch registers

Field stores use `rax` (as slot pointer from `tmpfs_inode_slot`) and
`rcx` (as small-constant carrier: `1` for flags/refcount/link_count,
`0xFFFF` for first_child sentinel). The name-copy loop uses `r8`
(dest cursor), `r9` (src cursor), `rcx` (counter), and `rax` (byte
buffer). The insert-at-head phase uses `r8` (extracted first_child
lane). None of these are read across a nested call — either the call
is at the end of a phase or the value is stashed into a callee-save
register first.

## 4. Algorithm

### 4.1 Prologue + arg stash

```asm
tmpfs_create:
    push rbx
    push r12
    push r13
    push r14
    push r15                            ; rsp%16 = 0

    mov  rbx, rdi                       ; rbx = dir_idx
    mov  r12, rsi                       ; r12 = name_ptr
    mov  r13, rdx                       ; r13 = name_len
    mov  r15, rcx                       ; r15 = type (until stored)
```

`r14 = new_idx` is set later, after the allocation call.

### 4.2 Directory type gate

Type-check the parent **before** allocating anything. If it is not a
directory, return 0 without touching the pool.

```asm
    ; --- Type-gate parent: dir.type at +0 must be VNODE_TYPE_DIR (2) ---
    mov  rdi, rbx
    call tmpfs_inode_slot               ; rax = dir_ptr
    xor  rcx, rcx
    mov_b rcx, [rax + 0]                ; rcx = dir.type
    cmp  rcx, 2                         ; VNODE_TYPE_DIR
    jne  tmpfs_create_fail              ; parent is not a directory
```

### 4.3 Name-collision probe

Ask `tmpfs_lookup` whether the name already exists in the parent's
child chain. If it does, we cannot insert without breaking the "no
duplicate names in a directory" invariant.

```asm
    ; --- Collision probe: tmpfs_lookup(dir_idx, name_ptr) ---
    mov  rdi, rbx
    mov  rsi, r12
    call tmpfs_lookup                   ; rax = existing_idx or 0
    cmp  rax, 0
    jne  tmpfs_create_fail              ; name already exists in dir
```

**Note on the length mismatch.** `tmpfs_lookup` operates on
NUL-terminated names (see r16-m2-003 §5.2 for its termination logic),
while `tmpfs_create` receives a `(name_ptr, name_len)` pair. Callers
that reach tmpfs_create through the R16.M3 vops adapter will provide
a NUL-terminated name (path_resolver always terminates its component
buffer, r16-m1-004 §3.3), so passing `r12 = name_ptr` to
`tmpfs_lookup` is safe. Direct-test callers (this issue's own
witness) must also NUL-terminate. If a future caller needs to create
a name that does not follow this convention, add a `tmpfs_lookup_n`
length-explicit variant then; for R16.M2 the terminator is a hard
prereq documented in this section.

### 4.4 Allocation

```asm
    ; --- Allocate new inode from bitmap ---
    call tmpfs_inode_alloc              ; rax = new_idx or 0xFFFF
    cmp  rax, 0xFFFF                    ; TMPFS_INODE_ALLOC_OOM
    je   tmpfs_create_fail
    mov  r14, rax                       ; r14 = new_idx (preserved)
```

### 4.5 Populate: fixed-size fields

Get `new_ptr` and populate the header fields. r15 morphs here.

```asm
    ; --- Get new_ptr; store type; then r15 = new_ptr ---
    mov  rdi, r14
    call tmpfs_inode_slot               ; rax = new_ptr

    mov_b [rax + 0], r15                ; type at +0 (r15 held it)
    mov  r15, rax                       ; r15 = new_ptr (repurpose)

    ; flags = TMPFS_INODE_FLAG_VALID (1) at +1 (u8)
    mov  rcx, 1
    mov_b [r15 + 1], rcx

    ; refcount = 1 at +2 (u16)  — rcx still 1
    mov_w [r15 + 2], rcx

    ; link_count = 1 at +4 (u16) — rcx still 1
    mov_w [r15 + 4], rcx

    ; size = 0 at +8 (u64) — explicit zero for future free-then-reuse safety
    xor  rcx, rcx
    mov  [r15 + 8], rcx
```

**Why refcount = 1.** The task specification for this issue sets
`refcount = 1`, treating the newly-created inode as if a vnode has
already bound to it. This mirrors the eventual R16.M3 semantic where
`vfs_create` wraps `tmpfs_create` and then binds a vnode (which would
normally bump refcount). Setting it to 1 here saves the vops adapter
one atomic increment (and keeps `refcount == link_count == 1` as the
initial live-file invariant, which sits nicely with the eventual
POSIX-like unlink semantics). It **does** diverge from `tmpfs_init`'s
convention of leaving refcount at 0 for root and /tmp; that
divergence is documented in §6.4 as an intentional asymmetry (root
and /tmp are init-time skeleton entries that never get bound by a
user-facing vnode; user-created entries at run time always get
bound).

**Why explicit zero for size.** At R16.M2 the pool is still `.bss`-
zero and no `tmpfs_inode_free` primitive exists, so freshly-alloc'd
slots contain all zeros as a matter of stack invariant. The explicit
`xor rcx, rcx; mov [r15+8], rcx` costs two instructions and defends
against the day #583 lands and slots are reused. Every field the
caller can observe (type, flags, refcount, link_count, size, name,
parent_idx) is explicitly written; only the internal-implementation
fields (`page_ptrs[16]` at +16..+144) rely on the `.bss` invariant.

### 4.6 Name copy

Copy `min(name_len, 31)` bytes from `[r12]` to `[r15 + 144]`, then
write an explicit NUL terminator at the copy cursor. The 31-byte cap
leaves room for the trailing NUL within the 32-byte name field.

```asm
    ; --- Name copy: [r12, r12+min(name_len, 31)) → [r15+144, ...) ---
    xor  rcx, rcx                       ; rcx = counter
    lea  r8, [r15 + 144]                ; r8 = dest cursor
    mov  r9, r12                        ; r9 = src cursor

tmpfs_create_name_loop:
    cmp  rcx, r13                       ; done if counter == name_len
    jae  tmpfs_create_name_done
    cmp  rcx, 31                        ; cap at 31 (leave room for NUL)
    jae  tmpfs_create_name_done
    xor  rax, rax
    mov_b rax, [r9]                     ; load src byte
    mov_b [r8], rax                     ; store dest byte
    add  r8, 1
    add  r9, 1
    add  rcx, 1
    jmp  tmpfs_create_name_loop

tmpfs_create_name_done:
    xor  rax, rax
    mov_b [r8], rax                     ; explicit NUL at cursor
```

**Why explicit NUL.** Same reasoning as §4.5: `.bss` provides zeros
today, but once slot reuse is possible, the trailing bytes could
contain the previous inhabitant's name. The explicit NUL is the
canonical "end of this name" marker that `tmpfs_lookup`'s 32-byte
byte-compare terminates on. Two extra instructions bought against a
class of bugs.

**Why cap at 31, not 32.** The name field is 32 bytes wide (§2 of
#579). If we copied up to 32 bytes with no room for NUL, a 32-char
name would have no terminator, and `tmpfs_lookup`'s 32-byte compare
loop would hit its "32-byte overrun" path (§5.2 row 3 of the lookup
doc) — a path that returns hit for the wrong semantic reason. Capping
at 31 + explicit NUL keeps `tmpfs_lookup`'s hot path in the both-NUL
match case, which is the intended termination.

### 4.7 Populate: chain fields on the new inode

```asm
    ; parent_idx = dir_idx (rbx) at +176 (u16)
    mov_w [r15 + 176], rbx

    ; first_child = 0xFFFF at +180 (u16) — new inode has no children
    mov  rcx, 0xFFFF
    mov_w [r15 + 180], rcx
```

`next_sibling` at +178 is deferred to the insert phase — it needs to
be set to the parent's current `first_child`, which we do not know
yet.

### 4.8 Insert-at-head

Get the directory pointer, read its current `first_child`, thread the
new inode in front of it, and update.

```asm
    ; --- Get dir_ptr again for insert phase ---
    mov  rdi, rbx
    call tmpfs_inode_slot               ; rax = dir_ptr
                                        ; (r15 still holds new_ptr — safe
                                        ;  across the call because it's
                                        ;  callee-save)

    ; Read dir's u64 @+176 (parent_idx | next_sibling | first_child | pad).
    ; Extract dir.first_child from bits [32, 48) via the same
    ; shr 32 + and 0xFFFF idiom used in tmpfs_lookup §4.2.
    mov  r8, [rax + 176]
    shr  r8, 32
    and  r8, 0xFFFF                     ; r8 = dir.first_child (may be 0xFFFF)

    ; Write into new.next_sibling at +178 (u16)
    mov_w [r15 + 178], r8

    ; Write new_idx into dir.first_child at +180 (u16)
    mov_w [rax + 180], r14

    ; --- Success: return new_idx ---
    mov  rax, r14
    jmp  tmpfs_create_done
```

**Chain state after insert.** Before: `dir.first_child = X` (some
u16; 0xFFFF if empty). After: `dir.first_child = new_idx` and
`new.next_sibling = X`. The chain is now `dir → new_idx → X → … →
0xFFFF`, which is a well-formed extension of the pre-insert chain by
one node at position 0.

**Ordering.** We write `new.next_sibling` **before** we update
`dir.first_child`. This means at every intermediate point during the
insert:

- After the `mov_w [r15 + 178], r8` and before the `mov_w [rax + 180],
  r14`: the new inode is fully populated with the correct sibling
  pointer, but the parent still points at the pre-insert first_child.
  Any concurrent walker would see the pre-insert chain (as if the
  create never happened) — a valid state.

- After the `mov_w [rax + 180], r14`: the parent points at the new
  inode, whose sibling chain correctly threads back to the pre-insert
  first_child. Any concurrent walker would see the post-insert chain
  (with the new node visible) — also a valid state.

There is no intermediate state where the new inode is visible via
`dir.first_child` but has a stale `next_sibling`. This ordering is
lock-free-safe under a single-writer / multi-reader concurrency model,
which is exactly the FS-lock discipline planned at R17. R16.M2 is
single-threaded, so the property is moot today but is a free bonus
for the future.

### 4.9 Epilogue

```asm
tmpfs_create_fail:
    xor  rax, rax                       ; rax = 0 (failure)

tmpfs_create_done:
    pop  r15
    pop  r14
    pop  r13
    pop  r12
    pop  rbx
    ret
```

Total instruction count: ~55 in the primary body plus ~10 in the
prologue/epilogue plus the ~12 name-copy inner loop. Roughly 75
instructions of body, matching the ~140-LOC estimate (assembly plus
one comment per line plus the module wrapper).

## 5. Failure paths and side-effect discipline

All four failure modes route to `tmpfs_create_fail` before any pool
mutation. This gives the "atomic" property described in §2.

### 5.1 Failure inventory

| Failure                | Detected at                          | Pool state after |
|------------------------|--------------------------------------|-----------------|
| Parent not a directory | §4.2 `cmp rcx, 2; jne`               | Unchanged.       |
| Name collision         | §4.3 `cmp rax, 0; jne`               | Unchanged.       |
| Allocation OOM         | §4.4 `cmp rax, 0xFFFF; je`           | Unchanged.       |
| (Future) post-alloc    | Would go here, needs `tmpfs_inode_free` | Deferred to #583's follow-up. |

### 5.2 Why type-gate before collision-probe

The type-gate check is `O(1)` (single byte load); the collision probe
is `O(fan-out)` (linear chain scan). Doing the cheaper gate first
short-circuits pathological callers (e.g., a script that repeatedly
tries to create files under a regular file). Ordering matters for
future-proofing when directory sizes grow.

### 5.3 Why collision-probe before allocation

If we allocated first and probed after, a collision would leak an
inode (no free primitive at R16.M2). Probing first keeps the bitmap
clean under all rejection paths.

Cost of the probe: a linear scan of the parent's child chain
(`≤ 64 * ~35` instructions ≈ 2 240 instructions worst-case per the
r16-m2-003 doc §6.6). The probe is called once per `tmpfs_create`;
under expected boot loads (dozens of creates), this is comfortably
below any performance threshold that would motivate skipping.

### 5.4 Why r15 morph is safe for the failure path

If we fail **before** the `mov_b [rax+0], r15; mov r15, rax` morph
sequence, r15 still holds `type` (a caller-supplied value we do not
own or leak). If we fail after — but we never do; the morph happens
inside a straight-line block with no branches that could fail before
the end of §4.5. The failure paths are all detected before the morph
point (§4.2, §4.3, §4.4). So r15's morph is a straight-line invariant,
not a conditional one, and the epilogue's `pop r15` restores the
caller's value correctly regardless of the success/failure exit.

## 6. Alternatives considered

### 6.1 Append at tail instead of insert at head

**Proposal.** Walk the sibling chain from `first_child` to the
`next_sibling == 0xFFFF` terminator and append the new inode there.
Preserves insertion-order iteration for `readdir`.

**Rejected.** Two costs, both real:

1. **O(fan-out) insert.** Each create walks the whole existing chain.
   Doubles the amortized cost of `tmpfs_create` (one linear scan for
   collision + one for tail-find).
2. **Complexity.** The tail-append needs a two-pointer walker to
   track (prev, cur) so it can rewrite `prev.next_sibling` when it
   finds the terminator; also a special case for the empty chain
   where `dir.first_child` itself is the write target. Insert-at-head
   is a two-instruction linked-list splice with no special cases.

Insertion-order iteration is not a specified guarantee at R16.M2, and
tests that depend on it can just enumerate in the reverse of insertion
order (which is what insert-at-head naturally produces).

### 6.2 Aggregate u64 rewrite for the two-lane chain update

**Proposal.** Instead of two `mov_w` narrow stores (§4.8 —
`mov_w [r15+178], r8` and `mov_w [rax+180], r14`), rewrite both u64
words at +176 atomically:

- New's u64 @+176: mask off bits [16, 32), OR in `(r8 << 16)`, write.
- Dir's u64 @+176: mask off bits [32, 48), OR in `(r14 << 32)`, write.

**Rejected.** More complex for zero benefit at R16.M2:

- **Uses more instructions.** Each u64 update needs load + mask + OR
  + shift + store (5 instructions per lane) vs. a single mov_w (1
  instruction). Two lanes update means 10 instructions vs. 2 —
  penalizing the exact hot path we care about.
- **`mov_w` at disp32 is proven.** `tmpfs_init.pdx` uses exactly this
  shape (`mov_w [r13 + 178], rcx` and `mov_w [r13 + 180], r12` at
  lines 73, 76, 109, 112). No new encoder risk.
- **Aggregate would trash more fields.** Reading + masking + rewriting
  the whole u64 is only atomic under a "same value except one lane"
  discipline, which needs a read-modify-write that we do not have a
  primitive for. Any misread would corrupt neighboring lanes
  (parent_idx, pad). Narrow stores touch exactly the lane they
  advertise.

**Kept as backup:** if a future encoder regression drops `mov_w [reg
+ disp32]` support, this alternative is the safe fallback — pure u64
load/store/shift/mask is a universally-encodable set.

### 6.3 Skip collision-probe (trust the caller)

**Proposal.** Assume the caller has already verified the name does
not exist (via a prior `tmpfs_lookup`) and skip the internal probe.
Saves one `tmpfs_lookup` call.

**Rejected.** Two failure modes we cannot let leak:

1. **Direct-caller mistakes.** A test that forgets to probe would
   double-insert, leaving a broken chain (two entries with the same
   name; the second `tmpfs_lookup` return is undefined by our
   invariant). Defense-in-depth here is cheap.
2. **TOCTOU under future concurrency.** Once R17 lands multithreading,
   a caller's external probe result becomes stale between the probe
   and the create call. The internal probe under a create-time lock
   is the only correct pattern. Building that discipline in now
   (even under single-threaded R16.M2) keeps the interface stable
   through the concurrency transition.

The probe's ~2 240-instruction worst case is not on any hot path we
care about at R16.M2.

### 6.4 Refcount = 0 (match tmpfs_init's convention)

**Proposal.** Leave `refcount` at 0 on create, matching how
`tmpfs_init` handles root and /tmp. Rely on the eventual R16.M3 vnode
binder to bump it to 1 when a vnode wraps the inode.

**Rejected for R16.M2 (via task spec).** Two considerations:

1. The task spec explicitly sets `refcount = 1`. Interpretation: the
   act of `tmpfs_create` is semantically equivalent to "create + open
   for the caller who requested it", so the refcount starts at 1 to
   reflect that logical ownership.
2. `tmpfs_init` leaves refcount at 0 because root and /tmp are
   init-time skeleton entries with no vnode bound; they exist as
   name-space anchors, not as "opened" objects. User-created entries
   are always "opened" (by the caller who created them), so refcount
   = 1 matches their intended lifecycle.

The asymmetry between init-time (0) and create-time (1) is documented
here. If a future R16.M3 audit finds the asymmetry hard to reason
about, tmpfs_init can bump both entries to 1 in a follow-up (no
protocol change needed, just a symmetry cleanup).

### 6.5 Zero the whole 256-byte slot before populating

**Proposal.** After `tmpfs_inode_slot(new_idx)`, memset the full 256
bytes to zero, then overwrite only the fields we care about.

**Rejected.** Two issues:

1. **Wasteful.** The `.bss` invariant already provides zeros at
   R16.M2 (no free primitive; slots are never reused). A memset would
   be 32 x u64 stores of zero for no observable state change.
2. **Zeros the wrong things.** The name field and page_ptrs field
   would then be redundant-zeroed by the memset AND by their
   individual writes / non-writes. The pattern would erode discipline
   (why do we zero these two but not the others?).

If a future R17 slot reuse policy needs a clean slate on alloc,
**`tmpfs_inode_alloc` itself** should own the memset (not the
caller). This keeps the "who cleans" question single-answered per
primitive.

### 6.6 Combined refcount + link_count + flags into one u32 store

**Proposal.** flags (+1, u8), refcount (+2, u16), link_count (+4,
u16) are all in [+1, +6). A single 4-byte store at +1 could set all
three fields in one instruction (packing `0x0001_0100_0001_01` or
similar into the appropriate lanes).

**Rejected.** Three costs:

1. **Encoder complexity.** `mov_d [reg + disp8]` (32-bit store) is
   used elsewhere in the codebase but adds a memorization burden if
   we're mixing narrow-store sizes (u8, u16, u32) in the same block.
2. **Padding gap.** flags is at +1, refcount at +2, link_count at +4.
   So there's a byte-position gap between refcount (+2..+4) and
   link_count (+4..+6). Packing across this gap would either
   miss-align the u32 or write into the wrong lane.
3. **No performance benefit.** These are byte stores to L1-cached
   memory; the store buffer coalesces them at the microarch layer.

Kept as a future micro-op if `perf` ever shows tmpfs_create as a
hotspot.

### 6.7 Callee-side name_len computation (strlen)

**Proposal.** Drop the `name_len` argument and have `tmpfs_create`
compute it internally via a strlen probe on `name_ptr`.

**Rejected.** Two costs:

1. Extra loop with its own alignment / cursor management.
2. Doesn't match the eventual R16.M3 vops adapter shape, which
   already knows the length (path_resolver produces `(name, len)`
   pairs by splitting on `/`).

The caller-provided length is the correct interface. If a future
callsite genuinely doesn't know the length, add a `tmpfs_create_z`
NUL-terminator variant then.

## 7. Invariants

### 7.1 Success return is a valid inode idx in [1, 63]

On the success path, `rax = r14`, and r14 was set from
`tmpfs_inode_alloc`'s return which is guaranteed in `[1, 63]` on
non-OOM by that primitive's contract (r16-m2-002 §4.1). Upper 48 bits
of rax are zero because `tmpfs_inode_alloc` returns via `mov rax,
rdx` where rdx comes from `bsf_q` on a masked bitmap (bounded [0, 63]).

### 7.2 Failure return is exactly `rax = 0`

`tmpfs_create_fail` zeros rax via `xor rax, rax`, which zero-idioms
the full u64. Callers using `cmp rax, 0` are safe.

### 7.3 Post-success, new inode is fully populated

Every field the layout defines has a written value before we jump to
`tmpfs_create_done`:

| Field         | Offset | Written by                            |
|---------------|--------|--------------------------------------|
| type          | +0     | §4.5 `mov_b [rax + 0], r15`          |
| flags         | +1     | §4.5 `mov_b [r15 + 1], rcx` (VALID)  |
| refcount      | +2     | §4.5 `mov_w [r15 + 2], rcx` (1)      |
| link_count    | +4     | §4.5 `mov_w [r15 + 4], rcx` (1)      |
| size          | +8     | §4.5 `mov [r15 + 8], rcx` (0, explicit) |
| page_ptrs[16] | +16..+144 | Unwritten — relies on `.bss` zero (§4.5 note) |
| name[]        | +144..+176 | §4.6 (bounded copy + explicit NUL) |
| parent_idx    | +176   | §4.7 `mov_w [r15 + 176], rbx`        |
| next_sibling  | +178   | §4.8 `mov_w [r15 + 178], r8`         |
| first_child   | +180   | §4.7 `mov_w [r15 + 180], rcx` (0xFFFF) |

The `page_ptrs[16]` gap is the only field relying on the `.bss` zero
invariant. R16.M2 has no free primitive, so this is safe today. When
#583 lands, either `tmpfs_inode_free` must zero the slot (deferred
choice) or `tmpfs_create` must add an inner loop to zero the page
pointers. The design doc for #583 will make this call.

### 7.4 Post-success, dir's chain is well-formed

Before the create: `dir.first_child = X` (some u16, possibly 0xFFFF).
After the create:

- `new.next_sibling = X` (whatever the pre-insert first_child was).
- `dir.first_child = new_idx`.

So the chain runs `dir → new_idx → X → (chain from X)`. Because we
did not touch any other node's `next_sibling`, the rest of the chain
is byte-identical to its pre-insert state. Chain terminator (some
`next_sibling == 0xFFFF` somewhere in the chain) is preserved.

### 7.5 Failure preserves the pool byte-identically

All failure paths return **before** any store into
`_tmpfs_inode_pool`. The two nested `tmpfs_inode_slot` calls that
happen before the type-gate result is known are pure address
computations (`shl` + `add`); they do not touch pool memory. The one
`tmpfs_lookup` call in the collision probe is `!{mem}` on the READ
side only (r16-m2-003 §2). The `tmpfs_inode_alloc` call **would**
mutate the bitmap, but only executes after both prior checks pass;
if either check fails, alloc is never called.

### 7.6 Name field always contains a NUL within the 32-byte window

Either the copy loop terminates at `rcx == name_len` (rcx < 32), and
the explicit NUL is written at position rcx; or the copy loop
terminates at `rcx == 31`, and the explicit NUL is written at
position 31. In both cases position ≤ 31 holds NUL, which is within
the 32-byte field. This preserves invariant §7.3 of r16-m2-003
(tmpfs_lookup's 32-byte compare always terminates at the both-NUL
match or the byte-mismatch, never at the 32-byte overrun).

### 7.7 refcount / link_count arithmetic is not overflow-safe

We set both to `1` at create time (from `mov rcx, 1`). If a future
extension bumps refcount or link_count to their u16 max (65535) via
repeated hard-linking or open, wraparound would be silent. This is
out-of-scope for R16.M2 (no hard-link primitive; open sets refcount
= 1, no bump). Documented for R17+ audit.

## 8. Encoder verification

Every mnemonic shape used by this issue's code is proven in R16.M1
/ R16.M2 landed modules. No new encoder work.

| Shape                              | Proven by                                                                        |
|------------------------------------|----------------------------------------------------------------------------------|
| `push` / `pop r64`                 | `tmpfs_init.pdx:30-32, 122-124`, `tmpfs_lookup.pdx:33-35, 113-116`. 5-push pattern is uniform with `vfs_open`'s prologue at r16-m1-006. |
| `mov r64, r64`                     | Ubiquitous.                                                                       |
| `call sym`                         | Ubiquitous.                                                                       |
| `xor r64, r64`                     | Ubiquitous zero-idiom.                                                            |
| `mov_b r64, [r64 + disp8]`         | `tmpfs_lookup.pdx:45, 75-76`. Load form.                                          |
| `mov_b [r64 + disp8], r64`         | `tmpfs_init.pdx:53, 57, 85, 89, 96-100`. Store form.                              |
| `mov_w [r64 + disp32], r64`        | `tmpfs_init.pdx:70, 73, 76, 105, 109, 112`. Offsets +176, +178, +180 all proven — same three offsets this module writes. |
| `mov_w [r64 + disp8], r64`         | `tmpfs_init.pdx:64, 92`. Offset +4 (refcount lane).                               |
| `mov [r64 + disp8], r64`           | Ubiquitous store form (used for `mov [r15 + 8], rcx` at §4.5).                    |
| `mov r64, [r64 + disp32]`          | `tmpfs_lookup.pdx:52, 98`. Load form at +176 with shr+and extraction — same idiom used in §4.8. |
| `lea r64, [r64 + disp32]`          | `tmpfs_lookup.pdx:69` (`lea r9, [r13 + 144]`). Same disp32 offset used in §4.6.   |
| `cmp r64, imm8`                    | Ubiquitous (`cmp rax, 0`, `cmp rcx, 31`, `cmp rcx, 2`).                           |
| `cmp r64, imm32`                   | Ubiquitous (`cmp rax, 0xFFFF`).                                                   |
| `shr r64, imm8`                    | `tmpfs_lookup.pdx:53, 99`, `mount.pdx:203`.                                       |
| `and r64, imm32`                   | `tmpfs_lookup.pdx:54, 100`.                                                       |
| `jmp label` / `je` / `jne` / `jae` | Ubiquitous.                                                                       |
| `add r64, imm8`                    | `tmpfs_lookup.pdx:83-85`, `path.pdx:80, 142-145` (all `add r64, 1`).              |

The +176 / +178 / +180 disp32 offsets have been battle-tested through
two prior landings (tmpfs_init writes, tmpfs_lookup reads). This
module reads +176 (u64) and writes +178 and +180 (u16 each), all shapes
proven in the exact register-class × offset combination.

No `mov_w [r64 + disp32], imm` (immediate-source narrow store), no
`mov_w r64, [r64 + disp32]` (narrow-load with disp32) are used —
neither shape is proven in this codebase yet, and the design routes
around both.

## 9. Test canary — R16 TMPFS CREATE OK

Runs in `kernel_main` immediately after the `R16 TMPFS LOOKUP OK`
marker. Placement rationale: `tmpfs_create` mutates the /tmp inode's
`first_child` field, so any downstream code that walks /tmp will see
"/tmp/x" as a child. The witness for tmpfs_lookup already ran and
verified the empty-/tmp behavior; running tmpfs_create's witness
after tmpfs_lookup's preserves the property that each witness runs
against a stable, pre-verified precondition.

Four sub-tests, one marker.

### 9.1 Witness fixture — name string in boot_stub.S

One new witness name string (reuses `witness_name_any` from #581's
fixture — same "x\0" content):

```s
# R16-M2-004 (#582): tmpfs_create witness — reuses witness_name_any
```

No new name string needed; #581's `witness_name_any` (which contains
"x\0") is exactly the string we want to create. Reusing it also
proves that a lookup miss for "x" earlier (which happened as a
side-effect of tmpfs_lookup's sub-test C using slot 63) truly is a
miss, and that `tmpfs_create` inserts "x" into a chain where the
lookup would previously have missed.

Wait — sub-test C of #581 used `witness_name_any` on slot 63 (a
non-DIR), which returned 0 due to the type gate, not due to a chain
miss. So the previous lookups did not exercise `witness_name_any` on
a real chain scan. `tmpfs_create`'s sub-test A (below) is the first
actual chain scan for "x".

Two new witness message strings, alongside the existing
`tmpfs_lookup_*_msg` pair (r16-m2-003 §9.5 anchor):

```s
# R16-M2-004 (#582): tmpfs_create witness success + failure messages
.global tmpfs_create_ok_msg
.align 8
tmpfs_create_ok_msg: .ascii "R16 TMPFS CREATE OK\n\0"

.global tmpfs_create_fail_msg
.align 8
tmpfs_create_fail_msg: .ascii "R16 TMPFS CREATE FAIL\n\0"
```

### 9.2 Sub-test A — tmpfs_create(tmp_idx, "x", 1, REG) returns non-zero new_idx

```asm
    ; --- Recover tmp_idx via tmpfs_lookup on root (proven working at this
    ;     boot point by the tmpfs_lookup witness immediately above) ---
    mov  rdi, 1                             ; root_idx = TMPFS_INODE_IDX_ROOT
    lea  rsi, [rip + witness_name_tmp]      ; name = "tmp\0"
    call tmpfs_lookup
    cmp  rax, 0
    je   tmpfs_create_witness_fail          ; can't proceed — /tmp missing
    mov  r12, rax                           ; r12 = tmp_idx (for later cross-checks)

    ; --- tmpfs_create(tmp_idx, "x", 1, REG=1) ---
    mov  rdi, r12                           ; dir_idx = tmp_idx
    lea  rsi, [rip + witness_name_any]      ; name_ptr = "x\0"
    mov  rdx, 1                             ; name_len = 1 (just 'x')
    mov  rcx, 1                             ; type = VNODE_TYPE_REG
    call tmpfs_create
    cmp  rax, 0
    je   tmpfs_create_witness_fail          ; expected non-zero new_idx
    cmp  rax, 0xFFFF
    je   tmpfs_create_witness_fail          ; alloc-OOM sentinel — shouldn't happen
    mov  r13, rax                           ; r13 = new_idx (for cross-checks)
```

Proves: (a) tmpfs_create passes the type gate on /tmp (which is a
DIR), (b) passes the collision probe (nothing named "x" existed
before), (c) allocates an inode successfully, (d) returns a non-zero,
non-sentinel index.

**Why recover tmp_idx via tmpfs_lookup, not via saved r-register.**
The tmpfs_lookup witness (r16-m2-003 §9.2) also used `r12` for
tmp_idx cross-check but did not preserve it beyond that witness's
scope. Rather than adding state-passing between witnesses (which
would couple them fragilely), we recompute tmp_idx via a fresh
lookup. The lookup was just proven to work; using it here as a
building block is exactly the composition the R16 series is
designed to test.

### 9.3 Sub-test B — tmpfs_lookup(tmp_idx, "x") returns new_idx

```asm
    ; --- The whole point of tmpfs_create's acceptance criterion:
    ;     "create /tmp/x; subsequent lookup returns it." ---
    mov  rdi, r12                           ; tmp_idx
    lea  rsi, [rip + witness_name_any]      ; "x\0"
    call tmpfs_lookup
    cmp  rax, r13                           ; expect returned idx == new_idx
    jne  tmpfs_create_witness_fail
```

Proves: end-to-end — the inode we created is discoverable by the same
name we created it with, from the same directory. This is the
acceptance criterion verbatim.

### 9.4 Sub-test C — /tmp.first_child == new_idx

Verifies the linked-list splice landed correctly at the head position.

```asm
    ; --- Load /tmp's u64 @+176; extract first_child from bits [32, 48) ---
    mov  rdi, r12                           ; tmp_idx
    call tmpfs_inode_slot                   ; rax = &tmp_inode
    mov  rcx, [rax + 176]
    shr  rcx, 32
    and  rcx, 0xFFFF                        ; rcx = tmp.first_child
    cmp  rcx, r13                           ; expect == new_idx
    jne  tmpfs_create_witness_fail
```

Proves: the insert-at-head phase (§4.8) correctly rewrote the
directory's `first_child` field. Directly witnesses the chain
mutation, independent of the tmpfs_lookup walker (which sub-test B
already exercised).

### 9.5 Sub-test D — new inode fields are correctly populated

Verifies type, parent_idx, and name.

```asm
    ; --- Get new_ptr ---
    mov  rdi, r13                           ; new_idx
    call tmpfs_inode_slot                   ; rax = &new_inode
    mov  r14, rax                           ; r14 = new_ptr (survive nothing here;
                                            ; kept just for consistency with reads)

    ; --- Check type == VNODE_TYPE_REG (1) ---
    xor  rcx, rcx
    mov_b rcx, [r14 + 0]
    cmp  rcx, 1
    jne  tmpfs_create_witness_fail

    ; --- Check parent_idx == tmp_idx: extract from bits [0, 16) of u64 @+176 ---
    mov  rcx, [r14 + 176]
    and  rcx, 0xFFFF
    cmp  rcx, r12                           ; expect == tmp_idx
    jne  tmpfs_create_witness_fail

    ; --- Check name field: u64 @+144 == 0x78 ('x' + 7 zero pad bytes) ---
    mov  rcx, [r14 + 144]
    mov  rdx, 0x78                          ; expected: 'x' at byte 0, zeros elsewhere
    cmp  rcx, rdx
    jne  tmpfs_create_witness_fail
```

Proves: (a) type was correctly written (validates §4.5's `mov_b [rax +
0], r15`), (b) parent_idx was correctly written (validates §4.7's
`mov_w [r15 + 176], rbx`), (c) name field contains exactly "x\0" with
the trailing 30 bytes as NUL — validates both the copy loop (§4.6)
and the explicit NUL write.

The `u64 @+144 == 0x78` check is powerful: it verifies bytes [144, 152)
of the name field are exactly `'x', 0, 0, 0, 0, 0, 0, 0`. Combined
with the `.bss`-zero invariant on bytes [152, 176), this witnesses
that the entire 32-byte name field is in the expected `x\0…\0` state.

### 9.6 Marker

On all four sub-tests green:

```
R16 TMPFS CREATE OK
```

Fingerprint added to:

- `tests/r14b/expected-boot-r14b-loader.txt` — line immediately
  following `R16 TMPFS LOOKUP OK`.
- `tests/r15/expected-boot-r15-ring3.txt` — same position.
- `tests/r15/expected-boot-r15-process.txt` — same position.

The witness failure message is `R16 TMPFS CREATE FAIL`; both strings
land in `tools/boot_stub.S` immediately after the
`tmpfs_lookup_*_msg` pair (~line 534).

## 10. Boot integration

Witness is inserted in `kernel_main.pdx` between
`tmpfs_lookup_witness_done` (line 2434) and the `wrmsr` for GS_BASE
(line 2437). Insertion point avoids any interaction with the process
subsystem (whose init runs immediately after). The state mutation
this witness makes (creating "/tmp/x" and threading it into /tmp's
child chain) is preserved through subsequent boot — no downstream
code depends on /tmp being empty, and any code that walks /tmp's
child chain (there is none at this point in kernel_main) would
correctly see the "/tmp/x" entry.

Rough kernel_main.pdx delta:

```asm
      tmpfs_lookup_witness_done:

      // ============================================================
      // R16-M2-004 (#582): tmpfs_create witness — 4 sub-tests, 1 marker
      // ============================================================
      tmpfs_create_witness:
          // ---------- Sub-test A: create returns non-zero new_idx ----------
          // ... (see §9.2)
          // ---------- Sub-test B: lookup returns the created idx ----------
          // ... (see §9.3)
          // ---------- Sub-test C: /tmp.first_child == new_idx ----------
          // ... (see §9.4)
          // ---------- Sub-test D: new inode fields correct ----------
          // ... (see §9.5)

          lea  rdi, [rip + tmpfs_create_ok_msg]
          call uart_puts
          jmp  tmpfs_create_witness_done

      tmpfs_create_witness_fail:
          lea  rdi, [rip + tmpfs_create_fail_msg]
          call uart_puts

      tmpfs_create_witness_done:

      // R14b-m5-002 (#507): IA32_GS_BASE = &_cpu_locals[0] on CPU0.
      lea rax, [rip + _cpu_locals];
      ...
```

## 11. Cross-references

- Issue: paideia-os#582
- Milestone: R16.M2 (tmpfs — in-memory VFS backend)
- Upstream:
  - paideia-os#579 (R16-M2-001 — frozen layout §2; every offset here
    is exported from `inode.pdx`).
  - paideia-os#580 (R16-M2-002 — `tmpfs_inode_alloc` primitive we call;
    `tmpfs_init` pattern we mirror for field-store discipline).
  - paideia-os#581 (R16-M2-003 — `tmpfs_lookup` we call for the
    collision probe; also §6 of that doc predicted this issue would
    consume the walker).
- Downstream consumers:
  - #583 (`tmpfs_unlink` — inverse; scans + splices out. Its
    correctness depends on the "every reachable child has valid
    next_sibling" invariant this issue writes.)
  - A follow-on R16.M3 issue (tmpfs vops table — registers a thin
    adapter that reads `dir_vn.backend_ptr` (+32) as the inode idx
    and forwards to `tmpfs_create` after computing `name_len` from
    the passed name).
  - `vops_create` (a follow-on R16.M3 issue — the vops dispatch stub;
    reaches this writer via the adapter mentioned above).
  - R17 `sys_create` / `sys_open(O_CREAT)` — user-facing syscall that
    reaches this primitive through the vops chain.
- Sibling primitive: `mount.pdx` (#571) has a similar
  "populate-then-splice" shape for vnode allocation into the mount
  table. Different domain (mount points, not directory entries) but
  same design DNA.
- Tactical plan: `design/milestones/r14b-tactical-plan.md` §Subsystem
  12 item 4 — "Alloc inode from pool, insert into parent's dentry
  list. Acceptance: create /tmp/x; subsequent lookup returns it."
