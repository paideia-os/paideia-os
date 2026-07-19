issue: 575
milestone: R16.M1 (VFS abstract layer)
subsystem: 11 — VFS abstract layer
topic: vfs_open — resolve path, alloc-if-O_CREAT, refcount++

# Goal

`vfs_open(path_ptr, flags) -> u16` — resolve a null-terminated path against the mount root, optionally create if missing, increment refcount, return vnode idx.

# Signature

- Input:
  - `rdi = path_ptr` (u64) — pointer to null-terminated ASCII path
  - `rsi = flags` (u64) — bitmask
- Output:
  - `rax = vnode_idx` (u16 zero-extended) or 0 on failure

# Flags (frozen)

| bit | flag       | value  |
|-----|------------|--------|
| 0-1 | access     | 0=RDONLY, 1=WRONLY, 2=RDWR |
| 6   | O_CREAT    | 0x40   |
| 7   | O_TRUNC    | 0x80   |
| 9   | O_APPEND   | 0x200  |

# Body sequence

1. Prologue: 5-push callee-save (rbx, r12, r13, r14, r15). Aligns rsp%16==0 for nested calls.
2. Save: rbx = path_ptr, r12 = flags
3. Call `mount_root_vnode()` → rax = root_idx
4. Call `path_resolve(rbx, rax, 0)` (cwd=0 for now — task_struct cwd deferred to R16.M3)
   - rax = resolved vnode idx or 0
5. If rax != 0: goto :found
6. Else (path not found):
   - Test flags & O_CREAT (0x40)
   - If not set: rax=0, epilogue
   - If set: TODO minimal impl — for R16.M1 witness, resolve to a `_witness_dir_vnode` and call vops_create with the path leaf as name
   - For R16.M1 body: fall through to :not_created returning 0 (real create body in R16.M2 tmpfs)
7. :found:
   - Call vnode_slot(rax) → rdi = &vnode
   - Load refcount @+4 (u16): mov cx, [rdi+4]
   - inc cx
   - Store back: mov [rdi+4], cx
8. Optional: call vops_open (returns 0 on success, error otherwise). Skip for R16.M1 (backends implement in R16.M2+).
9. Epilogue: pop r15..rbx, ret

# Register discipline

- rbx = path_ptr (survives path_resolve, vnode_slot)
- r12 = flags (survives path_resolve, vnode_slot)
- r13, r14, r15 unused (kept in prologue for uniform pattern with path_resolve)
- rax = scratch/return
- rcx = refcount scratch
- rdi = vnode ptr (from vnode_slot)

# Witness (kernel_main.pdx)

Preamble: mount is already done by #574 witness with fresh root vnode at some idx N.

- Sub-test A: rax = vfs_open("/", 0). Expect rax != 0 (root vnode found).
- Sub-test B: vnode_slot(rax).refcount now 2 (was 1 after mount).
- Sub-test C: rax = vfs_open("/nonexistent", 0). Expect rax == 0.
- Sub-test D: rax = vfs_open("/nonexistent", 0x40). For R16.M1, expect rax == 0 (real create in R16.M2). Documented as scope limit — sub-test D checks that O_CREAT path is REACHED (branch taken), not that create succeeds.

For witness purposes, sub-test D can be relaxed: any return value acceptable, but the flag check must be exercised in disassembly.

Emit `R16 VFS OPEN OK` after A, B, C pass.

# Files touched

- `src/kernel/core/fs/vfs_open.pdx` (new, ~80 LOC)
- `src/kernel/boot/kernel_main.pdx` (+~60 LOC witness)
- `tools/boot_stub.S` (+2 rodata strings)
- 3 fingerprint files (+1 marker line each)

# Tractability

HIGH. Composition of landed primitives. No new encoder shapes. Register pattern mirrors path_resolve.

# Deferred

- O_CREAT actual create body → R16.M2 tmpfs backend
- O_TRUNC handling → R16.M2
- O_APPEND → R16.M3
- vops_open backend hook call → R16.M2
- Task-scoped cwd → R16.M3 fd table phase

# Design doc for #574 mount_table

Note: `design/kernel/r16-m1-005-mount-table.md` is currently untracked; include it in the #575 commit.
