# Satellite-repo ELF embed ordering hazard

Tracking: paideia-os #2440 (shell-satellite embed), #2443 (rootfs_seed
real ELFs — /bin/mount leg).

## 0. Status

Design-only closure. No code changes land with this document; it
records the hazard both issues hit, the two candidate fixes, and which
one to reach for first. `tools/user/shell` is confirmed already
adopted as a `.gitmodules` submodule at HEAD (`git submodule status`
shows a pinned commit, `v1.0.0-36-g8aae70d`) — the remaining work on
#2440 is wiring, not submodule adoption.

## 1. The hazard

`tools/build.sh` and `tools/build-user.sh` populate the **same**
directory, `build/user/`, from two different scripts that run at two
different points:

```
tools/build.sh
  |
  +-- line 207: tools/build-user.sh            <-- runs FIRST
  |     `rm -rf "${BUILD_DIR}"`  (BUILD_DIR = build/user, line 126)
  |     ... builds shell.elf, init.elf, cat.elf, ls.elf, ps.elf, ...
  |     ... (R113 #2441) assembles tools/init_userbin_embed.S and
  |         links init.elf AFTER ls.elf/cat.elf/ps.elf exist
  |
  +-- lines 244-356: r64v2-tools block                <-- runs SECOND
  |     builds tools/user/{libpdx-volume,libpdx-audit,libpdx-elevate,
  |     libpdx-argv} then tools/user/{mkfs,mount,umount}.pdxfs in
  |     parallel, copies each build-out/<name>.elf into
  |     build/user/<name>.elf
  |
  +-- lines 358-426: r102-tools block (skip stub today)
  |
  +-- line 432-434: tools/userbin_embed.S -> userbin_embed.o
        (KERNEL-side embed: .incbin build/user/{shell,init,...,
         mkfs.pdxfs,mount.pdxfs,umount.pdxfs}.elf — this already runs
         AFTER both blocks above, so it never hits the hazard.)
```

Two structurally identical hazards fall out of this:

1. **`build-user.sh`'s `rm -rf "${BUILD_DIR}"` (line 126) is
   unconditional.** Any `build/user/*.elf` staged by a step that runs
   *before* `build-user.sh` — whether because it is textually placed
   above line 207, or because a future refactor moves it there — is
   deleted before `build-user.sh` even starts. The r64v2-tools block
   avoids this today purely because it happens to run *after*
   `build-user.sh`, not because anything enforces the ordering.
2. **`build-user.sh` (and anything it assembles, e.g.
   `tools/init_userbin_embed.S`) cannot `.incbin` a satellite-repo ELF
   that a *later*-running block (r64v2-tools, or a future
   shell-satellite block) has not produced yet.** `as` fails at
   assemble time with "no such file", not at link time, so this is a
   hard stop, not a warning.

Both #2440 and #2443's `/bin/mount` leg are instances of hazard (2).

## 2. #2440 — shell-satellite

`tools/user/shell` is a real, buildable, submoduled satellite repo
(`build-out/shell.elf` already exists there today — confirmed by
`ls tools/user/shell/build-out`). Wiring `bin_seeds.pdx` (or a
kernel-side embed) to a `_shell_satellite_bin_start` symbol requires:

- a new `tools/build.sh` block, shaped like r64v2-tools, that invokes
  `tools/user/shell/tools/build.sh` and copies its output to
  `build/user/shell-satellite.elf`;
- a new `.incbin "build/user/shell-satellite.elf"` pair of symbols in
  `tools/userbin_embed.S`.

The **hazard**: `tools/userbin_embed.S` is already correctly
positioned after both `build-user.sh` and r64v2-tools (line 432), so
`.incbin`-ing a satellite ELF from *there* is safe by construction —
**provided the new shell-satellite build block is placed after
`build-user.sh` too** (naturally: right after the r64v2-tools block,
at what would become line ~357). The trap is textual/conceptual: the
line-206 comment reads `"ensuring build/user/shell.bin (R15-M1-007
embed prerequisite)"`, which invites a contributor to treat
shell-satellite as a *prerequisite of* `build-user.sh` and place the
new block *above* it — which would have the new block's staged
`build/user/shell-satellite.elf` deleted by line 126's `rm -rf` a few
lines later.

