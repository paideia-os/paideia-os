# R17-M0-665: vnode/inode conflation fix (vnode_cache_or_alloc)

## §1. Overview

Issue #665 fixes a fundamental architectural flaw in the VFS implementation: the conflation of vnode indices with backend inode indices. Until R17-M0, path_resolve treated backend inode indices (returned by vops_lookup) as if they were vnode indices, requiring manual pre-wiring of vnode slots with ops_ptr and backend_ptr fields. This fix introduces vnode_cache_or_alloc, a lookup-or-allocate helper that properly allocates vnode-pool slots on-demand with correct ops_ptr and backend_ptr wiring, eliminating the need for manual pre-wires in all witnesses.

**Status**: Landed R17-M0-665, removing 60+ LOC of pre-wire preambles from five witness sections (sys_read, sys_write, sys_dup2, fd_inherit, fd_cloexec).

## §2. Problem Statement

### §2.1 The conflation

Prior to this fix, path_resolve exhibited the following flaw:

1. vops_lookup(dir_vnode, name) returns a backend-native inode index (e.g., a tmpfs inode index 1..1023).
2. path_resolve treated this index as if it were a vnode index (0..255).
3. A later vnode_slot(inode_idx) call would access _vnode_pool[inode_idx], which was often never populated.
4. As a result, vnode fields (ops_ptr at +24, backend_ptr at +32) would be zero, breaking downstream vfs operations.

Witness code worked around this by manually pre-wiring vnodes:
```asm
mov rdi, inode_idx
call vnode_slot                              // rax = &vnode[inode_idx]
lea rcx, [rip + _tmpfs_vops]
mov [rax + 24], rcx                          // ops_ptr = &_tmpfs_vops
mov rcx, inode_idx
mov [rax + 32], rcx                          // backend_ptr = inode_idx
```

This workaround was:
- Manual and error-prone
- Scattered across five witness sections
- Semantically incorrect (treating indices as interchangeable)
- A blocker for future work on multi-backend filesystems

### §2.2 Impact on mount() and path_resolve()

