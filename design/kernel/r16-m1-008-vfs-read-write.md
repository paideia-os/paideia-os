issue: 577
milestone: R16.M1 (VFS abstract layer)
subsystem: 11 — VFS abstract layer
topic: vfs_read + vfs_write — argument-forwarding dispatchers into vops_read/write

# Goal

Ship the two remaining VFS surface entries in R16.M1:

- `vfs_read(vnode_idx, buf_ptr, len, offset) -> u64` — validate vnode
  index, resolve to slot pointer, forward `(vnode_ptr, buf, len, off)` to
  `vops_read`, return the op's rax verbatim.
- `vfs_write(vnode_idx, buf_ptr, len, offset) -> u64` — same shape,
  dispatches through `vops_write`.

R16.M1 closes with an `R16 VFS READ WRITE OK` marker; a real backend
(tmpfs) that actually consumes `buf` and `len` lands in R16.M2. This
issue therefore ships the dispatcher only and witnesses it against a
stub-vops-table backend that ignores its args and returns a predetermined
value.

# Signatures

Both are 4-arg u64-returning under SysV AMD64:

| Reg | vfs_read input     | vfs_write input     |
|-----|--------------------|---------------------|
| rdi | vnode_idx (u64)    | vnode_idx (u64)     |
| rsi | buf_ptr (u64)      | buf_ptr (u64)       |
| rdx | len (u64)          | len (u64)           |
| rcx | offset (u64)       | offset (u64)        |

Return in rax:
- Success: bytes read/written as reported by the backend (`0..=len`).
  A short read at EOF (rax < len) is not an error — the backend
  reports it in-band per the vops contract (§2, r16-m1-003-vops.md).
- Failure: `0xFFFFFFFFFFFFFFFF` (VOPS_ERR_NOT_SUPPORTED). Three
  failure modes collapse to this single sentinel:
  1. `vnode_idx == 0` — slot-0 sentinel reserved invalid per #570 §7.2.
  2. `vnode_idx >= 256` — out of range vs. `VNODE_MAX`.
  3. Dispatch reached vops but the vnode's `ops_ptr` or the read/write
     slot itself is null — the vops dispatcher's own null-guards
     surface `VOPS_ERR_NOT_SUPPORTED` and vfs_read/write forward it
     verbatim.

The unified sentinel is intentional. R16.M1 has no errno plumbing;
distinguishing "bad idx" from "unsupported op" is meaningless at this
altitude and would require the caller to know which vops slots each
backend implements. The sys_read / sys_write boundary in R16.M4
translates this sentinel to a POSIX-shaped `-EBADF` or `-ENOSYS`
based on syscall context.

# Non-decisions (deferred by scope contract)

- **Refcount consultation.** vfs_read/write do NOT check
  `vnode.refcount != 0` before dispatching. The precondition
  "caller holds a refcount via vfs_open" is contract, not enforcement.
  Adding a runtime refcount check would surface fd-lifecycle bugs
  higher in the stack, but at R16.M1 the only caller is the witness
  and syscalls don't exist yet. R16.M3 fd-table plumbing enforces
  the invariant one level up (`sys_read(fd)` only reaches vfs_read
  if `fd_table[fd].vnode_idx` is populated, which implies the fd was
  produced by an open).
- **Byte-range validation.** vfs_read/write pass `len` and `offset`
  unchecked to the backend. It is the backend's job to know its own
  size and clamp reads to EOF; a tmpfs backend that overruns its own
  inode data is a backend bug, not a dispatcher bug.
- **User-vs-kernel buf provenance.** `buf_ptr` is treated as a bare
  u64 with no address-space validation. R17 syscall-boundary plumbing
  will validate that a userspace buf lives in the calling task's
  aspace before the pointer reaches vfs_read. At R16.M1 all callers
  are kernel-domain.