## 3. #2443 — rootfs_seed real ELFs

Re-audited against HEAD, not just the original issue text (filed
2026-09-12, ECOTABLE re-scope wave) — the on-disk state has moved on:

| File | rootfs_seed.pdx state | Blocker |
|---|---|---|
| `/bin/ls` | **Real ELF** (R113 #2441, already landed) | none |
| `/bin/cat` | **Real ELF** (R113 #2441, already landed) | none |
| `/bin/ps` | **Real ELF** (R113 #2441, already landed) | none |
| `/bin/mount` | **9-byte stub** (`rs_stub_bin`) | hazard (2), below |

`src/user/rootfs_seed.pdx`'s own header (§ "R113 (paideia-os #2441)
narrowed the stub's consumer set") documents that ls/cat/ps were
already promoted to real ELFs, embedded via a **second**, distinct
embed file — `tools/init_userbin_embed.S` — which targets `init.elf`'s
own `.rodata` (not the kernel's) via `_init_ls_bin_start` /
`_init_cat_bin_start` / `_init_ps_bin_start` symbols.
`build-user.sh` §694-707 assembles `init_userbin_embed.S` and links
`init.elf` **after** `ls.elf`/`cat.elf`/`ps.elf` are built earlier in
the *same* script — same-script ordering, no cross-script hazard,
because all four artifacts are produced by `build-user.sh` itself.

`/bin/mount` is different in kind, not degree: the only real `mount`
ELF in the tree today is `mount.pdxfs` (a `tools/user/mount.pdxfs`
satellite build, `_mount_pdxfs_bin_start` on the **kernel** side via
`tools/userbin_embed.S`). Promoting `rootfs_seed.pdx`'s `/bin/mount`
row to real bytes the same way ls/cat/ps were promoted means adding
`_init_mount_pdxfs_bin_start` to `tools/init_userbin_embed.S` and
`.incbin`-ing `build/user/mount.pdxfs.elf` — but that file is produced
by the r64v2-tools block, which runs in `tools/build.sh` **after**
`build-user.sh` has already assembled `init_userbin_embed.S` and
linked `init.elf`. This is hazard (2), byte-for-byte the same shape as
#2440's shell-satellite gap.

(Separately, `/bin/mount` also carries a genuine design ambiguity —
`src/user/mount.pdx` is deferred by the R57 parser gap #1800, and
`mount.pdxfs` answers a different question, "mount a pdxfs volume",
than a POSIX-shaped generic `/bin/mount`. That ambiguity is orthogonal
to the ordering hazard and is out of scope for this document; see
`design/user/rootfs-seed-inventory.md`'s R113 addendum.)

## 4. Candidate fixes

### Fix A — reorder + preserve

1. In `tools/build.sh`, move the r64v2-tools block (and any future
   shell-satellite block) to run **before** the `tools/build-user.sh`
   call at line 207, so every satellite ELF (`mkfs.pdxfs.elf`,
   `mount.pdxfs.elf`, `umount.pdxfs.elf`, `shell-satellite.elf`)
   exists in `build/user/` before `build-user.sh` starts.
2. Change `build-user.sh` line 126 from
   `rm -rf "${BUILD_DIR}"` to a form that preserves pre-existing
   `*.elf` files — e.g. `find "${BUILD_DIR}" -mindepth 1 ! -name
   '*.elf' -delete` (or stage satellite ELFs into a sibling directory
   `build/user-satellite/` that `build-user.sh` never touches, and
   have `init_userbin_embed.S` / `userbin_embed.S` read from there
   instead).

**Trade-off:** small diff (one call-site move + one line in
`build-user.sh`), but couples two scripts' internal directory
conventions more tightly — a future contributor re-adding a blanket
`rm -rf "${BUILD_DIR}"` (e.g. while refactoring) silently reintroduces
the hazard with no build-time signal until an `.incbin` line goes
missing-file.

### Fix B — move the embed step, not the build order

Keep `build-user.sh` running first (as today) and keep its `rm -rf`
unconditional, but move any `.incbin` step that needs a satellite ELF
**out of `build-user.sh` and into `tools/build.sh` proper**, positioned
after the relevant satellite block — exactly where
`tools/userbin_embed.S`'s assembly already lives (line 432, after
r64v2-tools). For #2443's `/bin/mount` leg, this means: don't grow
`init_userbin_embed.S` / `init.elf`'s link step (owned by
`build-user.sh`) with a `mount.pdxfs` row at all; instead point
`witness_bin_seeds` (kernel-side, `src/kernel/boot/witness/
bin_seeds.pdx`, which already runs at kernel-embed time — safely after
r64v2-tools) at `_mount_pdxfs_bin_start` for a **kernel-seeded**
`/bin/mount`, leaving `rootfs_seed.pdx`'s userspace fallback row as the
defensive stub it already is for `/bin/sh` and `/bin/true` (per the
module's own documented rationale: kernel-seeded first, userspace
fallback is unreachable on the standard boot path).

**Trade-off:** no reordering risk, and mirrors a pattern already
proven correct (`userbin_embed.S`'s placement). But it means `/bin/ls`
et al.'s "defence-in-depth on init.elf's own rodata" pattern from
#2441 does NOT extend to `/bin/mount` — the userspace fallback stays
stubbed for a no-kernel-seed boot mode, which is a real (if narrow)
capability regression relative to ls/cat/ps.

## 5. Recommendation

**Fix B for #2443's `/bin/mount` leg; Fix A's placement discipline
(not its `rm -rf` change) for #2440's shell-satellite block.**

- #2443: wiring `witness_bin_seeds` to `_mount_pdxfs_bin_start`
  (kernel-side, already-embedded, zero new build-order surface) closes
  the "sh running `mount` fails on ELF parse" symptom with the
  smallest possible diff. `rootfs_seed.pdx`'s userspace stub row can
  stay as documented defensive fallback, matching `/bin/sh` and
  `/bin/true`'s existing precedent in the very same file.
- #2440: land the new shell-satellite block in `tools/build.sh`
  **after** `build-user.sh` and the r64v2-tools block (i.e., appended
  near line 357, before the r102-tools skip stub), so
  `tools/userbin_embed.S`'s existing after-both-blocks position covers
  it for free. This needs **zero** changes to `build-user.sh` line 126
  — Fix A's reordering idea is unnecessary for this specific case once
  the block is placed correctly the first time. Fix A's `rm -rf`
  hardening is still worth doing defensively (a one-line change,
  `rm -rf "${BUILD_DIR}"` → delete-all-except-`*.elf`) so a *future*
  satellite block that genuinely needs to run before `build-user.sh`
  (unlike shell-satellite, which does not) doesn't silently regress.

Neither fix requires touching `tools/user/shell`'s own build (already
green) or the submodule pin (already correct).

## 6. Cross-references

- `tools/build.sh` — lines 206-207 (`build-user.sh` invocation),
  244-356 (r64v2-tools block), 432-434 (kernel-side
  `userbin_embed.S` assembly).
- `tools/build-user.sh` — line 126 (`rm -rf "${BUILD_DIR}"`), 694-707
  (`init_userbin_embed.S` assembly + init.elf link, R113 #2441).
- `tools/userbin_embed.S` — kernel-side embed; R102.MON-003's reserved
  (commented-out) symbol block documents the same satellite-ELF
  posture for the R102 graphical stack, worth reusing as the template
  for the shell-satellite symbol pair.
- `tools/init_userbin_embed.S` — init-side embed (ls/cat/ps today).
- `src/user/rootfs_seed.pdx` — the userspace seed loop; header
  documents the #2441 promotion and the `/bin/mount` ambiguity.
- `src/kernel/boot/witness/bin_seeds.pdx` — the kernel-side tmpfs
  seed witness; `bs_ls_seed` is the template Fix B's `/bin/mount` row
  would mirror.
- `design/user/rootfs-seed-inventory.md` — the manifest + fingerprint
  contract `rootfs_seed.pdx` implements.
