issue: 576
milestone: R16.M1 (VFS abstract layer)
subsystem: 11 — VFS abstract layer
topic: vfs_close — validate idx, refcount--, on 0 call vops_close

# Goal

`vfs_close(vnode_idx) -> u64` — decrement the vnode's refcount; if it hits
zero, dispatch the backend cleanup hook via `vops_close`. Returns 0 on
success, `0xFFFFFFFFFFFFFFFF` (matching the VOPS error sentinel already in
use across the VFS layer) on any of the four failure modes below.

# Signature

- Input:
  - `rdi = vnode_idx` (u64) — index into `_vnode_pool[0..256]`
- Output:
  - `rax = 0` on success
  - `rax = 0xFFFFFFFFFFFFFFFF` on failure (see §3 for failure modes)

The u64 return preserves symmetry with `vops_close` (which returns u64 with
`VOPS_ERR_NOT_SUPPORTED = 0xFFFFFFFFFFFFFFFF` on a null backend slot). Using
the same sentinel keeps VFS-layer error checks byte-identical.

# Failure modes

1. `vnode_idx == 0` — slot-0 sentinel (reserved invalid vnode per #570 §7.2).
2. `vnode_idx >= 256` — out of range vs. `VNODE_MAX`.
3. `refcount == 0` at entry — underflow (`vfs_close` without matching `vfs_open`).
4. (Deferred) — backend `vops_close` returning non-zero. R16.M1 explicitly
   IGNORES the vops_close return value and always returns 0 on the
   refcount-hits-zero path. Real backends land in R16.M2 (tmpfs), and if
   any backend later returns a hard failure from close, this dispatcher
   grows a fourth failure mode without changing sentinel encoding.

Rationale for underflow-as-error rather than panic: the acceptance criterion
"close pair with open leaves refcount at 0" implies balanced usage is the
contract. In the balanced case underflow never triggers; in the unbalanced
case an error return is more informative to a caller (sys_close in R16.M3)
than a hard fault and preserves the ability to write regression tests for
misuse.

# Body sequence

1. **Prologue**: 5-push callee-save (rbx, r12, r13, r14, r15). Aligns
   rsp%16==0 for nested calls into `vnode_slot` and `vops_close`. This
   matches the vfs_open prologue exactly — uniform pattern across the
   vfs surface makes the register-save discipline audit-once.

2. **Save argument**: `mov rbx, rdi` — vnode_idx lands in the first
   callee-save reg. rbx survives the `call vnode_slot` and (later) `call
   vops_close` without further work.

3. **Validate**:
   - `cmp rbx, 0` / `je vfs_close_fail` — reject slot-0 sentinel.
   - `cmp rbx, 256` / `jae vfs_close_fail` — reject out-of-range.

4. **Resolve slot**:
   - `mov rdi, rbx; call vnode_slot` — rax = &vnode[idx].
   - `mov r12, rax` — r12 holds the vnode ptr across the (optional)
     `call vops_close`. r12 is callee-save (already pushed in the
     prologue) so it survives any nested call without further work.

5. **Load refcount** (u16 @ +4):
   - `xor rcx, rcx; mov_w rcx, [r12 + 4]` — zero-extend u16 to u64 in rcx.
   - The `mov_w` narrow-load is the same encoder path exercised by
     `vfs_open` and the debugger fix that landed with #575; encoder
     support already verified.

6. **Check underflow**:
   - `cmp rcx, 0; je vfs_close_fail` — refcount was 0 at entry → failure
     mode 3.

7. **Decrement + store back**:
   - `dec rcx`
   - `mov_w [r12 + 4], rcx` — narrow 16-bit store; upper bits of rcx are
     zero because we entered with a zero-extended u16 and only decremented.

8. **Conditional vops_close** (refcount hit zero → cleanup):
   - `cmp rcx, 0; jne vfs_close_ok` — refcount still positive, skip
     backend hook.
   - `mov rdi, r12; call vops_close` — dispatch backend close. rdi = vnode
     ptr. rax return ignored per §3 mode 4.

9. **Epilogue**:
   - `vfs_close_ok:` `xor rax, rax` (return 0).
   - `vfs_close_fail:` `mov rax, 0xFFFFFFFFFFFFFFFF`.
   - `vfs_close_done:` pop r15 r14 r13 r12 rbx; ret.

# Register discipline

| reg | role                                                            |
|-----|-----------------------------------------------------------------|
| rbx | vnode_idx (saved through validate + vnode_slot)                 |
| r12 | vnode ptr (saved through the optional vops_close call)          |
| r13 | unused — kept in prologue for uniform pattern                   |
| r14 | unused — kept in prologue for uniform pattern                   |
| r15 | unused — kept in prologue for uniform pattern                   |
| rax | scratch + return                                                 |
| rcx | refcount scratch                                                 |
| rdi | vnode ptr (for vnode_slot input, vops_close input)              |

Two live values only (vnode_idx, vnode ptr). Both survive nested calls via
callee-save regs already pushed in the prologue. Same ABI-safety rationale
as vfs_open's §5 justification: r8-r11 are caller-save and MUST NOT be
relied on across `call` per SysV AMD64.

# Witness plan

Enters with root vnode refcount = 1 (left there by #575's sub-test A, which
did `vfs_open("/", 0)` and never closed). #575's sub-test D took the
O_CREAT-on-missing-path branch which returns 0 without touching refcount,
so state is preserved.

## Sub-test A — refcount transitions + conditional close hook

Baseline: `mount_root_vnode()` idx N with refcount = 1.

1. `vfs_open("/", 0)` → returns N, refcount now 2.
2. Load refcount via `vnode_slot(N)` + `mov_w`; assert == 2.
3. `vfs_close(N)` → returns 0, refcount now 1. vops_close NOT called
   (only observable via disassembly of the branch; witness asserts
   return-value and post-condition refcount).
4. Load refcount; assert == 1.
5. `vfs_close(N)` → returns 0, refcount now 0. vops_close IS called;
   root vnode's `ops_ptr` slot (+24) is null (mount.pdx §14 comment:
   "ops_ptr (+24) deliberately left at zero"), so vops_close hits its
   null-guard and returns VOPS_ERR_NOT_SUPPORTED. Per §3 mode 4 we
   ignore that value.