- **Concurrent access on SMP.** As with the rest of the VFS R16.M1
  surface (#575, #576), no atomic discipline is applied to the
  vnode. Safe today because VFS entries only reach from CPU0 kernel
  context. Locking lands with the tmpfs backend in R16.M2 or the
  R17 SMP-VFS pass, whichever crosses the concern first.

# Body sequence

Both functions share an identical prologue, validate, resolve, marshal,
dispatch, epilogue skeleton. The only per-function delta is a single
mnemonic (`call vops_read` vs. `call vops_write`) — the same isomorphism
that vops.pdx exploits across its 7 dispatchers.

## Prologue and argument save

```
push rbx
push r12
push r13
push r14
push r15
mov  rbx, rdi          ; rbx = vnode_idx    (survives vnode_slot)
mov  r12, rsi          ; r12 = buf_ptr      (survives vnode_slot)
mov  r13, rdx          ; r13 = len          (survives vnode_slot)
mov  r14, rcx          ; r14 = offset       (survives vnode_slot)
                       ; r15 = unused (uniform 5-push pattern)
```

Five pushes + return address = 48 bytes = 0 mod 16, so nested calls into
`vnode_slot` and `vops_{read,write}` see rsp%16 == 0 as SysV requires
at the call site.

## Validation

```
cmp rbx, 0             ; reject slot-0 sentinel
je  vfs_XX_fail
cmp rbx, 256           ; VNODE_MAX
jae vfs_XX_fail        ; reject out-of-range
```

## Resolve to slot pointer

```
mov  rdi, rbx          ; vnode_idx into vnode_slot's arg reg
call vnode_slot        ; rax = &_vnode_pool[vnode_idx]
```

## Marshal 4-arg call to vops dispatcher

```
mov  rdi, rax          ; rdi = vnode ptr    (from vnode_slot)
mov  rsi, r12          ; rsi = buf_ptr
mov  rdx, r13          ; rdx = len
mov  rcx, r14          ; rcx = offset
call vops_read         ; or vops_write in the write path
                       ; rax = op's return (bytes / sentinel) — forward verbatim
```

## Epilogue

```
jmp  vfs_XX_done
vfs_XX_fail:
    mov rax, 0xFFFFFFFFFFFFFFFF
vfs_XX_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
```

# Register discipline

| reg | role                                                            |
|-----|-----------------------------------------------------------------|
| rbx | vnode_idx (saved through validate + vnode_slot)                 |
| r12 | buf_ptr (saved through vnode_slot, remarshaled to rsi)          |
| r13 | len (saved through vnode_slot, remarshaled to rdx)              |
| r14 | offset (saved through vnode_slot, remarshaled to rcx)           |
| r15 | unused — kept in prologue for uniform 5-push pattern            |
| rax | scratch + return                                                 |
| rdi | vnode_idx into vnode_slot; then vnode ptr into vops             |
| rsi | buf_ptr (re-established from r12 before vops dispatch)          |
| rdx | len (re-established from r13 before vops dispatch)              |
| rcx | offset (re-established from r14 before vops dispatch)           |

## Why r12/r13/r14 and not r8/r9/r10 for stashing buf/len/off

The three buf/len/offset arguments arrive in rsi/rdx/rcx which are all
caller-save under SysV AMD64. They MUST be spilled to callee-save regs
before any nested `call` — including `call vnode_slot` — because the
ABI does not guarantee they survive it.

`vnode_slot`'s current body only touches rax and rdi (src/kernel/core/
fs/vnode_pool.pdx:148-159), so in practice today the args would
survive. That is exactly the trap #575 tripped on: vfs_open originally
stashed live values in r8/r9 across nested calls that happened not to
touch those regs. When a later evolution of a callee did touch them,
the caller silently corrupted state. The #575 debugger pass corrected
it (commit f69f35a5) and the design lesson landed as the "DO NOT use
r8/r9 as scratch across nested calls" rule captured in this design's
input contract.

r12/r13/r14 are three of the six SysV callee-save GPRs (rbx, rbp,
r12, r13, r14, r15). They are already pushed in the 5-push prologue,
so nesting more calls costs nothing extra. r8/r9/r10/r11 are all
caller-save and are never used to hold live values across a `call`
in this dispatcher — the ABI-safety property is thus load-bearing on
the source, not on the callee's current implementation choices.

