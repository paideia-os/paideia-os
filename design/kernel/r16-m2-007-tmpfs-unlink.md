---
issue: 585
milestone: R16.M2 (tmpfs — in-memory VFS backend)
subsystem: 12 — tmpfs
topic: tmpfs_unlink — splice + page release + inode release (R16-M2-007)
freeze-discipline: strict
  - tmpfs inode layout frozen by R16-M2-001 (#579); this issue reads from
    frozen offsets `+0` (type, u8) and `+178`/`+180` (chain lanes at
    +176 u64), and writes into `+178`/`+180` on splice. Data-page release
    reads `+16..+144` (page_ptrs[16], u64*16). Inode-slot release zeros
    the full 256 bytes via `rep_stosq`. All offsets sourced from the
    exported constants in `inode.pdx`; no numeric offset embedded here.
  - `tmpfs_unlink` signature `(u64, u64) -> u64` — `(dir_idx, name_ptr)
    -> 0_or_error_sentinel` — completes the R16.M2 primitive quartet
    (create / lookup / write / read / unlink). The failure sentinel
    is `0xFFFFFFFFFFFFFFFF` to match `tmpfs_write`, `tmpfs_read`, and
    `phys_free`; success is exactly `0`. The `tmpfs_create` /
    `tmpfs_lookup` "0-on-failure" convention is inverted here because
    a returning-inode function needs 0 as the null sentinel, whereas
    a returning-status function has 0 as the success value. Both
    conventions are stable across the milestone.
  - `tmpfs_inode_free(idx) -> u64` lands as a **new leaf primitive** in
    `inode.pdx` alongside `tmpfs_inode_slot` and `tmpfs_inode_alloc`.
    It clears the slot's bitmap bit and zeros the 256-byte slot payload,
    preserving the `.bss`-zero invariant that `tmpfs_create` §7.3 relies
    on for `page_ptrs[16]` when the same slot is later re-allocated.
    Mirrors `vnode_free` (#571).
  - Splice-then-release ordering: the sibling-chain splice must complete
    before any data-page or inode-slot release, so no walker can ever
    observe a chain node pointing at freed memory. This ordering is
    lock-free-safe for the future single-writer / multi-reader FS-lock
    at R17 (see §4.7 for the argument).
  - Data-page release cannot reuse the write-side lazy contract: pages
    populated by `tmpfs_write` came from `phys_alloc(0)` and are freed
    via `phys_free(page_va, 0)` (#649). No refcount arithmetic at
    R16.M2 — every allocated data page has refcount = 1 (single owner),
    so `phys_free` monotonically clears the bitmap bit. R17 shared-page
    semantics may bump refcounts, at which point `phys_free`'s built-in
    decrement handles the sharing correctly (see phys_free.pdx §4).
blocks:
  - "R16.M3 tmpfs vops table (`tmpfs_vops` — registers a wrapper
    adapting `tmpfs_unlink(dir_inode_idx, name_ptr)` to the vops
    shape `(dir_vnode_ptr, name_ptr)` by reading the vnode's
    `backend_ptr` (+32) as the inode idx.)"
  - "R17 `sys_unlink` syscall — user-facing entry point that reaches
    this primitive through the vops chain. Depends on this issue's
    error-sentinel contract for POSIX-shaped `ENOENT` translation."
  - "A follow-on `tmpfs_rmdir` issue — same shape as `tmpfs_unlink`
    but with an extra `dir.first_child == 0xFFFF` empty-dir precondition.
    Will fork out of this file's inline walker + splice pattern."
touching:
  - src/kernel/core/fs/tmpfs/unlink.pdx        (new module — `tmpfs_unlink`; ~130 LOC)
  - src/kernel/core/fs/tmpfs/inode.pdx         (add `tmpfs_inode_free` leaf; ~50 LOC)
  - src/kernel/boot/kernel_main.pdx            (witness block ~80 LOC)
  - tools/boot_stub.S                          (2 message strings; ~10 LOC)
  - tests/r14b/expected-boot-r14b-loader.txt   (marker: "R16 TMPFS UNLINK OK")
  - tests/r15/expected-boot-r15-ring3.txt      (marker)
  - tests/r15/expected-boot-r15-process.txt    (marker)
  - design/kernel/r16-m2-007-tmpfs-unlink.md   (this doc)
related:
  - design/kernel/r16-m2-001-tmpfs-inode-pool.md  (#579 — frozen layout §2;
    every field offset this module touches is exported by `inode.pdx`.
    §7.3 of that doc reserves bit-0 of the bitmap as the sentinel that
    tmpfs_inode_free must **never** clear; §4 covers slot indexing.)
  - design/kernel/r16-m2-002-tmpfs-init.md        (#580 — narrow-store
    discipline used for the two splice writes (`mov_w [reg + disp32], reg`
    at +178 and +180). tmpfs_inode_alloc's leaf shape is the direct
    counterpart for the tmpfs_inode_free leaf added here.)
  - design/kernel/r16-m2-003-tmpfs-lookup.md      (#581 — the walker
    called from Phase A of this module. §4 chain-scan and NUL-termination
    logic is inherited verbatim; this module's Phase B walker duplicates
    the *chain* traversal but skips the strncmp — replaced by a
    `next_sibling == target_idx` probe.)
  - design/kernel/r16-m2-004-tmpfs-create.md      (#582 — the inverse.
    §4.8 "insert-at-head" is undone by this module's §4.5 "splice-out";
    §7.4 "post-success dir chain is well-formed" is preserved by
    §4.7 of this doc.)
  - src/kernel/core/mm/phys_free.pdx              (#649 — the underlying
    page-release primitive. Handles VA/PA normalization at the boundary;
    accepts kernel-VA form from `page_ptrs[i]`. Idempotent on
    double-free; refcount-aware.)
  - src/kernel/core/fs/vnode_pool.pdx             (#571 — the pattern
    template for `tmpfs_inode_free`: `btr_q` for bit-clear + unrolled
    slot zero. tmpfs_inode_free adopts the same shape but uses
    `rep_stosq` for the 256-byte payload (vs. vnode's 64-byte unrolled).)
  - design/milestones/r14b-tactical-plan.md       §Subsystem 12 item 7 —
    "Not required for shell demo but useful. Release inode + pages.
    Acceptance: unlink → subsequent lookup miss."
---

# R16-M2-007 — `tmpfs_unlink` (splice + release, #585)

## 1. Scope

Ship the tmpfs directory-mutation primitive that removes a `(dir_idx,
name)` binding from a directory's sibling chain and releases the
target inode's backing memory. Given a parent directory index and a
byte buffer with the name, `tmpfs_unlink`:

1. Type-gates the parent inode (must be `VNODE_TYPE_DIR`),
2. Locates the target inode via `tmpfs_lookup`,
3. Walks the parent's sibling chain a second time to find the target's
   predecessor (`prev`),
4. Splices the target out of the chain (head-case rewrites
   `dir.first_child`; middle-case rewrites `prev.next_sibling`),
5. Releases every non-zero page in the target's `page_ptrs[16]` back
   to the physical allocator via `phys_free(page_va, 0)`,
6. Releases the target's inode slot via `tmpfs_inode_free(idx)`
   (new leaf; clears bitmap bit, zeros the 256-byte payload),
7. Returns `0`.

Concretely:

- **Enter** with `rdi = dir_inode_idx` (u64 with u16 semantics),
  `rsi = name_ptr` (u64, points at a NUL-terminated byte buffer). No
  bounds pre-check on `dir_inode_idx` — callers arrive through
  `tmpfs_init`'s pinned root/tmp indices or `tmpfs_lookup`'s validated
  return.
- **Type gate.** Load the directory inode's `type` byte at `+0`;
  if it is not `VNODE_TYPE_DIR`, return the error sentinel without
  touching anything. Zero-cost defense against callers that hand us
  a regular-file index (nothing else could look like a valid unlink
  target).
- **Locate.** Call `tmpfs_lookup(dir_idx, name_ptr)`. If it returns
  `0`, the name is not present and we return the error sentinel.
  This is the acceptance criterion's inverse: "unlink → subsequent
  lookup miss" implies "unlink of missing name is an error."
- **Prev-find walker.** Read `dir.first_child` from `dir_ptr + 180`
  (u16, extracted from `[dir_ptr + 176]` via the same `shr 32 + and
  0xFFFF` idiom used in `tmpfs_lookup` §4.2 and `tmpfs_create` §4.8).
  If `first_child == target_idx`, the target is at the head — record
  `prev_idx = 0xFFFF` as the sentinel "no prev; write into
  dir.first_child instead." Otherwise, walk the chain via
  `next_sibling` reads, testing each `cur.next_sibling == target_idx`;
  when it hits, `prev_idx = cur_idx`.
- **Splice.** Read `target.next_sibling` at `+178` (u16). Then:
  - If `prev_idx == 0xFFFF`: write `next_sibling` into
    `[dir_ptr + 180]` (dir.first_child slot).
  - Else: write `next_sibling` into `[prev_ptr + 178]`
    (prev.next_sibling slot).
  After this write, no future chain walker can reach `target_idx`.
- **Page release.** Loop `i in [0, 16)`; for each `page_ptrs[i]` that
  is non-zero, call `phys_free(page_va, 0)`. Ignore the return
  value at R16.M2 (phys_free is idempotent and range-guarded; any
  failure indicates a bug elsewhere, but tmpfs_unlink is not the
  layer to diagnose it).
- **Inode release.** Call `tmpfs_inode_free(target_idx)` — the new leaf
  clears the bitmap bit and zeros the 256-byte slot payload,
  restoring the `.bss` invariant for future re-allocation.
- **Return** `0` in `rax`.

Out of scope (deliberately deferred):

- **Not `rmdir`.** `tmpfs_unlink` refuses to unlink a directory — the
  type gate is on the **parent**, not the target, but the target's
  own type is checked implicitly: if the target is a directory that
  still has children, the child chain gets orphaned when we free the
  inode slot. R16.M2 avoids this by policy: **callers must not pass
  a directory name** at the tmpfs layer. R17's `sys_unlink` /
  `sys_rmdir` translation layer will enforce this at the vops
  boundary. A follow-on `tmpfs_rmdir` issue adds the empty-child-chain
  precondition; until then, calling `tmpfs_unlink` on a directory
  name is a caller-side bug (documented in §5.5).
- **No refcount decrement / open-file guard.** POSIX-shaped unlink
  under an active open marks the inode "orphan" until the last close.
  R16.M2 has no `fd_table` sharing (single-writer runtime) and no
  refcount-arbitration at the tmpfs layer, so unlink is unconditional.
  When R17 lands file descriptors, this module gains a
  `refcount > 0 → mark-orphan-defer-free` branch. The current
  return-0-success semantic remains stable through that change; only
  the internal free-vs-defer decision changes.
- **No vnode-side dispatch.** `tmpfs_unlink` is the tmpfs-layer
  primitive; the vops-side function `vops_unlink(dir_vn, name_ptr)`
  is dispatched by `vops.pdx` (#572) and reaches this writer via an
  adapter registered at R16.M3.
- **No page-sharing / COW awareness.** Every page freed here comes
  from a `tmpfs_write` on this same inode (single-owner invariant at
  R16.M2). `phys_free` gracefully handles the refcount-shared case
  when R17 introduces sharing, but tmpfs_unlink does not need to
  reason about it.
- **No inode-orphan reachability.** Because splice completes before
  page release, no walker can observe a spliced-out target through
  the chain. Callers that stash a raw `target_idx` from a prior
  `tmpfs_lookup` and dereference it after our return will see zeros
  (post-`tmpfs_inode_free`). This is a "don't hold stale inode idxs
  across unlink" contract; the vops layer will enforce it via
  vnode refcounts at R16.M3.

## 2. Contract

```
tmpfs_unlink : (u64, u64) -> u64 !{mem} @{}
  → rax = 0                            on success
  → rax = 0xFFFFFFFFFFFFFFFF           on failure (bad parent type,
                                                    name miss)
```

Nullary on capabilities at R16.M2 (see §1 out-of-scope). `!{mem}`
because we mutate the frozen `_tmpfs_inode_pool` slab (target slot
zeroed, dir/prev sibling lane rewritten), the `_tmpfs_inode_bitmap`
(target bit cleared), and — indirectly, via `phys_free` — the
`_phys_pool_bitmap` (page bits cleared).

**Non-leaf.** Makes nested calls to `tmpfs_inode_slot` (three times
minimum: dir_ptr at type gate, target_ptr for splice-source read +
page loop base, plus once per walker iteration for cur_ptr;
prev_ptr on splice if head-case fails), `tmpfs_lookup` (once, for
target-idx acquisition), `phys_free` (0..16 times), and
`tmpfs_inode_free` (once). Five-push callee-save prologue matches
`tmpfs_create` and `tmpfs_write`.

**Failure collapse.** The two failure modes (parent-not-a-directory,
name-miss) both collapse to `rax = 0xFFFFFFFFFFFFFFFF`. Callers that
need to distinguish must probe via `tmpfs_lookup` first — but no
such caller is planned in the R16 series. The vops layer will
translate at R18+ under POSIX-shaped `-ENOTDIR` / `-ENOENT`.

**Idempotence.** Not idempotent: calling `tmpfs_unlink` twice with the
same `(dir_idx, name)` triple returns `0` the first time and the
error sentinel the second time (the second `tmpfs_lookup` misses).
Callers relying on "try-unlink; success even if absent" must probe
first — a two-syscall pattern at R17.

**Ordering guarantee.** On success, the caller observes:
(a) chain splice complete, (b) data pages fully released, (c) inode
slot fully released. On failure, the pool is byte-identical to the
pre-call state (both failure paths fire before any store; see §5.6).
No intermediate window exists in which a chain walker could reach a
freed inode: splice fires before any release. Under R17
single-writer / multi-reader concurrency, this preserves reader
safety (the "no reader observes freed memory through the chain"
invariant).

## 3. Register discipline

### 3.1 Push plan — 5 pushes

Five-push callee-save prologue: `rbx`, `r12`, `r13`, `r14`, `r15`. On
SysV AMD64, `rsp mod 16 == 8` at prologue entry (call pushed the
return address from a 16-aligned rsp). Five pushes add `5 * 8 = 40`
bytes, so `rsp mod 16 == 0` at every nested call site. Matches the
alignment requirement uniformly with `tmpfs_create`, `tmpfs_write`,
and `tmpfs_read`.

An alternative 4-push plan (drop r15) was considered and rejected:
this function must hold five distinct live-across-call values
(dir_idx, name_ptr, target_idx, target_ptr, walker_cursor). Dropping
one forces a reload, and there is no readily-reloadable source for
any of them (name_ptr could be recomputed from stack, but that costs
push/pop pairs that offset the saved push, so no net gain).

| Reg | Role                                                                 |
|-----|----------------------------------------------------------------------|
| rbx | `dir_idx` — caller's arg1, saved on entry. Read at the type-gate `tmpfs_inode_slot(dir_idx)` call, the `tmpfs_lookup(dir_idx, name_ptr)` call, and the second `tmpfs_inode_slot(dir_idx)` call at splice time (to obtain dir_ptr for the head-case first_child write). Also read once inside the walker as the base for `dir.first_child` read. Must survive every nested call. |
| r12 | `name_ptr` — caller's arg2, saved on entry. Read exactly once, at the `tmpfs_lookup(dir_idx, name_ptr)` call in Phase A. After that call returns, name_ptr is semantically dead — its value is not read again, but r12 stays occupied to preserve the 5-push alignment. (Repurposing r12 would need a stack-based reload of walker state; not worth it for one dead register.) |
| r13 | `target_idx` — result of `tmpfs_lookup`, saved into r13 the moment it lands. Read at the walker's `cur.next_sibling == target_idx` termination test, at the `tmpfs_inode_slot(target_idx)` call for target_ptr, and at the final `tmpfs_inode_free(target_idx)` call. Must survive every intervening call. |
| r14 | `target_ptr` — result of `tmpfs_inode_slot(target_idx)`. Read at the `target.next_sibling` extraction (source of the splice write) and throughout the page-release loop (base for `page_ptrs[i]` reads). Must survive every `phys_free` call in the page loop, but is semantically dead after the loop ends. Repurpose to *page-loop counter* would need a re-slot lookup; kept as target_ptr through the loop and let the counter live in r15. |
| r15 | **Morphing role.** Initially holds `cur_idx` during Phase-B walker (walker cursor tracking predecessor candidates). At walker exit, r15 holds either `0xFFFF` (head case: no prev) or the actual `prev_idx` (middle case). After splice, r15 is repurposed as the **page-loop counter** (0..15), because prev_idx is semantically dead after the splice write completes. Second morph point at the page loop's first instruction: `xor r15, r15` (reset to 0 for the loop counter). |

### 3.2 Why the r15 double-morph, not a 6th push

A cleaner design would push a 6th register to hold the page-loop
counter separately from the walker cursor. Rejected:

1. **Alignment.** 6 pushes gives `rsp mod 16 == 8` at nested call
   sites, breaking the SysV rule. Would need a `sub rsp, 8` pad
   before every `call`, costing four extra instructions.
2. **Walker cursor is single-lifetime.** After splice, prev_idx is
   never read again — the write phase used it. The page counter
   likewise is only read during the loop; before the loop it does
   not exist. The morph re-uses r15's slot for two disjoint
   lifetimes, which is the exact pattern `tmpfs_create` uses for r15
   (type → new_ptr).

### 3.3 Scratch registers

The walker inner loop uses `rax` (target of `tmpfs_inode_slot` return
for cur_ptr), `rcx` (u64 load of `cur.next_sibling` lane at +176,
then extracted via shr 16 + and 0xFFFF). None survive nested calls.

The splice phase uses `rax` (dir_ptr / prev_ptr from
`tmpfs_inode_slot`), `rcx` (target.next_sibling value). The
head-case branch reads `rbx = dir_idx` again to re-call
`tmpfs_inode_slot`.

The page-release loop uses `rdi` (page_va argument to `phys_free`),
`rsi` (order=0 argument), and `rax` (page_ptrs base pointer, hoisted
inside the loop each iteration since r14 must survive the call). No
scratch register survives the `phys_free` call — r14 (target_ptr)
and r15 (counter) are callee-saved and preserved by the call.

## 4. Algorithm

### 4.1 Prologue + arg stash

```asm
tmpfs_unlink:
    push rbx
    push r12
    push r13
    push r14
    push r15                            ; rsp%16 = 0

    mov  rbx, rdi                       ; rbx = dir_idx
    mov  r12, rsi                       ; r12 = name_ptr
```

`r13 = target_idx` set later after `tmpfs_lookup`. `r14 = target_ptr`
set later after `tmpfs_inode_slot(target_idx)`. `r15 = cur_idx`
(walker cursor) set later at walker entry.

### 4.2 Directory type gate

```asm
    ; --- Type-gate parent: dir.type at +0 must be VNODE_TYPE_DIR (2) ---
    mov  rdi, rbx
    call tmpfs_inode_slot               ; rax = dir_ptr
    xor  rcx, rcx
    mov_b rcx, [rax + 0]                ; rcx = dir.type
    cmp  rcx, 2                         ; VNODE_TYPE_DIR
    jne  tmpfs_unlink_fail              ; parent is not a directory
```

Same shape as `tmpfs_create` §4.2. Cheap `O(1)` check that pre-guards
the more expensive lookup.

### 4.3 Phase A — locate target via tmpfs_lookup

```asm
    ; --- Locate: tmpfs_lookup(dir_idx, name_ptr) ---
    mov  rdi, rbx
    mov  rsi, r12
    call tmpfs_lookup                   ; rax = target_idx or 0
    cmp  rax, 0
    je   tmpfs_unlink_fail              ; name not present
    mov  r13, rax                       ; r13 = target_idx (survives all nested calls)
```

Reuses the proven walker. On miss, tmpfs_lookup returns `0` and we
propagate as the error sentinel. On hit, we know target is somewhere
in the parent's sibling chain — Phase B is guaranteed to terminate.

### 4.4 Phase B — walker to find prev

```asm
    ; --- Read dir.first_child (from dir's u64 @+176, bits [32, 48)) ---
    mov  rdi, rbx
    call tmpfs_inode_slot               ; rax = dir_ptr
    mov  rcx, [rax + 176]
    shr  rcx, 32
    and  rcx, 0xFFFF                    ; rcx = dir.first_child

    ; --- Head-case shortcut: if dir.first_child == target_idx, prev is virtual ---
    cmp  rcx, r13
    je   tmpfs_unlink_head_splice       ; prev_idx = 0xFFFF; jump straight to splice

    ; --- Walker: find cur such that cur.next_sibling == target_idx ---
    mov  r15, rcx                       ; r15 = cur_idx (starts at first_child)

  tmpfs_unlink_walker:
    ; cur_idx cannot be 0xFFFF here: tmpfs_lookup returned target_idx as a
    ; hit, so target is reachable from first_child. The head case above
    ; consumed the "target IS first_child" branch. Every iteration below
    ; either matches or advances to a valid next_sibling.
    mov  rdi, r15
    call tmpfs_inode_slot               ; rax = cur_ptr
    mov  rcx, [rax + 176]
    shr  rcx, 16
    and  rcx, 0xFFFF                    ; rcx = cur.next_sibling
    cmp  rcx, r13                       ; is cur the predecessor?
    je   tmpfs_unlink_mid_splice        ; found — r15 holds prev_idx
    mov  r15, rcx                       ; advance cursor
    jmp  tmpfs_unlink_walker
```

**Walker termination invariant.** Because `tmpfs_lookup` succeeded,
`target_idx` is somewhere in the chain. Two cases:

1. Target is at the head (`dir.first_child == target_idx`) — caught by
   the head-case shortcut above the loop.
2. Target is at position ≥ 1. Some cur in the chain has
   `cur.next_sibling == target_idx`. The walker will find it in
   ≤ `TMPFS_MAX - 1` iterations.

There is no way to fall off the chain end (`next_sibling == 0xFFFF`
past the target's position): the chain is well-formed
(`tmpfs_create` §7.4 invariant), and target is present in it. So
the walker doesn't need an "end of chain" guard.

**Belt-and-braces guard rejected.** A defensive `cmp r15, 0xFFFF; je
tmpfs_unlink_fail` inside the walker would catch a corrupted chain
where target vanished between tmpfs_lookup and Phase B — but such
corruption is impossible at R16.M2 (single-writer). Adding the guard
costs two instructions per iteration for zero R16.M2 benefit. R17
concurrency will add an FS lock around the whole unlink, at which
point the corruption is still impossible (walker runs under the same
lock as the lookup). So no guard needed.

### 4.5 Splice — head case

```asm
  tmpfs_unlink_head_splice:
    ; --- Head case: dir.first_child was target_idx; rewrite it. ---
    ; Need target.next_sibling and dir_ptr. dir_ptr is still in rax
    ; from §4.4's tmpfs_inode_slot call — but tmpfs_lookup was called
    ; between then and now (Phase A). rax is not preserved. So we
    ; re-call. r14 not yet loaded.
    mov  rdi, r13
    call tmpfs_inode_slot               ; rax = target_ptr
    mov  r14, rax                       ; r14 = target_ptr (survives phys_free later)

    ; Load target.next_sibling from bits [16, 32) of u64 @+176.
    mov  rcx, [r14 + 176]
    shr  rcx, 16
    and  rcx, 0xFFFF                    ; rcx = target.next_sibling

    ; Get dir_ptr for the first_child write.
    mov  rdi, rbx
    call tmpfs_inode_slot               ; rax = dir_ptr

    ; Write target.next_sibling into dir.first_child at +180.
    mov_w [rax + 180], rcx
    jmp  tmpfs_unlink_release
```

### 4.6 Splice — middle case

```asm
  tmpfs_unlink_mid_splice:
    ; --- Middle case: r15 = prev_idx. ---
    mov  rdi, r13
    call tmpfs_inode_slot               ; rax = target_ptr
    mov  r14, rax

    ; target.next_sibling from bits [16, 32) of u64 @+176.
    mov  rcx, [r14 + 176]
    shr  rcx, 16
    and  rcx, 0xFFFF                    ; rcx = target.next_sibling

    ; prev_ptr = tmpfs_inode_slot(prev_idx).
    mov  rdi, r15
    call tmpfs_inode_slot               ; rax = prev_ptr

    ; Write target.next_sibling into prev.next_sibling at +178.
    mov_w [rax + 178], rcx
    ; fall through to tmpfs_unlink_release
```

### 4.7 Splice ordering safety (informational)

At every intermediate point in the splice writes, the chain remains
well-formed for any single-writer / multi-reader concurrent walker:

- **Head case, after `mov_w [dir_ptr + 180], rcx`:**
  `dir.first_child = target.next_sibling`. A walker starting at the
  new first_child sees the sub-chain that used to follow target.
  Target itself is unreachable via the chain. No memory yet freed.

- **Middle case, after `mov_w [prev_ptr + 178], rcx`:**
  `prev.next_sibling = target.next_sibling`. A walker crossing prev
  bypasses target directly. Target itself is unreachable via the chain.
  No memory yet freed.

Every reader that started iteration **before** the splice write and
happened to be sitting on target when we wrote is holding a raw
`cur_idx = target_idx` — that's the "held stale idx across unlink"
scenario documented in §1. Under R17 vnode-refcount-shared reads
this window closes: the vops layer bumps target's vnode refcount
before the reader entered the chain scan, and this unlink's
`tmpfs_inode_free` call gets deferred (see §1 out-of-scope
refcount-decrement discussion). At R16.M2 single-threaded, the
window doesn't exist.

### 4.8 Data-page release loop

Both splice branches converge at `tmpfs_unlink_release`. r14 =
target_ptr, r13 = target_idx (still needed for the final
tmpfs_inode_free call), r15 becomes the loop counter.

```asm
  tmpfs_unlink_release:
    ; --- Loop counter in r15 (survives phys_free) ---
    xor  r15, r15                       ; r15 = i = 0

  tmpfs_unlink_page_loop:
    cmp  r15, 16                        ; page_ptrs has 16 slots
    jae  tmpfs_unlink_pages_done

    ; --- Load page_ptrs[i] ---
    lea  rax, [r14 + 16]                ; rax = &page_ptrs[0]
    mov  rdi, [rax + r15*8]             ; rdi = page_ptrs[i]
    cmp  rdi, 0
    je   tmpfs_unlink_page_next         ; slot empty — skip

    ; --- phys_free(page_va, order=0) ---
    xor  rsi, rsi                       ; order = 0
    call phys_free                      ; ignore rax (idempotent)

  tmpfs_unlink_page_next:
    add  r15, 1
    jmp  tmpfs_unlink_page_loop

  tmpfs_unlink_pages_done:
```

**Why hoist `lea rax, [r14 + 16]` inside the loop.** rax is
caller-saved and clobbered by `phys_free`. Recomputing the base
each iteration is cheaper (single `lea`) than saving/restoring
another callee-save register. r14 is preserved by SysV so the base
is always available.

**Ignoring `phys_free`'s return.** At R16.M2, `phys_free` returns 0
on success and `PHYS_FREE_INVALID` (`-1`) on unsupported order or
out-of-pool address. Order is fixed at 0 (a pinned invariant), and
every `page_va` in `page_ptrs[]` came from `phys_alloc(0)` and is
therefore in-pool. A non-zero return here would indicate a bug
elsewhere (page pool corruption, VA/PA mismatch); tmpfs_unlink is
not the layer to diagnose it. A future R17 audit hook may add a
`kernel_panic` on unexpected non-zero, but the R16.M2 policy is
"trust phys_free and continue."

### 4.9 Inode-slot release

```asm
    ; --- tmpfs_inode_free(target_idx) — clears bitmap bit + zeros slot ---
    mov  rdi, r13
    call tmpfs_inode_free
```

After this call, `target_idx`'s bitmap bit is 0 (slot is available
for future `tmpfs_inode_alloc`) and the 256-byte payload at
`&_tmpfs_inode_pool[target_idx]` is fully zeroed (restoring the
`.bss` invariant on `page_ptrs[16]` that `tmpfs_create` §7.3 relies
on for the next allocation into this slot).

### 4.10 Epilogue

```asm
    xor  rax, rax                       ; success = 0
    jmp  tmpfs_unlink_done

  tmpfs_unlink_fail:
    mov  rax, 0xFFFFFFFFFFFFFFFF        ; error sentinel

  tmpfs_unlink_done:
    pop  r15
    pop  r14
    pop  r13
    pop  r12
    pop  rbx
    ret
```

Total body instruction count: ~75 in the primary body plus ~10 in
the prologue/epilogue plus the ~10 walker inner loop. Roughly 95
instructions of body, matching a ~130-LOC estimate (assembly plus
one comment per line plus the module wrapper).

## 5. Failure paths and side-effect discipline

All two failure modes route to `tmpfs_unlink_fail` before any pool
mutation, giving the "atomic on failure" property described in §2.

### 5.1 Failure inventory

| Failure                | Detected at                          | Pool state after |
|------------------------|--------------------------------------|-----------------|
| Parent not a directory | §4.2 `cmp rcx, 2; jne`               | Unchanged.       |
| Name not present       | §4.3 `cmp rax, 0; je`                | Unchanged.       |

Neither failure path reaches Phase B / splice / release, so no
sibling chain or bitmap bit is mutated on either.

### 5.2 Why type-gate before lookup

The type-gate is `O(1)` (one byte load); the lookup is
`O(fan-out)` (chain scan). Doing the cheap gate first
short-circuits the pathological "unlink under a regular file"
caller.

### 5.3 Why one lookup + one walker, not one combined pass

An alternative inlines a single walker that tracks
`(prev_idx, cur_idx)` and does the strncmp inline (avoiding the
Phase-A `tmpfs_lookup` call). Rejected:

1. **Code duplication.** The strncmp inner loop is ~15 assembly
   instructions inside `tmpfs_lookup`. Copying it into `unlink.pdx`
   creates two callers (lookup, unlink) of the same encoder shape
   with no shared implementation; any encoder tweak to strncmp
   (e.g., a `mov_b` variant swap) must land in two places.
2. **Encoder surface unchanged.** All shapes used by the
   `tmpfs_lookup + inline Phase-B walker` split are already proven.
   The combined-pass variant adds no new shapes; just duplicates
   proven ones.
3. **Marginal cost.** Two chain scans are `O(2 * fan-out)`; at
   R16.M2 fan-out ≤ 1 (only `/tmp/x` in `/tmp`), so the doubled
   walk is 4 iterations vs. 2 iterations. Both are negligible.

Kept as future micro-op if `perf` ever flags tmpfs_unlink; the
lookup call in Phase A is the natural fusion point.

### 5.4 Why splice before release

Splice-first ordering is a **hard correctness requirement**, not an
optimization: it makes the "no walker can reach freed memory"
invariant compositional. Under the reverse ordering
(release-then-splice), a concurrent walker holding `cur_idx =
target_idx` and about to load `cur_ptr` would see freed memory (or
zeroed slot post-`tmpfs_inode_free`) between the release and the
splice. Splice-first makes the target unreachable **before** any
memory changes state.

At R16.M2 single-threaded, no concurrent walker exists, so the
"correctness" reduces to "self-consistency": tmpfs_unlink itself
doesn't re-walk the chain after splice, so either ordering is
observably identical from the caller's perspective. The
splice-first policy is chosen anyway because R17 concurrency needs
it and there's no reason to introduce a temporary ordering that
must be undone later.

### 5.5 Directory-unlink caller-side bug

If a caller passes a directory name (e.g., `tmpfs_unlink(root_idx,
"tmp")`), the type gate on the parent passes (root is DIR), lookup
succeeds (tmp is present), and we splice + release /tmp. Its
child chain — currently empty at R16.M2, but non-empty at R16.M3+ —
is orphaned. Bitmap bits for orphaned children remain set (they were
allocated), but the slots are unreachable via any chain walk.

R16.M2 policy: this is a **caller-side bug**, documented but not
guarded. Two reasons:

1. **No target-type gate at R16.M2.** Adding
   `cmp target.type, VNODE_TYPE_DIR; je tmpfs_unlink_fail` costs
   two instructions. It's zero-cost defensively but changes the
   contract from "unconditional" to "regular-files-only," which
   the R17 syscall design may not want (POSIX `sys_unlink` allows
   directory-descriptor-unlink for empty directories under certain
   flags).
2. **The vops layer will enforce.** R17's `sys_unlink` /
   `sys_rmdir` split enforces the target-type policy at the syscall
   boundary. Once that's live, tmpfs_unlink's contract stays
   "unconditional at the primitive level," and syscall glue picks
   the right primitive. Kept clean.

If a future test regression traces to this class of bug, add the
target-type guard as a follow-on issue; the encoder shapes are all
proven and the two instructions fit at line 4.2's end.

### 5.6 Failure preserves the pool byte-identically

Both failure paths return before any store into
`_tmpfs_inode_pool`, `_tmpfs_inode_bitmap`, or the phys pool. The
one `tmpfs_inode_slot` call before either failure decision is a
pure address computation (`shl` + `add`); it does not touch pool
memory. The one `tmpfs_lookup` call before the name-miss failure
is `!{mem}` on the read side only (r16-m2-003 §2 contract). No
mutation.

## 6. Alternatives considered

### 6.1 Reference-counted unlink (defer free until refcount == 0)

**Proposal.** Read `target.refcount`; if > 1, decrement and return
success without releasing (defer to the last close). If == 1,
release as normal.

**Rejected for R16.M2.** No caller bumps refcount above 1 today —
the R16.M2 open path (which does not yet exist) would set it to 1
initially, and there's no shared-fd or dup2 syscall. Deferred to
the R17 `fd_table` design, at which point the branch is a
2-instruction addition here.

### 6.2 One-pass walker (inline strncmp)

Covered in §5.3. Rejected — duplicates the strncmp shape.

### 6.3 Skip page-release loop (leak pages)

**Proposal.** Skip the page loop entirely; call `tmpfs_inode_free`
directly. Simplifies the module by ~15 lines.

**Rejected.** Slot re-allocation would inherit stale `page_ptrs[i]`
values (because `tmpfs_inode_free` zeros the slot — so actually no,
it wouldn't). But the physical pages themselves would leak: their
bits in `_phys_pool_bitmap` stay set forever, exhausting the phys
pool after 1024 unlink cycles. The R17 shell demo will not survive
1024 unlinks, but the `phys_free` call is `O(1)` per page and the
loop is `O(16)` per unlink — pennies on the dollar. Leak-free is
free.

### 6.4 Zero-fill `page_ptrs[i]` after `phys_free`

**Proposal.** After `phys_free(page_va, 0)`, also write `0` into
`page_ptrs[i]` to remove the stale reference from the inode.

**Rejected.** `tmpfs_inode_free` zeros the whole 256-byte slot,
which includes `page_ptrs[]`. Zeroing per-slot in the loop
duplicates the work that `tmpfs_inode_free`'s `rep_stosq` already
does in ~5 instructions total. Kept as an idea if
`tmpfs_inode_free` ever stops zeroing the slot (unlikely).

### 6.5 Inline `tmpfs_inode_free` (fold into unlink)

**Proposal.** Merge the bitmap-clear + slot-zero into unlink;
skip the separate leaf primitive.

**Rejected.** Two reasons:

1. **Reusability.** A future `tmpfs_rmdir` needs the same
   primitive; likewise any error-path recovery in an extended
   `tmpfs_create` (§7.3 discussion in r16-m2-004). Extracting the
   leaf now avoids a copy-paste inline.
2. **Testability.** The witness's sub-test D (verify bitmap bit is
   cleared) is a direct probe of `tmpfs_inode_free`'s effect;
   naming it as a separate primitive makes the test intention
   crisp.

### 6.6 Btr-based bitmap clear vs. shl/xor/and

**Proposal.** Clear the bit in `tmpfs_inode_free` via the manual
`mov rdx, 1; shl rdx, cl; xor rdx, -1; and word, rdx` sequence
used by `phys_free`.

**Rejected.** `btr_q` (register form, W64) is proven for this
codebase (vnode_pool.pdx line 121 clears a bit exactly this way,
line 85 sets one via bts_q). One instruction vs. four. No
encoder work.

### 6.7 Slot-zero via unrolled stores vs. rep_stosq

**Proposal.** Zero the 256-byte slot via 32x unrolled
`mov [r8 + N], rax` stores (with `rax = 0`), mirroring
`vnode_free`'s 8x unroll.

**Rejected.** `rep_stosq` is proven in `task_pool.pdx` line 107
and `zero_bss.pdx` line 15, and for 256 bytes (32 qwords) the
unroll would cost 32 stores + 32 disp8 bytes of encoding vs.
`rep_stosq`'s 3-instruction setup + 1-instruction op. `vnode_free`
uses the unroll because 64 bytes is only 8 stores — the crossover
favors rep_stosq at ≥ 16 stores. tmpfs's 32 stores put us
comfortably above the crossover.

## 7. Invariants

### 7.1 Success return is exactly `rax = 0`

`tmpfs_unlink_done` reaches the success epilogue only via `xor rax,
rax`, which zero-idioms the full u64. Callers using `cmp rax, 0`
are safe.

### 7.2 Failure return is exactly `rax = 0xFFFFFFFFFFFFFFFF`

`tmpfs_unlink_fail` sets `rax = 0xFFFFFFFFFFFFFFFF` via `mov rax,
imm64`. Matches `tmpfs_write` and `tmpfs_read` error sentinels.

### 7.3 Post-success, parent chain is well-formed

Before unlink, the chain was `... → prev → target → next → ...`
(or `dir.first_child → target → next → ...` for head-case).
After the splice write, the chain is either
`... → prev → next → ...` (middle) or
`dir.first_child → next → ...` (head). No other node's
`next_sibling` was touched, so the rest of the chain is
byte-identical. The chain terminator (`next_sibling == 0xFFFF`
somewhere) is preserved.

### 7.4 Post-success, target's inode slot is fully zeroed

`tmpfs_inode_free(target_idx)` zeros all 256 bytes of the slot
(via `rep_stosq`, count = 32 qwords). This restores the `.bss`
invariant for the entire slot including `page_ptrs[16]`, so any
future `tmpfs_inode_alloc` handing out this slot to
`tmpfs_create` sees the same slot state that the very first
allocation saw.

### 7.5 Post-success, target's bitmap bit is 0

`tmpfs_inode_free` clears bit `target_idx` in
`_tmpfs_inode_bitmap[0]` via `btr_q`. Bit 0 (the reserved
sentinel) is untouched because `target_idx` from `tmpfs_lookup`
is always in `[1, 63]` (r16-m2-003 §7.1). Bit 0 stays set for the
whole system lifetime by policy (r16-m2-001 §7.3).

### 7.6 Post-success, target's data pages are released

Every `page_ptrs[i] != 0` at unlink entry has had `phys_free(va, 0)`
called on it exactly once. `phys_free` clears the corresponding
bit in `_phys_pool_bitmap` (via the refcount-decrement path when
refcount hits 0, which is always at R16.M2). The pages are now
available for `phys_alloc(0)` to hand out.

### 7.7 Failure preserves the pool byte-identically

See §5.6. Neither failure path executes any store.

## 8. Encoder verification

Every mnemonic shape used by this issue's code is proven in R16.M1
/ R16.M2 landed modules or Phase 7 memory modules. No new encoder
work.

| Shape                              | Proven by                                                                        |
|------------------------------------|----------------------------------------------------------------------------------|
| `push` / `pop r64`                 | `tmpfs_lookup.pdx`, `tmpfs_create.pdx`, `tmpfs_write.pdx`, `tmpfs_read.pdx`. 5-push pattern uniform across R16.M2. |
| `mov r64, r64`                     | Ubiquitous.                                                                       |
| `call sym`                         | Ubiquitous.                                                                       |
| `xor r64, r64`                     | Ubiquitous zero-idiom.                                                            |
| `mov_b r64, [r64 + disp8]`         | `tmpfs_lookup.pdx:45, 75-76`.                                                    |
| `mov_w [r64 + disp32], r64`        | `tmpfs_init.pdx:70, 73, 76`. Offsets +178, +180 used here.                       |
| `mov r64, [r64 + disp32]`          | `tmpfs_lookup.pdx:52, 98`. Load form at +176 with shr+and extraction.            |
| `mov r64, [r64 + r64*8]`           | `phys_alloc.pdx`, `tmpfs_read.pdx:103` (`page_ptrs[i]` scaled load).             |
| `lea r64, [r64 + disp8]`           | Ubiquitous (`lea rax, [r14 + 16]` for page_ptrs base).                            |
| `lea r64, [rip + sym]`             | Ubiquitous (RIP-relative for `_tmpfs_inode_bitmap`, `_tmpfs_inode_pool`).         |
| `cmp r64, imm8`                    | Ubiquitous.                                                                       |
| `cmp r64, imm32`                   | Ubiquitous (`cmp rcx, 0xFFFF`).                                                   |
| `cmp r64, r64`                     | Ubiquitous (`cmp rcx, r13`).                                                      |
| `shr r64, imm8`                    | `tmpfs_lookup.pdx:53, 99`.                                                        |
| `and r64, imm32`                   | `tmpfs_lookup.pdx:54, 100`.                                                       |
| `jmp label` / `je` / `jne` / `jae` | Ubiquitous.                                                                       |
| `add r64, imm8`                    | Ubiquitous (`add r15, 1`).                                                        |
| `mov rax, imm64`                   | `tmpfs_write.pdx:140` (`mov rax, 0xFFFFFFFFFFFFFFFF`).                            |

For the new `tmpfs_inode_free` leaf in `inode.pdx`:

| Shape                              | Proven by                                                                        |
|------------------------------------|----------------------------------------------------------------------------------|
| `btr_q r64, r64`                   | `vnode_pool.pdx:121` (`btr_q r9, rcx` — the exact shape).                        |
| `shl r64, cl`                      | `phys_alloc.pdx:60`, `phys_free.pdx:70`. Not actually used here (btr_q avoids it), but listed for the alternate design in §6.6. |
| `rep_stosq`                        | `task_pool.pdx:107`, `zero_bss.pdx:15`. Full 3-instruction setup form.           |
| `cld`                              | `tmpfs_write.pdx:118`, `tmpfs_read.pdx:119`. Belt-and-braces DF=0 before rep.    |

## 9. Test canary — R16 TMPFS UNLINK OK

Runs in `kernel_main` immediately after the `R16 TMPFS READ OK`
marker (line ~2636), between `tmpfs_read_witness_done` and the
`wrmsr` for `IA32_GS_BASE`. This position is chosen because:

- The read witness has just verified `/tmp/x` exists with size=100
  and page_ptrs[0] != 0 — the pre-conditions for a fully-populated
  unlink test.
- No downstream code walks `/tmp` at this point (process init and
  the runqueue are all next), so removing `/tmp/x` has no
  observable downstream effect.

Four sub-tests, one marker.

### 9.1 Witness fixture — no new strings needed

`witness_name_tmp` ("tmp\0") and `witness_name_any` ("x\0") are
both defined in `boot_stub.S` and used by every prior R16.M2
witness. `tmpfs_unlink` reuses both.

Two new witness message strings, alongside the existing
`tmpfs_read_*_msg` pair (~line 578 of boot_stub.S):

```s
# R16-M2-007 (#585): tmpfs_unlink witness success + failure messages
.global tmpfs_unlink_ok_msg
.align 8
tmpfs_unlink_ok_msg: .ascii "R16 TMPFS UNLINK OK\n\0"

.global tmpfs_unlink_fail_msg
.align 8
tmpfs_unlink_fail_msg: .ascii "R16 TMPFS UNLINK FAIL\n\0"
```

### 9.2 Sub-test A — `tmpfs_unlink(tmp_idx, "x")` returns 0

```asm
    ; --- Recover tmp_idx via tmpfs_lookup on root ---
    mov  rdi, 1                             ; root_idx = TMPFS_INODE_IDX_ROOT
    lea  rsi, [rip + witness_name_tmp]      ; "tmp\0"
    call tmpfs_lookup
    cmp  rax, 0
    je   tmpfs_unlink_witness_fail
    mov  r12, rax                           ; r12 = tmp_idx

    ; --- Save x_idx BEFORE unlink for sub-test D bitmap check ---
    mov  rdi, r12                           ; tmp_idx
    lea  rsi, [rip + witness_name_any]      ; "x\0"
    call tmpfs_lookup
    cmp  rax, 0
    je   tmpfs_unlink_witness_fail
    mov  r13, rax                           ; r13 = x_idx (pre-unlink snapshot)

    ; --- tmpfs_unlink(tmp_idx, "x") — expect rax = 0 ---
    mov  rdi, r12
    lea  rsi, [rip + witness_name_any]
    call tmpfs_unlink
    cmp  rax, 0
    jne  tmpfs_unlink_witness_fail
```

Proves: (a) type gate on /tmp passes, (b) lookup finds "x",
(c) splice + release complete, (d) return is exactly 0.

### 9.3 Sub-test B — `tmpfs_lookup(tmp_idx, "x")` returns 0 (miss)

```asm
    ; --- Post-unlink lookup should miss ---
    mov  rdi, r12                           ; tmp_idx
    lea  rsi, [rip + witness_name_any]      ; "x\0"
    call tmpfs_lookup
    cmp  rax, 0
    jne  tmpfs_unlink_witness_fail          ; expected miss
```

Proves: the acceptance criterion verbatim — "unlink → subsequent
lookup miss."

### 9.4 Sub-test C — `/tmp.first_child == 0xFFFF`

Since "/tmp/x" was the only child of "/tmp" at witness time (the
create witness put it there; no other witness touched /tmp),
splicing it out should leave `/tmp.first_child == 0xFFFF`
(empty-chain sentinel).

```asm
    ; --- Load /tmp's u64 @+176; extract first_child from bits [32, 48) ---
    mov  rdi, r12                           ; tmp_idx
    call tmpfs_inode_slot                   ; rax = &tmp_inode
    mov  rcx, [rax + 176]
    shr  rcx, 32
    and  rcx, 0xFFFF                        ; rcx = tmp.first_child
    mov  rdx, 0xFFFF
    cmp  rcx, rdx
    jne  tmpfs_unlink_witness_fail          ; expected empty-chain sentinel
```

Proves: the splice §4.5 head-case write landed correctly. Also
witnesses the invariant §7.3 — chain well-formed after splice.

### 9.5 Sub-test D — bitmap bit for x_idx is now 0

```asm
    ; --- Verify _tmpfs_inode_bitmap[0] bit (r13 = x_idx) is 0 ---
    lea  rax, [rip + _tmpfs_inode_bitmap]
    mov  r8, [rax]                          ; bitmap word
    mov  rcx, r13                           ; shift count = x_idx
    mov  rdx, 1
    shl  rdx, cl                            ; rdx = 1 << x_idx
    and  r8, rdx                            ; isolate bit
    cmp  r8, 0                              ; must be zero (bit cleared)
    jne  tmpfs_unlink_witness_fail

    lea  rdi, [rip + tmpfs_unlink_ok_msg]
    call uart_puts
    jmp  tmpfs_unlink_witness_done

tmpfs_unlink_witness_fail:
    lea  rdi, [rip + tmpfs_unlink_fail_msg]
    call uart_puts

tmpfs_unlink_witness_done:
```

Proves: `tmpfs_inode_free`'s `btr_q` cleared the slot's bit; the
slot is truly available for future `tmpfs_inode_alloc` to hand out.

**Why check bit, not slot payload.** Sub-test C already proves the
splice landed. Sub-test D independently witnesses the *release*
half (bitmap-clear), which is the second half of `tmpfs_inode_free`'s
contract. A future sub-test E could also verify the 256-byte zero
via `mov rcx, [x_ptr + 0]; cmp rcx, 0` — omitted here because the
payload zero is redundant with the bit-clear witness (the two land
together in tmpfs_inode_free's straight-line block; if the bit is
clear, the zero preceded it or was simultaneous).

### 9.6 Marker

On all four sub-tests green:

```
R16 TMPFS UNLINK OK
```

Fingerprint added to:

- `tests/r14b/expected-boot-r14b-loader.txt` — line 25 (immediately
  following `R16 TMPFS READ OK`).
- `tests/r15/expected-boot-r15-ring3.txt` — same position.
- `tests/r15/expected-boot-r15-process.txt` — same position.

## 10. Boot integration

Witness is inserted in `kernel_main.pdx` between
`tmpfs_read_witness_done` (line ~2636) and the `wrmsr` for
`IA32_GS_BASE` (line ~2638). Insertion point avoids any interaction
with the process subsystem (whose init runs immediately after). The
state mutation this witness makes (removing "/tmp/x" and returning
its data page to the phys pool) is preserved through subsequent
boot — no downstream code depends on /tmp/x being present, and the
freed phys page is available for the process init's paging setup
to use (a marginal free-space bonus).

Rough kernel_main.pdx delta:

```asm
      tmpfs_read_witness_done:

      // ============================================================
      // R16-M2-007 (#585): tmpfs_unlink witness — 4 sub-tests, 1 marker
      // ============================================================
      tmpfs_unlink_witness:
          // ---------- Preamble: recover tmp_idx, snapshot x_idx ----------
          // ... (see §9.2)
          // ---------- Sub-test A: unlink returns 0 ----------
          // ... (see §9.2)
          // ---------- Sub-test B: lookup misses ----------
          // ... (see §9.3)
          // ---------- Sub-test C: /tmp.first_child == 0xFFFF ----------
          // ... (see §9.4)
          // ---------- Sub-test D: bitmap bit for x_idx is 0 ----------
          // ... (see §9.5)

          lea  rdi, [rip + tmpfs_unlink_ok_msg]
          call uart_puts
          jmp  tmpfs_unlink_witness_done

      tmpfs_unlink_witness_fail:
          lea  rdi, [rip + tmpfs_unlink_fail_msg]
          call uart_puts

      tmpfs_unlink_witness_done:

      // R14b-m5-002 (#507): IA32_GS_BASE = &_cpu_locals[0] on CPU0.
      lea rax, [rip + _cpu_locals];
      ...
```

## 11. `tmpfs_inode_free` leaf primitive (new in `inode.pdx`)

### 11.1 Signature

```
tmpfs_inode_free : (u64) -> u64 !{mem} @{}
  → rax = 0  (always success at R16.M2; no error path)
```

Enters with `rdi = idx` (u16 semantics; caller-validated to be in
[1, 63]). Leaf: no callee-save prologue, no nested calls.

### 11.2 Justification (matches inode.pdx style)

```
justification: "R16-M2-007 (#585): Clear bit idx from
_tmpfs_inode_bitmap[0] via btr_q (register form, same as
vnode_pool.pdx:121), then zero the 256-byte slot payload via
rep_stosq (count = 32 qwords, same shape as task_pool.pdx:107).
Leaf function: no callee-save prologue; rax/rcx/rdi/r8/r9 all
caller-saved per SysV AMD64. Splits into two disjoint memory
regions (bitmap word + slot payload); ordering (bit-clear then
zero, or reverse) is observably identical under single-writer
R16.M2. Under R17 concurrency, bit-clear-first would let a
concurrent tmpfs_inode_alloc race the same slot — but tmpfs_inode_alloc
is called only from tmpfs_create under the future FS lock, so no race
window opens. Implementation chooses zero-first for defensive
symmetry with vnode_free (#571)."
```

### 11.3 Body

```asm
tmpfs_inode_free:
    ; --- Zero the 256-byte slot payload first ---
    ; Compute slot address inline (no call to tmpfs_inode_slot — leaf)
    lea  r8, [rip + _tmpfs_inode_pool]
    mov  r9, rdi
    shl  r9, 8                          ; idx * 256
    add  r8, r9                         ; r8 = &_tmpfs_inode_pool[idx]

    mov  rdi, r8                        ; rep_stosq dst = slot base
    mov  rcx, 32                        ; 256/8 qwords
    xor  eax, eax                       ; fill = 0 (rax = 0 also becomes return)
    cld
    rep_stosq

    ; --- Clear bit idx in bitmap word (bitmap has only 1 word for TMPFS_MAX=64) ---
    lea  r8, [rip + _tmpfs_inode_bitmap]
    mov  r9, [r8]
    ; rdi was clobbered by rep_stosq (advanced by 256); reload from wherever?
    ; NOTE: rep_stosq advances rdi by count*8. idx is gone.
    ; Fix: save idx before rep_stosq.
    ...
```

**Register-save wrinkle.** `rep_stosq` clobbers `rdi` (advances it
by `rcx * 8`). We need the original `idx` for `btr_q` after the
zero. Two options:

- **Save idx in a callee-saved register before rep_stosq.** Would
  need a `push`/`pop` pair (leaf → no prologue), or use a
  currently-free scratch reg. `r10`, `r11` are caller-saved and
  clobbered by rep_stosq indirectly? Actually `rep_stosq` only
  writes rdi, rcx, rax. r10, r11 survive.

Let me refine:

```asm
tmpfs_inode_free:
    ; --- Save idx (rdi) into r10 before rep_stosq clobbers rdi ---
    mov  r10, rdi                       ; r10 = idx (survives rep_stosq)

    ; --- Compute slot address ---
    lea  r8, [rip + _tmpfs_inode_pool]
    mov  r9, rdi
    shl  r9, 8                          ; idx * 256
    add  r8, r9                         ; r8 = &_tmpfs_inode_pool[idx]

    ; --- Zero via rep_stosq (dst=rdi, count=rcx, fill=rax) ---
    mov  rdi, r8
    mov  rcx, 32
    xor  eax, eax
    cld
    rep_stosq

    ; --- Clear bit idx (in r10) in the single bitmap word ---
    lea  r8, [rip + _tmpfs_inode_bitmap]
    mov  r9, [r8]
    btr_q r9, r10                       ; clear bit r10 in r9
    mov  [r8], r9

    ; --- Return 0 (rax already zero from `xor eax, eax` above) ---
    ret
```

**Encoder note on `btr_q r64, r64`.** Register form is proven by
`vnode_pool.pdx:121` (`btr_q r9, rcx`). Uses second-operand as the
bit index. `btr_q r9, r10` follows the same shape.

**Bitmap indexing.** `_tmpfs_inode_bitmap` is a single-word bitmap
(TMPFS_MAX = 64), so idx is directly the bit position (idx < 64 by
construction). No word-index compute needed — differs from
`vnode_pool`'s multi-word bitmap that needs `shr 6 / and 63`.

**Sentinel guard omitted.** Callers guarantee `idx > 0` (bit 0 is
reserved). Adding `cmp rdi, 0; je tmpfs_inode_free_done` is
belt-and-braces but not required. The leaf skips it for minimal
instruction count; `tmpfs_unlink` never passes idx == 0 (tmpfs_lookup
returns [1, 63] on hit, filtered at Phase A).

**Boundary guard omitted.** Callers guarantee `idx < 64` (TMPFS_MAX).
Adding `cmp rdi, 64; jae tmpfs_inode_free_done` is belt-and-braces
but not required. tmpfs_lookup returns values from within
`_tmpfs_inode_bitmap`, all `< 64`.

Total: 12 body instructions, ~50 LOC in `inode.pdx` including
docstring and justification.

### 11.4 Interaction with `tmpfs_inode_alloc`

`tmpfs_inode_alloc` scans `_tmpfs_inode_bitmap[0]` for a clear bit,
sets it, and returns the index. After `tmpfs_inode_free(idx)`, bit
`idx` is 0, so a subsequent `tmpfs_inode_alloc` may return the same
`idx`. This is the intended re-use pattern.

The 256-byte slot payload is zeroed by `tmpfs_inode_free`, so
`tmpfs_create` (which writes new field values but relies on
`.bss`-zero for `page_ptrs[16]`) can allocate the freed slot
correctly. This closes the "R16.M2 has no free primitive so slot
reuse is impossible" caveat that r16-m2-004 §7.3 documented — the
caveat is retired at #585.

## 12. Cross-references

- Issue: paideia-os#585
- Milestone: R16.M2 (tmpfs — in-memory VFS backend)
- Upstream:
  - paideia-os#579 (R16-M2-001 — frozen layout §2; all offsets used
    here exported from `inode.pdx`).
  - paideia-os#580 (R16-M2-002 — `tmpfs_inode_alloc` counterpart;
    `tmpfs_inode_free` is its inverse and lives in the same file).
  - paideia-os#581 (R16-M2-003 — `tmpfs_lookup` called in Phase A;
    walker shape mirrored inline in Phase B (with strncmp replaced
    by `next_sibling == target_idx`)).
  - paideia-os#582 (R16-M2-004 — `tmpfs_create` inverse; insert-at-head
    is undone by splice-out).
  - paideia-os#583 (R16-M2-005 — `tmpfs_write` populated `/tmp/x` with
    one page; this issue frees it).
  - paideia-os#584 (R16-M2-006 — `tmpfs_read` witness precondition
    ordering ensures `/tmp/x` is fully-populated at unlink witness time).
  - paideia-os#571 (R16-M1-002 — `vnode_free` pattern template for
    `tmpfs_inode_free`).
  - paideia-os#649 (R15-M1-010 — `phys_free` real body; the underlying
    page-release primitive called from §4.8).
