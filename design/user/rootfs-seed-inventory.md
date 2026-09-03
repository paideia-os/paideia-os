# Rootfs seed inventory — R57.M4-006 (#1802) + R106.M1 (#2228)

Init-time /bin + /etc/motd + /home seed loop. This document is the
manifest that `src/user/rootfs_seed.pdx` implements; the code and this
text must move together in every future landing that touches the seed
table.

R106.M1 (`#2228`) extended the manifest with two content-addressed
identity directories, `/home` and `/home/<placeholder_fp>/` — see
§"R106.M1 additions" below and the anchor design docs
[persistent-home-wave.md](../roadmap/persistent-home-wave.md) §R106
and [content-addressed-identity.md](content-addressed-identity.md) §4.
The placeholder fingerprint constant that composes the per-user home
path lives in `src/user/founder_constants.pdx` (module
`FounderConstants`, symbols `fc_*`) so R108.M2 can retire it in one
commit when real Argon2id + ML-DSA-65 key generation lands.

## Scope

At R57.M0, init assumes ownership of populating the userland-visible root
directory tree on first boot. The design's ultimate direction removes the
kernel-side `bin_seeds.pdx` block (`src/kernel/boot/witness/bin_seeds.pdx`)
and lets init do all of it in ring 3. This landing lands the mechanism —
directory create + file open+write+close over the SC+ frozen syscall
surface — while `bin_seeds.pdx` still runs at boot for compatibility.

The seed loop is idempotent: each seed run probes `/etc` via `sys_stat`
first, and skips all writes if `/etc` already exists (persistent-FS reboot
path). Under the current tmpfs mount, `/etc` is fresh at every boot, so the
loop always runs its work path.

## Directory + file manifest

Directories created (mode word supplied for POSIX conformance; tmpfs
backend drops it and forces `VNODE_TYPE_DIR` — the mode still travels
so a future mode-honouring backend picks up the intent):

| path                          | mode | notes                                                                   |
| ----------------------------- | ---- | ----------------------------------------------------------------------- |
| /bin                          | 0777 | may already exist under kernel `bin_seeds`; EIO ok                      |
| /etc                          | 0777 | new — the probe target and the /etc/motd parent                         |
| /tmp                          | 0777 | new — reserved for shell scratch                                        |
| /home                         | 0755 | R106.M1 — parent of every per-user home                                 |
| /home/<placeholder_fp>/       | 0700 | R106.M1 — placeholder founder home; `<placeholder_fp>` = 64-hex-char    |
|                               |      |   constant from `FounderConstants::fc_placeholder_fp_hex`; R108.M2      |
|                               |      |   overwrites it in place with the real founder fingerprint              |

Files written (open O_CREAT|O_WRONLY, mode 0644; skip per-file if the file
already exists so a kernel-side seed of the same path is not overwritten):

| # | path        | payload         | R57.M0 note                                     |
| - | ----------- | --------------- | ----------------------------------------------- |
| 1 | /bin/ls     | stub_bin (9 B)  | placeholder ELF; the real ls lands post-R57.M0  |
| 2 | /bin/cat    | stub_bin (9 B)  | placeholder ELF; the real cat lands post-R57.M0 |
| 3 | /bin/ps     | stub_bin (9 B)  | placeholder ELF; the real ps lands post-R57.M0  |
| 4 | /bin/mount  | stub_bin (9 B)  | placeholder ELF; the real mount lands post-R57  |
| 5 | /bin/true   | stub_bin (9 B)  | kernel `bin_seeds` already writes the real ELF; |
|   |             |                 | seed skips per stat probe so exec stays intact  |
| 6 | /bin/sh     | stub_bin (9 B)  | kernel `bin_seeds` already writes the real ELF; |
|   |             |                 | seed skips per stat probe so exec stays intact  |
| 7 | /etc/motd   | motd_banner     | fixed welcome banner — the seeded-marker file   |