The 5-push pattern lands with one dead register (r15). Keeping the
push pattern uniform across the vfs surface (vfs_open, vfs_close,
vfs_read, vfs_write) makes register-save discipline audit-once: any
reviewer who has read vfs_open.pdx or vfs_close.pdx sees the same
prologue and doesn't have to re-derive the alignment count.

## Argument marshaling contract with vops dispatchers

The vops layer (r16-m1-003-vops.md §2.3) explicitly pins that its
dispatchers pass argument registers through untouched. Our marshaling
step (`mov rdi/rsi/rdx/rcx from vnode_ptr/r12/r13/r14`) reproduces
the exact register set the eventual real op — `tmpfs_read` in R16.M2
— will read. There is no ABI translation across the vfs → vops
boundary; a caller could conceptually reach `tmpfs_read` directly
via the vnode's ops_ptr, but the dispatch layer is the single point
where "which backend?" resolves without every caller needing to know.

# Structural options considered

## Option A (chosen): two files, one function each

`src/kernel/core/fs/vfs_read.pdx` and `src/kernel/core/fs/vfs_write.pdx`.

Matches the prior pattern (vfs_open.pdx, vfs_close.pdx are each their
own file). Symmetric with the R16.M4 boundary: `sys_read.pdx` will
`call vfs_read` and `sys_write.pdx` will `call vfs_write` — the file-
per-syscall pattern already used by fd_table.pdx and mount.pdx.

## Option B (rejected): one file with both functions

`src/kernel/core/fs/vfs_read_write.pdx`.

Rejected because the R16.M4 syscall boundary treats read and write as
separate first-class syscalls (`sys_read`, `sys_write`) which each
have their own arg-shape assertions and per-syscall stubs. Splitting
the underlying VFS entries mirrors that boundary. A single-file
combined form would force `sys_write.pdx` to open a file it shares
with `sys_read.pdx` just to reach the dispatcher, breaking one-
module-one-responsibility.

## Option C (rejected): macro-generated dispatcher over an op discriminant

`vfs_op(vnode_idx, buf, len, off, op_tag)` where op_tag selects between
vops_read and vops_write, called by thin trampolines named vfs_read /
vfs_write. Rejected: adds indirection (op_tag→branch) at zero benefit;
the two paths share a body but not a hot-path signature. The vops
layer already achieves the "one shape, seven ops" compression via
isomorphic dispatchers; duplicating that structure here doesn't
compress further.

# Test canary — R16 VFS READ WRITE OK

Runs in `kernel_main.pdx` immediately after the `vfs_close_witness_done`
label. Three composed sub-tests, one marker.

## Witness fixture

Reuses the existing `_vops_witness_table` (from vops.pdx §5.1) and
allocates a fresh pool vnode via `vnode_alloc` as the "backend
vnode." The witness vnode fixture in vops.pdx (`_vops_witness_vnode`,
a `.bss` symbol) is NOT usable here because `vfs_read/write` reach
their vnode through `vnode_slot(idx)` which computes
`&_vnode_pool + idx*64` — the fixture lives outside the pool and is
not addressable by index.

Adds one new stub to vops.pdx:

- `_vops_witness_rw_stub` — returns 42 (0x2A) in rax, ignoring all
  four arguments. The value 42 is arbitrary — the point is to prove
  the stub was reached and its rax was forwarded end-to-end. Reusing
  the same stub for both read and write reduces witness surface;
  installing it in both slot +0 (read) and slot +8 (write) of the
  witness table lets sub-tests A and B exercise the two vfs entries
  against the same fixture.

## Sub-test A — vfs_read forwards a backend read