**mount()** (R16-M1-005 #574): Allocated the root vnode for a mounted filesystem but left ops_ptr and backend_ptr at zero, deferring wiring to first-access workarounds.

**path_resolve()** (R16-M1-004 #573): Called vops_lookup to get backend child indices but had no mechanism to allocate corresponding vnode slots with proper wiring.

## §3. Solution

### §3.1 vnode_cache_or_alloc(parent_idx, backend_idx, ops_ptr) → vnode_idx

**Signature**: Three-argument leaf function returning a vnode index or 0xFFFF on OOM.

**Semantics**:
1. Linear scan of vnode pool [1..256) for an existing slot matching (parent_idx@+8, backend_idx&0xFFFF@+32, ops_ptr@+24).
2. If found: return the matching vnode_idx (deduplication).
3. If not found: allocate a fresh slot via vnode_alloc, populate fields, return new_idx.
4. On vnode_alloc OOM: return 0xFFFF.

**Implementation notes**:
- Uses callee-save registers (r12/r13/r14) to preserve arguments across vnode_alloc call.
- Stores parent_idx as full u64 (high 48 bits zero for u16 values) for atomicity.
- Stores backend_ptr as full u64 (low 16 bits = backend_idx).
- Defined in `src/kernel/core/fs/vnode_pool.pdx`.

### §3.2 Backend dispatch helpers

Two new leaf functions in `src/kernel/core/fs/backend_registry.pdx`:

**backend_ops_table(backend_type: u64) → u64**
- Switch on backend_type.
- For MOUNT_BACKEND_TMPFS (1): return &_tmpfs_vops.
- For other types: return 0 (NULL).

**backend_root_inode(backend_type: u64) → u64**
- Switch on backend_type.
- For MOUNT_BACKEND_TMPFS (1): return 1 (TMPFS_INODE_IDX_ROOT).
- For other types: return 0.

These helpers enable generic vnode wiring without hardcoded addresses.

### §3.3 path_resolve regular_lookup rewrite

The regular_lookup block in path_resolve (§3 of design/kernel/r16-m1-004-path-resolver.md) now:

1. Calls vops_lookup to get backend_child_idx (as before).
2. Loads parent's ops_ptr via vnode_slot(cur).
3. Calls vnode_cache_or_alloc(cur, backend_child_idx, ops_ptr) to allocate or deduplicate.
4. Sets cur = returned vnode_idx.

This ensures every vnode resolved via path_resolve is properly wired without pre-wiring.

### §3.4 mount() root vnode wiring

The alloc_root block in mount() (§4 of design/kernel/r16-m1-005-mount-table.md) now:

1. Allocates root vnode via vnode_alloc (unchanged).
2. Sets type = VNODE_TYPE_DIR and parent_idx = 0xFFFF (unchanged).
3. **NEW**: Calls backend_ops_table(backend_type) to get ops_ptr.
4. **NEW**: Stores ops_ptr to slot+24.
5. **NEW**: Calls backend_root_inode(backend_type) to get backend root inode idx.
6. **NEW**: Stores backend_idx to slot+32.

This wires the root vnode at mount time, eliminating the sys_read_witness pre-wire for root.

## §4. Implementation

### §4.1 Files created/modified

**Created**:
- `src/kernel/core/fs/backend_registry.pdx` (66 LOC): backend_ops_table, backend_root_inode.

**Modified**:
- `src/kernel/core/fs/vnode_pool.pdx`: Added vnode_cache_or_alloc (130 LOC).
- `src/kernel/core/fs/path.pdx`: Rewrote regular_lookup block (14 lines → 25 lines, net +11).
- `src/kernel/core/fs/mount.pdx`: Wired root vnode in alloc_root (5 lines → 20 lines, net +15).
- `src/kernel/boot/kernel_main.pdx`: Removed 60+ LOC of pre-wires; added #665 witness (120 LOC).
- `tools/boot_stub.S`: Added vnode_conflation_ok_msg, vnode_conflation_fail_msg (8 LOC).
- `tests/r15/expected-boot-r15-process.txt`, `tests/r15/expected-boot-r15-ring3.txt`: Added marker line.

### §4.2 Witness structure (#665)

**Sub-test A**: Create /tmp/x inode via tmpfs_create (low-level operation).

**Sub-test B**: Call path_resolve("/tmp/x", root_idx, 0) **without pre-wiring** → assert rax != 0.

**Sub-test C**: Verify returned vnode's ops_ptr == &_tmpfs_vops and backend_ptr & 0xFFFF == x_inode_idx.

**Sub-test D**: Re-resolve same path → assert returned idx equals prior (deduplication via vnode_cache_or_alloc cache hit).

**Marker**: "R17 VNODE CONFLATION FIX OK" on success; "R17 VNODE CONFLATION FIX FAIL" on any sub-test failure.

## §5. Witness and test plan

### §5.1 New #665 witness

Located in kernel_main.pdx after mount_witness_done, before vfs_open_witness.

Demonstrates that path_resolve works correctly without manual pre-wires:
1. Backend inode indices (from vops_lookup) are distinct from vnode indices.
2. vnode_cache_or_alloc bridges the gap, allocating vnodes on-demand.
3. Deduplication prevents redundant allocations for repeated path resolves.

### §5.2 Updated witnesses (sys_read, sys_write, sys_dup2, fd_inherit, fd_cloexec)

All five witnesses now omit manual pre-wire preambles:
- **Root pre-wire removed**: mount() handles it.
- **Tmp pre-wire removed**: path_resolve handles it via vnode_cache_or_alloc.
- **X pre-wire removed**: path_resolve handles it via vnode_cache_or_alloc.

Witnesses still run the same test logic; they now rely on vnode_cache_or_alloc instead of pre-wiring.

### §5.3 Path_resolve witness (#573) update

Sub-test D (resolve "/foo/bar") updated:
- Old assertion: `cmp rax, 3` (expected specific vnode idx).
- New assertion: `cmp rax, 0; je fail` (any non-zero, non-0xFFFF idx is valid).
- Verification: vnode_slot(rax).backend_ptr & 0xFFFF must equal 3 (bar's backend idx from witness stub).

The witness tree uses fixed indices 1, 2, 3 for root, foo, bar, but vnode_cache_or_alloc may reuse or allocate different vnode slots; the important invariant is backend_ptr, not vnode_idx.

## §6. Backward compatibility and migration

This is a **breaking fix** within R17-M0 only. No user-facing APIs change, but internal vnode representation is corrected:

1. All code calling path_resolve benefits automatically (no call-site changes needed).
2. Code calling vops_* functions directly with vnode indices is unaffected.
3. Code relying on vnode pre-wiring (i.e., the witness preambles) is obsolete; removal is part of this landing.

## §7. Performance and correctness implications

### §7.1 Correctness

- **Eliminates index conflation**: Every vnode allocated by vnode_cache_or_alloc has consistent ops_ptr and backend_ptr.
- **Semantics clarity**: Path resolution now clearly separates vnode indices (pool identity) from backend inode indices (FS-specific identity).
- **Future-proof**: Multi-backend FS scenarios (e.g., union mounts, overlay FS) can reuse vnode slots via deduplication (different vnode_idx for the same backend inode via different parent or ops_ptr).

### §7.2 Performance

- **Vnode allocation cost**: vnode_cache_or_alloc adds a linear scan [1..256) per path component lookup. For typical paths (3–5 components), this is negligible; deduplication on repeated resolve calls recovers cost.
- **Memory efficiency**: Deduplication reduces vnode pool waste (same backend inode accessed via different paths reuses one vnode).
- **Alignment**: No change to vnode pool layout, cache-line properties, or alignment (@align(64) per vnode).

## §8. Amendment notes to related design docs

### §8.1 r16-m1-004-path-resolver.md

Add to §5 (Witness):
> Amended by R17-M0 #665: path_resolve now uses vnode_cache_or_alloc to allocate vnodes on-demand. Sub-test D no longer asserts a specific vnode_idx; instead, it verifies backend_ptr matches the expected backend inode index.

### §8.2 r16-m1-005-mount-table.md

Add to §4 (Implementation):
> Amended by R17-M0 #665: mount() now wires the root vnode's ops_ptr and backend_ptr via backend_ops_table and backend_root_inode helpers at allocation time, eliminating the need for post-mount pre-wiring by witnesses.

### §8.3 r16-m3-003-sys-read.md

Add to §4.3.1 (Design decision):
> Amended by R17-M0 #665: Manual vnode pre-wiring removed. vnode_cache_or_alloc handles ops_ptr and backend_ptr wiring automatically during path_resolve. Witness preambles simplified to remove 50+ LOC of pre-wire code.

---

**Milestone closure**: R17-M0 closes issue #665. All vnode/inode conflation workarounds are removed; vfs layer is semantically correct.
