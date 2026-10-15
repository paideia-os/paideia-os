# `/bin/sh` front-end dispatcher — R222.M7 (paideia-os#2664)

**Status.** Accepted. User-space binary + build alias landed at R222.M7
(stub body for the semantic path, every mode falls through to the legacy
shell). Kernel-side swap of the `/bin/sh` and `/bin/legacy-sh` tmpfs
seeds, and the real semantic-shell body, deferred to the R229-close
landing cited at §SECTION 4.

**Umbrella.** paideia-os#2486 — R222..R229 shell-replacement roadmap.
This milestone (M7) wires the gate; a sibling milestone replaces the
stub with the real semantic shell; the umbrella's R229 close flips the
default.

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
routes exactly once:

| Value             | Route                                       | Rationale                                                      |
| ----------------- | ------------------------------------------- | -------------------------------------------------------------- |
| `semantic`        | `_sd_semantic_stub` -> legacy fallback      | M7 stub; real semantic shell replaces this at a sibling wave.  |
| `legacy`          | `_sd_legacy_fallback`                       | Explicit opt-in to the legacy shell. Documented, same code path as the unset default. |
| unset / missing   | `_sd_legacy_fallback`                       | Default is legacy throughout R222..R229 to preserve every existing workflow. |
| anything else     | `_sd_legacy_fallback`                       | Conservative: unknown modes do NOT fail the invocation; they fall through to legacy. |
| envp == NULL      | `_sd_legacy_fallback`                       | Pre-execve-abi.md call sites that still pass envp=NULL get legacy. |

At R229 close one line in this table changes: the "unset / missing"
row routes to the real semantic path.

### 2.1 Byte-level match discipline

The envp scan uses the exact byte-compare idiom the rest of the user
tree uses for env-key matches (`shell.pdx` `shell_home_scan` for
`HOME=`, `dispatch.pdx` `dispatch_find_path_env` for `PATH=`):

- Up to `SH_DISPATCH_ENVP_CAP = 16` entries (matches the cap in
  `design/user/execve-abi.md` and every other envp-walking site in this
  codebase).
- 15-byte prefix compare against `"PDX_SHELL_MODE="` (no NUL on the
  wire).
- 9-byte value compare against `"semantic\0"` including the trailing
  NUL. A value of `semantic-foo` matches the first 8 bytes but diverges
  at byte 8 (`-` vs NUL) and falls through to legacy -- *not* to
  semantic -- so partial prefixes do not accidentally opt into the
  semantic path.

### 2.2 Why the `legacy` literal is in rodata but unmatched at M7

`sd_legacy_val` ("legacy\0") ships in rodata and is grep-able but is
not matched against anywhere today -- the fall-through branch covers it.
The literal is here for two reasons:

1. **Documentation.** A future reader can `grep legacy src/user/sh_dispatch.pdx`
   and find the symmetric opt-in next to the semantic opt-in.
2. **Smoke anchor.** A boot smoke that greps the rodata of the shipped
   ELF can confirm the explicit-legacy literal is wired (useful once
   `legacy` becomes an opt-OUT of the new semantic default at R229+).

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

## 4. R229-close swap plan

The umbrella #2486 names R229 as the point at which the semantic shell
becomes the default. The sequencing of landings between M7 and R229 is:

| Milestone | Landing                                                            | Blocker                      |
| --------- | ------------------------------------------------------------------ | ---------------------------- |
| M7 (this) | `sh_dispatch.elf` builds, `legacy-sh.elf` alias ships              | --                           |
| M7-cont   | `bin_seeds.pdx` seeds `/bin/legacy-sh = shell.elf`                 | M7                           |
| M7-cont   | `bin_seeds.pdx` swaps `/bin/sh = sh_dispatch.elf`                  | M7-cont /legacy-sh seed      |
| M8..R228  | Real semantic-shell body replaces `_sd_semantic_stub` body         | Semantic shell dependencies  |
| R229-close| Table in §2 edit: "unset / missing" routes to semantic             | Semantic shell soak-tested   |