1. `call vnode_alloc` → rax = witness_idx (guaranteed non-zero, per
   vnode_pool.pdx's slot-0-reserved discipline).
2. Save witness_idx in a callee-save reg (r12 in the witness scope).
3. `call vnode_slot(r12)` → rax = &_vnode_pool[witness_idx].
4. Zero the 64-byte slot (8 × `mov [ptr+N], 0`) so `ops_ptr` starts null.
5. Install `&_vops_witness_table` in vnode +24 (ops_ptr slot).
6. Install `&_vops_witness_rw_stub` in `_vops_witness_table + 0`
   (read slot) and in `_vops_witness_table + 8` (write slot).
7. `vfs_read(witness_idx, 0, 0, 0)` — args intentionally zero; the
   stub ignores them.
8. Assert `rax == 42`. Failure → `R16 VFS READ WRITE FAIL`.

Passing this sub-test proves:
- vfs_read's 5-push prologue + 4-arg save discipline round-trips.
- vfs_read's idx validation permits an allocator-produced idx.
- vfs_read's `vnode_slot` resolution + argument remarshaling
  preserves the stub's rax through the return path.

## Sub-test B — vfs_write forwards a backend write

Same fixture as sub-test A (no state change between them, since sub-
test A's stub does not mutate `_vops_witness_rw_stub` and the vnode's
ops_ptr is still installed).

1. `vfs_write(witness_idx, 0, 0, 0)`.
2. Assert `rax == 42`. Failure → `R16 VFS READ WRITE FAIL`.

Passing this sub-test proves that vfs_write's separate dispatch path
(`call vops_write` at the +8 slot) reaches the same stub and
returns its rax, isolating that the read/write functions differ
only in their vops entry.

## Sub-test C — null ops_ptr returns error sentinel

1. Zero the witness vnode's ops_ptr (write 0 to vnode + 24).
2. `vfs_read(witness_idx, 0, 0, 0)`.
3. Assert `rax == 0xFFFFFFFFFFFFFFFF`. Failure → fail message.

Passing this sub-test proves that vfs_read forwards the vops
dispatcher's own null-guard sentinel verbatim without post-processing.

Sub-test C is placed after A + B so state teardown does not affect
them; the null-ops_ptr install is one-way at witness scope.

Skipped by scope (present in vfs_close witness B already):
- Explicit `vfs_read(0, ...)` and `vfs_read(0xFFFF, ...)` idx-reject
  sub-tests. The idx-validation path is byte-identical to
  vfs_close's (same prologue, same `cmp rbx, 0 / je` and
  `cmp rbx, 256 / jae` sequence). Duplicating in this witness adds
  no signal beyond disassembly review.

## Marker

Emit `R16 VFS READ WRITE OK` after A + B + C green.
Emit `R16 VFS READ WRITE FAIL` on any assertion failure.

## Post-witness state

