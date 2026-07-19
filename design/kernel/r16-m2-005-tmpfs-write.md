---
issue: 583
milestone: R16.M2 (tmpfs — in-memory VFS backend)
subsystem: 12 — tmpfs
topic: tmpfs_write — allocate page on first write; copy bytes; update size (R16-M2-005)
freeze-discipline: strict
  - tmpfs inode layout frozen by R16-M2-001 (#579); this issue writes into
    frozen offsets `+8` (size, u64) and `+16..+144` (page_ptrs[16], u64*16),
    and reads `+0` (type). No numeric offset is embedded outside the
    exported constants from `inode.pdx`.
  - `tmpfs_write` signature `(u64, u64, u64, u64) -> u64` — `(inode_idx,
    buf_ptr, len, offset) -> bytes_written_or_error` — is frozen for the
    whole R16.M2 series. Downstream `tmpfs_read` (#584) mirrors this
    shape with `buf_ptr` as destination and returns bytes-read; the vops
    adapter at R16.M3 relies on both primitives having a uniform contract.
  - Single-page constraint (§1) is a **runtime-enforced** constraint at
    R16.M2, not a permanent one. Multi-page loop lands in a follow-on
    issue when the R17 syscall demo needs it. The runtime guard rejects
    cross-page writes with the error sentinel — never silently truncates,
    never silently corrupts.
  - phys_alloc VA/PA contract: at R16.M2, `phys_alloc(0)` returns a
    higher-half kernel VA (bit 63 set) per phys_alloc.pdx §doc; when
    #658 rebases phys_alloc onto genuine PAs, this issue's inode field
    stays byte-identical and the vops adapter (which needs a VA for
    the memcpy) grows a PA→VA lift there.
blocks:
  - "#584 (`tmpfs_read` — mirror; reads `min(inode.size - offset, len)`
    bytes into caller's buffer. Depends on the invariant that
    `page_ptrs[i]` is non-zero iff bytes at page i have been written,
    which this issue establishes.)"
  - "R16.M3 tmpfs vops table (`tmpfs_vops` — registers a wrapper
    adapting `tmpfs_write(inode_idx, buf_ptr, len, offset)` to the vops
    shape `(vnode_ptr, buf_ptr, len, offset)` by reading the vnode's
    `backend_ptr` (+32) as the inode idx.)"
  - "R17 `sys_write` syscall — user-facing entry point that copies from
    user space to a kernel buffer, then reaches this primitive through
    the vops chain. Depends on this issue's contract that the passed
    buffer is a kernel VA (the syscall trampoline does the copy_from_user
    first)."
touching:
  - src/kernel/core/fs/tmpfs/write.pdx           (new module — `tmpfs_write`; ~120 LOC)
  - src/kernel/boot/kernel_main.pdx              (witness block ~85 LOC)
  - tools/boot_stub.S                            (100-byte source buf + 2 message strings; ~15 LOC)
  - tests/r14b/expected-boot-r14b-loader.txt     (marker: "R16 TMPFS WRITE OK")
  - tests/r15/expected-boot-r15-ring3.txt        (marker)
  - tests/r15/expected-boot-r15-process.txt      (marker)
  - design/kernel/r16-m2-005-tmpfs-write.md      (this doc)
related:
  - design/kernel/r16-m2-001-tmpfs-inode-pool.md (#579 — frozen layout §2;
    every field offset this module reads/writes is exported by
    `inode.pdx`)
  - design/kernel/r16-m2-004-tmpfs-create.md     (#582 — the exact 5-push
    register discipline this module reuses; §3 alignment discipline; the
    `x` file this witness writes into was created by that issue's witness
    and is still live at boot time)
  - src/kernel/core/mm/phys_alloc.pdx            (bitmap-first order-0
    allocator; returns kernel VA in [1, 4 MiB) offset from
    `_phys_page_pool` VA base with bit 63 set. Contract: returns 0 on OOM.)
  - design/paideia-as/non-milestone-issue-1228-bulkmemops-phase2.md
    (paideia-as encoder support for `rep_movsb` — landed with F3 A4
    byte sequence per §encoder table; the smoke test at
    `tools/paideia-as/tests/build-emit/rep_movsb_smoke.pdx` proves the
    bare-form encoding used by this module)
  - design/milestones/r14b-tactical-plan.md      §Subsystem 12 item 5 —
    "Allocate page(s) on first write; copy from user buf; update
    inode.size. Acceptance: write 100 bytes → inode.size == 100."
---

# R16-M2-005 — `tmpfs_write` (first-write page alloc + memcpy + size bump, #583)

## 1. Scope

Ship the tmpfs data-write primitive that turns a `(inode_idx, buf,
len, offset)` tuple into (a) a lazily-allocated backing page threaded
into the inode's `page_ptrs[]`, (b) a byte-for-byte copy of `buf` into
the page at the correct intra-page offset, and (c) an updated
`inode.size` reflecting the highest byte written so far.

Concretely, `tmpfs_write` takes the acceptance test — "write 100
bytes at offset 0 into a freshly-created REG file; `inode.size` reads
100" — end to end.

**Scope constraint: single-page writes only.** This issue implements
the **single-page path** — writes where `start_page == end_page` (both
`offset >> 12` and `(offset + len - 1) >> 12` yield the same index in
`[0, 15]`). Cross-page writes return the error sentinel (`u64::MAX`)
without touching state; the multi-page loop lands in a follow-on
issue (§5 backtrack anchor). The 100-byte-at-offset-0 acceptance test
lands squarely inside page 0, so the constraint is invisible to R16.M2's
demo; the runtime guard exists purely so a future caller (or a bug)
cannot silently corrupt inode state by rolling off page 0.

