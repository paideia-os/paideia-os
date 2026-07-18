---
issue: 648
parent: 520 (R15-M1-008 loader structural witness — currently only symbol-resolves)
milestone: R15.M1 (User aspace creation & ELF-lite loader)
subsystem: 8 — ELF-lite loader
prereq:
  - "#517 (elf_lite_load skeleton — landed with the two bugs this doc fixes)"
  - "#519 (userbin embed — supplies _shell_bin_start.._shell_bin_end)"
  - "#649 (phys_free real body — pool no longer leaks; safe to allocate PT_LOAD pages then teardown)"
  - "#652 (aspace_map VA→PA translation — elf_lite_load's aspace_map call now stores real PAs in PTE frame fields)"
  - "#651 (enter_userland_initial relocated — not called by this witness, but proves the loader path is downstream of ring3)"
blocks:
  - "R15.M2 first shell process launch (needs elf_lite_load to actually load, not just symbol-resolve)"
  - "R15.M6 fork/exec (exec directly re-enters elf_lite_load per image)"
touching:
  - src/kernel/core/loader/elf_lite.pdx          (3 LOC — the two bug fixes)
  - src/kernel/boot/kernel_main.pdx              (~35 LOC — extend loader witness from symbol-check to runtime call)
  - tools/boot_stub.S                            (~8 LOC — two new witness message strings)
  - tests/r15/expected-boot-r15-ring3.txt        (+1 line marker)
  - design/kernel/r15-m1-008b-elf-lite-load-runtime-bugs.md (this file)
related:
  - "#658 (phys_alloc/aspace_create VA-not-PA landmine — orthogonal; elf_lite_load's aspace_map call is already covered by #652's per-callsite fix, so #658 stays deferred)"
---

# R15-M1-008b — elf_lite_load runtime bugs: HIGH_HALF false-positive + W^X mask bit-pattern (#648)

## 1. Scope

Fix the two encoder-level bugs in `elf_lite_load` that make it fail on
every legitimately-formed ELF64 (specifically, the embedded
`_shell_bin` — a two-segment `RE / RW` image at low-half VAs
0x400000 / 0x700000), then extend the R15.M1.008 loader witness so it
actually **calls** `elf_lite_load` on the embed instead of just
`lea`-ing the symbol and asserting non-zero. The two bugs are strictly
local to the segment-header gate block in `src/kernel/core/loader/elf_lite.pdx`
(lines 325–343); neither touches allocator, aspace_map, or any calling
convention.

Ring-3 execution of the loaded image is **out of scope**. That needs
GDT trampoline mapping under strict-KPTI + a syscall path (`#650`) and
belongs on the R15.M2 shell-launch track. This issue restores the
loader to a state where `boot_continue_after_ring3`'s loader witness
prints `ELF LOAD OK` and the next issue can drive the loaded pages into
ring-3.

Out of scope (deliberately deferred):

- Non-canonical vaddr detection beyond the simple high-half boundary
  (bit 47 unset && bits 63:47 mixed — the CPU rejects those on load;
  we stay at the coarser gate).
- Filesz > memsz normalization / .bss zeroing beyond what the current
  per-page zero-then-copy already does (works correctly for shell.bin
  segment 2 where filesz == 0, memsz == 0).
- Overlap detection between adjacent PT_LOAD segments.
- Real physical-address contract in `phys_alloc` — see #658.

## 2. Prereq check

### 2.1 What's in place

- `src/kernel/core/loader/elf_lite.pdx:205–521`: full skeleton of
  `elf_lite_load` — header validation, PT_LOAD loop, W^X + high-half
  gates, per-page allocate / zero / partial-copy / flag-translate /
  `aspace_map` loop, all six error paths + cleanup epilogue. Bugs live
  only in the two gates.
- `tools/userbin_embed.S`: `_shell_bin_start` / `_shell_bin_end`
  bracket a real ELF64 image whose two `PT_LOAD` segments have
  `p_vaddr = 0x400000` (RE, flags 0x5) and `p_vaddr = 0x700000` (RW,
  flags 0x6). `readelf -l build/user/shell.elf` confirms.
- `src/kernel/boot/kernel_main.pdx:479–505`: the R15-M1-008 loader
  structural witness. Today it only checks that `aspace_create_user`,
  `elf_lite_load`, `user_stack_alloc`, `_shell_bin_start`,
  `_shell_bin_end` all resolve non-zero, then prints `LOADER OK`.
  Comment at line 481–482 explicitly parks the runtime call on this
  issue: `"Runtime end-to-end load deferred to #648 (elf_lite_load
  HIGH_HALF false-positive fix)."`.