The witness_idx vnode remains allocated with:
- ops_ptr = 0 (from sub-test C teardown)
- refcount = 0 (never touched — vfs_read/write don't touch refcount)
- All other fields = 0 (from step 4 zero-fill)

This is inert vs. downstream R16.M1 witnesses (#578 is the milestone
smoke). If R16.M2 witnesses need a fresh pool state, they call
`vnode_free(witness_idx)` at their prologue.

# Files touched

| File                                              | Delta        |
|---------------------------------------------------|--------------|
| `src/kernel/core/fs/vfs_read.pdx`                 | new, ~90 LOC |
| `src/kernel/core/fs/vfs_write.pdx`                | new, ~90 LOC |
| `src/kernel/core/fs/vops.pdx`                     | +12 LOC (one new `_vops_witness_rw_stub` returning 42) |
| `src/kernel/boot/kernel_main.pdx`                 | +~70 LOC witness block after `vfs_close_witness_done` |
| `tools/boot_stub.S`                               | +8 lines (2 rodata strings: ok + fail) |
| `tests/r14b/expected-boot-r14b-loader.txt`        | +1 line `R16 VFS READ WRITE OK` after `R16 VFS CLOSE OK` |
| `tests/r15/expected-boot-r15-ring3.txt`           | +1 line, same position |
| `tests/r15/expected-boot-r15-process.txt`         | +1 line, same position |

Aggregate: ~270 net LOC across 8 files.

# Encoder verification

All mnemonics used are already exercised elsewhere in R16.M1:

- `push r64` / `pop r64` — vfs_open.pdx, vfs_close.pdx prologues.
- `mov r64, r64` — universal.
- `cmp r64, imm32` / `je` / `jae` / `jne` — universal.
- `call symbol` (direct) — universal.
- `mov r64, imm64` (for the 0xFFFFFFFFFFFFFFFF sentinel) —
  vfs_close.pdx line 107 uses the identical form.
- `mov r64, imm32` (for the 42 constant in the new stub) — universal.
- `ret` — universal.

Zero new mnemonics. Zero new addressing modes. Encoder gap risk:
NONE.

# Interaction contract with vops layer

vops_read and vops_write dispatch via
`mov rax, [rdi+24]; ... call rax; ...` (r16-m1-003-vops.md §3). They
expect at entry:
- `rdi` = vnode ptr
- `rsi/rdx/rcx` = buf/len/offset (pass-through, untouched)

Our marshaling step delivers exactly this shape. The `sub rsp, 8 /
add rsp, 8` alignment pad inside each vops dispatcher (post-#572
verify-pass correction) means the real backend op eventually sees
rsp%16==8 at entry — the vfs entries themselves don't have to
compensate.

Return value contract from vops:
- Backend implemented: whatever the backend returns (bytes count for
  our r/w paths, in `0..=len` on success).
- Backend not implemented (null ops_ptr or null slot):
  `VOPS_ERR_NOT_SUPPORTED = 0xFFFFFFFFFFFFFFFF`.

vfs_read/write forward both cases verbatim. No post-processing.

# Cross-references

- Issue: paideia-os#577.
- Milestone: R16.M1 (VFS abstract layer).
- Upstream:
  - #570 — vnode 64-byte layout (pins VNODE_OPS_PTR_OFFSET).
  - #571 — vnode_pool + vnode_slot (this design's slot resolver).
  - #572 — vops table + dispatchers (this design's dispatch backend).
  - #576 — vfs_close (register discipline template).
- Downstream consumers:
  - #578 — R16.M1 VFS smoke — the milestone-closing witness that
    round-trips read/write against a real backend fixture.
  - R16.M2 — tmpfs backend implements the actual `read`/`write` ops
    behind the pointers this dispatcher forwards to.
  - R16.M4 — `sys_read` / `sys_write` — thin syscall wrappers that
    resolve `fd -> vnode_idx` via the fd table and call the entries
    landed here.

# Tractability

**HIGH.** Isomorphic to vfs_close (#576) in structure — same 5-push
prologue, same idx validation, same `vnode_slot` resolve step, same
callee-save stash discipline. Two novel elements:

1. Four-argument forwarding (buf/len/offset in rsi/rdx/rcx). The
   marshaling is three `mov r64, r64` instructions immediately before
   the vops call; the compile-time cost is dominated by the ABI
   discipline that already lives in the prologue.

2. Return value is the vops dispatcher's rax forwarded verbatim
   instead of an internally-derived value. Simpler than vfs_close's
   "ignore vops return, always return 0" — no post-processing branch.

The witness fixture reuses the existing `_vops_witness_table` from
vops.pdx and adds one stub. No new .bss allocations, no new fingerprint
files, no new encoder shapes. The only file structurally new is
`vfs_write.pdx`, and it is a two-mnemonic diff from `vfs_read.pdx`.

Sole subtle point: the `_vops_witness_rw_stub` returns a fixed
constant (42) that must not collide with the `VOPS_ERR_NOT_SUPPORTED`
sentinel or with the pre-existing `0xDEADBEEFCAFEBABE` witness magic
from #572. 42 satisfies both (well below 0xFFFF sentinel bar, distinct
from #572's magic) and stays comfortably in the sub-page range where
a real read return would land, so the test signal remains
representative of a healthy backend.
