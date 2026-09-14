# Satellite-tool .elf preservation across build-user.sh invocations

**Wave:** ο (hygiene) **Repo:** paideia-os (monorepo)
**Files:** `tools/build-user.sh`, `tools/build.sh` (r64v2-tools block,
~line 209 onward), `tools/build-image.sh`, `tools/mkimage.sh`.

## 1. The bug

`tools/build.sh` builds the userland set via `tools/build-user.sh`
(line 207), then immediately after, its own r64v2-tools block
(§ "R64v2 (#1976/#1977): sibling-lib + satellite-tool ELF pipeline")
builds `mkfs.pdxfs`, `mount.pdxfs`, and `umount.pdxfs` as separate git
submodules and copies each tool's real (or stub, on link failure)
`.elf` into `build/user/<name>.elf` so `tools/userbin_embed.S`'s
`.incbin` lines can find them.

`tools/build-image.sh` (the R28 MVP image builder) and `tools/mkimage.sh`
both orchestrate a build pipeline that:

1. Runs `tools/build.sh` in full (which performs the sequence above,
   ending with `build/user/{mkfs,mount,umount}.pdxfs.elf` staged).
2. Later, as a **separate, standalone step**, invokes
   `tools/build-user.sh` again directly — to (re)build only the
   generic userland set (shell, init, true, child_hello, ls, rm, mv,
   cp, …) — because that script is also the documented single source
   of truth for those binaries outside of a full `tools/build.sh` run.

`tools/build-user.sh`'s own body opens with an unconditional
`rm -rf "${BUILD_DIR}"` where `BUILD_DIR="${REPO_ROOT}/build/user"` —
the exact directory the r64v2-tools block staged the satellite `.elf`
files into. Step 2's standalone `build-user.sh` invocation has no
rebuild logic for the satellite tools (that logic lives entirely in
`tools/build.sh`'s r64v2-tools block, which step 2 does not re-run),
so the wipe silently deletes `mkfs.pdxfs.elf` / `mount.pdxfs.elf` /
`umount.pdxfs.elf` with nothing to replace them. Any image assembled
downstream of that pipeline (`build-image.sh` phase 4/5,
`mkimage.sh`'s own rootfs/ESP steps) then embeds or seeds a rootfs
missing those three tools, with no build failure to flag it — the
`.elf` files are just quietly absent.

## 2. Why this is a build-*order* bug, not a build-user.sh design flaw

`build-user.sh`'s wipe-and-rebuild-from-scratch pattern is correct
**in isolation** — it guarantees the userland set it owns never goes
stale. The bug is specifically that a second script
(`build-image.sh`/`mkimage.sh`) calls it a second time, after a
different script (`build.sh`) has already populated the same output
directory with artifacts `build-user.sh` itself did not produce and
does not know how to reproduce. `build-user.sh` cannot assume it owns
every file in `${BUILD_DIR}` exclusively; the r64v2-tools block's
staging step makes that assumption false as soon as it runs once.

## 3. Fix

`tools/build-user.sh` now stashes any `*.pdxfs.elf` file already
present in `${BUILD_DIR}` to a `mktemp -d` scratch directory
immediately before the `rm -rf`, then restores them immediately after
the `mkdir -p` that follows it. The glob (`*.pdxfs.elf`) matches this
org's existing satellite-tool naming convention
(`mkfs.pdxfs`, `mount.pdxfs`, `umount.pdxfs` — dotted names, distinct
from every plain-named userland binary `build-user.sh` itself
produces: `shell.elf`, `init.elf`, `ls.elf`, `rm.elf`, etc., none of
which collide with the glob). A `trap ... EXIT` cleans up the scratch
directory unconditionally.

This is intentionally a narrow, defensive fix scoped to
`build-user.sh` rather than a change to the calling order in
`build-image.sh`/`mkimage.sh`, because:

- `build-user.sh` is the shared dependency both the full
  `tools/build.sh` pipeline and the standalone image-builder pipelines
  invoke; fixing it once at the shared choke point protects every
  caller, present and future, rather than requiring each orchestrator
  script to remember to reorder or skip a redundant call.
- Reordering `build-image.sh`/`mkimage.sh` to call `build-user.sh`
  *before* `build.sh`'s r64v2-tools block runs is not available to
  those scripts anyway, since `tools/build.sh` is invoked as one
  opaque unit (`bash tools/build.sh`) — there is no hook to run the
  satellite staging step before or after a sub-part of it from the
  outside.
- A future new satellite tool (a fourth `foo.pdxfs`-shaped submodule)
  is automatically covered by the glob with no `build-user.sh` change
  needed.

## 4. What this does NOT fix

- It does not make `build-image.sh`/`mkimage.sh` skip their own
  redundant `build-user.sh` invocation — that call still rebuilds the
  generic userland set a second time (harmless, just extra work; the
  cost is a handful of `.pdx` files compiling twice per full
  `build-image.sh` run).
- It does not change `tools/build.sh`'s own STAMP-based incremental
  no-op logic (lines 22-54) or the r64v2-tools block's own
  `SAT_STAMP`-based incremental skip; both are orthogonal to this
  cross-script ordering hazard.

## 5. Verification note

This change is a shell-script edit with no `.pdx`/kernel surface —
verification is `bash tools/build.sh` (must still complete and stage
all three satellite `.elf` files) followed by
`bash tools/build-image.sh` (must complete with all three satellite
`.elf` files still present in `build/user/` after its own standalone
`tools/build-user.sh` step, where before this fix they would be
missing). Per this org's build discipline, that verification pass is
run by the invoking session, not authored inline in this document.
