# Operator getting-started (R59-R60 QEMU walkthrough)

R60.M7-003 (paideia-os #1814) — consolidated post-R51 QEMU-launcher
recipe for reaching the R59 operator shell demo state.

The canonical operator-facing user guide is
`doc/user-guide/getting-started.md` — a 500+-line, copy-paste-ready
walkthrough from clone → boot → PdxFS mount → shell. THIS document is
the design-side companion that fixes the R59 shell-demo boundary and
cross-references what the R55-R59 substrate lets an operator actually
observe today.

---

## What the R59 substrate delivers (at HEAD bf7a52d)

Cold boot from `bash tools/run-qemu.sh` reaches, in order:

1. Kernel entry via PVH ELF Note — `-kernel` launches into 64-bit long
   mode directly (no BIOS, no bootloader stage).
2. `BOOT SPAWN OK`, `RESPAWN OK`, `ACPI CRASH ISO OK`, etc. — 30-ish
   substrate fingerprints from `witness_bin_seeds` and its siblings.
3. `INIT ENTERED RING3` — ring-3 handoff to `init.elf`, dropping to
   CPL=3 and iretq'ing into user code.
4. `rootfs seed ok [legacy: ROOTFS SEED OK] files=7` — `init` runs
   `RootfsSeed::rootfs_seed_run` and writes /bin/{ls,cat,ps,mount,true,sh}
   + /etc/motd stubs. See `src/user/rootfs_seed.pdx`.
5. `ECHO PAIR OK`, `CHILD HELLO 42`, `WAIT: pid=9 status=42`, `REAPED`
   — the ring-3 IPC + wait4 substrate exercise.
6. `INIT FORK SH OK`, `INIT FORK ELEVATE OK`, `SHELL START`, `$ ` —
   `/bin/sh` is fork+execve'd from init and the interactive prompt is
   live on the serial console.

At the `$` prompt the operator can:

- Type any of the R17.M4 shell builtins (`pwd`, `cd`, `help`, `env`,
  `echo`, `exit`).
- Fork+exec any `/bin/*` seeded into tmpfs. Currently only `/bin/sh`
  and `/bin/true` have real ELF payloads (via `tools/userbin_embed.S`
  + `src/kernel/boot/witness/bin_seeds.pdx`). `/bin/ls`, `/bin/cat`,
  `/bin/ps`, `/bin/rm`, `/bin/mv`, `/bin/cp`, `/bin/mkdir`,
  `/bin/touch`, `/bin/dmesg` — landed in R57-R60 as ELF binaries but
  the tmpfs seed still writes 9-byte stubs (kernel-side seeding is
  deferred debt).

## The PATH resolver + IO redirection (R57.M4-005 + R58.M5-001)

At R57 the shell gained a PATH walker: `resolve_path` (in
`src/user/dispatch.pdx`) probes `/bin/<argv[0]>` and
`/usr/bin/<argv[0]>` via `sys_stat`, execs the first hit, falls back
to legacy `/bin/`-prepend on double-miss. The fingerprint
`shell exec ok -- argv[0]=<name> resolved=<path>` observes the
successful resolution.

At R58 the shell gained IO redirection: `>`, `>>`, `<` are recognized
as hard delimiters in `Tokenizer::tokenize` and stripped from argv by
`exec_child` after `sys_open` + `sys_dup2` + `sys_close` fires against
the target file. See `design/user/shell-io-redirection.md`.

Redirect fingerprint on success: `shell redirect ok -- argv[0]=<name>
op=<> or >> or <> file=<path>` from the child before execve.

## What's persistent across restarts

PdxFS-on-block landed at R55.M2 (write path) and R56.M3 (metadata
syscalls: sys_stat, sys_getdents, sys_mkdir, sys_rmdir, sys_unlink,
sys_rename). Under `bash tools/run-qemu.sh` today the disk path is
enabled only when `PAIDEIA_R54_DISK=1` (bdev round-trip) or
`PAIDEIA_R55_DISK=1` (write-e2e) are set — the default boot is the
SUBSTRATE branch (no NVMe device), so state resets each boot.

To see actual persistence across restarts, follow the
`doc/user-guide/getting-started.md` §NVMe path (dedicated section)
which walks through the `mkfs.pdxfs` → mount → write → unmount →
remount → readback cycle.

## What's still deferred

The R57-R59 composite smokes remain as R60+ debt:

- **#1803 boot_r57_shell_a** — composite `ls / && cat /etc/motd && ps`
  smoke with golden fingerprint tape. Blocked on real ELF payloads
  reaching /bin/* (kernel bin_seeds.pdx extension).
- **#1810 boot_r58_shell_b** — composite `echo hi > /tmp/x && cat
  /tmp/x && rm /tmp/x` smoke. Same block.
- **#1812 boot_r59_operator_shell** — two-phase orchestrator combining
  all R55-R59 substrate. Same block.
- **#1813 PAIDEIA_R59_OPERATOR=1 pre-push gate** — depends on #1812.
- **#1818 boot-transcript Phase C pass across R54-R59 fingerprints**
  — depends on the composite smokes above.

The block for all five is the same: real /bin/* ELF payloads need to
reach tmpfs via kernel-side seeding (extend `src/kernel/boot/witness/
bin_seeds.pdx` to embed the 8 new tool ELFs the way it embeds
`/bin/sh` and `/bin/true` today). This is a separate work-item; the
tool binaries themselves are all built and link-verified in
`build/user/`.

## Where to look next

- **Interactive walkthrough**: `doc/user-guide/getting-started.md` —
  clone-to-shell in the fewest possible steps.
- **Round retrospectives**: `design/round-retrospectives/r{55,56,57,58,
  59}-closure.md` — what landed, what deferred, what escalated.
- **Volume lifecycle** (persistence path): `design/tooling/volume-
  lifecycle-mechanism.md`.

R60 shell-visible polish (`/bin/dmesg`, `/bin/ps` enhanced columns)
lands under milestone R60 issues #1816-#1817 alongside this document.
