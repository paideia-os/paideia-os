# Persistent /home/operator — R65 design

**Status:** Partial. R65.M1-002 (init envp: PATH + HOME) is real,
landed code as of this document. Everything else described here — the
init-time probe/mount, the shell chdir-on-entry, the reboot-persistence
smoke — is design only, deferred behind the R64 volume-tooling ELF
chain (see `doc/user-guide/volume-tools.md` §6 and
`design/round-retrospectives/r64-closure.md`). Read §6 before assuming
`/home/operator` actually persists anything today.

**Depends on:** `design/tooling/volume-tooling-ux.md` (R53, mkfs.pdxfs
/ mount.pdxfs / umount.pdxfs / libpdx-volume design),
`design/filesystem/volume-fs-substrate.md` (R52, PDXB superblock + WAL
format), `design/user/execve-abi.md` (R62, real argv/envp on execve),
`design/user/rootfs-seed-inventory.md` (R57.M4-006, init-time /bin seed
loop this design's mount probe is sequenced alongside).

---

## 1. Goal

Today, `/home/operator` (and everything under it) is backed by tmpfs:
in-memory, gone on every reboot. R65's goal is to make `/home/operator`
a real mount point backed by a persistent PDXB volume, so a file an
operator writes survives a reboot cycle — the same guarantee R53's
volume tools give any mount point, applied specifically to the home
directory every interactive session starts in.

This is deliberately narrow in scope: one specific device
(`/dev/nvme0`), one specific mount point (`/home/operator`), probed
once at init time. It is not a general "any device, any mount point"
init-time automount facility — that is out of scope; see §5.

---

## 2. The mount-at-boot path (R65.M1-001, #1916 — deferred)

The intended sequence, added to `src/user/init.pdx` immediately after
the existing R57.M4-006 rootfs-seed loop and before the first
fork+exec cycle:

1. `sys_stat("/dev/nvme0")` — check the device node exists. Absence is
   not fatal: init continues boot with `/home/operator` still backed by
   tmpfs, exactly as it is today. This mirrors the existing rootfs-seed
   loop's own "skip silently, keep booting" discipline.
2. If present, probe for a valid PDXB superblock (the same signature
   check `mkfs.pdxfs`'s non-blank-target gate performs, run here in the
   opposite direction — confirming the device *does* carry a valid,
   signed volume before trusting it).
3. On a valid superblock, `sys_mount` the resulting `KIND_VOLUME` at
   `/home/operator`. This is the same kernel-side `sys_mount` entry
   point `mount.pdxfs` calls from userland (§4 of
   `design/tooling/volume-tooling-ux.md`) — init is simply a second,
   privileged caller of it, invoked before any shell exists to run the
   userland tool interactively.
4. On any failure at steps 1–3 (device absent, superblock invalid,
   mount syscall error), init logs and continues with the tmpfs
   fallback. A missing or corrupt home volume is never a boot-blocking
   condition.

### 2.1 Dependency chain

This mount can only ever succeed once every earlier link in the chain
is real:

```
mkfs.pdxfs produces a PDXB image on /dev/nvme0
        │  (needs libpdx-volume.pdxb_encode_superblock +
        │   pdxb_sign_superblock — the latter blocked on
        │   paideia-as #1730's mldsa65_sign intrinsic gap)
        ▼
a valid, signed KIND_VOLUME superblock exists on the device
        │
        ▼
init's boot-time probe (this section) finds it and calls sys_mount
        │  (sys_mount itself is real kernel substrate per R53's
        │   osarch half; what's missing is a *caller* wired into
        │   init's boot sequence)
        ▼
/home/operator is a real, persistent mount point
```

Every box above the last one is currently unmet: there is no PDXB
image on any `/dev/nvme0` in the paideia-os boot path today, because
`mkfs.pdxfs` itself cannot produce one until the tool-repo chain
described in `doc/user-guide/volume-tools.md` §6 closes. R65.M1-001
(#1916) is therefore deferred, not because the init-side code is hard,
but because it has nothing real to mount yet.

---

## 3. Environment prep: PATH + HOME (R65.M1-002, #1918 — landed)

Independent of the mount above, every process init execs now receives
a real, non-empty environment. `src/user/init.pdx` declares two rodata
strings and a runtime-populated pointer table:

```
init_env_path : "PATH=/bin:/usr/bin\0"   (19 bytes incl. NUL)
init_env_home : "HOME=/home/operator\0"  (20 bytes incl. NUL)
_init_envp    : [u64; 3] = uninit @align(8)   // populated at _start
```

`_init_envp` is populated once, at `_start`, before any of init's three
fork+exec cycles run: `_init_envp[0] = &init_env_path`,
`_init_envp[1] = &init_env_home`, `_init_envp[2] = 0` (NULL
terminator). This is the same idiom `dispatch.pdx`'s
`builtin_names`/`dispatch_init` already uses for its runtime dispatch
table (R17-m3-004, #624) — paideia-as data initializers accept literal
bytes, not label addresses, so a pointer array must be declared
`uninit` and filled via `lea`+`mov` at runtime rather than initialized
in place.

All three of init's execve sites (`/bin/child_hello`,
`/bin/sh`, `/bin/elevate_broker_daemon`) now load `rdx` with
`&_init_envp` instead of zeroing it. This activates R62's
(12a731a) previously-idle envp-marshalling path in `sys_execve_shim`:
the existing `sys execve argv ok -- argc=<N> envc=<M>` fingerprint
(`klog_s1_d2`) now fires with `envc=2` instead of `envc=0` on every
init-launched process.

**Note on HOME today:** `HOME=/home/operator` is now a real environment
variable every child process can read — but until §2's mount lands,
`/home/operator` itself remains backed by tmpfs like the rest of the
in-memory filesystem. Setting `HOME` correctly is a real, independent
improvement (any HOME-aware userland tool now has a value to read) that
does not depend on the mount landing; it simply does not yet gain the
*persistence* the mount would add.

---

## 4. Shell chdir-on-entry (R65.M1-003, #1921 — deferred)

**Intended fingerprint:** `shell cwd init ok -- cwd=<path>`.

Once `HOME` is populated (§3, now real), the plan is for `shell.pdx`'s
`_start` to read it and invoke the existing `cd_builtin` logic (see
`src/user/dispatch.pdx`'s `cd_builtin`, R17-M4 #632) to set the
shell's tracked working directory to `$HOME` before the first prompt,
rather than defaulting to `/`.

Two things are worth being precise about, because they are easy to
conflate:

- **`cd_builtin` today does not call any kernel syscall.** It copies
  `argv[1]` into a userland `_cwd_buf` after a `'/'`-prefix check and a
  256-byte length check — there is no `sys_chdir` syscall yet, and no
  kernel-side existence check on the target path (see
  `design/kernel/r17-m4-shell-builtins.md`'s note on this). Wiring
  chdir-on-entry to `$HOME` is therefore mechanically simple and does
  **not** by itself require the mount from §2 to exist.
- **It is deferred anyway in this round**, so that "cd to `$HOME`"
  lands together with a `$HOME` that is an actual, existing, mounted
  directory (§2) rather than a blindly-accepted path string that may or
  may not resolve to anything real. A future round — provisionally
  tracked as **R86**, when a real `sys_chdir` syscall is expected to
  land (giving the kernel an authoritative, validated current-directory
  concept rather than a userland-only `_cwd_buf` string) — is the
  natural point to revisit this together with real path validation.

---

## 5. Out of scope

- **General automount.** Only `/dev/nvme0` → `/home/operator` is
  probed; there is no config-driven "mount every discovered volume at
  its declared mount point" facility. That is a superset of R53's
  `mount.pdxfs` tool itself (an interactive/scripted tool, not a boot
  policy engine) and is not proposed here.
- **Multiple users / multiple home volumes.** R65 targets the single
  `operator` account. Per-user home-volume selection needs the
  multi-user `KIND_USER` model work tracked elsewhere in
  `design/user/model.md`; out of scope here.
- **Encryption-at-rest for `/home`.** Same R54+ deferral
  `design/tooling/volume-tooling-ux.md` §1.2 already carries for every
  PDXB volume; nothing home-specific changes that.

---

## 6. Honest scope block

**What is real, in this monorepo, today:**
- `src/user/init.pdx`'s `_init_envp` construction and the three
  execve-site `rdx` loads (§3, R65.M1-002, #1918).

**What is design-only, deferred, and why:**
- §2 init-time probe + mount (#1916) — deferred; nothing to mount
  until the R64 tool-repo chain (`mkfs.pdxfs` + `libpdx-volume`, itself
  blocked on paideia-as #1730) produces a real PDXB image.
- §4 shell chdir-on-entry (#1921) — mechanically independent of the
  mount, but deferred to land alongside a `$HOME` that resolves to
  something real; also anticipates the future `sys_chdir` syscall
  (provisionally R86).
- `boot_r65_persistent_home` composite smoke (R65.M1-004, #1926) and
  its `PAIDEIA_R65_PERSIST=1` pre-push gate (R65.M1-005, #1930) —
  deferred; both require §2 and §4 to be real first, since the smoke's
  whole point is proving a file survives a reboot through a real mount.

See `design/round-retrospectives/r65-closure.md` for the round's full
landed/deferred accounting and the `r65-closed` tag rationale.