**Rejection of stub-shape.** A "stub" tmpfs_write for R16.M2 would
either (a) hard-code offset = 0 and skip the general offset math, or
(b) silently truncate cross-page writes to the first page. Both are
outlawed by the R16.M2 discipline ("No stub / placeholder
implementations shipped — backtrack via new issue if a design gap
surfaces"). Instead, this module implements the general single-page
case (any offset in `[0, 4095]`, any `len` in `[1, 4096 - offset]`)
correctly, and refuses cross-page writes with a distinguishable error.
When multi-page is needed, a new issue extends the same code path with
a per-page loop — no rewrite.

Behavior spelled out:

1. **Enter** with `rdi = inode_idx` (u64 with u16 semantics), `rsi =
   buf_ptr` (u64, kernel VA of source bytes), `rdx = len` (u64, byte
   count), `rcx = offset` (u64, starting byte offset within the file).
   No bounds check on `inode_idx` — callers reach us only through a
   live index (initially from #582's `tmpfs_create` return, later from
   `vnode.backend_ptr` via the vops adapter).
2. **Zero-length fast path.** If `len == 0`, return 0 immediately.
   Skips all page work and size bookkeeping. This is a legal no-op
   (POSIX-shaped write(2) with count=0).
3. **Type gate.** Load `inode.type` at `+0`; if it is not
   `VNODE_TYPE_REG` (1), return the error sentinel. Directories,
   symlinks, and any future non-regular types cannot be `write`-target
   files — the vops layer's `vops_write` will fail here rather than at
   the syscall boundary, keeping the "wrong type" failure single-sourced.
4. **Range gate.** Reject `offset >= 65536`, `len > 65536`, and
   `offset + len > 65536`. 64 KiB is the frozen per-file cap (16 pages ×
   4 KiB, from #579 §layout). Explicit checks on both operands before
   the add catches overflow at the source (a caller passing offset =
   `u64::MAX` would wrap on the add otherwise).
5. **Single-page constraint.** Compute `start_page = offset >> 12` and
   `end_page = (offset + len - 1) >> 12`. If they differ, reject with
   the error sentinel. This is the constraint from §1; a follow-on
   issue lifts it by looping this issue's per-page work across
   `[start_page, end_page]`.
6. **Page-slot address.** The inode's `page_ptrs[i]` for
   `i = start_page` lives at `inode + 16 + i * 8`. Compute this address
   once as `r9 = &page_ptrs[start_page]` via two proven lea forms
   (`lea r9, [r15 + 16]`; `lea r9, [r9 + rax*8]`).
7. **Lazy allocation.** Load `[r9]`. If it is 0 (never written), call
   `phys_alloc(0)` to obtain a 4 KiB page (kernel VA per phys_alloc's
   R15-M1-010 contract) and store the returned VA into `[r9]`. If
   `phys_alloc` returns 0 (OOM), propagate the error sentinel.
8. **Memcpy.** Compute `dst = page_va + (offset & 0xFFF)` (intra-page
   offset). Set up `rsi = buf_ptr`, `rdi = dst`, `rcx = len`, `cld`
   (defensive DF-clear), then `rep_movsb`. paideia-as landed the
   `RepMovsb` encoder at PA-R13-011 (#940); the bare form emits
   `F3 A4` (§8 encoder verification).
9. **Size update.** Compute `end_offset = offset + len`. If
   `end_offset > inode.size`, store `end_offset` into `inode.size` at
   `+8`. Otherwise leave `inode.size` alone (in-place rewrite of a
   prefix does not shrink the file — POSIX-shaped semantics).
10. **Return** `len` (bytes written) in `rax`.

Out of scope (deliberately deferred):

- **Multi-page writes.** Handled by a follow-on issue that keeps this
  module's per-page primitive as its inner loop. §5.4 sketches the
  backtrack shape so the follow-on can pick up cleanly.
- **`copy_from_user`.** `buf_ptr` is treated as a **kernel VA**. The
  syscall boundary (R17) will land the user-to-kernel bounce in
  `sys_write`'s trampoline before it reaches this primitive. R16.M2's
  witness passes a `.data`-resident kernel buffer.
- **Sparse zeroing.** Between `inode.size` and `offset` on a
  seek-past-end write, POSIX says the gap reads as zeros. At R16.M2
  we cannot reach that case (single-page + acceptance test uses
  offset = 0), but the invariant we uphold is: `page_ptrs[i]` is
  non-zero only for pages actually touched. A follow-on `tmpfs_read`
  (#584) enforces the "zero for unwritten pages" invariant on the
  read side; this module contributes by leaving unwritten
  `page_ptrs[]` slots at `.bss` zero.
- **Page-boundary partial-page zeroing.** When `phys_alloc` returns a
  fresh page, the page's contents are whatever the previous inhabitant
  left (frame reuse pattern). For the single-page case with
  `offset & 0xFFF` non-zero, the bytes before the write start would be
  visible to a later `tmpfs_read` as garbage. R16.M2's witness writes
  from offset 0 so this is invisible. A follow-on will either (a)
  zero the fresh page before returning it from `phys_alloc`, (b) zero
  it at the `tmpfs_write` boundary before the copy, or (c) reject
  writes with non-aligned offsets until sparse-zero semantics land.
  §6.4 argues for (a) as the correct owner of the zeroing invariant.
- **Write barriers.** No `sfence` after the copy. tmpfs is a purely
  in-memory FS on a coherent x86_64; readers observe stores in program
  order. If a future SMP concurrency model requires ordering, it lands
  as a follow-on with the FS lock design.
- **Timestamps** (`mtime`, `ctime`). Same reasoning as #582 §out-of-scope
  — the inode layout has no timestamp fields; they will land with the
  disk-backed FS at R18+.
- **Refcount / link_count bumps.** `tmpfs_write` does not touch these;
  a write on a live file leaves refcount unchanged (the caller already
  holds a live reference via the vnode/backend chain).

## 2. Contract

```
tmpfs_write : (u64, u64, u64, u64) -> u64 !{mem} @{}
  → rax = len                    on success (bytes actually written)
  → rax = 0                      when len == 0 (legal no-op)
  → rax = 0xFFFFFFFFFFFFFFFF     on failure (bad type, range, cross-page, OOM)
```

Nullary on capabilities at R16.M2 (no capability system yet). `!{mem}`
because we mutate `_tmpfs_inode_pool` (size + one page_ptrs slot),
`_phys_pool_bitmap` (via `phys_alloc`), and the freshly-allocated
page's contents.

**Non-leaf.** Makes nested calls to `tmpfs_inode_slot` (once, for the
inode pointer) and `phys_alloc` (once, only when the page slot is 0 —
lazy allocation). Both callees may clobber caller-save regs; the
5-push callee-save prologue (§3) keeps every persistent value in
callee-save registers.

**Error signaling.** All failure modes collapse to `rax = -1`
(`0xFFFFFFFFFFFFFFFF`, i.e., every bit set). This is a value the
caller can never obtain from a legitimate write (`len` is capped at
65536 = `0x10000` by the range gate, so any non-negative return in
`[0, 65536]` is a byte count and any value above that is an error).
Distinguishing the specific failure mode (bad type vs range vs OOM)
is deferred to the vops layer at R18+ when POSIX-shaped `errno`
lands; at R16.M2 the caller sees "wrote all bytes" or "failed".

**Success return equals `len`.** `tmpfs_write` at R16.M2 is
"all-or-nothing" — a successful write copied exactly `len` bytes.
A partial-write return (`rax < len` on some failure mode) is not
implemented; the single-page constraint plus phys_alloc's binary
success/OOM make partial writes structurally impossible at this
issue's scope. A follow-on multi-page implementation could return
a partial count if the OOM hits page 2 of a 3-page write; that's
that issue's contract to design.

**Idempotence.** Not idempotent. Calling `tmpfs_write(x, buf, 100, 0)`
twice with the same buffer is well-defined (both writes hit page 0,
size stays 100, byte contents are identical) but the second call is
not a no-op — it still calls memcpy. Callers that want idempotence
must probe `inode.size` themselves.

**Ordering.** All writes to inode fields (`size` at +8, `page_ptrs[i]`
at +16+i*8) and to the backing page are single-threaded at R16.M2 —
no concurrent reader can observe an intermediate state. Under the
future R17 concurrency model, the write ordering is: (a) allocate
page, (b) copy bytes into page, (c) publish `page_ptrs[i]`, (d)
update `size`. Publishing the page pointer before size means a
concurrent reader that sees the new size will find the corresponding
page pointer non-null; publishing size last means a reader that sees
the old size will see either the old page pointer or the new one,
but never a dangling reference. That ordering is what the code below
naturally produces.

## 3. Register discipline

### 3.1 Push plan — 5 pushes

Five-push callee-save prologue: `rbx`, `r12`, `r13`, `r14`, `r15`.
Same alignment argument as `tmpfs_create` (§3.1 of r16-m2-004):
`rsp mod 16 == 8` at entry; five pushes add 40 bytes; `48 mod 16 == 0`
at nested call sites, satisfying SysV AMD64 alignment.

| Reg | Role                                                                 |
|-----|----------------------------------------------------------------------|
| rbx | `buf_ptr` — caller's arg2. Read at the `mov rsi, rbx` right before `rep_movsb`. Must survive `tmpfs_inode_slot` and `phys_alloc` calls. |
| r12 | `len` — caller's arg3. Read at the `mov rcx, r12` right before `rep_movsb`, at the `end_offset = offset + len` compute for the range gate and size update, and at the `mov rax, r12` return. Must survive both nested calls. |
| r13 | `offset` — caller's arg4. Read at the range gate compute, the single-page compute, the intra-page-offset compute (`offset & 0xFFF`), the page-slot compute (`offset >> 12`), and the size-update compute. Must survive both nested calls. |
| r14 | `page_slot_addr` (scratch, holds `&page_ptrs[start_page]`). Set once after the single-page constraint check via two `lea`s; read at the load / allocate-and-store operations. Does not need to survive `phys_alloc` because it is stored into memory (the page-slot address) before the call, and reloaded from `[r14]` after — but the address stays valid across the call (it points into `_tmpfs_inode_pool`, an immutable-address global). So r14 holds an address that survives the call as data. |
| r15 | `inode_ptr` — result of `tmpfs_inode_slot(inode_idx)`. Read at the type-gate, at every field access (page_ptrs[] base, size at +8), and at the size store. Must survive `phys_alloc`. |

**Why 5 registers.** Five persistent values (`buf`, `len`, `offset`,
`inode_ptr`, `page_slot_addr`). Fewer registers would force reloads
from memory (of `inode_ptr` — recomputable via a second
`tmpfs_inode_slot` call — but not of `buf`, `len`, `offset` which are
caller args and would be lost). Five is the minimum for zero reloads.

**Why not fold `page_slot_addr` into r14 = inode_ptr + offset**. The
page slot address `inode + 16 + start_page * 8` is a fixed offset from
`inode_ptr`, so we could recompute it whenever needed. Rejected: the
compute is 5 instructions (lea + shr + shl + lea; see §4.6), and we
read the address twice (at load, at store-back). Caching once saves
5 instructions per subsequent use.

### 3.2 Scratch registers

The following are used within single "phases" and never read across a
nested call:

- `rax` (scratch for byte load at type gate, u64 arithmetic for
  range gate, page slot compute; also holds `end_offset` at size
  update).
- `rcx` (scratch for `end_offset`, `rep_movsb` count, intra-page
  offset).
- `rdx` (scratch for `end_page` compute).
- `r8` (scratch for loaded page pointer; feeds `rep_movsb` dst).
- `r9` (scratch for start_page; feeds page-slot lea).
- `rsi`, `rdi` (implicit operands of `rep_movsb`).

None are read across a nested call. The `phys_alloc` call site sees
all persistent state in `rbx`/r12/r13/r14/r15, which are callee-save
per SysV AMD64 (and per phys_alloc's own R15-M1-010 fix to push
`r12/r13/r14`).

### 3.3 Why not use `r15` morph like tmpfs_create

`tmpfs_create` used a morphing r15 (type → new_ptr). tmpfs_write does
not need that pattern: no argument dies before allocation. All four
args plus the derived inode_ptr live across the whole function body.
Straight-line register allocation is simpler and matches the fact
that this function does less state juggling than `tmpfs_create`.

## 4. Algorithm

### 4.1 Prologue + arg stash

```asm
tmpfs_write:
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

Legal no-op. Skip all page + size work and return 0.

```asm
    cmp  r12, 0
    je   tmpfs_write_zero_len
```

Where `tmpfs_write_zero_len` is a label at the epilogue that returns
`rax = 0`. Placement in §4.10.

### 4.3 Inode pointer + type gate

Get the inode base pointer, then verify type at +0 is `VNODE_TYPE_REG`
(1). Any other type is a caller error.

```asm
    call tmpfs_inode_slot               ; rax = &inode (rdi was inode_idx)
    mov  r15, rax                       ; r15 = inode_ptr

    xor  rcx, rcx
    mov_b rcx, [r15 + 0]                ; rcx = inode.type
    cmp  rcx, 1                         ; VNODE_TYPE_REG
    jne  tmpfs_write_fail
```

### 4.4 Range gate

Reject each of `offset > 65536`, `len > 65536`, and `offset + len >
65536`. Explicit range check on both operands defends against unsigned
overflow of the sum.

```asm
    mov  rax, 65536
    cmp  r13, rax                       ; offset > 64 KiB?
    ja   tmpfs_write_fail
    cmp  r12, rax                       ; len > 64 KiB?
    ja   tmpfs_write_fail
    ; both in [0, 65536], sum fits in u64 without overflow
    mov  rcx, r13
    add  rcx, r12                       ; rcx = end_offset
    cmp  rcx, rax                       ; end_offset > 64 KiB?
    ja   tmpfs_write_fail
```

At this point `rcx` holds `end_offset` — we could stash it in a
callee-save slot for reuse at §4.9, but the recompute is one `add`
and we do not need to preserve it across the phys_alloc call, so
recomputing is cheaper than adding another push.

### 4.5 Single-page constraint

Compute `start_page = offset >> 12` and `end_page = (offset + len - 1)
>> 12`. Because we already rejected `len == 0` at §4.2, `offset + len
- 1 >= offset >= 0` and the `sub 1` is safe.

```asm
    mov  r9, r13                        ; r9 = offset
    shr  r9, 12                         ; r9 = start_page
    mov  rdx, r13
    add  rdx, r12                       ; rdx = end_offset
    sub  rdx, 1                         ; rdx = last_byte_offset
    shr  rdx, 12                        ; rdx = end_page
    cmp  r9, rdx
    jne  tmpfs_write_fail               ; cross-page (R16.M2 backtrack point)
```

After this: `r9 = start_page` in `[0, 15]`.

### 4.6 Page-slot address compute

`&page_ptrs[start_page] = inode + 16 + start_page * 8`. Two proven
lea forms:

```asm
    lea  r14, [r15 + 16]                ; r14 = &page_ptrs[0]
    lea  r14, [r14 + r9*8]              ; r14 = &page_ptrs[start_page]
```

The `[r64 + disp8]` and `[r64 + r64*8]` addressing modes are both
proven in landed modules (`tmpfs_lookup.pdx:69`, `phys_alloc.pdx:47`).

### 4.7 Lazy page allocation

Load the current page pointer; if 0, allocate and store.

```asm
    mov  r8, [r14]                      ; r8 = page_ptr
    cmp  r8, 0
    jne  tmpfs_write_have_page

    ; --- Allocate a fresh order-0 page ---
    xor  rdi, rdi                       ; order = 0
    call phys_alloc                     ; rax = page VA or 0
    cmp  rax, 0
    je   tmpfs_write_fail               ; OOM
    mov  r8, rax                        ; r8 = page_ptr
    mov  [r14], r8                      ; publish into page_ptrs slot

tmpfs_write_have_page:
```

**Why store to `page_ptrs` before the memcpy.** Under R16.M2's
single-threaded execution, ordering here is invisible. Under future
concurrency (R17+), the correct ordering is (a) copy bytes into page,
(b) publish page pointer, (c) update size — a reader that sees the
page pointer will see valid content. **We deviate from that
concurrency-safe ordering here for one reason:** the copy source is
the caller's `buf_ptr`, and if we defer the pointer store until
after `rep_movsb` we would need to preserve `r8` (the page VA) across
`rep_movsb` — but `rep_movsb` clobbers `rdi`, and `r8` is untouched.
So we could defer without cost.

Chosen ordering: store then copy. Reasoning: (a) single-threaded at
R16.M2, so ordering is moot; (b) the store-then-copy shape is what
the multi-page follow-on will use per iteration (allocate, publish,
copy — the copy is per-page and cannot cross iterations); (c) if
`rep_movsb` faults (impossible under the single-page constraint with
validated bounds, but a defensive concern), the page slot is at
least published, so a subsequent write to the same file at the same
offset would reuse it rather than leaking. Deferring is a future
follow-on when the concurrency lock design lands.

### 4.8 Memcpy via `rep_movsb`

Compute the intra-page destination, wire up `rep_movsb` operands,
clear DF (defensive), and execute.

```asm
    ; --- dst = page_va + (offset & 0xFFF) ---
    mov  rcx, r13
    and  rcx, 0xFFF                     ; rcx = intra-page offset
    add  r8, rcx                        ; r8 = dst

    ; --- rep_movsb operands: rsi=src, rdi=dst, rcx=count ---
    mov  rsi, rbx                       ; src = buf_ptr
    mov  rdi, r8                        ; dst
    mov  rcx, r12                       ; count = len
    cld                                 ; DF=0 (forward copy)
    rep_movsb
```

**Why explicit `cld`.** SysV AMD64 mandates DF=0 on function entry
(§3.4.1 of the ABI). But (a) we do not always trust that our callers
respect the ABI — some kernel entry paths may leave DF=1 accidentally,
(b) `cld` is a single-byte instruction (opcode `FC`), and (c) making
the DF discipline local to the memcpy means we never need to audit
callers. Cost: 1 byte, 1 cycle.

**Encoder shape.** `rep_movsb` is a bare-form mnemonic; the encoder
emits `F3 A4` (2 bytes) with no operands, per PA-R13-011 (#940). The
smoke fixture at `tools/paideia-as/tests/build-emit/rep_movsb_smoke.pdx`
covers the four variants (bare, after-cld, after-label, labeled-cld).
The `cld; rep_movsb` sequence used here is exactly the `after_cld`
variant.

### 4.9 Size update

Recompute `end_offset = offset + len` and store it into `inode.size`
if it exceeds the current size (POSIX-shaped "size = max(size,
end_offset)" semantics).

```asm
    mov  rax, r13
    add  rax, r12                       ; rax = end_offset
    mov  rdx, [r15 + 8]                 ; rdx = inode.size
    cmp  rax, rdx
    jbe  tmpfs_write_no_size_bump       ; end <= current size
    mov  [r15 + 8], rax                 ; publish new size

tmpfs_write_no_size_bump:
```

The `jbe` (jump if below-or-equal, unsigned) is correct: sizes are
unsigned.

### 4.10 Success + failure epilogue

```asm
    ; --- Success: return len ---
    mov  rax, r12
    jmp  tmpfs_write_done

tmpfs_write_zero_len:
    xor  rax, rax                       ; rax = 0 (bytes written = 0)
    jmp  tmpfs_write_done

tmpfs_write_fail:
    mov  rax, 0xFFFFFFFFFFFFFFFF        ; error sentinel

tmpfs_write_done:
    pop  r15
    pop  r14
    pop  r13
    pop  r12
    pop  rbx
    ret
```

The zero-length path skips all field mutations and returns 0.

**Why not fold zero-len into the success path.** The success path
returns `rax = r12` (which is len). If len == 0, `mov rax, r12` gives
`rax = 0` — the same answer. So the zero-len label could jump
directly to `tmpfs_write_done` after skipping the fail store. But
having an explicit label makes the intent explicit at the §4.2
comparison and keeps the failure path's fail-store isolated.

## 5. Failure paths and side-effect discipline

### 5.1 Failure inventory

| Failure                    | Detected at               | Pool state after                             |
|----------------------------|---------------------------|----------------------------------------------|
| Non-REG inode type         | §4.3 `cmp rcx, 1; jne`    | Unchanged.                                   |
| offset > 64 KiB            | §4.4 first `ja`           | Unchanged.                                   |
| len > 64 KiB               | §4.4 second `ja`          | Unchanged.                                   |
| offset + len > 64 KiB      | §4.4 third `ja`           | Unchanged.                                   |
| Cross-page write           | §4.5 `cmp r9, rdx; jne`   | Unchanged.                                   |
| `phys_alloc` OOM           | §4.7 `cmp rax, 0; je`     | Unchanged. Bitmap unchanged (phys_alloc's own OOM path preserves the bitmap). |
| (Future) copy fault         | Would go here             | Deferred — no fault handling at R16.M2.       |

Every failure path routes to `tmpfs_write_fail` **before** any store
into `_tmpfs_inode_pool`. The OOM path is subtle: it hits after the
inode pointer + type gate + range gate + single-page check + page-slot
compute, but **before** `mov [r14], r8` (the page pointer store).
Since the store only happens on the success path after phys_alloc
returns non-zero, an OOM leaves the page pointer slot at its
pre-call value.

### 5.2 Why type-gate + range-gate before allocation

Same reasoning as tmpfs_create §5.2 / §5.3: cheap checks first, and
allocation last, so that no failure leaks a page. `phys_alloc` at
R16.M2 has no `phys_free` peer usable in this control flow (phys_free
exists at #649 but is not on this hot path), so a leaked page would
leak until reboot. The pre-alloc gates make leak impossible.

### 5.3 Why single-page before allocation

Cross-page writes are rejected before allocation. A "partial success"
where we allocate page N then discover the write also needs page N+1
would either leak page N or require rollback. R16.M2 avoids this by
declaring cross-page an error; the follow-on multi-page issue will
allocate incrementally and can roll back cleanly using #649's
`phys_free` peer (or accept the leak, if the design prefers "hold
partial state on partial failure" — that's a follow-on design call).

### 5.4 Backtrack anchor — the multi-page follow-on

The single-page constraint is a **runtime guard**, not a permanent
architectural choice. When the R17 syscall demo (or an earlier need
in R16.M3's vops layer) requires multi-page writes, the follow-on
issue replaces §4.7 + §4.8 with a per-page loop:

```
for page_idx in [start_page, end_page]:
    slot_addr = &page_ptrs[page_idx]
    page_va = *slot_addr
    if page_va == 0:
        page_va = phys_alloc(0)
        if OOM:
            return partial_count or rollback
        *slot_addr = page_va
    chunk_start = max(page_idx * 4096, offset)
    chunk_end   = min((page_idx + 1) * 4096, end_offset)
    dst = page_va + (chunk_start & 0xFFF)
    src = buf_ptr + (chunk_start - offset)
    len = chunk_end - chunk_start
    memcpy(dst, src, len)
```

Two design questions to answer at that time:

1. **Partial success semantics.** If page 2's `phys_alloc` OOMs after
   page 1 already got a page + partial copy, does the return count
   reflect only the pages that fully copied, or all the way up to the
   OOM point? POSIX write(2) returns the "successful" byte count, so
   returning `chunk_start - offset` (bytes copied so far) is the
   compatible choice.

2. **Sparse zeroing.** If offset > current inode.size (write past
   end-of-file), do the pages between size and offset get allocated
   and zeroed? POSIX says yes (a hole reads as zero, but on tmpfs
   there is no VFS-level hole support, so we have to materialize the
   zeros). The follow-on will need a per-page phys_alloc + memset
   loop for the gap, plus a corresponding contract update to
   `tmpfs_read` (#584) to zero-fill for `page_ptrs[i] == 0` reads.

Both are out-of-scope for R16.M2's single-page constraint.

The follow-on's LOC estimate: ~50 additional LOC (per-page loop
around this issue's inner copy). The change is isolated to
`tmpfs_write`; no other module changes.

## 6. Alternatives considered

### 6.1 Byte-loop memcpy instead of `rep_movsb`

**Proposal.** Use the same byte-loop shape as `elf_lite.pdx:425-433`
(load byte / store byte / advance / count) instead of `rep_movsb`.
Would sidestep any encoder concern.

**Rejected.** Three reasons:

1. **Encoder support landed.** PA-R13-011 (#940) shipped `RepMovsb` in
   the encoder, complete with build-emit smoke and Rust runtime unit
   tests. Using it validates the landing rather than working around
   it.
2. **~10x smaller code size.** A byte loop is ~6 instructions per
   iteration × N iterations vs. a 2-byte `rep_movsb` for arbitrary N.
   For a 100-byte write, that is 600 instructions vs. 2.
3. **Microarch efficiency.** Modern x86 `rep_movsb` is fast-path
   optimized (Fast String Ops on Ivy Bridge and later) to use
   256-bit SIMD internally on aligned blocks. A hand-rolled byte loop
   is scalar and store-buffer-bound.

The elf_lite comment at line 394 ("`rep_movsb` not supported") predates
#940 and is stale; a follow-on cleanup can migrate elf_lite to
`rep_movsb`. Not a blocker for this issue.

### 6.2 `rep_stosq` for zero-fill of fresh page

**Proposal.** Before the memcpy, zero the entire fresh page via
`rep_stosq` to avoid leaking previous frame contents at intra-page
offsets that this write does not touch.

**Rejected — but for structural reasons, not correctness.** At R16.M2:

1. The witness writes from offset 0 with len = 100. Bytes [100, 4096)
   of the page are the "unwritten" region. If a future `tmpfs_read`
   reads bytes [100, 4096) after this write, it would see the fresh
   page's previous contents.
2. But R16.M2 has no `tmpfs_read` yet (#584 lands next). So the
   observability of stale bytes is not testable at R16.M2.
3. The correct owner of the zero-fill is either (a) `phys_alloc`
   (single-source guarantee: every allocated page is zero) or (b)
   `tmpfs_read` (zero-fill on read for the pre-size region — matches
   POSIX file semantics for sparse regions).

Design preference: (a) `phys_alloc` zeros the page. This is what
sane frame allocators do (Linux `alloc_page(GFP_ZERO)` on user
mappings; NT `MmAllocatePagesForMdlEx` with `MM_ALLOCATE_FROM_LOCAL_NODE`
under zero-fill policy). It centralizes the invariant in one place —
every subsystem consuming a page can assume zeros. The alternative,
zero-fill-on-read, requires every reader (tmpfs_read, elf_lite,
kmap_page, mmap-like) to remember the zeroing responsibility.

If `phys_alloc` were to gain a zero-fill (as an internal detail or
a `PHYS_ALLOC_ZERO` flag), this module needs no changes.

Landing plan: file a follow-on issue for `phys_alloc` zero-fill,
scoped independently of this issue. Not a blocker for R16.M2's
acceptance test (which reads only bytes [0, 100) from the page).

### 6.3 Store `page_ptrs[start_page]` after copy (concurrency-safe order)

**Proposal.** Reorder §4.7 so that `phys_alloc` → memcpy →
`mov [r14], r8`. Publishing the page pointer last means a concurrent
reader that sees the pointer will always see a fully-copied page.

**Rejected for R16.M2, kept for R17.** At R16.M2 there is no
concurrent reader — the kernel is single-threaded on the critical
path. Reordering has no observable effect and the store-then-copy
shape:

- Matches the multi-page follow-on's per-iteration pattern
  (§5.4 sketch).
- Puts the phys_alloc failure detection immediately next to its
  cause (rather than after an intervening rep_movsb).
- Makes the code linear (fewer forward jumps).

When R17 lands concurrency, this ordering flips as part of the
FS-lock design.

### 6.4 Split page_slot compute across nested-call boundaries

**Proposal.** Compute `&page_ptrs[start_page]` once *inside* the
"page already exists" branch and once again *inside* the "allocate
new page" branch, avoiding the need for `r14` to persist across
`phys_alloc`.

**Rejected.** The compute is 2 instructions. Duplicating it across
branches would double it. The current single-compute pattern is
smaller and clearer, and `r14`'s use as a persistent address is a
common pattern (see `tmpfs_lookup.pdx:69` where `r13` holds
`cur_ptr` across an inner loop).

### 6.5 Zero-page-on-first-write inside tmpfs_write

**Proposal.** Right after `phys_alloc` returns a fresh page, memset
it to zero via a `rep_stosq` (512 qwords) or a byte loop, before
copying user data on top.

**Rejected in favor of §6.2's phys_alloc-owns-zeroing plan.** Adding
the zero-fill here would:

- Duplicate the invariant across every caller of `phys_alloc`
  (tmpfs_write, elf_lite, kmap_page, etc.). Each needs to
  independently remember to zero.
- Add ~10 instructions to every page allocation on the write path
  (with the `rep_stosq` intrinsic once #1228 lands, or ~1000+
  scalar instructions per fresh page with a manual loop).
- Not solve the problem for R16.M2 — the witness reads no bytes
  outside its own write region, so the fresh-page contents are
  invisible.

`phys_alloc` is the correct owner of the zero-fill invariant.

### 6.6 Return-value shape: `bytes_written` vs `(status, count)`

**Proposal.** Return a two-word result `(rax = status, rdx = count)`
instead of a single `rax = bytes_or_error`. Callers get exact error
codes.

**Rejected.** Two costs:

1. **Non-standard ABI.** SysV AMD64 return in `rax + rdx` is legal
   for 128-bit integers and structs (`__int128`), but calling
   conventions for kernel primitives in paideia-os are strictly
   single-return-`rax`. Introducing a two-word return here would
   require a new convention.
2. **Sentinel-based encoding is sufficient.** The value space of a
   legal byte-count return is `[0, 65536]` (the range gate caps it).
   `0xFFFFFFFFFFFFFFFF` is comfortably outside that range and encodes
   "any error" cleanly. Callers that need finer-grained diagnosis
   can probe the inode state themselves.

The single-`rax` return matches tmpfs_lookup / tmpfs_create /
tmpfs_inode_alloc / phys_alloc / phys_free (all landed) and keeps
the vops adapter shape simple.

### 6.7 Cap `len` at 4096 instead of 65536

**Proposal.** Since we constrain to single-page writes, restrict the
range gate to `len <= 4096` (with `offset + len <= 4096` implicitly).
Simpler bounds check.

**Rejected.** The 64 KiB cap is the *file*-level cap (from #579 §layout,
16 pages × 4 KiB). The single-page constraint is a *transaction*-level
constraint. Conflating them would leak the transaction-level
constraint into the type of the primitive. When the multi-page
follow-on lifts the single-page constraint, we would need to bump
the range gate back up — but the file cap does not move. Keeping
the range gate at the file-level bound keeps the follow-on's diff
minimal (only §4.5 changes).

## 7. Invariants

### 7.1 Success returns `len` in [1, 65536]

The success path returns `mov rax, r12` where `r12 = len`. The range
gate at §4.4 guarantees `1 <= len <= 65536` on this path (zero-len
takes the fast path, which returns 0). Upper 48 bits of `r12` are
whatever the caller passed; since we checked `len <= 65536`,
`r12 <= 0x10000` and upper bits are zero.

### 7.2 Zero-len returns 0

The zero-len path (§4.2 + §4.10) executes `xor rax, rax` and returns.
No side effects.

### 7.3 Failure returns exactly `0xFFFFFFFFFFFFFFFF`

The failure path (§4.10) executes `mov rax, 0xFFFFFFFFFFFFFFFF` — a
`mov r64, imm64` encoding (10 bytes). Callers using
`cmp rax, 0xFFFFFFFFFFFFFFFF` (or the equivalent
`cmp rax, -1; je error`) can detect the error unambiguously.

### 7.4 Post-success, `inode.size >= end_offset`

Section §4.9 stores `end_offset` into `inode.size` if it exceeds the
current size. Post-store: `inode.size = max(pre-write inode.size,
end_offset)`. Both cases satisfy `inode.size >= end_offset`.

### 7.5 Post-success, `page_ptrs[start_page]` is non-zero

Two cases:

- Pre-write: `page_ptrs[start_page] == 0`. §4.7 calls `phys_alloc`,
  which returns non-zero on success (OOM would have jumped to
  `tmpfs_write_fail`). The store `mov [r14], r8` publishes it. Post:
  non-zero.
- Pre-write: `page_ptrs[start_page] != 0`. §4.7 skips the allocation.
  Post: unchanged, still non-zero.

### 7.6 Post-success, bytes `[offset, end_offset)` of the file match `[buf_ptr, buf_ptr + len)`

`rep_movsb` with (rsi = buf_ptr, rdi = page_va + (offset & 0xFFF),
rcx = len) copies exactly `len` bytes from source to destination.
Since we asserted single-page, all `len` bytes land in page
`start_page`. The mapping from file byte `k` (for `offset <= k <
end_offset`) to page byte `k mod 4096` is the standard byte-file
mapping.

### 7.7 Post-failure, `_tmpfs_inode_pool` is byte-identical to pre-call

All failure paths return before any store to the pool. The store
`mov [r14], r8` (page pointer publish) only executes after successful
phys_alloc. The store `mov [r15 + 8], rax` (size update) only executes
after successful memcpy. The two-store discipline is: no partial
mutation.

### 7.8 Post-failure, `_phys_pool_bitmap` is byte-identical to pre-call

Only reachable via `phys_alloc` OOM (all other failures precede the
call). `phys_alloc`'s R15-M1-010 contract guarantees the bitmap is
unchanged on OOM: no bit is set until the range check + set
sequence succeeds atomically at line 78-79. If OOM detected earlier
(via `next_word` chain), no bit was set at all.

### 7.9 phys_alloc VA has bit 63 set

phys_alloc's R15-M1-010 §doc-note: return VA is `_phys_page_pool` +
`page_index * 4096`, and `_phys_page_pool` is a high-half kernel
symbol (bit 63 set). This VA lands in `page_ptrs[start_page]` and
in `r8` for the memcpy. Both uses (dereference for memcpy, store as
u64 into inode) are correct with the VA form.

When #658 rebases phys_alloc to return genuine PAs, the vops adapter
(or a wrapping helper) will need to lift PA→VA for the memcpy;
tmpfs_write's own body stays byte-identical because it treats the
value as an opaque page reference.

### 7.10 rep_movsb is safe with rcx == 0

Not exercised (zero-len fast path handles rcx == 0), but per the x86
spec, `rep_movsb` with `rcx == 0` is a defined no-op (rcx checked
before iteration). This is a defensive property; the fast path is a
peer defense.

## 8. Encoder verification

Every mnemonic used is proven in landed modules.

| Shape                              | Proven by                                                                        |
|------------------------------------|----------------------------------------------------------------------------------|
| `push` / `pop r64`                 | `tmpfs_init.pdx:30-32, 122-124`, `tmpfs_create.pdx:45-49, 154-158`. 5-push uniform with tmpfs_create. |
| `mov r64, r64`                     | Ubiquitous.                                                                       |
| `call sym`                         | Ubiquitous.                                                                       |
| `xor r64, r64`                     | Ubiquitous zero-idiom.                                                            |
| `mov_b r64, [r64 + disp8]`         | `tmpfs_lookup.pdx:45, 75-76`, `tmpfs_create.pdx:60`. Load form.                   |
| `mov [r64 + disp8], r64`           | `tmpfs_init.pdx:76`, `tmpfs_create.pdx:96, 121`. Store form (size at +8; page slots via r14). |
| `mov r64, [r64 + disp8]`           | `tmpfs_lookup.pdx:52`. Load size at +8, dir chain at +176.                         |
| `mov r64, [r64]`                   | `phys_alloc.pdx:36`. Bare-base load (used for `mov r8, [r14]`).                    |
| `mov [r64], r64`                   | `phys_alloc.pdx:79`. Bare-base store (used for `mov [r14], r8`).                    |
| `lea r64, [r64 + disp8]`           | `tmpfs_lookup.pdx:69` (`lea r9, [r13 + 144]`). Same shape for `lea r14, [r15 + 16]`. |
| `lea r64, [r64 + r64*8]`           | Modeled by `phys_alloc.pdx:47` (`mov r9, [rax + rdx * 8]`) which uses the same SIB. |
| `cmp r64, imm8`                    | Ubiquitous.                                                                       |
| `cmp r64, imm32`                   | `phys_alloc.pdx:75` (`cmp rdi, 1024`), `elf_lite.pdx:407` (`cmp rdx, 4096`).      |
| `shr r64, imm8`                    | `tmpfs_lookup.pdx:53, 99`, `phys_alloc.pdx:72`.                                    |
| `and r64, imm32`                   | `tmpfs_lookup.pdx:54, 100`. Used for `and rcx, 0xFFF` (imm32 sign-extends fine).   |
| `add r64, r64`                     | Ubiquitous.                                                                       |
| `sub r64, imm8`                    | Ubiquitous (used for `sub rdx, 1`).                                                |
| `mov r64, imm32`                   | Ubiquitous (for `mov rax, 65536`, `mov rdi, 0`).                                    |
| `mov r64, imm64`                   | `phys_free.pdx:26` (`mov rax, 0xFFFF800000000000`). Used for the -1 sentinel.       |
| `ja` / `jbe` / `je` / `jne` / `jmp`| Ubiquitous. `jbe` used at §4.9 for unsigned "no size bump".                        |
| `cld`                              | Encoder emits opcode `FC` (1 byte). Proven by `rep_movsb_smoke.pdx::after_cld`.   |
| `rep_movsb`                        | Encoder emits `F3 A4` (2 bytes) per PA-R13-011 (#940). Proven by `rep_movsb_smoke.pdx::bare_rep_movsb` and `::after_cld`. |

**No new encoder shapes.** The `mov r64, imm64` for the error
sentinel and the `rep_movsb` are the "newest" shapes; both landed
before R16.M2.

**Shapes deliberately avoided:**

- `mov [r64 + r64*8], r64` (SIB store with disp = 0) — the design
  routes around by using an intermediate `lea r14, [r15 + 16 +
  r9*8]`. Two-step lea vs. one-step SIB store; the two-step form is
  encoder-uncontroversial.
- `mov_w [r64 + disp8], r64` narrow-store — not needed because
  `inode.size` (+8) is a full u64 and `page_ptrs[i]` (+16+i*8) is a
  full u64. The narrow-store forms live in tmpfs_create for u16
  fields; this issue writes only u64s.

## 9. Test canary — R16 TMPFS WRITE OK

Runs in `kernel_main` immediately after the `R16 TMPFS CREATE OK`
marker. Placement rationale: reuses the `/tmp/x` file that
`tmpfs_create`'s witness (r16-m2-004 §9) created, avoiding the need
to add a fresh witness name string in boot_stub.S. The `/tmp/x` inode
is a `VNODE_TYPE_REG` file with `size == 0` and no page pointers set
— the perfect starting state for a first-write test.

Four sub-tests, one marker (matches the acceptance criteria + three
invariant witnesses).

### 9.1 Witness fixture — source buffer + message strings

In `tools/boot_stub.S`, immediately after the `tmpfs_create_*_msg`
pair (~line 545):

```s
# R16-M2-005 (#583): tmpfs_write witness — 100-byte source buffer
.global tmpfs_write_src_buf
.align 8
tmpfs_write_src_buf:
    .rept 100
    .byte 0x41                          # 'A'
    .endr

# R16-M2-005 (#583): tmpfs_write witness success + failure messages
.global tmpfs_write_ok_msg
.align 8
tmpfs_write_ok_msg: .ascii "R16 TMPFS WRITE OK\n\0"

.global tmpfs_write_fail_msg
.align 8
tmpfs_write_fail_msg: .ascii "R16 TMPFS WRITE FAIL\n\0"
```

Source buffer is 100 bytes of `0x41` (`'A'`). Uniform-byte pattern
means sub-test D can verify content via a single u64 load and
compare against `0x4141414141414141` — checks 8 bytes of copied
content at once.

### 9.2 Preamble — recover `x_idx` from `/tmp/x`

Locate the inode that `tmpfs_create` (r16-m2-004 §9.2) placed under
`/tmp/x`. Reuses `witness_name_tmp` and `witness_name_any` from
boot_stub.S — no new witness name strings needed.

```asm
    ; --- Recover tmp_idx via lookup on root ---
    mov  rdi, 1                             ; root_idx = TMPFS_INODE_IDX_ROOT
    lea  rsi, [rip + witness_name_tmp]      ; "tmp\0"
    call tmpfs_lookup
    cmp  rax, 0
    je   tmpfs_write_witness_fail
    mov  r12, rax                           ; r12 = tmp_idx

    ; --- Recover x_idx via lookup on /tmp ---
    mov  rdi, r12                           ; tmp_idx
    lea  rsi, [rip + witness_name_any]      ; "x\0"
    call tmpfs_lookup
    cmp  rax, 0
    je   tmpfs_write_witness_fail
    mov  r13, rax                           ; r13 = x_idx (target of the write)
```

If either lookup misses, the witness fails — but that would indicate
a regression in tmpfs_lookup / tmpfs_create, not tmpfs_write.

### 9.3 Sub-test A — tmpfs_write returns 100

```asm
    ; --- tmpfs_write(x_idx, src_buf, 100, 0) → expect rax = 100 ---
    mov  rdi, r13                           ; x_idx
    lea  rsi, [rip + tmpfs_write_src_buf]   ; buf_ptr = &src[0]
    mov  rdx, 100                           ; len = 100
    xor  rcx, rcx                           ; offset = 0
    call tmpfs_write
    cmp  rax, 100
    jne  tmpfs_write_witness_fail
```

Proves: (a) tmpfs_write accepts the four args; (b) type gate passed
(x is REG); (c) range gate passed (100 < 65536); (d) single-page
constraint passed (bytes [0, 100) all in page 0); (e) phys_alloc
succeeded; (f) memcpy executed; (g) size update ran; (h) return
value is exactly len.

### 9.4 Sub-test B — inode.size == 100

```asm
    ; --- Verify inode.size == 100 ---
    mov  rdi, r13                           ; x_idx
    call tmpfs_inode_slot                   ; rax = &x_inode
    mov  r14, rax                           ; r14 = x_inode_ptr
    mov  rcx, [r14 + 8]                     ; rcx = inode.size
    cmp  rcx, 100
    jne  tmpfs_write_witness_fail
```

Proves: the size update at §4.9 correctly wrote `end_offset = 100`
into `inode.size`. This is the direct acceptance criterion from the
issue body.

### 9.5 Sub-test C — inode.page_ptrs[0] != 0

```asm
    ; --- Verify page_ptrs[0] is a live page pointer ---
    mov  rcx, [r14 + 16]                    ; rcx = page_ptrs[0]
    cmp  rcx, 0
    je   tmpfs_write_witness_fail
    mov  r15, rcx                           ; r15 = page_va (for sub-test D)
```

Proves: the lazy allocation at §4.7 called phys_alloc and stored the
returned VA into the page slot. Also captures `page_va` in `r15` for
the content check.

### 9.6 Sub-test D — content match (u64 @page_va == 0x4141414141414141)

```asm
    ; --- Verify first 8 bytes of the page are all 'A' ---
    mov  rcx, [r15]                         ; rcx = u64 at page start
    mov  rdx, 0x4141414141414141            ; expected: 8 x 'A'
    cmp  rcx, rdx
    jne  tmpfs_write_witness_fail
```

Proves: `rep_movsb` correctly copied source bytes into the page.
Reading 8 bytes at once catches memcpy failures at multiple offsets:
if the copy count was too short, byte 7 would be zero (fresh page
default) not 'A'. If the copy direction was wrong (DF=1 accidentally),
the destination bytes would be in different positions.

**A stronger content check** — reading byte 99 (last written byte) —
would need an intermediate compute `page_va + 99` and byte-load. That
is a follow-on if a content bug slips through the u64 check.

### 9.7 Marker

On all four sub-tests green:

```
R16 TMPFS WRITE OK
```

Fingerprint added to:

- `tests/r14b/expected-boot-r14b-loader.txt` — line immediately
  following `R16 TMPFS CREATE OK` (line 22).
- `tests/r15/expected-boot-r15-ring3.txt` — line 33.
- `tests/r15/expected-boot-r15-process.txt` — line 34.

Witness failure prints `R16 TMPFS WRITE FAIL` and falls through.

## 10. Boot integration

Witness is inserted in `kernel_main.pdx` between
`tmpfs_create_witness_done` (line 2515) and the `wrmsr` for GS_BASE
(line 2517). Same insertion pattern as the preceding tmpfs witnesses.

Rough kernel_main.pdx delta:

```asm
      tmpfs_create_witness_done:

      // ============================================================
      // R16-M2-005 (#583): tmpfs_write witness — 4 sub-tests, 1 marker
      // ============================================================
      tmpfs_write_witness:
          // ---------- Preamble: recover tmp_idx, x_idx ---------- (§9.2)
          // ---------- Sub-test A: tmpfs_write returns 100 ---------- (§9.3)
          // ---------- Sub-test B: inode.size == 100 ---------- (§9.4)
          // ---------- Sub-test C: page_ptrs[0] != 0 ---------- (§9.5)
          // ---------- Sub-test D: content match ---------- (§9.6)

          lea  rdi, [rip + tmpfs_write_ok_msg]
          call uart_puts
          jmp  tmpfs_write_witness_done

      tmpfs_write_witness_fail:
          lea  rdi, [rip + tmpfs_write_fail_msg]
          call uart_puts

      tmpfs_write_witness_done:

      // R14b-m5-002 (#507): IA32_GS_BASE = &_cpu_locals[0] on CPU0.
      lea rax, [rip + _cpu_locals];
      ...
```

State side-effect: after the witness, `/tmp/x`'s inode has
`size = 100` and `page_ptrs[0]` pointing to a live physical page
whose first 100 bytes are `0x41`. No downstream code walks
`/tmp/x`'s contents at this boot point (the process subsystem
follows), so the state is preserved without downstream interaction.

## 11. Cross-references

- Issue: paideia-os#583
- Milestone: R16.M2 (tmpfs — in-memory VFS backend)
- Upstream:
  - paideia-os#579 (R16-M2-001 — frozen layout §2; offsets +8 (size),
    +16 (page_ptrs[]) written here).
  - paideia-os#580 (R16-M2-002 — `tmpfs_inode_alloc`, tmpfs_init;
    frozen refcount / link_count conventions this issue does not
    touch).
  - paideia-os#581 (R16-M2-003 — `tmpfs_lookup` used by the witness
    preamble to recover x_idx).
  - paideia-os#582 (R16-M2-004 — `tmpfs_create` established `/tmp/x`
    as the write target; register discipline mirror).
  - paideia-os#649 (R15-M1-010 — `phys_alloc`/`phys_free` real bodies;
    contract of order-0 → 4 KiB VA return).
  - paideia-as#940 (PA-R13-011 — `rep_movsb` encoder landed).
- Downstream consumers:
  - #584 (`tmpfs_read` — mirror; reads bytes from `page_ptrs[]` slots
    up to `inode.size`. Depends on this issue's invariant that
    `page_ptrs[i] != 0` implies `page[i]` contains valid data at
    offsets `[i * 4096, (i + 1) * 4096) ∩ [0, inode.size)`.)
  - A follow-on R16.M2 issue (multi-page tmpfs_write — lifts the
    single-page constraint via a per-page loop around this issue's
    inner phys_alloc + rep_movsb work; §5.4 sketches the shape.)
  - A follow-on `phys_alloc` zero-fill issue (§6.5) — orthogonal to
    tmpfs_write; centralizes the fresh-page invariant.
  - R16.M3 `tmpfs_vops` — registers a wrapper adapting
    `tmpfs_write(inode_idx, buf, len, offset)` to
    `vops_write(vnode_ptr, buf, len, offset)` by reading
    `vnode.backend_ptr` (+32) as the inode idx.
  - R17 `sys_write` — user-facing syscall; copies user data to a
    kernel bounce buffer, then calls into the vops chain that
    ultimately reaches this primitive.
- Sibling primitive: `elf_lite.pdx`'s per-page copy loop
  (lines 425-433) — same shape (compute dst, compute src, copy len
  bytes) but with a byte loop instead of `rep_movsb`. A follow-on
  cleanup can migrate elf_lite to `rep_movsb` now that #940 has
  landed.
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 12 item 5 — "Allocate page(s) on first write; copy from
  user buf; update inode.size. Acceptance: write 100 bytes →
  inode.size == 100."
