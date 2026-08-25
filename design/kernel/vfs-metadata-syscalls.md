---
issue: 1790
milestone: R56.M3 (VFS metadata syscall block)
subsystem: syscall dispatch / VFS
topic: VFS metadata syscalls (stat, getdents, mkdir, rmdir, unlink, rename) — sysno block 77..82.
touching:
  - src/kernel/core/syscall/dispatch.pdx        (bounds check 76 -> 82; six ENOSYS stub labels)
  - design/kernel/vfs-metadata-syscalls.md      (this doc)
related:
  - src/kernel/core/syscall/dispatch.pdx        (R53.M2-001 mount/umount stub-body pattern followed here)
  - design/kernel/r17-m0-668-syscall-dispatch-align.md
  - design/kernel/vfs-layout.md
  - design/kernel/r16-m1-006-vfs-open.md
follow-ups:
  - 1791 (sys_stat body + sys_getdents body)
  - 1792 (sys_mkdir body)
  - 1793 (sys_rmdir body)
  - 1794 (sys_unlink body)
  - 1795 (sys_rename body + R56.M3 boot smoke exercising 77..82)
---

# R56.M3-001 — VFS metadata syscall block (#1790)

## 1. Scope

Widen the dispatch bounds check from `76` to `82` and reserve six
contiguous sysno ordinals for the VFS metadata syscall block:

| sysno | name         | ordinal in landing plan |
|-------|--------------|-------------------------|
| 77    | `sys_stat`     | body: #1791             |
| 78    | `sys_getdents` | body: #1791             |
| 79    | `sys_mkdir`    | body: #1792             |
| 80    | `sys_rmdir`    | body: #1793             |
| 81    | `sys_unlink`   | body: #1794             |
| 82    | `sys_rename`   | body: #1795             |

#1790 lands the dispatch-table expansion only. Each new dispatch
label returns `-ENOSYS` (`0xFFFFFFFFFFFFFFDA`) as an inline
forward-declaration stub — same discipline as R53.M2-001
(dispatch_mount / dispatch_umount) so the widened dispatch links
without an undefined-symbol reference to the sibling body files
that have not yet landed.

## 2. Schema table

All six syscalls follow the SysV positioning convention that
`syscall_dispatch` inherits from `syscall_entry` (see
`entry.pdx` §shuffle): `rdi = sysno`, `rsi = a0`, `rdx = a1`,
`rcx = a2`, `r8 = a3`, `r9 = a4`.

| sysno | name         | rsi (a0)         | rdx (a1)         | rcx (a2) | Return (rax)                              |
|-------|--------------|------------------|------------------|----------|-------------------------------------------|
| 77    | sys_stat     | `path_ptr` (u)   | `stat_buf_ptr` (u) | —      | `0` on success, `-errno` on failure       |
| 78    | sys_getdents | `fd`             | `buf_ptr` (u)    | `nbytes` | bytes-read on success, `-errno` on failure |
| 79    | sys_mkdir    | `path_ptr` (u)   | `mode`           | —        | `0` on success, `-errno` on failure       |
| 80    | sys_rmdir    | `path_ptr` (u)   | —                | —        | `0` on success, `-errno` on failure       |
| 81    | sys_unlink   | `path_ptr` (u)   | —                | —        | `0` on success, `-errno` on failure       |
| 82    | sys_rename   | `old_path_ptr` (u) | `new_path_ptr` (u) | —    | `0` on success, `-errno` on failure       |

`(u)` marks arguments that are user virtual addresses. Every such
arg requires `user_ptr_ok(va, cap)` at the dispatch layer as the
first-line KPTI defence (`#741` pattern; see
`design/kernel/r16-m3-741-user-ptr-ok-defense-in-depth.md`), plus
a bounce-buffer copy through `_dispatch_open_path_scratch` (or a
dedicated per-syscall scratch) via `user_read_str_via_walk` for
paths and `user_write_bytes_via_walk` for out-bufs. The bodies
themselves see kernel VAs only, matching the discipline pinned in
`vfs_open`, `vfs_read`, `vfs_write`, and the sibling `sys_open` /
`sys_read` / `sys_write` shims.

## 3. Errno convention

All six use the standard Linux-style **negative errno as u64**
convention that the rest of the syscall surface follows (bit 63
set so a ring-3 caller can `cmp rax, 0; jl err` to sign-test any
error class in a single instruction). Relevant sentinels the
bodies will populate in the follow-up landings:

| errno    | u64 value            | meaning                                  |
|----------|----------------------|------------------------------------------|
| `-EFAULT`  | `0xFFFFFFFFFFFFFFF2` | user pointer failed `user_ptr_ok` or walker |
| `-EINVAL`  | `0xFFFFFFFFFFFFFFEA` | bad mode / bad `nbytes` / etc.           |
| `-ENOENT`  | `0xFFFFFFFFFFFFFFFE` | path does not resolve                    |
| `-EEXIST`  | `0xFFFFFFFFFFFFFFEF` | `mkdir` on existing entry                |
| `-ENOTDIR` | `0xFFFFFFFFFFFFFFEC` | non-dir where dir expected               |
| `-EISDIR`  | `0xFFFFFFFFFFFFFFEB` | `unlink` on directory                    |
| `-ENOTEMPTY`| `0xFFFFFFFFFFFFFFDF`| `rmdir` on non-empty directory           |
| `-EBADF`   | `0xFFFFFFFFFFFFFFF7` | `getdents` on invalid fd                 |
| `-ENOSYS`  | `0xFFFFFFFFFFFFFFDA` | body not yet landed (this ticket's stubs) |

The stub landing returns only `-ENOSYS`; the errno families in
the rows above are declared here so the follow-up bodies land
into a documented taxonomy rather than re-invent one per body.

## 4. Table-widening posture

This ticket (#1790) intentionally lands **only** the dispatch
expansion + inline `-ENOSYS` stubs. Rationale:

* Widening the bounds check in the same edit that lands each
  body would serialise #1791..#1795 unnecessarily — they are
  independent ordinals with independent bodies. Landing the
  table first turns each sibling into a self-contained
  in-place rewrite of one dispatch label.
* The inline-stub shape mirrors R53.M2-001 (dispatch_mount /
  dispatch_umount) exactly, so the pattern is already
  established in the file and reviewers have a precedent to
  compare against.
* No fingerprint regression: `tools/verify-syscall-dispatch.sh`
  greps for `cmp.*0x3d` (== 61 = wait4) as the bounds-check
  witness. That `cmp rdi, 61; je dispatch_wait4` line stays
  intact in the switch cascade, so `TOTAL_CHECKS=19` and all
  existing checks continue to pass without touching the
  verifier.

Follow-up landings (#1791..#1795) each:

1. Land the per-syscall body (either in `dispatch.pdx` inline
   or in a new per-file `sys_<name>.pdx` following the
   `sys_mount.pdx` / `sys_umount.pdx` convention).
2. Rewrite the corresponding `dispatch_<name>:` label from
   the inline `mov rax, 0xFFFFFFFFFFFFFFDA; ret` stub into a
   full shim: `user_ptr_ok` gate(s), KPTI-bounce copy for
   paths / out-bufs, `sub rsp, 8` alignment bracket, `call
   sys_<name>_body`, `add rsp, 8`, `ret`.
3. #1795 additionally lands the R56.M3 boot smoke that
   exercises all six sysnos end-to-end from ring-3.

### 4.1 R56.M3-006 composite-smoke deferral (#1795)

Landed as a **dormant scaffold**:

* `src/kernel/boot/witness/r56_meta.pdx` — symbol
  `r56_meta_witness` exists (links into `build/kernel.elf`)
  and returns `77` (SKIP sentinel). NOT wired into
  `kernel_main` / `r30_platform.pdx`; body does not invoke
  any `sys_*_body`.
* `tools/run-smoke.sh` — `boot_r56_meta` mode is a
  SKIP-echo (matches the R54.M1-002 `boot_r54_bdev_flush`
  and R55.M2-005 dormant precedents).
* `tests/r56/expected-r56-meta.txt` — six-line composite
  golden reserved for the future FINGERPRINT_MODE=1 flip.

**Why deferred.** Every `sys_*_body` in the R56.M3 wave
walks its caller-supplied path via `user_read_str_via_walk`
against the current task's page tables. A kernel-side call
handing that walker a `.bss` scratch buffer either misses
the mapping (walker returns 0 -> EFAULT) or faults on a
kernel-only page. Forging a synthetic user aspace around
the composite call sequence duplicates the KPTI cr3 dance
without benefit over the natural R57 host: a **ring-3
harness** (userspace `mkdir(1)` / `stat(1)` / `rmdir(1)` /
`unlink(1)` / `rename(1)` binaries) that exercises the six
sysnos through the syscall trap. Landing the composite at
R56.M3 would conflate two independent verification tiers
(the syscall wire-up already covered per-body by
#1791..#1794, and the userspace client that exercises it).

**What is already covered.** Each per-body fingerprint is
witnessable individually via the R56.M3-002..005 goldens:

* `tests/r56/expected-r56-mkdir-rmdir.txt` — #1793
* `tests/r56/expected-r56-stat.txt`        — #1792
* `tests/r56/expected-r56-getdents.txt`    — #1791 (readdir), #1792..
* `tests/r56/expected-r56-unlink-rename.txt` — #1794

The R56.M3-006 composite golden aggregates these six lines
in call order so a future ring-3 harness (or an R57 wire-up
that mints a synthetic user aspace) can flip
`boot_r56_meta` from SKIP-echo to a real
`--fingerprint expected-r56-meta.txt` invocation without
touching the witness scaffold or the golden.

## 5. Reserved future range

The next free syscall number after this block is **83**. The
following adjacent claims are anticipated (not yet ticketed —
listed here so a future landing does not re-claim an ordinal
this block informally holds):

| range | intended family                             |
|-------|---------------------------------------------|
| 83    | `sys_stat64` / `sys_lstat` (extended stat)  |
| 84    | `sys_fstat` (fd-based stat)                 |
| 85    | `sys_symlink` + `sys_readlink` pair         |
| 86    | `sys_chmod` / `sys_fchmod`                  |

None of the above is a hard reservation — future rounds are
free to renumber per the "IDs are negotiable" clause
`design/tooling/volume-lifecycle-mechanism.md §10.1`
established. The list only signals what the block was
designed to expand into so a mid-round claimant does not
accidentally displace a contiguous VFS-metadata design.

## 6. SC+ freeze protocol interaction

The R17-M0-668 SC+ freeze locked the dispatch verifier
(`tools/verify-syscall-dispatch.sh`) to a specific set of
witnessable shapes. This ticket does not disturb any of them:

* Bounds-check witness (`cmp.*0x3d`) — matched by the wait4
  branch `cmp rdi, 61; je dispatch_wait4`, still present
  post-widen.
* ENOSYS witness (`0xffffffffffffffda`) — matched by
  `dispatch_enosys` and (now) by six additional inline stubs
  that share the same immediate. No verifier count needs to
  change.
* Per-sysno witnesses (checks 2..10, 16..19) — all continue to
  match their body-call greps unchanged.

Follow-up landings (#1791..#1795) that wire real bodies will
each add one witness line to the verifier (per the R17-M0-668
`TOTAL_CHECKS` convention). This ticket adds none.