Total FILE inventory: 7 entries. The fingerprint reports `files=7` — the
FILE-manifest size — regardless of how many entries were actually
written this boot. This is descriptive of the file inventory, not the
write count; keeping it stable lets goldens match a single line.

R106.M1 grew the DIRECTORY inventory from 3 to 5 (added `/home` and
`/home/<placeholder_fp>/`) but the fingerprint field is deliberately a
file count, not a total-entry count, so `files=7` remains the stable
work-path signal and `files=0` remains the stable skip-path signal.
The existing `tests/r17/expected-boot-r17-init.txt` golden does not
move under R106.M1.

## Payload strategy — R57.M0 stubs

For R57.M0 the payload is a small ASCII stub (`stub_bin`, 9 bytes:
`"R57 stub\n"`). This is intentional:

* the seed loop is what needs verifying — the mechanism of turning a fresh
  root inode-table into a populated /bin + /etc via ring-3 syscalls
* real ELFs (ls, cat, ps, mount) do not exist yet in `src/user/`; they land
  in R57.M4-007+ once their source `.pdx` files exist and `build-user.sh`
  learns to embed them into `init.elf`'s rodata the way it embeds
  `child_hello.elf` and `shell.elf` today
* /bin/true and /bin/sh already have real ELFs seeded by the kernel; the
  per-file stat probe below skips them so exec keeps working. When the
  kernel seed is removed in a later landing, this file's stub write becomes
  live and the entry flips to embedding the real ELF

/etc/motd carries a real 34-byte banner (`motd_banner`) — the only user-
visible content the R57.M0 landing produces on wire.

## Fingerprint

The seed loop emits exactly one fingerprint line via `sys_debug_puts`
(SC+ ID 12). The em-dash is intentionally dropped so the line contains
only 7-bit ASCII and grep patterns need no escape.

Work path (any file(s) actually written):
```
rootfs seed ok [legacy: ROOTFS SEED OK] files=7
```

Skip path (`/etc` already exists — persistent-FS reboot):
```
rootfs seed ok [legacy: ROOTFS SEED OK] files=0
```

Both lines share the prefix `rootfs seed ok` and the legacy alias
`ROOTFS SEED OK`; goldens targeting either the modern or legacy tag catch
both boot shapes. The count is the differentiator between first boot and
reboot.

## Syscall surface used

The loop uses only SC+ frozen syscalls (per `src/user/syscall_shim.pdx`
and the dispatch table in `src/kernel/core/syscall/dispatch.pdx`):

| SC+ ID | name           | usage                                       |
| ------ | -------------- | ------------------------------------------- |
| 1      | sys_write      | write payload to each fd                    |
| 2      | sys_open       | O_CREAT|O_WRONLY per file                   |
| 3      | sys_close      | close each fd                               |
| 12     | sys_debug_puts | emit the fingerprint                        |
| 77     | sys_stat       | first-boot probe + per-file dedup           |
| 79     | sys_mkdir      | create /bin, /etc, /tmp                     |

