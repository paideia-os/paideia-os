# Legacy-shell retirement — R229.M11 (paideia-os#2729, umbrella #2493)

**Status.** Accepted. Default-flip landed at R229.M11. Alias retirement
scheduled for one release cycle after the real semantic-shell body
replaces `_sd_semantic_stub`'s body (post-M11 sibling landing).

**Umbrella.** paideia-os#2493 — R229 close + legacy-retirement roadmap.
Sibling design: `design/shell/sh-dispatch.md` (the gate wired at M7
whose default policy this landing inverts).

**Scope.** Describe what R229.M11 actually changed, what still works
unchanged, and the staged retirement of the `legacy-sh` alias over the
one-release-cycle grace window.

---

## 1. Why retire legacy as the default

Three concrete reasons the R222..R229 wave was scheduled to end at a
default-flip, and three concrete reasons the flip must happen BEFORE the
real semantic-shell body lands rather than at the same time:

### 1.1 Why end the wave at a flip, not at a parallel alias

Keeping `/bin/sh` on the legacy shell indefinitely would mean:

1. **Every new shell workflow gets written against the legacy syntax by
   default.** `#!/bin/sh` is the muscle-memory shebang; if `/bin/sh` is
   the legacy shell, every new script in the tree opts into the shell
   that is explicitly being retired. The semantic-shell authoring
   discipline would need to be enforced socially rather than
   structurally.
2. **The dispatch gate becomes dead weight.** `sh_dispatch.elf` exists
   precisely so one line of policy can flip which shell `/bin/sh`
   resolves to. If the policy never flips, the gate is 10 KiB of ELF
   that only runs the explicit-opt-in path -- a strictly worse design
   than wiring the gate into the shell itself at R222.M7.
3. **The user-visible deprecation is implicit.** With the default on
   legacy, the only signal the retirement is coming is a design doc.
   With the default on semantic (stub), every default invocation emits
   `sh dispatch semantic shell not yet available` on serial, which is
   the deprecation announcement riding the fingerprint channel the
   smoke harness already watches.

### 1.2 Why flip BEFORE the real semantic body lands

The alternative — flip the default at the same landing that replaces
the stub body — would mean two risk surfaces merging into one
milestone:

- `_sd_route`'s match target changing (M11's one-line edit).
- `_sd_semantic_stub`'s body being replaced wholesale with the real
  semantic shell's entry (a dependency-chain-wide landing).

Landing them separately keeps the default-flip's blast radius to
exactly the one asm site documented in `sh-dispatch.md` §SECTION 2.a;
if the semantic body's landing has a bug, it does not retroactively
block the flip.

### 1.3 Why one release cycle, not immediate retirement

The `legacy-sh` alias stays alive after M11 because:

- **Scripts still exist.** Any downstream script that was written
  against the legacy shell's exact syntax (brace-grouping, `$?`
  semantics, specific builtin behaviors) keeps working under
  `#!/bin/legacy-sh` for the grace window. Immediate retirement would
  break them with no migration path.
- **The semantic shell is still stubbed at M11.** The real semantic
  entry's dependency chain is still being wired. If the semantic
  shell's landing takes longer than planned, the alias is the escape
  valve that keeps a usable shell on the system.
- **The dispatcher's `_sd_legacy_fallback` already handles explicit
  opt-out.** `PDX_SHELL_MODE=legacy` reaches the legacy shell with no
  stub warnings. Retiring the alias means retiring that opt-out as well
  -- a decision that waits until the semantic shell has soaked.

---

## 2. What R229.M11 actually changes

**One asm-level edit inside `_sd_route` in `src/user/sh_dispatch.pdx`.**

Compare target:

- Before (R222.M7): `lea r9, [rip + sd_semantic_val]`, length 9.
- After  (R229.M11): `lea r9, [rip + sd_legacy_val]`, length 7.

Jump polarity at the five sites that touched the fall-through branch:

- `cmp r13, 0; je sd_route_legacy` -> `je sd_route_semantic`
- `cmp r14, 16; jae sd_route_legacy` -> `jae sd_route_semantic`
- `cmp r15, 0; je sd_route_legacy` -> `je sd_route_semantic`
- `cmp r11, 9; jae sd_route_semantic` -> `cmp r11, 7; jae sd_route_legacy`
- `jne sd_route_legacy` (byte diverged in value compare) ->
  `jne sd_route_semantic`

Everything else is byte-identical to the R222.M7 build: the gate's
layout, both branch targets' bodies, the fingerprint markers, the
return codes, the register plan, the encoder discipline, the alias
discipline. The sh-dispatch.md §SECTION 2.a table captures the whole
semantic effect of the edit.

---

## 3. What R229.M11 does NOT change

- `_start`, `main`, `_sd_legacy_fallback`, `_sd_semantic_stub`,
  `envp_slot`, every status code in the `SH_DISPATCH_*` taxonomy.
- The hard-linked `legacy-sh.elf` alias in `tools/build-user.sh`.
- `bin_seeds.pdx` kernel-side seeds (`/bin/sh = sh_dispatch.elf` and
  `/bin/legacy-sh = shell.elf` continue to point at the same blobs).
- The two prior boot smokes
  (`boot_sh_dispatch_legacy.pdx`, `boot_sh_dispatch_semantic_stub.pdx`),
  which cover explicit-opt-out and explicit-semantic routes
  respectively — both still assert the same fingerprint sequences at
  M11.
- The semantic-shell's own dependency chain (R222..R228).
- Any user-space binary other than `sh_dispatch.elf`.

---

## 4. Boot-smoke contract

A new smoke `tests/boot_smokes/boot_sh_dispatch_flip.pdx` covers the
R229.M11 default-flip in the one scenario the pre-flip smokes did not
exercise: `PDX_SHELL_MODE` unset (empty / missing from envp).

