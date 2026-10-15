# `/bin/sh` front-end dispatcher — R222.M7 (paideia-os#2664) +
# R229.M11 default-flip (paideia-os#2729, umbrella #2493)

**Status.** Accepted. User-space binary + build alias landed at R222.M7.
Default-routing flip from legacy to semantic landed at R229.M11
(paideia-os#2729) under umbrella #2493: the semantic path is now the
default routing target for an unset / unknown / missing-envp invocation;
`PDX_SHELL_MODE=legacy` is now the explicit opt-out. The semantic path
is still stubbed at M11 (every invocation still ends in the legacy
shell via the stub's tail-call), so the user-visible behavior remains
stable; what changed is which fingerprint sequence the DEFAULT path
emits. The real semantic-shell body replaces the stub in a sibling
landing per `legacy-shell-retirement.md`.

**Umbrella.** paideia-os#2486 — R222..R229 shell-replacement roadmap
(M7 gate wiring). paideia-os#2493 — R229 legacy-retirement umbrella
(M11 default-flip + alias deprecation window). This file retains both
milestone's rationale: M7 remains the gate's architecture; M11 edits
only `_sd_route`'s match target and jump polarity. See §SECTION 2 for
the active routing table and §SECTION 4 for the full landing timeline.

**Scope.** Keep the current POSIX-shaped `src/user/shell.pdx` alive
under an alias (`legacy-sh`) for the duration of R222..R229 so every
existing boot, smoke, and interactive workflow continues to work. Mount
a new entry (`src/user/sh_dispatch.pdx`) at `/bin/sh` whose only job is
to inspect `PDX_SHELL_MODE=` in envp and route to one of two targets.
At M7 one of those targets is a stub.

**Non-scope at M7.**

- A real semantic-shell binary. The semantic path is a stub emitting a
  "not yet available" marker and falling back to legacy; replacing the
  stub body is a single-site edit per §SECTION 7.
- `-c '<cmd>'` command-line parsing. Both shells today ignore argv past
  argv[0]; a future landing wires it on both sides without changing the
  dispatch gate.
- Kernel-side tmpfs seeding of `/bin/sh = sh_dispatch.elf` and
  `/bin/legacy-sh = shell.elf`. The ELF alias (`legacy-sh.elf`) ships
  on disk at M7, but `bin_seeds.pdx` does not yet reference it; see
  §SECTION 4.

---

## 1. Why a dispatcher and not two conditional `/bin/sh` branches

Three concrete reasons to externalise the mode decision into a
dedicated binary rather than add a mode gate inside `src/user/shell.pdx`:

1. **Reversible swap.** Flipping the default at R229 is a one-line
   kernel-side edit (`bin_seeds.pdx`: swap which blob gets written to
   `/bin/sh`) with no risk to the legacy shell's inline logic. A branch
   inside shell.pdx would couple the two shells' lifetimes forever,
   which is exactly the kind of coupling the R229 close is meant to
   retire.
2. **Audit surface.** A separate 10-KiB binary is one grep target for
   anyone asking "when does /bin/sh pick its mode?" The alternative --
   a mode branch somewhere inside shell.pdx -- hides the policy decision
   inside the 402-line shell main loop and makes the decision
   contingent on wherever the branch happens to land.
3. **Zero-cost legacy path.** The dispatcher at M7 is 3 syscalls on the
   legacy path (debug_puts for the mode marker, execve into legacy-sh,
   and on failure a second debug_puts for the fail marker). It adds no
   runtime cost to the common path and keeps the legacy shell's
   instruction stream byte-identical to the pre-M7 build.

Not taking this surface would mean:

- doubling the shell's main loop with a mode check at every builtin and
  external-exec site, which widens the shell's audit surface at the
  worst possible time (R222..R229 is explicitly the period during which
  the shell is being replaced), and
- making the R229 default-flip a shell.pdx edit, which drags the
  legacy-shell goldens, verifier scripts, and every downstream smoke
  into every intermediate wave.

---

## 2. Semantics of `PDX_SHELL_MODE`

`PDX_SHELL_MODE` is an envp variable the parent (shell, init, or any
caller of `/bin/sh`) sets. The dispatcher reads it once at `_start` and
routes exactly once.

### 2.a Active table at R229.M11 (post-flip, paideia-os#2729)

| Value             | Route                                       | Rationale                                                      |
| ----------------- | ------------------------------------------- | -------------------------------------------------------------- |
| `semantic`        | `_sd_semantic_stub` -> legacy fallback      | Symmetric opt-in. Takes the same code path as the unset default (both land on the semantic stub). Retained so a smoke can grep rodata to confirm the literal is wired; a future landing may distinguish "user asked for semantic" from "default fall-through" without touching this table. |
| `legacy`          | `_sd_legacy_fallback`                       | Explicit opt-OUT of the new semantic default. Keeps the retiring shell reachable for the one-release-cycle grace window per `legacy-shell-retirement.md` §5. |
| unset / missing   | `_sd_semantic_stub` -> legacy fallback      | **NEW DEFAULT at R229.M11.** Semantic path is the default; still stubbed, so still falls through to legacy via the stub's tail-call. When the real semantic entry replaces the stub, this row flips to the real semantic shell with no edit to the table. |
| anything else     | `_sd_semantic_stub` -> legacy fallback      | Conservative: unknown values take the new default rather than the retiring shell. A typo like `PDX_SHELL_MODE=sematic` must NOT silently keep the user on legacy. |
| envp == NULL      | `_sd_semantic_stub` -> legacy fallback      | Legacy call sites still passing envp=NULL now take the new default. |

### 2.b Historical table at R222.M7 (pre-flip, paideia-os#2664)

Preserved for reviewers walking the git history; the R222.M7 build
emitted this exact routing table.

| Value             | Route                                       | Rationale (M7 only)                                             |
| ----------------- | ------------------------------------------- | --------------------------------------------------------------- |
| `semantic`        | `_sd_semantic_stub` -> legacy fallback      | M7 stub; real semantic shell replaces this at a sibling wave.   |
| `legacy`          | `_sd_legacy_fallback`                       | Explicit opt-in to the legacy shell. Same code path as default. |
| unset / missing   | `_sd_legacy_fallback`                       | Default was legacy throughout R222..R228 to preserve workflows. |
| anything else     | `_sd_legacy_fallback`                       | Conservative: unknown modes fell through to legacy.             |
| envp == NULL      | `_sd_legacy_fallback`                       | Pre-execve-abi.md call sites that still passed envp=NULL.       |

The R229.M11 landing is exactly the one-line table edit the M7 doc
anticipated: match target `sd_semantic_val` -> `sd_legacy_val`, match
length constant 9 -> 7, jump polarity inverted at the match/miss sites.
Every other invariant (gate wiring, alias discipline, encoder discipline,
register plan) is byte-identical across the flip.

### 2.1 Byte-level match discipline

The envp scan uses the exact byte-compare idiom the rest of the user
tree uses for env-key matches (`shell.pdx` `shell_home_scan` for
`HOME=`, `dispatch.pdx` `dispatch_find_path_env` for `PATH=`):

- Up to `SH_DISPATCH_ENVP_CAP = 16` entries (matches the cap in
  `design/user/execve-abi.md` and every other envp-walking site in this
  codebase).
- 15-byte prefix compare against `"PDX_SHELL_MODE="` (no NUL on the
  wire).
- **R229.M11 active:** 7-byte value compare against `"legacy\0"`
  including the trailing NUL. A value of `legacy-foo` matches the first
  6 bytes but diverges at byte 6 (`-` vs NUL) and falls through to the
  semantic stub -- *not* to the explicit legacy path -- so partial
  prefixes do not accidentally opt out of the new default.
- **R222.M7 (historical):** was a 9-byte value compare against
  `"semantic\0"`; the match target and length constant inverted at
  R229.M11 per paideia-os#2729.

### 2.2 Why the `semantic` literal is in rodata but unmatched at R229.M11

`sd_semantic_val` ("semantic\0") ships in rodata and is grep-able but
is not actively matched against anywhere today -- the fall-through
branch covers it. The literal is here for two reasons (same two reasons
`sd_legacy_val` held the symmetric role at M7):

1. **Documentation.** A future reader can `grep semantic src/user/sh_dispatch.pdx`
   and find the symmetric opt-in next to the explicit legacy opt-out.
2. **Smoke anchor + future distinguishability.** A boot smoke that
   greps the rodata of the shipped ELF can confirm the explicit-semantic
   literal is wired. More importantly: once the real semantic shell
   lands, a future landing may want to distinguish "user explicitly
   asked for the real semantic shell" from "the user hit the default
   fall-through"; the compare constant is already here for that landing.

---

## 3. Alias discipline — `legacy-sh` and the shell.elf blob

The legacy shell is `src/user/shell.pdx`, built as `build/user/shell.elf`
by the existing SHELL link block in `tools/build-user.sh`. Nothing about
that lifecycle changes at M7.

Immediately after the legacy shell's full lifecycle completes (link +
strip + verifier passes), `build-user.sh` creates a hard-link alias:

```
build/user/legacy-sh.elf <--hard-link--> build/user/shell.elf
```

The hard link is a cheap, byte-identical alias on ext4; on filesystems
that don't support hard links `ln(1)` falls back to a reflink or cp per
util-linux defaults. The result is a second filename referencing the
same ELF bytes, so there is exactly one on-disk inode to keep in sync.

### 3.1 Why hard-link rather than cp or symlink

- **cp** doubles the on-disk footprint for no benefit (the two files
  are definitionally byte-identical by construction).
- **symlink** would break any downstream tool that does
  `.incbin "build/user/legacy-sh.elf"` (because `.incbin` resolves
  symlinks differently across `as` versions and the embedding of the
  blob should be unambiguous).
- **hard-link** gives one inode, byte-identical reads from either path,
  and `.incbin` resolution the same way on every reader.

### 3.2 M7-cont kernel-side seed (DEFERRED)

The kernel-side tmpfs seed table (`src/kernel/boot/witness/bin_seeds.pdx`)
does NOT yet write `/bin/legacy-sh` from the shell.elf blob. Until that
lands:

- `sys_execve("/bin/legacy-sh", ...)` returns `-ENOENT`.
- `_sd_legacy_fallback` emits the `"sh dispatch: execve legacy-sh failed\n"`
  marker and returns `SH_DISPATCH_ERR_EXEC`.
- `/bin/sh` continues to be seeded as `shell.elf` verbatim (not as
  `sh_dispatch.elf`), so init's fork+exec of `/bin/sh` lands in the
  legacy shell unchanged.

See §SECTION 4 for the full staged swap.

---

## 4. Landing timeline

The umbrella #2486 named R229 as the point at which the semantic shell
becomes the default; umbrella #2493 scheduled the retirement sequence.
The actual landings:

| Milestone  | Landing                                                             | Status                               |
| ---------- | ------------------------------------------------------------------- | ------------------------------------ |
| M7         | `sh_dispatch.elf` builds, `legacy-sh.elf` alias ships               | Landed (paideia-os#2664)             |
| M7-cont    | `bin_seeds.pdx` seeds `/bin/legacy-sh = shell.elf`                  | Landed                               |
| M7-cont    | `bin_seeds.pdx` swaps `/bin/sh = sh_dispatch.elf`                   | Landed                               |
| M8..R228   | Real semantic-shell body replaces `_sd_semantic_stub` body          | Progressive wave work                |
| **R229.M11** | **Table in §2 flipped: "unset / missing" routes to semantic**     | **Landed (paideia-os#2729) — this**  |
| Post-R229  | `legacy-sh` alias retired from tools/build-user.sh after grace window | Deferred per `legacy-shell-retirement.md` §5 |

At every intermediate milestone the invariant was: `PDX_SHELL_MODE=legacy`
reached the legacy shell unchanged (M7 onward), and `PDX_SHELL_MODE=semantic`
reached the stub (M7..M11) or the real semantic shell (post-M11 whenever
the stub body is replaced). The default (no `PDX_SHELL_MODE`) stayed
legacy from R222.M7 through R229.M10 and flipped to the semantic path
at R229.M11.

### 4.1 Rollback story

Two independent rollback surfaces, one per flip:

**R229.M11 default-flip rollback (user-space).** If the semantic-stub
default surfaces a bug (e.g. the stub's "not yet available" marker
breaks a downstream smoke that was depending on the legacy start
fingerprint arriving before any other output), the rollback is a two-
line revert inside `_sd_route` in `src/user/sh_dispatch.pdx`: restore
the match target to `sd_semantic_val` and the match-length constant
to 9. Every other invariant stays identical. See §SECTION 2.b for the
exact routing table the revert restores.

**M7-cont kernel-side rollback.** If `sh_dispatch.elf` itself surfaces
a bug (e.g. a seg-fault in `_start` before `_sd_route`), the kernel-
side rollback is a one-line edit in `bin_seeds.pdx`:

```
# Before (M7-cont and later):
#   bin_sh_seed_source: &_sh_dispatch_bin_start / _sh_dispatch_bin_end
# Rollback (back to pre-M7-cont):
#   bin_sh_seed_source: &_shell_bin_start / _shell_bin_end
```

The dispatcher binary stays on disk; only the kernel-side seed pointer
flips back. No user-space edit is required for this rollback, which is
the point of keeping the dispatcher and the legacy shell as two separate
ELFs across every milestone of the retirement wave.

---

## 5. API surface

```
module ShDispatch = structure {
  // Entry via execve('/bin/sh', argv, envp) once M7-cont swaps the seed.
  pub let _start               : () -> () !{mem, sysreg} @{fs, sched, cap}

  // C-style thin wrapper for programmatic callers (test harness, chained
  // caller). Reads envp from .bss envp_slot populated at _start.
  pub let main                 : (u64, u64) -> u64 !{mem, sysreg} @{fs, sched}

  // Routes to _sd_legacy_fallback or _sd_semantic_stub by scanning envp.
  pub let _sd_route            : (u64, u64, u64) -> u64 !{mem, sysreg} @{fs, sched}

  // Emits legacy marker, execves /bin/legacy-sh.
  pub let _sd_legacy_fallback  : (u64, u64, u64) -> u64 !{mem, sysreg} @{fs, sched}

  // M7 stub: emits semantic-not-yet-available markers, tail-calls legacy.
  pub let _sd_semantic_stub    : (u64, u64, u64) -> u64 !{mem, sysreg} @{fs, sched}
}
```

### 5.1 Return / exit codes

| Code      | Name                        | Meaning                                       |
| --------- | --------------------------- | --------------------------------------------- |
| 0         | `SH_DISPATCH_OK`            | Unreachable at M7 (every success is an execve that replaces the image). Reserved for a future landing that returns without execve. |
| `0x1300`  | `SH_DISPATCH_ERR_EXEC`      | `sys_execve('/bin/legacy-sh', ...)` returned (non-zero), typically `-ENOENT` until M7-cont seeds the alias. |
| `0x1301`  | `SH_DISPATCH_ERR_SEMANTIC`  | Reserved for the real semantic shell body to signal a semantic-side failure. Unused by the M7 stub (which always falls through to legacy). |

The exit code lands in the task's wait-status via `sys_exit`. Parent
callers (shell, init) distinguish dispatcher-level failures from legacy-
shell exit codes by the `0x13xx` prefix.

---

## 6. Fingerprints

Every marker rides `sys_debug_puts` (SC+ ID 12) rather than `sys_write`
so it lands on serial regardless of whether the shell has wired stdout
yet. Lowercase per the tree's §SKIP fingerprint discipline.

| Marker                                             | Who emits it                     | When (R229.M11)                           |
| -------------------------------------------------- | -------------------------------- | ----------------------------------------- |
| `SH DISPATCH START`                                | `_start`                         | Every dispatcher invocation.              |
| `sh dispatch mode=legacy`                          | `_sd_legacy_fallback`            | Legacy route decided (either explicit `PDX_SHELL_MODE=legacy`, OR semantic-stub fall-through after the stub emits its own markers). The "unset-defaults-to-legacy" cause from the M7 table is GONE at R229.M11 — unset now routes to semantic. |
| `sh dispatch mode=semantic (stub)`                 | `_sd_semantic_stub`              | Semantic route decided — the DEFAULT at R229.M11 (unset / unknown / semantic / envp==NULL all land here). Stub body only; real semantic shell replaces the body in a sibling landing. |
| `sh dispatch semantic shell not yet available`     | `_sd_semantic_stub`              | Right before stub tails to legacy.        |
| `sh dispatch: execve legacy-sh failed`             | `_sd_legacy_fallback`            | `sys_execve` returned (image not seeded or kernel-side refusal). |

The uppercase `SH DISPATCH START` matches the shell's own
`SHELL START` discipline (`shell_start_msg`, shell.pdx L20); every
subsequent marker is lowercase per the broader skip-fingerprint
convention (`bin_child_hello_seed_fail`, cp.pdx / mkdir.pdx tags).

---

## 7. Replacing the stub

The semantic-shell landing's single edit is the body of
`_sd_semantic_stub`. The function's signature, callers (just
`_sd_route`), and return contract (exit code -> up to `_start` ->
`sys_exit`) stay fixed. The replacement body:

1. Drops the two `sys_debug_puts` markers.
2. Dispatches into the semantic shell's own entry point (TBD — likely
   a `call` into a module that gets linked into `sh_dispatch.elf` or a
   second `sys_execve` into `/bin/semantic-sh` if the semantic shell
   stays a separate binary).
3. Returns `SH_DISPATCH_ERR_SEMANTIC` on semantic-side failure. The
   caller (`_sd_route`) does NOT retry via legacy on
   `SH_DISPATCH_ERR_SEMANTIC` -- that was the stub's privilege, not the
   real path's. A user who wants legacy on semantic failure sets
   `PDX_SHELL_MODE=legacy` explicitly.

No change to `_start`, `main`, `_sd_route`, or `_sd_legacy_fallback`.

---

## 8. Encoder + register discipline

Standard paideia-as pitfalls per `feedback_pdx_encoder_pitfalls`
(2026-10-15):

- `cmp rN, 0` (never `test rN, rN`)
- `mov r10, imm64` staging (never `and r11, imm64`)
- `shl rN, 3 / 4` stride multiplies (never 2-op `imul r, imm`)
- Single-line `pub let name : [u8; N] = "..."` (no multiline bodies)
- Module basename `ShDispatch` matches `sh_dispatch.pdx` (CamelCase from
  underscored basename, same rule as `ChildHello` / `PdxProduce` /
  `ElevateBrokerDaemon`)
- Fingerprint tags: byte count = `len(string) + 1` for the trailing
  NUL; wire-length `*_len` constants exclude the NUL
- All internal branch labels prefixed `sd_` (none can collide with a
  reserved paideia-as keyword per `reference_paideia_as_reserved_labels`)
- Byte loads via `xor rax, rax; mov_b rax, [ptr]` then `cmp al, imm8`
  (paideia-as #1248 mitigation)
- No chained-displacement `[reg + a + b]`

Register plan: envp captured into callee-save `r14` at `_start` entry
BEFORE the first `sys_debug_puts` (which clobbers caller-save `rdx`).
Nested `call` chains preserve 16-byte rsp alignment per SysV: `_start`
enters at `%16 == 0` (PVH loader), `_sd_route` enters at `%16 == 8` (one
call deep), after `_sd_route`'s 5 pushes `%16 == 0`, the nested call into
`_sd_legacy_fallback` or `_sd_semantic_stub` lands at `%16 == 8`, their
own 3 pushes return to `%16 == 0`, and SYSCALL does not care.

---

## 9. Acceptance

### 9.a R222.M7 acceptance (quoting #2664)

> Both shells bootable side by side; smoke test runs
> `PDX_SHELL_MODE=legacy /bin/sh -c 'ls'` and
> `PDX_SHELL_MODE=semantic /bin/sh -c 'ls'` -- both succeed.

At M7 this was partially satisfiable (full AC land at M7-cont + the
semantic-shell sibling milestone). See the git history for the per-
mode breakdown; at R229.M11 it is fully satisfiable because the
kernel-side swap has long since landed.

### 9.b R229.M11 acceptance (quoting #2729)

> Boot smoke: `/bin/sh` is semantic; `legacy-sh` still works.

At R229.M11 the AC fully lands:

- **`/bin/sh` with no `PDX_SHELL_MODE` set**: the dispatcher routes to
  the semantic stub via `_sd_semantic_stub`, which emits
  `sh dispatch mode=semantic (stub)` and
  `sh dispatch semantic shell not yet available` and then tail-calls
  `_sd_legacy_fallback`. The legacy shell then runs the user's command
  (the stub body is still a fall-through at M11). Exit 0 on clean
  termination.
- **`/bin/legacy-sh` (direct invocation)**: unchanged. The hard-linked
  alias still points at `shell.elf`; the legacy shell boots verbatim.
- **`PDX_SHELL_MODE=legacy /bin/sh`**: `_sd_route` matches the "legacy\0"
  value and routes to `_sd_legacy_fallback` directly, skipping the stub
  markers. The legacy shell boots as before.

The boot smoke `tests/boot_smokes/boot_sh_dispatch_flip.pdx` asserts
the R229.M11 fingerprint sequence for the unset-envp default path. The
pre-flip smokes
(`boot_sh_dispatch_legacy.pdx` and `boot_sh_dispatch_semantic_stub.pdx`)
remain valid under the explicit-opt-out and explicit-opt-in forms.

---

## 10. References

- Design doc: `design/shell/sh-dispatch.md` (this document).
- R229.M11 retirement doc: `design/shell/legacy-shell-retirement.md`.
- Source: `src/user/sh_dispatch.pdx`, `src/user/sh_dispatch.ld`.
- Build: `tools/build-user.sh` SH_DISPATCH + ALIAS blocks.
- Smokes: `tests/boot_smokes/boot_sh_dispatch_legacy.pdx`,
  `tests/boot_smokes/boot_sh_dispatch_semantic_stub.pdx`,
  `tests/boot_smokes/boot_sh_dispatch_flip.pdx` (R229.M11).
- Upstream envp ABI: `design/user/execve-abi.md`.
- Prior art for envp scan: `src/user/shell.pdx` `shell_home_scan`
  (`HOME=`), `src/user/dispatch.pdx` `dispatch_find_path_env`
  (`PATH=`).
- Prior art for self-contained one-file-one-ELF binaries:
  `src/user/true.pdx`, `src/user/cat.pdx`, `src/user/run.pdx`.
- Umbrellas: paideia-os#2486 (M7 gate wiring), paideia-os#2493
  (M11 legacy-retirement). Tickets: paideia-os#2664 (M7),
  paideia-os#2729 (M11).