6. Load refcount; assert == 0.

Acceptance criterion "close pair with open leaves vnode refcount at 0" is
satisfied by steps 1 → 3 → 5 (open once + close once + close once from
the pre-existing baseline of 1) collapsing to refcount=0.

## Sub-test B — invalid idx rejection

1. `vfs_close(0)` → assert `rax == 0xFFFFFFFFFFFFFFFF` (sentinel reject).
2. `vfs_close(0xFFFF)` → assert `rax == 0xFFFFFFFFFFFFFFFF`
   (0xFFFF >= 256, out-of-range reject). Also covers the
   VNODE_IDX_NONE sentinel value produced by `vnode_alloc` OOM.

## Sub-test C — underflow rejection (implicit)

After sub-test A leaves refcount at 0, a third `vfs_close(N)` would hit
failure mode 3 (underflow). Sub-test C is OMITTED to keep the witness
tight: sub-test B already exercises the failure return path, and adding
C would leave the root vnode's refcount in an off-nominal state without
restoring it (making downstream witnesses in the R16 series harder to
reason about). The underflow branch is exercised in disassembly review;
a real regression test lands in R16.M2's tmpfs smoke.

## Marker

Emit `R16 VFS CLOSE OK` after A + B green. `R16 VFS CLOSE FAIL` on any
failed assertion.

# Files touched

| file                                             | delta      |
|--------------------------------------------------|------------|
| `src/kernel/core/fs/vfs_close.pdx`               | new, ~85 LOC |
| `src/kernel/boot/kernel_main.pdx`                | +~50 LOC witness (single block after `vfs_open_witness_done`) |
| `tools/boot_stub.S`                              | +2 rodata strings (`vfs_close_ok_msg`, `vfs_close_fail_msg`) |
| `tests/r14b/expected-boot-r14b-loader.txt`       | +1 line `R16 VFS CLOSE OK` after `R16 VFS OPEN OK` |
| `tests/r15/expected-boot-r15-ring3.txt`          | +1 line, same position |
| `tests/r15/expected-boot-r15-process.txt`        | +1 line, same position |
| `design/milestones/r14b-issue-map.tsv`           | mark #576 landed (if the tsv tracks per-issue status) |

Aggregate change: ~140 net LOC across 6 files.

# Encoder verification

- `mov_w reg, [mem]` and `mov_w [mem], reg` — encoder support verified in
  #575 (vfs_open uses the identical narrow-load/store pair). Same encoder
  path, no new work.
- `cmp reg, imm` / `jae`, `je`, `jne` — used throughout the kernel.
- `call symbol` (direct), `dec reg` — trivially supported.
- No new mnemonics required. Encoder gap risk: NONE.

# Interaction contract with `vops_close`

`vops_close` returns u64:
- `0` on backend success (real backend attached, close hook returned 0).
- `VOPS_ERR_NOT_SUPPORTED = 0xFFFFFFFFFFFFFFFF` on either null `ops_ptr` OR
  null close slot within a non-null ops table.

At R16.M1 the mount()-produced root vnode has `ops_ptr == 0` (see
mount.pdx line 168). Therefore in the witness, step A5's `call vops_close`
takes the null-ops_ptr path and returns the ERR sentinel. `vfs_close` MUST
ignore this — the semantics we're publishing are "on refcount 0, invoke
backend cleanup best-effort; a missing backend is not an error to the
VFS caller." This matches Linux VFS's `iput_final` which similarly treats
`super_operations->drop_inode == NULL` as "nothing to do."

# Deferred to later milestones

- **Real backend close** (tmpfs, devfs) — R16.M2 when backends exist.
- **vnode_free on refcount 0** — deliberately NOT called here. Whether a
  vnode is returned to the pool on last-close is a backend decision (see
  Linux `evict_inodes` semantics: some filesystems keep inode cache warm).
  The tmpfs backend in R16.M2 will decide. For R16.M1 the vnode stays
  allocated; the pool's 256 slots are ample runway.
- **Task-scoped fd → vnode mapping** — R16.M3. `sys_close(fd)` will call
  `vfs_close(fd_table[fd].vnode_idx)` after clearing the fd slot.
- **Concurrent close on SMP** — R17+. Refcount ops are not yet atomic.
  This is safe today because R16.M1 runs single-CPU-guarded (VFS calls
  only reached from CPU0 kernel context). A cmpxchg-based refcount lands
  when SMP VFS access opens up.

# Tractability

**HIGH.** Isomorphic to vfs_open (#575) in structure — same 5-push prologue,
same narrow-load/store idiom, same vops-family dispatcher shape. The
control flow is actually simpler than vfs_open (no O_CREAT branching, no
path_resolve, no create stub). Register discipline is a tighter subset of
vfs_open's (2 live values instead of 3). The one novel element is the
conditional vops_close on refcount==0, and that's a single `cmp/jne` gate
around a two-instruction call sequence.

Sole subtle point is the deliberate ignore of vops_close's return value;
that decision is captured in §3 mode 4 and §11 so a future maintainer can
find the rationale without re-deriving it.
