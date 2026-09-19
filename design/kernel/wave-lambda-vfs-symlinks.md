# Wave λ — VFS symlink surface (λ-02 · λ-03 · λ-04 · λ-05)

**Status:** landed (paideia-os, Wave λ, 2026-09-18).
**Companion designs:** `r16-m1-003-vops.md`, `vfs-metadata-syscalls.md`.

## Scope

Wave λ adds a symbolic-link surface to the kernel VFS. The syscall table
grows two entries (sysnos 125, 126), the vops function-pointer table
gains two tail slots (+96 readlink, +104 symlink), tmpfs receives real
adapters over a side-pool storage substrate, and the pdxfs family
receives refusal stubs pending the writable on-disk walker round.

Sysnos deliberately deviate from Linux convention (88/89): those slots
are already claimed by the R72.M1 TCP socket block (sys_bind /
sys_listen). Placing the new pair contiguously above the Wave iota pty
trio (122..124) keeps the dispatch chain monotonically ascending.

## Slot layout (post-Wave-λ)

| Offset | Name             | Introduced |
|--------|------------------|------------|
| +0     | read             | R16.M1-003 |
| +8     | write            | R16.M1-003 |
| +16    | open             | R16.M1-003 |
| +24    | close            | R16.M1-003 |
| +32    | lookup           | R16.M1-003 |
| +40    | create           | R16.M1-003 |
| +48    | unlink           | R16.M1-003 |
| +56    | stat             | R56.M3-002 |
| +64    | readdir          | R56.M3-003 |
| +72    | mkdir            | R56.M3-004 |
| +80    | rmdir            | R56.M3-004 |
| +88    | rename           | R56.M3-005 |
| **+96**  | **readlink**   | **Wave λ** |
| **+104** | **symlink**    | **Wave λ** |

`VOPS_SIZE` widens 96 → 112. `VOPS_NUM_OPS` widens 12 → 14. Witness
tables in `vops.pdx` widen defensively to `[u64; 14]`; the new tail
slots stay null so a stray dispatch renders as `VOPS_ERR_NOT_SUPPORTED`
via the existing null-guard rather than OOB-reading past `.bss`.

## tmpfs storage substrate (λ-04)

Target strings live in a dedicated side pool
`_tmpfs_symlink_pool : [u8; 65536]` (TMPFS_MAX × 256 B), indexed by the
tmpfs inode idx via the leaf helper `_tmpfs_symlink_slot`. Keeping the
pool disjoint from the tmpfs inode struct preserves every existing
offset invariant (name @+1040, sibling-chain @+1136, page_ptrs @+16 —
last rebased at paideia-os #2436) and avoids re-touching the eight-plus
consumers of those offsets. Target length lives in the standard
`inode.size` field (+8); type = 3 (LNK) lives in the standard
`inode.type` byte (+0).

Cap: 255 bytes per target (leaves the pool slot's final byte as an
implicit NUL sentinel; the length in `inode.size` is authoritative for
readback).

## pdxfs family refusal stubs (λ-05)

Both `pdxfs_lite` and `pdxfs_block` publish refusal-only adapters
(`VOPS_ERR_NOT_SUPPORTED` and `MOUNT_BACKEND_UNKNOWN` respectively).
Real on-disk symlink data persistence is deferred to the writable
walker round that also brings `PXT_OP_SYMLINK` (journal-append +
symlink-data write + dentry-add).

Superblock format is **not** bumped: the S_IFLNK marker fits inside the
existing inode type byte (0xA000 mask family) and the symlink target
reuses the existing block-pointer discipline. Older tools that pre-date
S_IFLNK reject any inode whose type byte reads 0xA-family as unknown,
which is the correct safety posture — no forced migration.

## Failure taxonomy

| sentinel               | u64 hex               | meaning                          |
|------------------------|-----------------------|----------------------------------|
| success                | 0 (symlink) / >0 bytes (readlink) | OK                     |
| -EFAULT                | 0xFFFFFFFFFFFFFFF2    | walker rejected user buf         |
| -ENOENT                | 0xFFFFFFFFFFFFFFFE    | no such path / missing basename  |
| -EINVAL                | 0xFFFFFFFFFFFFFFEA    | target not a symlink (readlink)  |
| -EACCES                | 0xFFFFFFFFFFFFFFF3    | backend refused                  |
| VOPS_ERR_NOT_SUPPORTED | 0xFFFFFFFFFFFFFFFF    | null slot / pdxfs refusal        |

readlink folds both `-EINVAL` and `VOPS_ERR_NOT_SUPPORTED` into a
uniform `-EINVAL` for ring-3 via sign-test on the vops return.

## Deferred

- Real pdxfs on-disk symlink data path (needs writable walker).
- Split of tmpfs collision into `-EEXIST` (currently folds to
  `-EACCES` via `VOPS_ERR_NOT_SUPPORTED`).
- Per-TCB scratches for `_sys_symlink_*_scratch` and
  `_sys_readlink_*_scratch` (single-flow at Wave λ; same follow-up as
  every other syscall-body scratch in this tree).
- Fingerprint emit tags (`tag_sys_symlink_ok`, `tag_sys_readlink_ok`)
  — deferred to keep `klog/keys.pdx` minting confined to a follow-on
  wave; the sys bodies currently return without emitting.

## λ-01 note (sys_stat)

The task brief described `sys_stat` as returning "a fixed stub shape",
but `src/kernel/core/syscall/sys_stat.pdx` (R56.M3-002) already
resolves the path, dispatches through `vops_stat`, and populates real
ino / size / mode / nlink / uid / gid / blksize / blocks fields per
backend. `st_mtime` is populated correctly by the pdxfs_lite adapter
(from on-disk `inode.mtime @+24`) but reads as 0 for tmpfs — the
tmpfs inode struct has no mtime slot yet, and adding one is a
high-risk rebase across the eight+ consumers of the frozen
`TMPFS_INODE_*_OFFSET` constants (last touched at paideia-os #2436).
Deferred to a dedicated tmpfs-mtime widening wave.