Expected on-wire fingerprint subsequence:

```
SH DISPATCH START
sh dispatch mode=semantic (stub)
sh dispatch semantic shell not yet available
sh dispatch mode=legacy
SHELL START
<ls output>
```

Both `/bin/sh` and `/bin/legacy-sh` still exit 0:

- `/bin/sh` with no `PDX_SHELL_MODE`: semantic stub emits its two
  markers, tail-calls `_sd_legacy_fallback`, legacy shell runs `ls`,
  exits 0.
- `/bin/legacy-sh` (direct invocation): legacy shell boots verbatim,
  runs `ls`, exits 0.

The three smokes together cover the three live routing cases at M11:

| Smoke                                     | `PDX_SHELL_MODE`  | R229.M11 route                 |
| ----------------------------------------- | ----------------- | ------------------------------ |
| `boot_sh_dispatch_legacy.pdx`             | `legacy`          | explicit `_sd_legacy_fallback` |
| `boot_sh_dispatch_semantic_stub.pdx`      | `semantic`        | explicit `_sd_semantic_stub` -> legacy |
| `boot_sh_dispatch_flip.pdx` (new at M11)  | unset             | default `_sd_semantic_stub` -> legacy |

---

## 5. One-release-cycle alias deprecation

The `legacy-sh` alias retirement is a THREE-landing sequence after
R229.M11. All three sites named explicitly so a future reader can grep
them without re-deriving the plan.

### 5.1 Milestone A — semantic body lands (post-R229.M11, sibling)

Replace `_sd_semantic_stub`'s body in `src/user/sh_dispatch.pdx` with
the real semantic entry per `sh-dispatch.md` §SECTION 7. At this
landing:

- The two stub markers (`sh dispatch mode=semantic (stub)` and
  `sh dispatch semantic shell not yet available`) are retired.
- A real semantic-entry fingerprint lands in their place.
- `boot_sh_dispatch_flip.pdx` is updated to assert the new fingerprint
  sequence (the `SHELL START` marker no longer appears on the semantic
  default path — the semantic shell no longer tail-calls legacy).
- `legacy-sh` alias stays alive; `PDX_SHELL_MODE=legacy` still works.

### 5.2 Milestone B — grace window (one release cycle after A)

Explicit soak period. No code change. Users with legacy-dependent
scripts migrate to `#!/bin/legacy-sh` or (ideally) to the semantic
shell's own syntax. The semantic shell is the DEFAULT and the EXPLICIT
semantic path; `legacy-sh` remains available via alias and via
`PDX_SHELL_MODE=legacy`.

### 5.3 Milestone C — alias retirement

Three sites in one landing:

1. `tools/build-user.sh` ALIAS block: drop the hard-link creation.
   `build/user/legacy-sh.elf` is no longer produced.
2. `src/kernel/boot/witness/bin_seeds.pdx`: drop the `/bin/legacy-sh`
   seed. The path no longer exists in the running image.
3. `src/user/sh_dispatch.pdx`:
   - `_sd_legacy_fallback`'s body becomes a hard error (emit
     `sh dispatch: legacy shell retired` and return
     `SH_DISPATCH_ERR_EXEC`).
   - `sd_legacy_val`, `sd_legacy_path` constants retired (grep-able
     dead-code removal, not merely commented out).
   - `_sd_route`'s value compare retired; the function becomes a
     single-arm router into `_sd_semantic_stub` for every envp shape.
   - This file (`legacy-shell-retirement.md`) gets a MILESTONE C
     STATUS: LANDED stamp.

After Milestone C the dispatcher gate itself is a candidate for
retirement — `/bin/sh` can be seeded directly from the semantic
shell's ELF. That retirement is a separate landing not scheduled by
this doc.

---

## 6. Rollback story

Two rollback surfaces, mirroring `sh-dispatch.md` §SECTION 4.1:

**User-space rollback of R229.M11.** Two-line edit inside `_sd_route`:
restore the match target to `sd_semantic_val` and the match-length
constant to 9. The jump polarity flips come back implicitly because
the asm references `sd_route_legacy` and `sd_route_semantic` labels
whose bodies are unchanged. This reverts the default to legacy without
touching `_start`, the stub body, or the fallback body.

**Kernel-side rollback (shared with M7).** `bin_seeds.pdx` flips
`/bin/sh` back to pointing at `shell.elf` directly, bypassing the
dispatcher entirely. See `sh-dispatch.md` §SECTION 4.1 for the exact
seed-table edit.

Rollback target decision: use the user-space rollback for a
semantic-stub-induced bug (the dispatcher is still useful; just restore
legacy as the default). Use the kernel-side rollback for a
dispatcher-level bug (something in `_start` or `_sd_route` is
breaking the fingerprint sequence).

---

## 7. Related docs

- `design/shell/sh-dispatch.md` — gate architecture (M7) + M11 flip
  policy table (§SECTION 2.a).
- `design/user/execve-abi.md` — envp ABI the gate scans.
- `src/user/sh_dispatch.pdx` — the dispatcher binary.
- `src/user/shell.pdx` — the legacy shell (unchanged at M11).
- `tools/build-user.sh` — SH_DISPATCH + ALIAS build blocks.
- `tests/boot_smokes/boot_sh_dispatch_flip.pdx` — M11 smoke.
- `tests/boot_smokes/boot_sh_dispatch_legacy.pdx`,
  `tests/boot_smokes/boot_sh_dispatch_semantic_stub.pdx` — pre-M11
  smokes that remain valid under their explicit-opt-* interpretations.
- Umbrellas: paideia-os#2486 (M7 gate wiring), paideia-os#2493
  (M11 legacy-retirement).
- Tickets: paideia-os#2664 (M7), paideia-os#2729 (M11).