- `src/kernel/core/mm/aspace_map.pdx:50` (post-#652): `phys_alloc`
  results are translated to real PAs at every PTE-write site inside
  `aspace_map`. `elf_lite_load`'s call at `elf_lite.pdx:469` is one of
  the (previously dead-code) call sites this fix specifically covers.
- `src/kernel/core/mm/phys_free.pdx` (post-#649): real bitmap release.
  The loader witness leaks its user aspace (no `aspace_teardown` call
  in the witness), so free-count won't return to the pre-witness value
  — that's fine for a one-shot boot witness, matches every other
  boot-time structural witness (KPTI, ring3, IPI).
- `paideia-as` v0.20 at 053faa2 + #1246 (REX.B fix — used by
  `mov r10, [rsi+r11+0]` style memory ops if we grow the loop; for the
  fixes in this issue we only need `and rax, imm8`, `cmp rax, imm8`,
  `jae` — all already emit correctly).

### 2.2 What's missing → this issue

- Correct W^X mask (`0x3, 0x3`) instead of `0x6, 0x6`.
- Unsigned comparison (`jae`) instead of signed (`jge`) at the high-half
  gate.
- Runtime witness in `boot_continue_after_ring3` that actually calls
  `elf_lite_load` on the embed and asserts `rax == ELF_OK (0)`.

## 3. Root cause — two encoder-level bugs

### 3.1 Bug A — W^X mask bit-pattern (elf_lite.pdx:325–329)

**Current code:**

```
// === W^X CHECK: both W and X set => error ===
mov rax, r9;
and rax, 0x6;         // PF_W (0x2) | PF_X (0x1) => 0x3 masked to bits [2:1]
cmp rax, 0x6;         // both set
je elf_load_wx_error;
```

**The bit-layout facts (elf_lite.pdx:35–37):**

| Flag | Constant | Bit |
|------|----------|-----|
| PF_X | 0x1      | 0   |
| PF_W | 0x2      | 1   |
| PF_R | 0x4      | 2   |

Correct `PF_W \| PF_X` mask is `0x2 \| 0x1 = 0x3`. The comment on
line 327 even **states** the correct value (`0x3`) but the emitted
constant is `0x6` — a straight typo from `PF_R \| PF_W` (bits 2 and
1). Truth table for the buggy mask:

| Segment | flags | flags & 0x6 | == 0x6? | Should error? | Actual |
|---------|-------|-------------|---------|---------------|--------|
| RWX     | 0x7   | 0x6         | yes     | yes           | correct |
| RW-     | 0x6   | 0x6         | **yes** | no            | **false positive** |
| R-X     | 0x5   | 0x4         | no      | no            | correct |
| -WX     | 0x3   | 0x2         | no      | **yes**       | **false negative** |
| -W-     | 0x2   | 0x2         | no      | no            | correct |
| --X     | 0x1   | 0x0         | no      | no            | correct |

**Impact on `shell.bin`:** segment 2 has flags `0x6` (RW-). Buggy mask
triggers `ELF_WX (0xFFFFFFFD)` on the very first non-text PT_LOAD of
the very first ELF the loader ever sees. Bug B never even executes on
this image — Bug A fires first.

**Fix (2 constants):** replace `0x6` → `0x3` at line 327 and line 328.

### 3.2 Bug B — HIGH_HALF signed vs unsigned comparison (elf_lite.pdx:340–343)

**Current code:**

```
// === HIGH-HALF CHECK: vaddr >= 0xFFFF800000000000 => error ===
mov rax, 0xFFFF800000000000;
cmp r10, rax;
jge elf_load_high_half_error;
```

The **constant is correct** — `0xFFFF800000000000` is exactly the
canonical high-half boundary matching `KERNEL_VMA_BASE` in `link.ld`.
The bug is the **conditional mnemonic**. `jge` reads signed flags
(`SF == OF`, or `ZF`), while high-half detection is fundamentally an
**unsigned** magnitude test.

Interpreted as signed 64-bit integers:

- `0xFFFF800000000000` has bit 63 set → treated as negative
  (`-140737488355328`).
- Any legitimate low-half user vaddr (e.g. `_shell_bin`'s `0x400000`)
  is a small positive integer.
- Signed `positive > negative` is always true → `jge` always
  triggers on legitimate low-half segments.

**Impact on `shell.bin`:** if Bug A were fixed in isolation, segment 1
(RE, `p_vaddr = 0x400000`) would clear the W^X gate and then Bug B
would fire `ELF_HIGH_HALF (0xFFFFFFFE)`. The loader has never
successfully loaded anything.

**Fix (1 mnemonic):** replace `jge` → `jae` at line 343. `jae` reads
`CF == 0` — the natural unsigned `>=` predicate. Same truth table as
the intent: any `p_vaddr` with bit 47 or higher set trips the gate.
(An equivalent alternative — `test r10, mask; jnz ...` where `mask`
has bits 63:47 set — is uglier and needs a `movabs` for the mask;
`jae` reuses the already-loaded `rax` constant.)

## 4. Fix approach

### 4.1 Bug fixes (3 LOC total in elf_lite.pdx)

```
// === W^X CHECK: both W and X set => error ===
mov rax, r9;
and rax, 0x3;         // PF_W (0x2) | PF_X (0x1) = 0x3
cmp rax, 0x3;         // both set
je elf_load_wx_error;

...

// === HIGH-HALF CHECK: vaddr >= 0xFFFF800000000000 => error ===
mov rax, 0xFFFF800000000000;
cmp r10, rax;
jae elf_load_high_half_error;
```

Both edits are in the segment-header gate block, both localized to
single tokens. The rest of `elf_lite_load` — six error paths, page
loop, flag translation, `aspace_map` call — is unchanged.

### 4.2 Loader runtime witness (~35 LOC in kernel_main.pdx)

Extend the loader structural witness in `boot_continue_after_ring3`
(currently `kernel_main.pdx:479–505`). Keep the five symbol-resolve
checks (they're cheap and catch link-time breakage), then chain a
runtime call:

```
// R15-M1-008b (#648): loader RUNTIME witness — actually call elf_lite_load.
// Precondition: aspace_create_user + phys_alloc + aspace_map work (proven
// upstream by the ring3 witness at #652); phys_free bitmap release lands
// (#649). Leaks the user aspace on success — matches every other boot-time
// structural witness (KPTI, ring3, IPI).

call aspace_create_user;      // rax = user_pml4_pa (VA form — same as #652)
cmp rax, 0;
je  loader_runtime_fail;
mov rdi, rax;                 // rdi = user_pml4_pa

lea rsi, [rip + _shell_bin_start];
lea rax, [rip + _shell_bin_end];
sub rax, rsi;                 // rax = image_len
mov rdx, rax;                 // rdx = image_len

call elf_lite_load;           // (rdi, rsi, rdx) -> rax = ELF_OK | error code
cmp rax, 0;                   // ELF_OK == 0
jne loader_runtime_fail;

lea rdi, [rip + elf_load_ok_msg];
call uart_puts;
jmp loader_runtime_done;

loader_runtime_fail:
lea rdi, [rip + elf_load_fail_msg];
call uart_puts;

loader_runtime_done:
```

Placement: **immediately after** the five symbol-resolve checks + the
existing `LOADER OK` print. That way, if the structural witness fails
(a link-time breakage) we still see the old marker in the fail path
and the runtime marker never appears — the two witnesses stay
independently diagnosable.

### 4.3 Two new witness strings (~8 LOC in boot_stub.S)

Append after the existing `loader_fail_msg` at line 184:

```
# R15-M1-008b (#648): ELF-lite loader runtime success witness message
.global elf_load_ok_msg
.align 8
elf_load_ok_msg: .ascii "ELF LOAD OK\n\0"

# R15-M1-008b (#648): ELF-lite loader runtime failure witness message
.global elf_load_fail_msg
.align 8
elf_load_fail_msg: .ascii "ELF LOAD FAIL\n\0"
```

Same idiom as `loader_ok_msg` / `loader_fail_msg` (boot_stub.S:177–184).

## 5. Test canary — smoke: `boot_r15_ring3`

We do **not** need a new smoke mode. The extended fingerprint slots
cleanly into the existing `boot_r15_ring3` fixture that already covers
`LOADER OK`. Add one line to
`tests/r15/expected-boot-r15-ring3.txt`:

```
B
HI VA FFFF8000
PaideiaOS R8
PHYS FREE ROUNDTRIP OK
KPTI OK
KPTI SCRATCH OK
ENTER USER RELOC OK
R15 RING3 HELLO OK
IPI OK
LOADER OK
ELF LOAD OK        <-- new marker
```

(`LOADER OK` is already emitted implicitly today because it's part of
the sequence but not asserted in the fingerprint file; adding
`ELF LOAD OK` also documents the previous `LOADER OK` line — the
fingerprint is a contains-in-order check per `tools/run-smoke.sh:180–194`,
so either both lines or just the new one is fine. Recommend adding
both for readability.)

Verification loop:

```
tools/run-smoke.sh boot_r15_ring3
```

Expected exit 0 with `smoke: fingerprint check passed`. The kernel
does not halt after the loader witness — control continues into the
scheduler bootstrap (task A/B alternation), so QEMU exits via the
5s timeout (rc 124, treated as clean per `run-smoke.sh:163`).

## 6. Backtrack candidates (things that could still bite)

Ordered by likelihood:

1. **`phys_alloc` VA/PA contract leak beyond aspace_map.** `elf_lite_load`
   uses the `phys_alloc` return as `page_pa` (line 370–372), then
   dereferences it directly for the zero-fill loop (line 382) and the
   partial-copy loop (line 424–428) — this is a **VA** dereference, works
   fine because `phys_alloc`'s "phys" is a kernel VA per #658. It also
   passes that same value to `aspace_map` (line 466), which is
   compensated by #652's in-function fix at the PTE-write site. So the
   witness should pass. If it doesn't and the failure is inside
   `aspace_map`'s intermediate-table alloc path, escalate to #658 as
   originally scoped.

2. **`aspace_map` per-page invocation cost.** The RE segment of
   `shell.bin` is 0xe8 bytes → 1 page. The RW segment has `p_memsz = 0`
   → the per-page loop's `cmp rax, r8; jge elf_load_seg_skip` at line
   364 exits immediately without allocating. So only **one** `phys_alloc`
   + `aspace_map` round-trip actually happens. If a future test image
   with N pages regresses, look at the "next page" arithmetic at line
   474–477 (stack-spilled offset increment).

3. **Filesz > memsz for shell.bin.** shell.bin segment 1 has
   `filesz = memsz = 0xe8`. Segment 2 has `filesz = memsz = 0`. Neither
   exercises the partial-copy tail (line 396–429). If a later image
   triggers partial-copy corner cases (page half-in half-out of the file
   region), test them separately — not on the critical path for #648.

4. **`aspace_create_user`'s KPTI-strict user PML4 vs `aspace_map`.**
   `aspace_create_user` (per `aspace_create.pdx:95`) builds a strict-KPTI
   PML4 with only the trampoline PT[260] / PT[261] pre-populated in the
   kernel half. `elf_lite_load` will `aspace_map` into user-half slots
   [0..255], which are empty in a fresh strict-KPTI PML4 — this exercises
   `aspace_map`'s intermediate-table allocation path (PDPT / PD / PT all
   allocated via `phys_alloc`). If this trips over #652's VA/PA fix at
   the reuse-branch (line 50 justification: "every entry REUSE (present-
   bit already set) ADDS KERNEL_VMA_BASE back after masking"), the
   backtrack is one intermediate-table alloc failing → investigate the
   `aspace_map` reuse branch on second page-map into the same PDPT/PD.

5. **`user_stack_alloc`.** Not called by this witness. The old
   symbol-resolve check for `user_stack_alloc` stays (line 489), so we
   catch linker breakage, but any runtime bug in `user_stack_alloc`
   remains undiscovered until R15.M2 shell launch actually uses it.

6. **Segment ordering.** The current PT_LOAD loop processes segments in
   `p_phnum` order. `shell.bin` puts RE (text) at phdr 0 and RW (data)
   at phdr 1. If Bug A were fixed in isolation and Bug B present, the
   text segment's high-half check fails first (fires `ELF_HIGH_HALF`,
   0xFFFFFFFE = -2). If Bug B were fixed in isolation and Bug A present,
   the data segment's W^X check fails first (fires `ELF_WX`, 0xFFFFFFFD
   = -3). Post-fix, both should pass. If the witness surprises us with
   an intermediate error code, the specific code identifies which gate
   is still wrong.