`sys_stat` (R56.M3-002 #1791) and `sys_mkdir` (R56.M3-004 #1793) are the
freshly landed dependencies that unblock this seed loop; `pdxfs_block_write`
(R55.M2-004 #1786) is what will make the seed persistent when the mount
migrates from tmpfs to pdxfs-block in a later R57 landing.

Inline `syscall` opcodes (as in `true.pdx` and `child_hello.pdx`) — no
dependency on `syscall_shim.pdx` — keep the rootfs_seed module self-
contained. `build-user.sh` classifies `rootfs_seed.pdx` into the init
object set only.

## Ordering with the init loop

`Init._start` calls `rootfs_seed_run` AFTER the /dev/tty0 open+dup2+close
block finishes and BEFORE the first fork+exec. Rationale:

* tty0 owns fd 0/1/2 first, so `sys_open` returns fd >= 3 for every seed
  file and `dispatch_write`'s fd∈{1,2}→UART fast-path is never hit
  mid-loop (which would write payload bytes onto the wire instead of
  the file)
* seeding before fork+exec means /bin/sh and /bin/child_hello are
  guaranteed present when init execs them, whether the kernel bin_seeds
  ran or not

## Register discipline

`rootfs_seed_run` follows SysV callee-save: push r12 at entry, pop before
ret. r12 holds the fd across the sys_open → sys_write → sys_close triple
in each unrolled per-file block. No nested SysV calls (only `syscall`),
so no alignment pad is needed between operations.

## R106.M1 additions (paideia-os #2228)

R106.M1 extends the manifest to seed the persistent-home tree in its
R108-final shape, without waiting for real crypto:

* `/home` (mode 0755) — world-traversable so every user can chdir into
  their own home; only the /home-root owner (init at R106) can add or
  remove home entries.
* `/home/<placeholder_fp>/` (mode 0700) — owner-only per-user home. The
  `<placeholder_fp>` component is the 64-lowercase-hex-char value
  exported by `FounderConstants::fc_placeholder_fp_hex` (currently
  `deadbeef00000000000000000000000000000000000000000000000000000000` —
  a deliberately-recognisable placeholder that R108.M2 will overwrite
  in place with `hex(SHAKE-256(pubkey)[0..32])` from the real founder
  keypair). See [content-addressed-identity.md §1](content-addressed-identity.md)
  for the identity primitive; the mode-0700 default is
  belt-and-suspenders defence-in-depth against a future POSIX-shaped
  consumer, and the authoritative access gate on the subtree remains
  the `KIND_HOME_ROOT` cap per §5 of that doc.

Idempotency: on a second boot with a persistent FS, the top-of-body
`sys_stat("/etc")` short-circuit (Phase 1 in `rootfs_seed_run`) skips
Phase 2 entirely, so the two /home mkdirs bypass alongside the /bin,
/etc, /tmp mkdirs and the seven file rows. Under today's tmpfs (§Scope
above), /etc is fresh at every boot, so the work path always runs and
both /home entries are (re)created every boot. Same idempotency shape
the pre-R106.M1 seed had — no per-entry stat probe on the /home dirs
is needed because the top-level short-circuit already covers them.

## Files

* `src/user/rootfs_seed.pdx` — payload table + seed loop
* `src/user/founder_constants.pdx` — R106.M1: placeholder fingerprint,
  `/home` root path, and composed `/home/<placeholder_fp>` path. Pure
  rodata; no callable surface. Retired at R108.M2 in favour of the real
  founder-fingerprint symbols.
* `src/user/init.pdx` — one-line `call rootfs_seed_run` insertion in _start
* `tools/build-user.sh` — rootfs_seed.o AND founder_constants.o join
  INIT_OBJECTS

## Argv posture (R62.M1-006, #1837)

R62 landed real `execve` argc/argv/envp marshalling — see
`design/user/execve-abi.md` for the frozen register ABI
(`rdi`=argc, `rsi`=argv, `rdx`=envp at `_start`) and the kernel-side
copy-in/copy-out mechanics in `sys_execve_shim.pdx`. The seeded tools this
document tracks (`/bin/ls`, `/bin/cat`, `/bin/rm`, `/bin/mv`, `/bin/cp`,
`/bin/mkdir`, `/bin/touch`) no longer hardcode their M0 target path(s):
each now reads `argv[1]` (and `argv[2]` for `mv`/`cp`) and falls back to
its previous hardcoded default only when the shell invoked it with too
few arguments (`argc` too small). `/bin/dmesg` takes no path argument and
is unaffected. `rootfs_seed.pdx` itself is unaffected — it seeds files by
direct `sys_open`/`sys_write`/`sys_close` from init's own `_start`, never
via `execve`, so it has no argv posture to update.
* `design/user/rootfs-seed-inventory.md` — this document