At every intermediate milestone the invariant is: `PDX_SHELL_MODE=legacy`
reaches the legacy shell unchanged, and `PDX_SHELL_MODE=semantic` reaches
the stub (M7..M7-cont) or the real semantic shell (M8+). The default (no
`PDX_SHELL_MODE`) stays legacy until R229 close.

### 4.1 Rollback story

If any milestone exposes a dispatcher bug, the kernel-side rollback is a
one-line edit in `bin_seeds.pdx`:

```
# Before (M7-cont and later):
#   bin_sh_seed_source: &_sh_dispatch_bin_start / _sh_dispatch_bin_end
# Rollback (back to M7):
#   bin_sh_seed_source: &_shell_bin_start / _shell_bin_end
```

The dispatcher binary stays on disk; only the kernel-side seed pointer
flips back. No user-space edit is required for rollback, which is the
point of keeping the dispatcher and the legacy shell as two separate
ELFs through the whole wave.

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

| Marker                                             | Who emits it                     | When                                     |
| -------------------------------------------------- | -------------------------------- | ---------------------------------------- |
| `SH DISPATCH START`                                | `_start`                         | Every dispatcher invocation.             |
| `sh dispatch mode=legacy`                          | `_sd_legacy_fallback`            | Legacy route decided (either explicit `legacy`, unset, or semantic-stub fall-through). |
| `sh dispatch mode=semantic (stub)`                 | `_sd_semantic_stub`              | Semantic route decided (stub body only). |
| `sh dispatch semantic shell not yet available`     | `_sd_semantic_stub`              | Right before stub tails to legacy.       |
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

## 9. Acceptance (quoting #2664)

> Both shells bootable side by side; smoke test runs
> `PDX_SHELL_MODE=legacy /bin/sh -c 'ls'` and
> `PDX_SHELL_MODE=semantic /bin/sh -c 'ls'` -- both succeed.

At M7 the AC is partially satisfiable:

- **`PDX_SHELL_MODE=legacy /bin/sh`**: the dispatcher routes to legacy
  via `_sd_legacy_fallback` and `sys_execve('/bin/legacy-sh', ...)`. The
  AC succeeds once M7-cont seeds `/bin/legacy-sh` and swaps `/bin/sh`.
  Until then the dispatcher binary exists on disk but is not mounted at
  `/bin/sh`, so `/bin/sh` continues to be the legacy shell verbatim and
  the AC is trivially met for the legacy mode (unchanged behavior).
- **`PDX_SHELL_MODE=semantic /bin/sh`**: at M7 this is identical to the
  legacy case because the stub body falls through. The semantic-shell
  marker IS emitted (fingerprint anchor), proving the gate decoded the
  env var. Full AC lands with the real semantic body at the sibling
  milestone named in §SECTION 4.
- **`-c 'ls'`**: both shells today ignore argv past argv[0]; the AC's
  `-c` syntax is aspirational per the umbrella #2486 roadmap and lands
  at a future milestone that wires it on both sides without touching
  the dispatch gate.

The two boot smokes `tests/boot_smokes/boot_sh_dispatch_legacy.pdx` and
`tests/boot_smokes/boot_sh_dispatch_semantic_stub.pdx` are shape stubs
at M7 declaring the fingerprint sequence the full-AC run will assert
once the kernel-side swap lands.

---

## 10. References

- Design doc: `design/shell/sh-dispatch.md` (this document).
- Source: `src/user/sh_dispatch.pdx`, `src/user/sh_dispatch.ld`.
- Build: `tools/build-user.sh` SH_DISPATCH + ALIAS blocks.
- Smokes: `tests/boot_smokes/boot_sh_dispatch_legacy.pdx`,
  `tests/boot_smokes/boot_sh_dispatch_semantic_stub.pdx`.
- Upstream envp ABI: `design/user/execve-abi.md`.
- Prior art for envp scan: `src/user/shell.pdx` `shell_home_scan`
  (`HOME=`), `src/user/dispatch.pdx` `dispatch_find_path_env`
  (`PATH=`).
- Prior art for self-contained one-file-one-ELF binaries:
  `src/user/true.pdx`, `src/user/cat.pdx`, `src/user/run.pdx`.
- Umbrella: paideia-os#2486, this ticket: paideia-os#2664.