- Downstream consumers:
  - A follow-on R16.M3 issue (tmpfs vops table — registers a thin
    adapter that reads `dir_vn.backend_ptr` (+32) as the inode idx
    and forwards to `tmpfs_unlink`).
  - R17 `sys_unlink` — user-facing syscall reaching this primitive
    through the vops chain.
  - A follow-on `tmpfs_rmdir` issue — forks off this file's walker +
    splice + release skeleton, adding an empty-child-chain
    precondition on the target.
- Tactical plan: `design/milestones/r14b-tactical-plan.md` §Subsystem
  12 item 7 — "Not required for shell demo but useful. Release inode
  + pages. Acceptance: unlink → subsequent lookup miss."

## 13. LOC + tractability

- `unlink.pdx` module: ~130 LOC (95 instructions + comments +
  module wrapper).
- `tmpfs_inode_free` leaf in `inode.pdx`: ~50 LOC (12 instructions
  + docstring + justification).
- Witness in `kernel_main.pdx`: ~80 LOC.
- Message strings in `boot_stub.S`: ~10 LOC.
- Expected-boot fingerprints: 3 lines across 3 files.

Total delta: ~275 LOC. All encoder shapes proven. No paideia-as
gaps expected. Tractability: **high** — mirrors the well-worn
`vnode_free` pattern for the leaf, and the walker/splice pattern
is a straightforward inversion of `tmpfs_create` §4.8.