## 7. LOC budget

| File | LOC |
|------|-----|
| src/kernel/core/loader/elf_lite.pdx (3 token edits) | 3 |
| src/kernel/boot/kernel_main.pdx (runtime witness block) | ~30 |
| tools/boot_stub.S (two message strings) | ~8 |
| tests/r15/expected-boot-r15-ring3.txt (1 line, optionally 2) | 1 |
| **Total** | **~42** |

## 8. Acceptance criteria

- `tools/run-smoke.sh boot_r15_ring3` exits 0 and prints
  `smoke: fingerprint check passed`.
- Serial log contains `LOADER OK` followed by `ELF LOAD OK`, in that
  order.
- No regression in any other smoke mode (`boot_r14b_kpti`,
  `boot_r15_ring3` pre-existing lines, `boot_r14b_ipi`,
  `boot_r14b_loader`).
- `readelf -a build/kernel.elf | grep -E "elf_lite_load|elf_load_ok_msg"`
  shows the loader symbol at high-VA and the new message strings at
  low-VA in `.rodata`.

## 9. Tractability

**High.** Both bug fixes are single-token edits in existing code with
crystal-clear root causes (encoder-level typo + wrong signed/unsigned
mnemonic). Neither touches memory model, syscall path, KPTI, or any
concurrency-sensitive code. The runtime witness reuses the exact same
scaffold as the #652 ring-3 witness (already passing) — a straight-
line call chain with printk-style failure reporting. Verification is
one smoke run.

The two prereqs (#649 phys_free, #652 aspace_map VA→PA) have already
landed, and #1246's REX.B fix in `paideia-as` v0.20 is not exercised
by the small mnemonic changes here — no encoder risk. Estimated
effort: **1 sitting**, primarily writing the loader runtime witness
block and its two message strings; the actual bug fixes take under
five minutes.
