---
issue: 584
milestone: R16.M2 (tmpfs — in-memory VFS backend)
subsystem: 12 — tmpfs
topic: tmpfs_read — copy bytes from inode page(s) into caller buf; clamp to size (R16-M2-006)
freeze-discipline: strict
  - tmpfs inode layout frozen by R16-M2-001 (#579); this issue reads from
    frozen offsets `+0` (type, u8), `+8` (size, u64), and
    `+16..+144` (page_ptrs[16], u64*16). No numeric offset is embedded
    outside the exported constants from `inode.pdx`.
  - `tmpfs_read` signature `(u64, u64, u64, u64) -> u64` — `(inode_idx,
    buf_ptr, len, offset) -> bytes_read_or_error` — is the read-side
    mirror of #583's `tmpfs_write`. R16.M3's vops adapter relies on
    both primitives having a uniform contract: same argument layout,
    single-`rax` return, same failure sentinel.
  - Single-page constraint (§1) is a **runtime-enforced** constraint at
    R16.M2, not a permanent one. Cross-page reads return the error
    sentinel — never silently truncate to page 0, never silently
    return zero. The multi-page loop lands in a follow-on issue when
    the R17 syscall demo needs it (mirror of #583's cross-page
    backtrack anchor).
  - Hole semantics: if `page_ptrs[start_page] == 0` (page never
    allocated by any prior write on this file), return 0 bytes read.
    R16.M2 does **not** zero-fill unwritten pages; the zero-fill
    invariant lives with `phys_alloc` (#583 §6.5). At the acceptance
    test point, `page_ptrs[0]` for `/tmp/x` is guaranteed non-zero
    because #583's witness wrote 100 bytes at offset 0 — so the hole
    path is defensively present but never exercised at R16.M2.
  - phys_alloc VA/PA contract: at R16.M2, `page_ptrs[i]` holds a
    higher-half kernel VA (bit 63 set) courtesy of `phys_alloc`'s
    current VA contract. When #658 rebases phys_alloc onto genuine
    PAs, this module gains a PA→VA lift at the same site as
    `tmpfs_write` (both stay byte-identical to the pre-#658 shape at
    the inode-field boundary).
blocks:
  - "R16.M3 tmpfs vops table (`tmpfs_vops` — registers a wrapper
    adapting `tmpfs_read(inode_idx, buf_ptr, len, offset)` to the vops
    shape `(vnode_ptr, buf_ptr, len, offset)` by reading the vnode's
    `backend_ptr` (+32) as the inode idx.)"
  - "R17 `sys_read` syscall — user-facing entry point that reaches
    this primitive through the vops chain. Depends on this issue's
    contract that the passed buffer is a kernel VA (the syscall
    trampoline does the copy_to_user afterward)."
  - "A follow-on multi-page `tmpfs_read` issue — lifts the single-page
    constraint via a per-page loop around this issue's inner memcpy.
    See §5.4 for the backtrack sketch."
touching:
  - src/kernel/core/fs/tmpfs/read.pdx             (new module — `tmpfs_read`; ~110 LOC)
  - src/kernel/boot/kernel_main.pdx               (witness block ~80 LOC)
  - tools/boot_stub.S                             (128-byte destination buffer + 2 message strings; ~18 LOC)
  - tests/r14b/expected-boot-r14b-loader.txt      (marker: "R16 TMPFS READ OK")
  - tests/r15/expected-boot-r15-ring3.txt         (marker)
  - tests/r15/expected-boot-r15-process.txt       (marker)
  - design/kernel/r16-m2-006-tmpfs-read.md        (this doc)
related:
  - design/kernel/r16-m2-001-tmpfs-inode-pool.md  (#579 — frozen layout §2;
    every field offset this module reads is exported by `inode.pdx`)
  - design/kernel/r16-m2-005-tmpfs-write.md       (#583 — read's peer
    primitive. This module's register discipline, encoder set, and
    5-push prologue mirror it. #583's witness left `/tmp/x` at
    `size=100, page_ptrs[0]!=0, first 100 bytes = 'A'` — the exact
    starting state this witness reads back.)
  - design/kernel/r16-m2-003-tmpfs-lookup.md      (#581 — used by the
    witness preamble to recover `x_idx` from `/tmp/x`. Same lookup
    chain used by #583's witness.)
  - src/kernel/core/mm/phys_alloc.pdx             (bitmap-first order-0
    allocator; `page_ptrs[i]` values are kernel VAs it returned to
    `tmpfs_write`. This module dereferences them read-only.)
  - design/paideia-as/non-milestone-issue-1228-bulkmemops-phase2.md
    (paideia-as encoder support for `rep_movsb` — landed with F3 A4
    byte sequence per §encoder table; already exercised by
    `tmpfs_write` and re-used here.)
  - design/milestones/r14b-tactical-plan.md      §Subsystem 12 item 6 —
    "Copy from inode's page(s) into user buf; respect offset + count.
    Acceptance: read after write returns same bytes; read past EOF
    returns 0."
---

# R16-M2-006 — `tmpfs_read` (single-page memcpy + clamp-to-size, #584)

## 1. Scope

Ship the tmpfs data-read primitive that turns a `(inode_idx, buf,
len, offset)` tuple into (a) a bounds-clamped byte count `n =
min(len, size - offset)` if `offset < size` else `n = 0`, and (b) a
byte-for-byte copy of the file's bytes `[offset, offset + n)` into
the caller's buffer.

Concretely, `tmpfs_read` takes the acceptance test — "after
`tmpfs_write(x, buf, 100, 0)`, the sequence `tmpfs_read(x, dst,
100, 0)` returns 100 and `dst[0..100]` matches the source buffer" —
end to end.

**Scope constraint: single-page reads only.** This issue implements
the **single-page path** — reads where `start_page == end_page` for
the **clamped** length. That is, we first clamp `n = min(len, size -
offset)`, then check `(offset >> 12) == ((offset + n - 1) >> 12)`.
Cross-page (post-clamp) returns the error sentinel (`u64::MAX`); the
multi-page loop lands in a follow-on issue when the R17 syscall
demo needs it. The 100-byte-at-offset-0 acceptance test lands
squarely inside page 0, so the constraint is invisible at R16.M2's
demo; the runtime guard exists purely so a future caller cannot
silently truncate a valid multi-page read.

**Rejection of stub-shape.** A "stub" tmpfs_read for R16.M2 would
either (a) hard-code offset = 0 + return `min(len, size)` bytes from
page 0, or (b) silently short-read at the page boundary without
signalling that the caller lost bytes. Both are outlawed by the
R16.M2 discipline. Instead, this module implements the general
single-page case (any `offset` in `[0, size)`, any `len` in `[0,
65536]`, with correct clamp) and refuses cross-page reads with a
distinguishable error. When multi-page is needed, a new issue
extends the same code path with a per-page loop — no rewrite.

**Read/write symmetry.** The read and write primitives share:

- The `(inode_idx, buf_ptr, len, offset) -> u64` signature.
- The five-push callee-save prologue (§3).
- The type-gate + range-gate + single-page-guard failure ladder.
- The `rep_movsb` memcpy shape (only src/dst are swapped: read has
  `rsi = page_va + intra`, `rdi = buf_ptr`; write reverses these).
- The `0xFFFFFFFFFFFFFFFF` error sentinel and the `[0, 65536]`
  legitimate return range.

They differ in three respects, all narrowly localized:

1. **No lazy allocation.** Read does not call `phys_alloc`. If
   `page_ptrs[start_page] == 0`, read returns 0 (hole ⇒ short read
   of length 0). Write allocates the page.
2. **No size update.** Read does not mutate `inode.size`. The
   `[r15 + 8]` field is a **load**, not a store — used only to
   compute the clamp.
3. **EOF clamp instead of overflow-error.** Write rejects
   `offset + len > 65536` with the error sentinel (write past
   file cap is a caller error). Read handles `offset >= size` by
   returning 0 (legitimate POSIX-shaped EOF), and handles
   `offset + len > size` by clamping to `size - offset`
   (legitimate POSIX-shaped short read).

The three deltas collapse the code path: read has no
allocation-failure branch, no size-mutation store, and one arithmetic
branch (`if offset >= size: return 0`) that write does not need.

Behavior spelled out:

1. **Enter** with `rdi = inode_idx` (u64 with u16 semantics), `rsi
   = buf_ptr` (u64, kernel VA of destination bytes), `rdx = len`
   (u64, byte count requested), `rcx = offset` (u64, starting byte
   offset within the file). No bounds check on `inode_idx` —
   callers reach us only through a live index (initially from
   #582's `tmpfs_create` return; later from `vnode.backend_ptr`
   via the vops adapter).
2. **Zero-length fast path.** If `len == 0`, return 0 immediately.
   Skips all page work. Legal no-op (POSIX-shaped `read(2)` with
   count=0).
3. **Type gate.** Load `inode.type` at `+0`; if it is not
   `VNODE_TYPE_REG` (1), return the error sentinel. Directories,
   symlinks, and any future non-regular types cannot be `read`-source
   files — the vops layer's `vops_read` will fail here rather than
   at the syscall boundary, keeping the "wrong type" failure
   single-sourced. (Directory reads eventually route to
   `tmpfs_readdir`, a distinct primitive.)
4. **Range gate on `offset`.** Reject `offset > 65536`. `len` is
   not range-gated at entry because the clamp (§7) will bound it
   by `size - offset` anyway, and `size` is invariant-bounded by
   `65536`. This is a small departure from write, which gates
   `len` up front to prevent overflow on `offset + len`; read
   avoids the overflow by clamping first (never adding `len` to
   `offset` without the clamp).
5. **EOF check.** Load `inode.size` at `+8`. If `offset >= size`,
   return 0 (POSIX-shaped EOF: legitimate zero-byte read). This
   is the "read past EOF returns 0" acceptance criterion from the
   issue body.
6. **Clamp.** Compute `n = min(len, size - offset)`. After this,
   `n` in `[0, size - offset]` and (with §4 gate) `n <= 65536`.
   If `n == 0` (i.e., `len == 0` — but that's the fast path — or
   `size == offset`, but that's caught by §5), fall through to
   the success return of 0. In practice §5 covers all `n == 0`
   cases, so we can jump straight into the copy path.
7. **Single-page constraint (post-clamp).** Compute `start_page =
   offset >> 12` and `end_page = (offset + n - 1) >> 12`. If they
   differ, reject with the error sentinel. Because we already
   clamped by `size` (which is invariant-bounded by 65536), the
   compute stays within u16 arithmetic even in the corner cases.
8. **Page-slot load.** Compute `&page_ptrs[start_page] = inode + 16 +
   start_page * 8` (two `lea`s, same pattern as write §4.6). Load
   the pointer.
9. **Hole check.** If the loaded pointer is `0`, return 0. R16.M2
   does not zero-fill unwritten pages here (§ Out-of-scope). The
   hole path is defensively present but never exercised at R16.M2:
   #583's witness left `page_ptrs[0]` non-zero for `/tmp/x`, which
   is the only file the R16.M2 witness reads from.
10. **Memcpy.** Compute `src = page_va + (offset & 0xFFF)`. Set up
    `rsi = src`, `rdi = buf_ptr`, `rcx = n`, `cld` (defensive
    DF-clear), then `rep_movsb`. paideia-as landed the `RepMovsb`
    encoder at PA-R13-011 (#940).
11. **Return** `n` (bytes read) in `rax`.

Out of scope (deliberately deferred):

- **Multi-page reads.** Handled by a follow-on issue that keeps
  this module's per-page primitive as its inner loop. §5.4 sketches
  the backtrack shape.
- **Zero-fill on hole.** POSIX file semantics require that unwritten
  regions of a file (page-slot == 0 in tmpfs's page-ptr shape) read
  as zero. R16.M2's witness never reads from a hole, so the
  observable behavior is untestable at this issue's scope. The
  correct owner of the zero-fill invariant is `phys_alloc`
  (#583 §6.5): every allocated page is guaranteed zero, so a
  regular read of an unwritten byte within an allocated page
  naturally sees zero. For **fully unallocated** pages
  (`page_ptrs[i] == 0`), the follow-on multi-page issue can
  either (a) memset the caller's buffer to zero for that page's
  contribution, or (b) rely on a caller-provided zeroed buffer
  convention. That decision lives with the follow-on issue.
- **`copy_to_user`.** `buf_ptr` is treated as a **kernel VA**. The
  syscall boundary (R17) will land the kernel-to-user bounce in
  `sys_read`'s trampoline after this primitive returns. R16.M2's
  witness passes a `.data`-resident kernel buffer.
- **Timestamps** (`atime`). Same reasoning as #582/#583 — the
  inode layout has no timestamp fields; they will land with the
  disk-backed FS at R18+.
- **Refcount / link_count bumps.** `tmpfs_read` does not touch
  these; a read on a live file leaves refcount unchanged (the
  caller already holds a live reference via the vnode/backend
  chain).
- **Read barriers.** No `lfence` before the load. tmpfs is a
  purely in-memory FS on a coherent x86_64; the writer publishes
  size + page pointer in program order (#583 §4.7), and readers
  observe those stores in the same order under the R16.M2
  single-threaded execution model. Under future SMP concurrency
  (R17+), the reader's load of `size` (§4.5) and `page_ptrs[]`
  (§4.8) need to happen in an order that matches the writer's
  publish order — specifically, the reader must load
  `page_ptrs[]` after `size` to guarantee "if I see the new
  size, I see the new page pointer". The load-load ordering is
  natural on x86_64 (TSO); the follow-on FS-lock design can
  add memory barriers if the semantics tighten.

## 2. Contract

```
tmpfs_read : (u64, u64, u64, u64) -> u64 !{mem} @{}
  → rax = n                      on success (bytes actually read,
                                  n in [0, 65536], n <= len,
                                  n <= size - offset)
  → rax = 0                      when len == 0 (legal no-op)
                                  or when offset >= size (POSIX EOF)
                                  or when page_ptrs[start_page] == 0
                                  (hole; see §1 "Out of scope")
  → rax = 0xFFFFFFFFFFFFFFFF     on failure (bad type, offset > 64 KiB,
                                  cross-page after clamp)
```

Nullary on capabilities at R16.M2 (no capability system yet).
`!{mem}` because we write into the caller-supplied buffer via
`rep_movsb`. Even though we do not mutate `_tmpfs_inode_pool` or
`_phys_pool_bitmap`, the memcpy destination is memory, so the
effect is not `!{}`.

**Why `!{mem}` and not a read-only effect.** paideia-as's effect
lattice at R16 has `!{mem}` as the coarse "mutates memory" effect
and no finer-grained "mutates caller-supplied buffer only" effect.
The vops adapter at R16.M3 will already carry `!{mem}` for its
own dispatch shape, so tightening `tmpfs_read` beyond `!{mem}`
would not propagate a tighter effect upward. When (if) the effect
lattice grows a "no-op on pool state" effect, this module can
refine.

**Non-leaf.** Makes one nested call: `tmpfs_inode_slot` (for the
inode pointer). No `phys_alloc` call (unlike write). The callee
may clobber caller-save regs; the 5-push callee-save prologue
(§3) keeps every persistent value in callee-save registers.

**Error signaling.** All failure modes collapse to `rax = -1`
(`0xFFFFFFFFFFFFFFFF`). Legitimate returns are in `[0, 65536]`; the
sentinel is comfortably outside that range. Distinguishing bad
type vs offset-overflow vs cross-page is deferred to the vops
layer at R18+ when POSIX-shaped `errno` lands.

**Success return `n` can be < `len` (short read).** Unlike write,
which is "all-or-nothing" (`rax` on success is exactly `len`),
read is "up-to-`len`" — the return value is `min(len, size -
offset)`. This is the POSIX-shaped read semantics: a short read at
EOF is not an error.

**Idempotence.** Idempotent under a fixed inode state: calling
`tmpfs_read(x, buf, 100, 0)` twice with the same file state and
same buffer address produces the same return value and the same
buffer contents. No state is mutated in the pool. (The buffer is
overwritten each call, but its final contents are a pure function
of inputs.)

**Ordering.** All reads of inode fields (`type` at +0, `size` at
+8, `page_ptrs[i]` at +16+i*8) and of the backing page are
single-threaded at R16.M2 — no concurrent writer can interleave.
Under future concurrency (R17+), the reader load order is: (a)
`type` (immutable after create), (b) `size`, (c) `page_ptrs[i]`,
(d) page contents. Loading `size` before `page_ptrs[i]` matches
the writer's publish order (write publishes the page pointer
first, then `size`), so if the reader sees the new `size`, it
sees the new `page_ptrs[i]`. On x86_64 TSO, load-load ordering
is preserved without explicit barriers.

## 3. Register discipline

### 3.1 Push plan — 5 pushes

Five-push callee-save prologue: `rbx`, `r12`, `r13`, `r14`, `r15`.
Same alignment argument as `tmpfs_write` (§3.1 of r16-m2-005):
`rsp mod 16 == 8` at entry; five pushes add 40 bytes; `48 mod 16
== 0` at nested call sites, satisfying SysV AMD64 alignment.

| Reg | Role                                                                 |
|-----|----------------------------------------------------------------------|
| rbx | `buf_ptr` — caller's arg2. Read at `mov rdi, rbx` right before `rep_movsb`. Must survive `tmpfs_inode_slot`. |
| r12 | `len` — caller's arg3. Read at the clamp compute (§4.6) — the `cmp rax, r12; jbe use_len` shape that picks `min(len, size - offset)`. Must survive `tmpfs_inode_slot`. |
| r13 | `offset` — caller's arg4. Read at the range gate, EOF check, clamp, single-page compute, intra-page-offset compute (`offset & 0xFFF`), page-slot compute (`offset >> 12`). Must survive `tmpfs_inode_slot`. |
| r14 | `n` (clamped byte count). Set once after the clamp compute (§4.6); read at the single-page constraint compute, the `rep_movsb` count set-up, and the success return (`mov rax, r14`). Persists across zero further nested calls (there are none after the clamp), so its callee-save status is defensive but consistent. |
| r15 | `inode_ptr` — result of `tmpfs_inode_slot(inode_idx)`. Read at the type gate, at `size` load, at `page_ptrs[start_page]` load. Must survive `tmpfs_inode_slot` (which sets it, so it's post-call). No other nested call after the slot resolution — the persistence requirement is trivial. |

**Why 5 registers.** Five persistent values (`buf`, `len`, `offset`,
`inode_ptr`, `n`). The clamped byte count `n` matters because it is
read three times after computation (single-page constraint compute,
memcpy count, return value). Materializing it once into a callee-save
register saves two recomputes.

**Why not fold `n` into `r12` (overwriting `len`).** We could
overwrite `r12` with the clamped `n` after computing it, since `len`
is not read again post-clamp. Rejected: (a) the read discipline
becomes "r12 means `len` before line X, `n` after line X" which is
fragile under future edits; (b) five pushes are already committed
for SysV alignment (four would leave rsp mod 16 == 8 at nested
calls); (c) the clarity cost of morphing register semantics
outweighs the microscopic savings. We keep `r12` = `len` and `r14`
= `n` distinct throughout.

### 3.2 Scratch registers

Used within single phases and never read across a nested call:

- `rax` (scratch for byte load at type gate, `size` load, `size -
  offset` compute, page-slot lea intermediate). Also holds the
  success return value at the epilogue (`mov rax, r14`).
- `rcx` (scratch for `end_page` compute, intra-page offset,
  `rep_movsb` count set-up).
- `rdx` (scratch for `end_page` intermediate compute).
- `r8` (scratch for loaded page pointer; feeds `rep_movsb` src).
- `r9` (scratch for start_page; feeds page-slot lea).
- `rsi`, `rdi` (implicit operands of `rep_movsb`).

None are read across a nested call. The single nested call
(`tmpfs_inode_slot`) is a leaf function with a shallow clobber
set, and it happens at §4.3 before any of the scratch values
above are computed.

### 3.3 Why r15 doesn't morph (contrast with tmpfs_create)

`tmpfs_create` used a morphing r15 (type → new_ptr). tmpfs_read
doesn't need that pattern: `inode_ptr` is set once by
`tmpfs_inode_slot` and read multiple times (type gate, size,
page_ptrs). No argument or intermediate dies before another is
computed. Straight-line register allocation matches the fact
that this function does less state juggling than `tmpfs_create`.

### 3.4 Contrast with tmpfs_write's r14 role

In `tmpfs_write`, `r14` holds `&page_ptrs[start_page]` — the
slot address, because it is both loaded from (to check for
lazy-alloc) and stored to (on lazy-alloc success). Here, the
slot is only loaded from, once. We don't need to cache the
address; we load into a scratch (`r8`) directly. `r14` is
therefore repurposed for `n` (the clamped count), which needs
persistence across the single-page-constraint compute and the
memcpy setup.

## 4. Algorithm

### 4.1 Prologue + arg stash

```asm
tmpfs_read:
    push rbx
    push r12
    push r13
    push r14
    push r15                            ; rsp%16 = 0

    mov  rbx, rsi                       ; rbx = buf_ptr
    mov  r12, rdx                       ; r12 = len
    mov  r13, rcx                       ; r13 = offset
    ; rdi still holds inode_idx for the tmpfs_inode_slot call below
```

### 4.2 Zero-length fast path

Legal no-op. Skip all page + clamp work and return 0.

```asm
    cmp  r12, 0
    je   tmpfs_read_zero_return
```

Where `tmpfs_read_zero_return` is a label at the epilogue that
returns `rax = 0`. Placement in §4.11.

### 4.3 Inode pointer + type gate

Get the inode base pointer, then verify type at +0 is
`VNODE_TYPE_REG` (1). Any other type is a caller error.

```asm
    call tmpfs_inode_slot               ; rax = &inode (rdi was inode_idx)
    mov  r15, rax                       ; r15 = inode_ptr

    xor  rcx, rcx
    mov_b rcx, [r15 + 0]                ; rcx = inode.type
    cmp  rcx, 1                         ; VNODE_TYPE_REG
    jne  tmpfs_read_fail
```

### 4.4 Range gate on offset

Reject `offset > 65536`. Only offset is gated at this point; `len`
is bounded by the clamp (§4.6), not by an explicit range check.
This is a small but deliberate divergence from `tmpfs_write`
(which gates both `offset` and `len` up front to prevent overflow
on `offset + len`); read never adds `len` to `offset` without
clamping first, so the overflow does not arise.

```asm
    mov  rax, 65536
    cmp  r13, rax                       ; offset > 64 KiB?
    ja   tmpfs_read_fail
```

**Why not also gate `len`.** `len` up to `u64::MAX` is safe at
this primitive because the clamp at §4.6 replaces it with `min(len,
size - offset) <= size <= 65536`. A caller passing `len = u64::MAX`
gets a legitimate response — up to `min(65536, size - offset)`
bytes. That matches POSIX read(2)'s "count > SSIZE_MAX is
implementation-defined but never overflows" latitude.

### 4.5 EOF check

Load `inode.size`; if `offset >= size`, return 0 (POSIX EOF).

```asm
    mov  rax, [r15 + 8]                 ; rax = inode.size
    cmp  r13, rax                       ; offset >= size?
    jae  tmpfs_read_zero_return         ; POSIX-shaped EOF
```

The `jae` (jump if above-or-equal, unsigned) is correct: both
`offset` and `size` are unsigned; `offset == size` is EOF (nothing
past the last byte to read).

**Order matters here.** We use the type gate (§4.3) result before
touching `size`. If a non-REG type reached §4.5, `[r15 + 8]` would
read a field with different semantics (`size` for REG, but for
DIR the same byte is `size` = summary of children count in a
future revision, and for FREE slots the field is zero). The gate
at §4.3 ensures the load here is meaningful.

### 4.6 Clamp: n = min(len, size - offset)

```asm
    ; rax = size (from §4.5)
    sub  rax, r13                       ; rax = size - offset (guaranteed >= 1 here,
                                        ;   since offset < size after §4.5's jae)
    cmp  rax, r12                       ; size - offset vs len
    jbe  tmpfs_read_clamp_done          ; if size - offset <= len, rax already right
    mov  rax, r12                       ; else n = len
tmpfs_read_clamp_done:
    mov  r14, rax                       ; r14 = n (clamped bytes to read)
```

Post-clamp invariant: `1 <= r14 <= min(len, size - offset)`. The
`>= 1` follows from §4.5 having taken the `offset >= size` branch
out — after §4.5, `offset < size` so `size - offset >= 1`, and the
clamp picks the smaller of that and `len`. Combined with §4.2
(`len == 0` fast path taken out), `len >= 1`, so `n = min(>=1,
>=1) >= 1`. This is why we can skip the "if n == 0, return 0"
check after the clamp — §4.2 and §4.5 have handled every path
that would yield `n == 0`.

### 4.7 Single-page constraint (post-clamp)

Compute `start_page = offset >> 12` and `end_page = (offset + n
- 1) >> 12`. Because §4.6 ensures `n >= 1`, the `sub 1` is safe.

```asm
    mov  r9, r13                        ; r9 = offset
    shr  r9, 12                         ; r9 = start_page
    mov  rdx, r13
    add  rdx, r14                       ; rdx = end_offset (offset + n)
    sub  rdx, 1                         ; rdx = last_byte_offset
    shr  rdx, 12                        ; rdx = end_page
    cmp  r9, rdx
    jne  tmpfs_read_fail                ; cross-page (R16.M2 backtrack point)
```

After this: `r9 = start_page` in `[0, 15]`.

**Why the constraint is post-clamp.** A pre-clamp check would
reject cases like `offset=0, len=65536, size=100` where the raw
range crosses pages but the clamped range fits in page 0. Clamping
first, checking second, gives the primitive its widest useful
range: any single-page slice of a file within `[offset, offset +
min(len, size - offset))` is readable.

### 4.8 Page-slot load

`&page_ptrs[start_page] = inode + 16 + start_page * 8`. Two proven
lea forms (same shape as tmpfs_write §4.6):

```asm
    lea  rax, [r15 + 16]                ; rax = &page_ptrs[0]
    mov  r8, [rax + r9*8]               ; r8 = page_ptrs[start_page]
```

**Why fold into a single load rather than a two-step lea + deref.**
`tmpfs_write` uses `lea r14, [r15 + 16]` then `lea r14, [r14 +
r9*8]` because it needs to *store* to the slot (lazy alloc
publish). We only *load*, so a `mov r8, [rax + r9*8]` is one
instruction shorter. The `[base + index*8]` SIB form is proven
by `phys_alloc.pdx:47` (`mov r9, [rax + rdx * 8]`).

### 4.9 Hole check

If the loaded page pointer is 0, return 0. Under the R16.M2
scope, this is defensively present but not exercised (the
witness reads from `/tmp/x` after tmpfs_write's own witness
allocated `page_ptrs[0]`).

```asm
    cmp  r8, 0
    je   tmpfs_read_zero_return         ; hole ⇒ 0 bytes read at R16.M2
```

**Why 0 and not memset-to-zero.** POSIX-shaped semantics would
zero-fill the caller's buffer for holes. R16.M2 defers zero-fill
to either (a) `phys_alloc` (which #583 §6.5 recommends make every
allocated page zero) or (b) the multi-page follow-on issue
(which can memset the caller buffer for unallocated pages). At
R16.M2, returning 0 says "we read no bytes" — the caller's buffer
contents are unchanged from before the call, which is the safest
default when the primitive has nothing valid to give.

### 4.10 Memcpy via `rep_movsb`

Compute the intra-page source, wire up `rep_movsb` operands,
clear DF (defensive), and execute.

```asm
    ; --- src = page_va + (offset & 0xFFF) ---
    mov  rcx, r13
    and  rcx, 0xFFF                     ; rcx = intra-page offset
    add  r8, rcx                        ; r8 = src

    ; --- rep_movsb operands: rsi=src, rdi=dst, rcx=count ---
    mov  rsi, r8                        ; src = page_va + intra
    mov  rdi, rbx                       ; dst = buf_ptr
    mov  rcx, r14                       ; count = n
    cld                                 ; DF=0 (forward copy)
    rep_movsb
```

**Direction swap vs write.** In `tmpfs_write`, `rsi = buf_ptr`
(source is caller buffer), `rdi = page_va + intra` (destination
is the file page). Here we swap: `rsi = page_va + intra`
(source is the file page), `rdi = buf_ptr` (destination is the
caller's buffer). This is the entire read/write duality at the
memcpy level.

**Why explicit `cld`.** Same as write's §4.8: defensive DF-clear
guards against callers that fail to respect SysV AMD64's DF=0
convention. Cost: 1 byte, 1 cycle.

**Encoder shape.** `rep_movsb` emits `F3 A4` (2 bytes) per
PA-R13-011 (#940); already exercised by `tmpfs_write.pdx:119`.

### 4.11 Success + failure epilogue

```asm
    ; --- Success: return n ---
    mov  rax, r14                       ; rax = n (clamped bytes read)
    jmp  tmpfs_read_done

tmpfs_read_zero_return:
    xor  rax, rax                       ; rax = 0 (bytes read = 0)
    jmp  tmpfs_read_done

tmpfs_read_fail:
    mov  rax, 0xFFFFFFFFFFFFFFFF        ; error sentinel

tmpfs_read_done:
    pop  r15
    pop  r14
    pop  r13
    pop  r12
    pop  rbx
    ret
```

The zero-return path serves three cases: `len == 0` (§4.2), `offset
>= size` (§4.5 EOF), and hole (§4.9). Consolidating them into one
label saves three `xor rax, rax; jmp done` sequences.

**Why not fold zero-return into the success path.** The success
path returns `mov rax, r14` where `r14 = n`. If we could
guarantee `r14 = 0` in the zero-return cases, we could reuse
the success path. But `r14` is not written on the §4.2 fast path
(zero-length fast path exits before the clamp), so `r14` there
holds whatever the caller-saved value was (garbage). The
explicit `xor rax, rax` at `tmpfs_read_zero_return` ensures a
clean 0 return in all zero-return cases without depending on
`r14`'s initialization.

## 5. Failure paths and side-effect discipline

### 5.1 Failure inventory

| Failure                    | Detected at               | Pool state after     | Buffer state after  |
|----------------------------|---------------------------|----------------------|---------------------|
| Non-REG inode type         | §4.3 `cmp rcx, 1; jne`    | Unchanged.           | Unchanged.          |
| offset > 64 KiB            | §4.4 `cmp r13, 65536; ja` | Unchanged.           | Unchanged.          |
| Cross-page (post-clamp)    | §4.7 `cmp r9, rdx; jne`   | Unchanged.           | Unchanged.          |

Zero-return cases (not failures — legitimate no-ops):

| Zero-return                | Detected at               | Return | Buffer state after  |
|----------------------------|---------------------------|--------|---------------------|
| len == 0                   | §4.2 `cmp r12, 0; je`     | 0      | Unchanged.          |
| offset >= size (EOF)       | §4.5 `cmp r13, rax; jae`  | 0      | Unchanged.          |
| page_ptrs[start_page] == 0 | §4.9 `cmp r8, 0; je`      | 0      | Unchanged.          |

**No pool mutation, ever.** tmpfs_read does not store to
`_tmpfs_inode_pool` on any path — success, zero-return, or
failure. This is the fundamental read/write distinction: reads
are pool-invariant.

**No caller-buffer mutation on failure or zero-return.** The
only path that writes to `buf_ptr` is §4.10 (`rep_movsb`),
which executes only after all three failure gates (§4.3, §4.4,
§4.7) and all three zero-return gates (§4.2, §4.5, §4.9) have
been cleared. A failed or zero-return read leaves the caller's
buffer byte-identical to pre-call.

### 5.2 Why type gate before EOF check

Loading `inode.size` (§4.5) requires that `[r15 + 8]` be a
meaningful `size` field, which is only true for `VNODE_TYPE_REG`.
For a FREE slot (all-zero inode), `size` would be 0 and the EOF
check would pass — but then §4.4's offset-gate would also pass
(offset defaults to 0 in the caller's test scenario), and the
page-slot load at §4.8 would read a zeroed slot. The result
would be `page_ptrs[0] == 0` ⇒ hole ⇒ return 0. That is
technically not incorrect (no bytes read from a nonexistent
file), but it silently blesses reads on freed inodes as
"legitimate zero-byte reads". Type-gating first turns those
into explicit errors, matching write's discipline.

### 5.3 Why clamp before single-page check

See §4.7's "Why the constraint is post-clamp" note. Clamping
first widens the primitive's useful range at zero cost — the
primitive accepts more inputs correctly than the pre-clamp check
would allow, without introducing any incorrect output on any
input.

### 5.4 Backtrack anchor — the multi-page follow-on

The single-page constraint is a **runtime guard**, not a
permanent architectural choice. When the R17 syscall demo (or
an earlier need in R16.M3's vops layer) requires multi-page
reads, the follow-on issue replaces §4.7–§4.10 with a per-page
loop:

```
n_remaining = min(len, size - offset)
cursor_offset = offset
cursor_buf = buf_ptr
n_total = 0
while n_remaining > 0:
    page_idx = cursor_offset >> 12
    intra = cursor_offset & 0xFFF
    chunk = min(n_remaining, 4096 - intra)
    page_va = page_ptrs[page_idx]
    if page_va == 0:
        memset(cursor_buf, 0, chunk)   # zero-fill hole (POSIX)
    else:
        memcpy(cursor_buf, page_va + intra, chunk)
    cursor_offset += chunk
    cursor_buf    += chunk
    n_remaining   -= chunk
    n_total       += chunk
return n_total
```

Two design questions to answer at that time:

1. **Zero-fill policy.** Does the multi-page loop memset the
   caller buffer for holes (POSIX-shaped), or does it truncate
   the read at the first hole (like this R16.M2 primitive
   does — hole ⇒ 0 bytes returned)? POSIX-shaped is more
   compatible with `read(2)`; the R16.M2 single-page hole
   behavior is a simplification.

2. **Buffer atomicity.** If page 2 of a 3-page read faults
   during memcpy, does the caller see pages 1-2 populated and
   page 3 untouched, or is the whole read rolled back? POSIX
   `read(2)` is not atomic — partial buffers are legal on
   signal interruption. The follow-on can inherit that model.

Both are out-of-scope for R16.M2's single-page constraint.

The follow-on's LOC estimate: ~60 additional LOC (per-page loop
around this issue's inner copy + a memset primitive if
zero-fill lands). The change is isolated to `tmpfs_read`; no
other module changes.

## 6. Alternatives considered

### 6.1 Byte-loop memcpy instead of `rep_movsb`

**Proposal.** Use a byte-load / byte-store loop shape (as
`elf_lite.pdx:425-433` does) instead of `rep_movsb`.

**Rejected.** Same reasoning as tmpfs_write §6.1:

1. **Encoder support landed** (PA-R13-011 / #940). Using
   `rep_movsb` validates the landing rather than working around it.
2. **~10x smaller code size.** 2 bytes vs. ~600 bytes for a
   100-byte read.
3. **Microarch efficiency.** Fast String Ops on modern x86.

`rep_movsb` also makes the read/write pair textually symmetric —
the only delta in the memcpy stanza is the source/destination
swap, which is a self-documenting form of the primitive's
duality.

### 6.2 Return `-1` for EOF and `0` only for hole

**Proposal.** Distinguish EOF (`offset >= size`) from hole
(`page_ptrs[i] == 0`) in the return value: EOF returns 0, hole
returns some other sentinel (e.g., `0xFFFFFFFFFFFFFFFE`).

**Rejected.** Two reasons:

1. **POSIX `read(2)` conflates them.** A read past EOF and a
   read from a hole both return 0 (or, for hole, zero-fill —
   which R16.M2 defers). Distinguishing them at the
   primitive's return would require the vops adapter to reunify
   them at the syscall boundary. Better to unify here.
2. **Hole is a rare corner case.** In tmpfs's normal
   usage (create → write → read), every readable page has been
   allocated. Holes arise only from sparse writes (offset > size
   on a write), which the R16.M2 write primitive rejects at its
   range gate. So the hole return path is unreachable from
   normal R16.M2 usage; distinguishing it optimizes for a case
   that cannot occur.

### 6.3 Read into `dst` byte-by-byte with per-byte page lookup

**Proposal.** For each byte in `[0, n)`, compute
`file_offset = offset + i`, `page_idx = file_offset >> 12`, look
up `page_ptrs[page_idx]`, load the byte, store to
`buf_ptr + i`. Handles multi-page naturally without a loop
around the pages.

**Rejected.** Two costs:

1. **~1000x slowdown.** Every byte does a full inode field
   traversal (compute address, load pointer, hole check, add
   intra-offset, load byte, store byte). vs. `rep_movsb`'s
   direct byte-block copy.
2. **Doesn't scale to multi-page** cleanly either. The
   per-byte page lookup is the wrong granularity; the natural
   granularity is "one memcpy per touched page", which is
   what §5.4's sketch uses.

### 6.4 Materialize `end_page` from a stored `end_offset`

**Proposal.** In §4.6, after computing `n`, also compute
`end_offset = offset + n` and stash it into a callee-save
register for reuse by §4.7's single-page check.

**Rejected.** The compute is one `add`; reusing it saves one
`add` at §4.7 but costs one register slot. We already use 5
push slots for alignment; freeing one wouldn't save the push
(the four-slot push wouldn't align). Zero win, added complexity.

### 6.5 Zero-fill caller buffer for hole reads

**Proposal.** At §4.9, if `page_ptrs[start_page] == 0`, execute
a `rep_stosb` (or byte loop) to zero the first `n` bytes of the
caller's buffer, then return `n`. Matches POSIX read(2) for
sparse files.

**Rejected for R16.M2, revisited for the multi-page follow-on.**
At R16.M2:

1. The witness never reads from a hole (tmpfs_write left
   `page_ptrs[0]` populated for `/tmp/x`).
2. Zero-fill adds another mnemonic (`rep_stosb`) and its
   verification — encoder is present (PA-R13-011 §encoder
   table, related to `rep_movsb`), but not yet exercised by
   any tmpfs primitive.
3. The zero-fill invariant lives most naturally with
   `phys_alloc` (see tmpfs_write §6.5): if every allocated
   page is zero, then holes-within-allocated-pages naturally
   zero-fill on read. Only fully-unallocated pages (which R16.M2
   doesn't have at all after tmpfs_write) need the memset.

The multi-page follow-on lifts this decision explicitly per
§5.4's "zero-fill policy" question.

### 6.6 Fold read + write into a single "transfer" primitive with a direction bit

**Proposal.** Have a single `tmpfs_transfer(inode_idx, buf, len,
offset, direction)` that reads or writes based on the fifth arg.
Reduces code duplication.

**Rejected.** Three costs:

1. **The two paths diverge on more than direction.** Write has
   lazy allocation, size update, and cross-page = error semantics.
   Read has EOF handling, clamp, and hole = zero-return
   semantics. A unified primitive would carry six branches on the
   direction bit, one per divergent behavior. Not simpler.
2. **The five-arg calling convention breaks the vops shape.**
   The vops table entries are `(vnode_ptr, buf, len, offset) ->
   count`; a fifth argument would require a different vops slot
   pair or an extension of the vops shape. Neither is warranted.
3. **The two primitives are separately testable.** Splitting
   them lets #583 and #584 verify independently. Fusing them
   would collapse two witnesses into one, saving marker lines
   at the cost of coverage granularity.

The read/write split is the correct decomposition.

### 6.7 Range-gate `len` up front like write

**Proposal.** Mirror `tmpfs_write` §4.4 exactly and reject
`len > 65536` at entry, in addition to the offset check.

**Rejected.** Read has no overflow risk because §4.6 clamps
before adding. A read with `len = u64::MAX` and `size = 100`
returns 100 bytes, which is the POSIX-correct answer. Rejecting
oversized `len` would turn correct requests into errors, adding
zero safety.

The asymmetry is deliberate: write's range gate protects against
overflowing the sum for size-update math; read's clamp handles
the same overflow risk implicitly.

## 7. Invariants

### 7.1 Success returns `n` in `[1, 65536]`

The success path returns `mov rax, r14` where `r14 = n = min(len,
size - offset)`.

- Upper bound: `size <= 65536` (invariant established by write's
  §4.4 range gate + size-update discipline), so `size - offset <=
  65536`, so `min(len, size - offset) <= 65536`.
- Lower bound: §4.2's zero-length fast path takes `len == 0` out
  of the success path. §4.5's EOF check takes `offset >= size`
  out. So on the success path, `len >= 1` and `size - offset >=
  1`, so `n >= 1`.

### 7.2 Zero-return returns exactly 0

The `tmpfs_read_zero_return` label (§4.11) executes `xor rax, rax`
and returns. Reached by three cases (§5.1): `len == 0`, EOF, hole.

### 7.3 Failure returns exactly `0xFFFFFFFFFFFFFFFF`

The failure path (§4.11) executes `mov rax, 0xFFFFFFFFFFFFFFFF`
— a `mov r64, imm64` encoding (10 bytes). Callers using
`cmp rax, 0xFFFFFFFFFFFFFFFF` (or the equivalent `cmp rax, -1;
je error`) detect the error unambiguously.

### 7.4 Post-success, `_tmpfs_inode_pool` is byte-identical to pre-call

No path stores to the pool. Verified by inspection of §4.
`tmpfs_read` has no equivalent of `tmpfs_write`'s
`mov [r14], r8` (page publish) or `mov [r15 + 8], rax` (size
update).

### 7.5 Post-success, `_phys_pool_bitmap` is byte-identical to pre-call

No path calls `phys_alloc` or `phys_free`. Verified by
inspection of §4.

### 7.6 Post-success, `buf_ptr[0..n]` matches `file_bytes[offset..offset+n]`

`rep_movsb` with `rsi = page_va + (offset & 0xFFF)`, `rdi =
buf_ptr`, `rcx = n` copies exactly `n` bytes from source to
destination. Under the single-page constraint (§4.7), all `n`
source bytes lie in one page, at intra-page offsets `[offset &
0xFFF, (offset & 0xFFF) + n)`. Under tmpfs_write's §7.6
invariant, those page bytes match the source buffer of the
prior write. Chained: `buf_ptr[0..n]` matches
`write_buf[offset..offset+n]`.

### 7.7 Post-any-outcome, no bytes past `buf_ptr + n` are written

`rep_movsb` writes exactly `rcx` = `n` bytes. `buf_ptr + n` and
beyond are not touched. Callers can safely fill the tail of a
larger buffer with their own initialization before calling.

### 7.8 Read/write chain: write(x, buf, k, o) then read(x, dst, k, o) → dst[0..k] == buf[0..k]

Composing tmpfs_write's §7.6 invariant with this issue's §7.6:
after `tmpfs_write(x, buf, k, o)` (with `k > 0` and no
constraint failure), file bytes `[o, o+k)` match `buf[0..k]`.
Then `tmpfs_read(x, dst, k, o)` under matching constraints (`k
+ o <= size` guaranteed by post-write invariant `size >= o + k`,
so no clamp) returns `n = k` and `dst[0..k]` matches file bytes
`[o, o+k)` which matches `buf[0..k]`. Transitively, `dst[0..k]
== buf[0..k]`. This is the "read after write returns same bytes"
acceptance criterion.

### 7.9 Read past EOF returns 0

`tmpfs_read(x, dst, k, o)` with `o >= size`: §4.5 branches to
`tmpfs_read_zero_return`, which returns 0. This is the "read
past EOF returns 0" acceptance criterion.

### 7.10 `rep_movsb` is safe with rcx == n >= 1

§7.1 gives `n >= 1` on the success path. `rep_movsb` with rcx
>= 1 performs at least one iteration; per the x86 spec, DF=0
(which §4.10's `cld` ensures) means the copy proceeds
low-address → high-address, matching the natural byte order.

## 8. Encoder verification

Every mnemonic used is proven in landed modules, most of them
already exercised by `tmpfs_write.pdx` at R16-M2-005.

| Shape                              | Proven by                                                                        |
|------------------------------------|----------------------------------------------------------------------------------|
| `push` / `pop r64`                 | `tmpfs_write.pdx:43-47, 143-147`. 5-push uniform with tmpfs_write.                |
| `mov r64, r64`                     | Ubiquitous.                                                                       |
| `call sym`                         | Ubiquitous.                                                                       |
| `xor r64, r64`                     | Ubiquitous zero-idiom.                                                            |
| `mov_b r64, [r64 + disp8]`         | `tmpfs_write.pdx:63`. Load form for `inode.type` at `+0`.                          |
| `mov r64, [r64 + disp8]`           | `tmpfs_write.pdx:124`. Load `inode.size` at `+8`.                                 |
| `mov r64, [r64 + r64*8]`           | `phys_alloc.pdx:47` (`mov r9, [rax + rdx * 8]`). Used for the fused page-slot load. |
| `lea r64, [r64 + disp8]`           | `tmpfs_write.pdx:90` (`lea r14, [r15 + 16]`). Same shape here for `lea rax, [r15 + 16]`. |
| `cmp r64, imm8`                    | Ubiquitous.                                                                       |
| `cmp r64, imm32`                   | `tmpfs_write.pdx:69, 71, 76` (`cmp r13, rax` with `rax = 65536`).                  |
| `cmp r64, r64`                     | `tmpfs_write.pdx:86` (`cmp r9, rdx`).                                              |
| `shr r64, imm8`                    | `tmpfs_write.pdx:81, 85`.                                                          |
| `and r64, imm32`                   | `tmpfs_write.pdx:111` (`and rcx, 0xFFF`).                                          |
| `sub r64, r64`                     | Ubiquitous (used for `sub rax, r13` in the clamp).                                 |
| `sub r64, imm8`                    | `tmpfs_write.pdx:84` (`sub rdx, 1`).                                                |
| `add r64, r64`                     | Ubiquitous.                                                                       |
| `mov r64, imm32`                   | Ubiquitous (for `mov rax, 65536`).                                                 |
| `mov r64, imm64`                   | `tmpfs_write.pdx:140` (`mov rax, 0xFFFFFFFFFFFFFFFF`). Reused for sentinel.        |
| `ja` / `jae` / `jbe` / `je` / `jne` / `jmp` | Ubiquitous. `jae` at §4.5 for unsigned EOF; `jbe` at §4.6 for clamp branch. |
| `cld`                              | `tmpfs_write.pdx:118`. Same defensive DF-clear.                                    |
| `rep_movsb`                        | `tmpfs_write.pdx:119`. Same F3 A4 encoding per PA-R13-011 (#940).                  |

**No new encoder shapes.** Every mnemonic used here has landed
before R16-M2-006. The read primitive is entirely composed of
patterns already proven by `tmpfs_write` and its upstreams.

**Shapes deliberately avoided (same as write):**

- `mov [r64 + r64*8], r64` (SIB store) — not needed; read only
  loads from `page_ptrs[i]`.
- `mov_w [r64 + disp8], r64` narrow-store — not needed; no field
  writes at all.

## 9. Test canary — R16 TMPFS READ OK

Runs in `kernel_main` immediately after the `R16 TMPFS WRITE OK`
marker. Placement rationale: reuses the `/tmp/x` inode state
that #583's witness populated (`size = 100`, `page_ptrs[0]` non-zero,
first 100 bytes = `0x41`). No new witness names needed; the
destination buffer replaces the write-side source buffer's role.

Four sub-tests, one marker (matches the two acceptance criteria
+ two invariant witnesses).

### 9.1 Witness fixture — destination buffer + message strings

In `tools/boot_stub.S`, immediately after the `tmpfs_write_fail_msg`
string (~line 560):

```s
# R16-M2-006 (#584): tmpfs_read witness — 128-byte destination buffer
# (16 u64 slots; covers the 100-byte read from /tmp/x plus tail slack
# for the sub-test D partial-read of 50 bytes at offset 50).
.global tmpfs_read_dst_buf
.align 8
tmpfs_read_dst_buf:
    .rept 16
    .quad 0x0000000000000000
    .endr

# R16-M2-006 (#584): tmpfs_read witness success + failure messages
.global tmpfs_read_ok_msg
.align 8
tmpfs_read_ok_msg: .ascii "R16 TMPFS READ OK\n\0"

.global tmpfs_read_fail_msg
.align 8
tmpfs_read_fail_msg: .ascii "R16 TMPFS READ FAIL\n\0"
```

Destination buffer is 128 bytes of `0x00`. Zero-initialized so a
short/failed copy is distinguishable from a full copy: any post-
read byte in the [0, n) region that is still 0x00 indicates a
memcpy shortfall.

### 9.2 Preamble — recover `x_idx` from `/tmp/x`

Locate the inode that `tmpfs_create`'s witness placed under
`/tmp/x`. Reuses `witness_name_tmp` and `witness_name_any` from
boot_stub.S — no new witness name strings needed.

```asm
    ; --- Recover tmp_idx via lookup on root ---
    mov  rdi, 1                             ; root_idx = TMPFS_INODE_IDX_ROOT
    lea  rsi, [rip + witness_name_tmp]      ; "tmp\0"
    call tmpfs_lookup
    cmp  rax, 0
    je   tmpfs_read_witness_fail
    mov  r12, rax                           ; r12 = tmp_idx

    ; --- Recover x_idx via lookup on /tmp ---
    mov  rdi, r12                           ; tmp_idx
    lea  rsi, [rip + witness_name_any]      ; "x\0"
    call tmpfs_lookup
    cmp  rax, 0
    je   tmpfs_read_witness_fail
    mov  r13, rax                           ; r13 = x_idx (source of the reads)
```

If either lookup misses, the witness fails — but that would
indicate a regression in tmpfs_lookup / tmpfs_create, not
tmpfs_read.

### 9.3 Sub-test A — tmpfs_read returns 100

Direct acceptance criterion "read after write returns same
bytes" — half A (the count).

```asm
    ; --- tmpfs_read(x_idx, dst_buf, 100, 0) → expect rax = 100 ---
    mov  rdi, r13                           ; x_idx
    lea  rsi, [rip + tmpfs_read_dst_buf]    ; buf_ptr = &dst[0]
    mov  rdx, 100                           ; len = 100
    xor  rcx, rcx                           ; offset = 0
    call tmpfs_read
    cmp  rax, 100
    jne  tmpfs_read_witness_fail
```

Proves: (a) tmpfs_read accepts the four args; (b) type gate
passed (x is REG); (c) offset range gate passed (0 <= 65536);
(d) EOF check passed (0 < 100 = size); (e) clamp resolved to
`n = min(100, 100 - 0) = 100`; (f) single-page constraint
passed (bytes [0, 100) all in page 0); (g) hole check passed
(page_ptrs[0] non-zero from #583); (h) memcpy executed; (i)
return value is `n`.

### 9.4 Sub-test B — dst_buf content matches the write source

Direct acceptance criterion "read after write returns same
bytes" — half B (the bytes).

```asm
    ; --- Verify first 8 bytes of dst are all 'A' (0x4141414141414141) ---
    lea  r14, [rip + tmpfs_read_dst_buf]
    mov  rcx, [r14]                         ; rcx = u64 at dst_buf[0]
    mov  rdx, 0x4141414141414141            ; expected: 8 x 'A'
    cmp  rcx, rdx
    jne  tmpfs_read_witness_fail
```

Proves: `rep_movsb` correctly copied source bytes (which are
100 x 0x41 from #583's `tmpfs_write_src_buf`) into the
destination. Reading 8 bytes at once catches memcpy failures at
multiple offsets — if the copy count was too short, byte 7
would be zero (fresh dst_buf default) not 'A'.

**A stronger content check** — reading byte 99 (last written
byte) — would need an intermediate compute `dst_buf + 99` and
byte-load. Deferred to a follow-on if a content bug slips
through the u64 check.

### 9.5 Sub-test C — tmpfs_read past EOF returns 0

Direct acceptance criterion "read past EOF returns 0".

```asm
    ; --- tmpfs_read(x_idx, dst_buf, 10, 100) → expect rax = 0 ---
    ; offset == size == 100 → EOF path taken
    mov  rdi, r13                           ; x_idx
    lea  rsi, [rip + tmpfs_read_dst_buf]    ; buf_ptr
    mov  rdx, 10                            ; len = 10
    mov  rcx, 100                           ; offset = 100 (== size)
    call tmpfs_read
    cmp  rax, 0
    jne  tmpfs_read_witness_fail
```

Proves: the EOF check at §4.5 correctly branches to
`tmpfs_read_zero_return` when `offset >= size`. Also proves
the failure sentinel does **not** trigger for this legitimate
zero-return.

**Why offset = 100 (equal to size) rather than 101.** Both are
"past EOF" per POSIX, but offset = 100 exercises the `jae`
edge case (equal). offset = 101 would test `above`. The `jae`
covers both, so the equal case is a stronger boundary test.

### 9.6 Sub-test D — partial read clamps to size

Partial-read invariant: `tmpfs_read(x, dst, 100, 50)` with
`size = 100` should return `min(100, 100 - 50) = 50`, not 100.

```asm
    ; --- tmpfs_read(x_idx, dst_buf, 100, 50) → expect rax = 50 ---
    mov  rdi, r13                           ; x_idx
    lea  rsi, [rip + tmpfs_read_dst_buf]    ; buf_ptr
    mov  rdx, 100                           ; len = 100 (requested)
    mov  rcx, 50                            ; offset = 50
    call tmpfs_read
    cmp  rax, 50                            ; expect clamp to size - offset
    jne  tmpfs_read_witness_fail
```

Proves: the clamp at §4.6 correctly picks `min(len, size -
offset)`. Under `len = 100`, `size - offset = 50`, the clamp
takes the `jbe` branch and returns `n = 50`. Also proves the
single-page constraint (§4.7) passes on the clamped-and-shifted
range `[50, 100)` (all in page 0).

**Why this test after sub-test C.** Sub-test C leaves the
dst_buf partially overwritten (or unchanged — the EOF path
doesn't copy). Sub-test D's copy of 50 bytes at offset 50
lands in `dst_buf[0..50]`, overwriting the first 50 bytes of
whatever sub-test A's copy left. This is order-sensitive only
if we did a content check on D's dst_buf; we don't (D checks
only the return count), so ordering doesn't matter.

### 9.7 Marker

On all four sub-tests green:

```
R16 TMPFS READ OK
```

Fingerprint added to:

- `tests/r14b/expected-boot-r14b-loader.txt` — line immediately
  following `R16 TMPFS WRITE OK` (line 24).
- `tests/r15/expected-boot-r15-ring3.txt` — line 34.
- `tests/r15/expected-boot-r15-process.txt` — line 35.

Witness failure prints `R16 TMPFS READ FAIL` and falls through.

## 10. Boot integration

Witness is inserted in `kernel_main.pdx` between
`tmpfs_write_witness_done` (line 2573) and the `wrmsr` for
GS_BASE (line 2576). Same insertion pattern as the preceding
tmpfs witnesses.

Rough kernel_main.pdx delta:

```asm
      tmpfs_write_witness_done:

      // ============================================================
      // R16-M2-006 (#584): tmpfs_read witness — 4 sub-tests, 1 marker
      // ============================================================
      tmpfs_read_witness:
          // ---------- Preamble: recover tmp_idx, x_idx ---------- (§9.2)
          // ---------- Sub-test A: tmpfs_read returns 100 ---------- (§9.3)
          // ---------- Sub-test B: dst content = 8 x 'A' ---------- (§9.4)
          // ---------- Sub-test C: read past EOF returns 0 ---------- (§9.5)
          // ---------- Sub-test D: partial-read clamps to 50 ---------- (§9.6)

          lea  rdi, [rip + tmpfs_read_ok_msg]
          call uart_puts
          jmp  tmpfs_read_witness_done

      tmpfs_read_witness_fail:
          lea  rdi, [rip + tmpfs_read_fail_msg]
          call uart_puts

      tmpfs_read_witness_done:

      // R14b-m5-002 (#507): IA32_GS_BASE = &_cpu_locals[0] on CPU0.
      lea rax, [rip + _cpu_locals];
      ...
```

State side-effect: after the witness, `/tmp/x`'s inode is
byte-identical to its post-#583-witness state (size = 100,
page_ptrs[0] populated, page contents = 100 x 'A'). Only
`tmpfs_read_dst_buf` in `.data` has been mutated (partially
overwritten to `50 x 'A'`, then `100 x 'A'`, then... — depending
on sub-test ordering; the final state depends only on the last
successful read). Downstream code does not consume
`tmpfs_read_dst_buf`, so its final state is inert.

## 11. Cross-references

- Issue: paideia-os#584
- Milestone: R16.M2 (tmpfs — in-memory VFS backend)
- Upstream:
  - paideia-os#579 (R16-M2-001 — frozen layout §2; offsets `+0`
    (type), `+8` (size), `+16` (page_ptrs[]) loaded here).
  - paideia-os#580 (R16-M2-002 — `tmpfs_inode_alloc`, tmpfs_init;
    frozen conventions this issue does not touch).
  - paideia-os#581 (R16-M2-003 — `tmpfs_lookup` used by the
    witness preamble to recover `x_idx`).
  - paideia-os#582 (R16-M2-004 — `tmpfs_create` established
    `/tmp/x`; register discipline peer).
  - paideia-os#583 (R16-M2-005 — `tmpfs_write` — the peer
    primitive this issue mirrors. #583's witness left `/tmp/x`
    at the exact state this witness reads back.)
  - paideia-os#649 (R15-M1-010 — `phys_alloc`/`phys_free`; VA
    contract that `page_ptrs[i]` values obey.)
  - paideia-as#940 (PA-R13-011 — `rep_movsb` encoder landed).
- Downstream consumers:
  - A follow-on R16.M2 issue (multi-page tmpfs_read — lifts the
    single-page constraint via a per-page loop around this
    issue's inner rep_movsb work; §5.4 sketches the shape.)
  - A follow-on `phys_alloc` zero-fill issue (see #583 §6.5) —
    orthogonal; centralizes the fresh-page zero invariant so
    the multi-page follow-on's zero-fill policy for holes is
    simplified.
  - R16.M3 `tmpfs_vops` — registers a wrapper adapting
    `tmpfs_read(inode_idx, buf, len, offset)` to
    `vops_read(vnode_ptr, buf, len, offset)` by reading
    `vnode.backend_ptr` (+32) as the inode idx.
  - R17 `sys_read` — user-facing syscall; calls into the vops
    chain that reaches this primitive, then does a
    `copy_to_user` from the kernel buffer to userspace.
- Sibling primitive: `tmpfs_write` (#583) — read's write-side
  mirror. Every design choice here is deliberately either
  identical (register discipline, encoder shapes, failure
  sentinel) or narrowly divergent (EOF clamp vs range overflow;
  hole = zero-return vs lazy alloc; no size update). The
  divergences are enumerated in §1 "Read/write symmetry".
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 12 item 6 — "Copy from inode's page(s) into user
  buf; respect offset + count. Acceptance: read after write
  returns same bytes; read past EOF returns 0."
