---
issue: 645
milestone: R15.M4 (real syscall from ring-3)
subsystem: 6 — syscall/sysret ABI
prereq: [#499 (kpti_build_user_pml4), #500 (_kernel_pml4_pa), #503 (swapgs)]
blocks: [#533 (syscall slow-path runtime witness), first ring-3 SYSCALL]
touching:
  - src/kernel/link.ld
  - src/kernel/core/mm/kpti.pdx
  - src/kernel/core/syscall/entry.pdx (no code change, symbol relocation only)
  - src/kernel/core/syscall/kernel_stack.pdx (remove two symbols)
  - src/kernel/core/syscall/trampoline_data.pdx (new)
  - src/kernel/boot/kernel_main.pdx (extend kpti witness)
  - tests/r14b/expected-boot-r14b-kpti.txt (+1 fingerprint line)
---

# R14b-M4-006b — SYSCALL entry CR3 ordering (#645)

## 1. Scope

Fix the latent ordering bug in `src/kernel/core/syscall/entry.pdx` that
would triple-fault the first ring-3 → ring-0 SYSCALL under strict KPTI.

Concretely: the entry currently does

```
swapgs;
mov [rip + _saved_user_rsp], rsp;      ; kernel .bss — NOT mapped in user CR3
mov rax, cr3;
mov [rip + _saved_user_pml4], rax;     ; kernel .bss — NOT mapped in user CR3
mov rax, [rip + _kernel_pml4_pa];      ; kernel .bss — NOT mapped in user CR3
mov cr3, rax;
lea rsp, [rip + _syscall_kernel_stack + 16384];
```

Under `kpti_build_user_pml4` (r14b-m4-003, #499) the user PML4 has
`PML4[256]` routed through a shared trampoline PDPT that maps a *single*
higher-half page — `.text.syscall_trampoline` at phys 0x104000 / VA
0xFFFF800000104000. All three RIP-relative memory operands above land in
kernel `.bss` (a *different* page in the higher-half range that is NOT
present in the user PML4). Each one #PFs on CPL=0 with user rsp still
active → the #PF frame push targets the caller's rsp → double-fault →
triple-fault.

The audit in `design/audit/entries/r15-m3-005-syscall-slow-path.md`
records that the code "works today only because R14b-M3 KPTI keeps the
kernel higher-half mapped in user CR3 (non-strict KPTI)". That statement
mis-characterises what actually happens: `aspace_create_user_pgd`
allocates a fresh, all-zero PML4 and `kpti_build_user_pml4` installs
*only* PML4[256] → trampoline-PDPT. Nothing else in higher-half is
mapped. The reason there is no triple-fault today is that no ring-3
code exists to invoke SYSCALL — the trampoline is unreached. The
first `iretq` into ring-3 that returns via `syscall` will faceplant.

Goal: make the entry sequence safe under the strict KPTI mapping that
already exists, without requiring a runtime patch of the trampoline
image, an extra CR3 round-trip, or a rearrangement of the audited
push/shuffle discipline downstream.

## 2. Design choice — RW trampoline scratch slot

The issue offers two mechanisms:

- **GS scratch slot.** After `swapgs`, use `[gs:offset]` to save user
  rsp. Requires the effective linear address `GS_BASE + offset` to be
  present in the user CR3.
- **RW trampoline scratch slot.** Place `_saved_user_rsp`,
  `_saved_user_pml4`, and `_kernel_pml4_pa` on a dedicated RW page that
  the KPTI PT chain maps alongside the trampoline text page, with U=0
  (ring-0 only) and XD=1 (no execute).

We adopt the **RW trampoline scratch slot** and defer the GS scratch
route to a follow-up. Rationale:

1. **Minimal delta to the audited entry sequence.** The RW-slot fix
   leaves the assembly *byte-identical* modulo RIP-relative
   displacements. The audit trace in `r15-m3-005-syscall-slow-path.md`
   holds line-for-line; only the linker section of three symbols
   changes.

2. **No encoder gap to route around.** paideia-as ships
   `[gs:reg+disp]` (PA-R13-002) but not `[gs:disp32]` (no-base form).
   The GS route needs a base register with a known value, which means
   spending one of `rax`/`r8`/`r9` on a `xor` and losing it as scratch
   for the rest of the entry.

3. **GS_BASE currently points into kernel `.bss`.** `syscall_msr_init`
   sets `IA32_KERNEL_GS_BASE = &_cpu0_kernel_gs` and `kernel_main_64`
   sets `IA32_GS_BASE = &_cpu_locals[0]`. Both symbols live in kernel
   `.bss` (not trampoline-mapped). The GS scratch route requires
   relocating one of them onto a trampoline-mapped page — which is
   *exactly the same PT-plumbing exercise* as the RW-slot approach,
   plus a rework of the per-CPU layout module. Strictly more work for
   the same net effect.

4. **Generalises.** The trampoline data page has room for future
   ring-transition scratch (per-CPU IRQ shadow rsp, capability shim
   state, SMAP AC-flag save) without further PT changes. The RW page
   is the natural home for anything that syscall/interrupt entry must
   touch *before* the CR3 flip.

5. **Multi-CPU story is compatible.** At `MAX_CPUS = 1` a single
   4 KiB trampoline data page is sufficient. When `MAX_CPUS > 1` the
   same page is expanded to N × 64 B per-CPU sub-slots indexed by the
   CPU id — the same page keeps working; only the offset arithmetic
   changes. The GS route needs an entire per-CPU page-fan-out
   redesign at that point (each user PML4 must map that CPU's page,
   which is not a natural invariant).

### 2.1 What "RW trampoline scratch slot" means concretely

Introduce a new output section `.data.syscall_trampoline`:

- **VMA**: 0xFFFF800000105000 (immediately after `.text.syscall_trampoline`).
- **LMA**: 0x105000.
- **Alignment**: 4 KiB (one page).
- **Contents**:
  - `_saved_user_rsp : u64`   (offset 0)
  - `_saved_user_pml4 : u64`  (offset 8)
  - `_kernel_pml4_pa : u64`   (offset 16)  — *moved* from kernel `.bss`.
  - Reserved 0x18..0xFFF (per-CPU sub-slots, IRQ shadow rsp, etc.).

Mapping in the user PML4:

- Extend the shared trampoline-PDPT chain to populate `PT[261]`
  (`260*4K` is the text page; `261*4K` is the new data page).
- PTE flags: `phys | 0x8000000000000003`
  = present + writable + U=0 (kernel-only) + XD=1 (no execute).
  XD requires `IA32_EFER.NXE = 1`, which is set by `nx_enable` in
  `kernel_main_64` *before* the KPTI witness runs.

Under kernel CR3 the same VA is already mapped by the boot-stub
higher-half PDPT alias (PML4[256] → PDPT[0..3] identity), with kernel
default flags. Both address spaces therefore see the scratch page at
the same VA.

## 3. Concrete asm sequence

The `syscall_entry` body does **not** change:

```asm
;; entry.pdx — post-fix
swapgs;
mov [rip + _saved_user_rsp], rsp;      ; trampoline .data page → mapped in user CR3
mov rax, cr3;
mov [rip + _saved_user_pml4], rax;     ; trampoline .data page → mapped in user CR3
mov rax, [rip + _kernel_pml4_pa];      ; trampoline .data page → mapped in user CR3
mov cr3, rax;                          ; flip to kernel CR3 (CR3 write is serializing)
lea rsp, [rip + _syscall_kernel_stack + 16384];

push rcx;                              ; user RIP
push r11;                              ; user RFLAGS
push rax;                              ; syscall# (was in rax before CR3 read? see §3.1)
mov r8, r10;                           ; SysV shuffle
mov rcx, rdx;
mov rdx, rsi;
mov rsi, rdi;
pop rdi;                               ; = syscall# → arg0

call syscall_dispatch;

pop r11;
pop rcx;
mov rsp, [rip + _saved_user_rsp];      ; trampoline .data page (kernel CR3 sees it too)
mov rax, [rip + _saved_user_pml4];     ; trampoline .data page
mov cr3, rax;                          ; flip back to user CR3
swapgs;
sysret
```

### 3.1 Pre-existing wart preserved

The current entry clobbers `rax` (syscall#) at line 30 to hold `cr3`,
then re-uses `rax` at line 32 to load the kernel PML4, then pushes the
*loaded PML4 value* at line 39 as if it were the syscall# — the shuffle
downstream recovers "sysno" via `pop rdi` but what it actually gets is
the kernel PML4 phys, not the sysno.

This is either (a) a second latent bug that #645 should not fold in, or
(b) an artefact of an interim discipline that pushes garbage and never
actually reads it. Trace `r15-m3-005` calls the sequence out but does
not audit for this misuse. The safest read is: **do not touch this in
#645**. File a follow-up (`r14b-m4-006c-syscall-entry-sysno-preserve`)
that either

- moves the CR3 save/flip after the `push rax; push rcx; push r11;`
  register-preserve block, or
- shuffles sysno into a callee-saved register before touching `cr3`.

This deferral keeps #645 scoped to the CR3-ordering / KPTI-mapping
question and keeps the diff surgical.

### 3.2 Encoder & compiler capability review

- **#1244 unsafe-block source-order emission (fixed).** The current
  entry.pdx relies on the compiler emitting the `call syscall_dispatch`
  at its source position, not at the end of the unsafe block. Prior to
  #1244 the ordering-safety of the audited sequence was not guaranteed
  by the compiler. With #1244 landed the entry.pdx code sequence is
  what actually reaches the linker. Nothing in #645 exercises any
  additional source-order property beyond what the current code
  already assumes — the fix is safe *because of* #1244, and would have
  been unsafe to land before it.

- **#1240 encoder mem+imm64 arm.** Not required for the RW-slot
  approach — all trampoline-data writes use `mov [mem], reg` and reads
  use `mov reg, [mem]`. `#1240` is relevant only to the "immediate
  patched trampoline" backtrack candidate (§6).

- **`mov cr3, rN`.** Already exercised by `kpti_switch_to_kernel` (#501).

- **XD (bit 63) in PTE.** `kpti_build_user_pml4` currently writes 64-bit
  PTE values via `mov` from `rcx`/`rdx` registers; setting bit 63 is a
  register-immediate operation (`mov rcx, 0x8000000000000003` — the
  encoder ships `mov r64, imm64`). No encoder gap.

## 4. File-by-file delta

### 4.1 `src/kernel/link.ld`

Insert `.data.syscall_trampoline` between the existing
`.text.syscall_trampoline` and `.text` sections. LMA follows the
trampoline text page (0x105000). Segment: `data_high` (RW).

```ld
.data.syscall_trampoline : AT(ADDR(.data.syscall_trampoline) - KERNEL_VMA_BASE) ALIGN(4K) {
    _syscall_trampoline_data_start = .;
    KEEP(*core/syscall/trampoline_data.o(.data))
    _syscall_trampoline_data_end = .;
    . = ALIGN(4K);
} :data_high
```

Placement between text and .text preserves the invariant that the
trampoline text page is at phys 0x104000; the new data page lands at
0x105000, matching `KPTI_TRAMP_PT_DATA_IDX = 261`.

### 4.2 `src/kernel/core/syscall/trampoline_data.pdx` (new, ~20 LOC)

New module `TrampolineData` declares the three scratch symbols with
`@align(8)`. paideia-as places `let mut ... = uninit` into `.bss` by
default; we need `.data`. If a `@section(".data")` attribute is not yet
supported by paideia-as, declare the module and add a linker `KEEP`
that pulls the `.bss` output of this .o into the trampoline data
section — the linker script above handles that by KEEPing the .o's
`.data` section explicitly. For strictness in KPTI mapping we do want
the symbols in an *allocated* (non-NOLOAD) section so the loader
zero-fills the page as part of PT_LOAD image mapping.

Implementation options, in order of preference:

1. **paideia-as gains a `@section(".data.syscall_trampoline")`
   attribute on `let mut` decls.** Cleanest. File a paideia-as
   issue if the attribute is not present. Escalation code:
   PA-R15-011 (section-placement attribute).
2. **Linker script wildcard on the .o file.** Change the `KEEP` in
   `link.ld` to `*core/syscall/trampoline_data.o(.bss .bss.*)` and
   accept that these three symbols are `.bss`-in-name but land in the
   trampoline data page. Zero-init at boot is already handled by the
   PT_LOAD zero-fill for `.bss`-labelled but *allocated* sections
   present in the ELF. Verify with `readelf -S`.
3. **Hand-emit a small assembly stub** (via paideia-as raw asm) that
   defines the symbols in an explicit output section directive.
   Fallback if (1) and (2) both slip.

### 4.3 `src/kernel/core/mm/kpti.pdx`

Two additions.

**a. Constants** (near existing KPTI_TRAMP_PT_IDX):

```pdx
pub let KPTI_TRAMP_PT_DATA_IDX : u64 = 261
pub let KPTI_TRAMPOLINE_DATA_VA_KERNEL : u64 = 0xFFFF800000105000
```

**b. In `kpti_build_user_pml4`**, after the block that populates
`PT[260]` with the trampoline text page (lines 176–184) and before
the `PD[0]` install:

```asm
; Populate PT[261] with trampoline data page (LMA = 0x105000).
lea rcx, [rip + _syscall_trampoline_data_start];
mov rdx, 0xFFFF800000000000;                   ; KERNEL_VMA_BASE
sub rcx, rdx;                                  ; rcx = trampoline data phys
mov rdx, 0x8000000000000003;                   ; present + RW + U=0 + XD
or rcx, rdx;
mov r9, r8;                                    ; r9 = PT base (r8 unchanged from prior block)
add r9, 2088;                                  ; r9 = PT[261] slot (261*8)
mov [r9], rcx;
```

Placement inside the cold-path (allocate PT chain) branch is
sufficient: the PDPT is cached in `_kpti_trampoline_pdpt_pa` and reused
across user aspaces, so the data-page mapping propagates on first
allocation. No change to the hot path (`kpti_have_pdpt`).

Update the `justification:` string to reference #645 and the RW-slot
discipline.

### 4.4 `src/kernel/core/syscall/kernel_stack.pdx`

Remove the two lines:

```pdx
pub let mut _saved_user_rsp : [u64; 1] = uninit @align(8)
pub let mut _saved_user_pml4 : [u64; 1] = uninit @align(8)
```

They migrate to `trampoline_data.pdx`. Keep `_syscall_kernel_stack` in
kernel `.bss` — after CR3 flip we are on kernel CR3 and the kernel
stack VA is mapped normally.

### 4.5 `src/kernel/core/syscall/entry.pdx`

**No source change.** The symbols `_saved_user_rsp`, `_saved_user_pml4`,
`_kernel_pml4_pa` now resolve to different VAs; the emitted RIP-relative
displacements shift by ~a page. Update the `justification:` string to
reference #645 and drop the "…ordering fix tracked at #645" clause.

### 4.6 `src/kernel/boot/kernel_main.pdx`

The line `mov [rip + _kernel_pml4_pa], rax;` (#500) writes the kernel
PML4 phys once at boot. `_kernel_pml4_pa` migrates to
`trampoline_data.pdx` but under *kernel* CR3 (early boot) the
trampoline data page is mapped via the boot-stub PDPT alias, so this
write reaches the same physical byte. No code change; verify with
`readelf` that `_kernel_pml4_pa` resolves into the
`.data.syscall_trampoline` section.

## 5. Test canaries

### 5.1 Structural (extends existing `boot_r14b_kpti`)

Extend the KPTI witness block in `kernel_main.pdx` (lines 90–126) with
a scratch-slot round-trip *without* activating user CR3 for real. The
existing witness already runs before ring-3 exists, so we mirror the
same approach:

1. After `kpti_build_user_pml4` succeeds, walk the user PML4 into the
   trampoline-PDPT and assert PT[261] present + RW + U=0.
2. Read `_kernel_pml4_pa` back via its new VA and confirm the boot
   write survived the section move.
3. Write a canary value (0xDEAD_BEEF_CAFE_F00D) to
   `_saved_user_rsp[0]`, read it back, confirm.
4. Print `KPTI SCRATCH OK`.

**Fingerprint delta**: `tests/r14b/expected-boot-r14b-kpti.txt` gains
one line after `KPTI OK`:

```
B
HI VA FFFF8000
PaideiaOS R8
KPTI OK
KPTI SCRATCH OK
```

Verification: `tools/run-smoke.sh boot_r14b_kpti` (5s timeout,
fingerprint match). Per `feedback_paideia_os_no_cicd.md` this is the
sole verification path — there is no GitHub Actions surface.

### 5.2 Runtime (deferred to #533 / R15.M4)

The end-to-end witness — real ring-3 SYSCALL round-trip printing
"SYS OK" — cannot be exercised until #533's substrate (ring-3 witness
path, `sys_debug_puts` from user context) closes. #645 delivers the
*enabling* fix; #533 delivers the runtime demonstration. Both are
tracked in `design/audit/entries/r15-m3-005-syscall-slow-path.md`.

For the pre-#533 interim, a QEMU CR3-transition trace via
`qemu -d cpu -no-reboot -no-shutdown` on a hand-built `iretq` +
`syscall` fixture would confirm no #PF. Deferring this instrumentation
is safe *given* the structural canary in §5.1 proves the mapping
discipline.

### 5.3 Objdump discipline

`objdump -d build/kernel.elf | sed -n '/<syscall_entry>:/,/^$/p'`
must show:

- `mov QWORD PTR [rip+0x<X>],rsp` where `<X>` resolves to a VA in
  `.data.syscall_trampoline` (verifiable via
  `nm build/kernel.elf | grep _saved_user_rsp`).
- `mov cr3,rax` at exactly two sites (entry flip, exit restore).
- `swapgs` (0f 01 f8) at exactly two sites.

Adding this to a `tools/verify-syscall-entry.sh` helper (~20 lines) is
low-cost insurance against a future refactor silently re-introducing
the bug.

## 6. Backtrack candidates

Ordered by preference should the RW-slot approach hit blocking issues.

### Backtrack A — hold user rsp in `r9` across CR3 flip, patch immediate

Reorder-and-patch: preserve user rsp in `r9`, encode `_kernel_pml4_pa`
as an inline `mov rax, imm64` patched at boot.

```asm
swapgs;
mov r9, rsp;                    ; scratch preserve
mov r8, cr3;                    ; scratch preserve
mov rax, 0xDEADBEEFDEADBEEF;    ; patched at boot with kernel PML4 phys
mov cr3, rax;
lea rsp, [rip + _syscall_kernel_stack + 16384];
push r9;                        ; user rsp now on kernel stack
push r8;                        ; user cr3 now on kernel stack
;; continue with SysV shuffle, dispatch, restore
```

Requires:
- Runtime patching of the trampoline `.text` page during boot (write
  8 bytes into the immediate slot). Trampoline text must therefore be
  RW during boot and remapped RO afterwards, or patched via the
  higher-half alias which is RW under kernel CR3 today.
- paideia-as `mov r64, imm64` — already present.
- A named symbol for the patch site (e.g. label
  `syscall_entry_kernel_pml4_imm_lo`). Requires a paideia-as feature
  to expose an immediate as a relocatable target — this is the
  "encoder mem+imm64 arm" family (#1240) applied to the *immediate
  operand* of a `mov r64, imm64`. **Non-trivial encoder work** —
  reason this is a backtrack, not the primary path.

Trade-off: no linker script change, no PT change. Costs: boot-time
patch step + a new paideia-as feature.

### Backtrack B — GS scratch via trampoline-mapped per-CPU page

Relocate `_cpu0_kernel_gs` (currently a 16-byte kernel `.bss`
placeholder) onto the trampoline data page. Point `IA32_KERNEL_GS_BASE`
at that location. After `swapgs` on syscall entry, `GS_BASE` = trampoline
data page; `[gs:rax*0 + SCRATCH_OFF]` writes to that page under user
CR3.

Trade-offs:
- Requires a zero base register for the `[gs:reg+disp]` form —
  `xor rax, rax` clobbers the syscall# **before** we save it, so we
  must shuffle sysno out first. Adds two instructions.
- Puts the RW trampoline plumbing exactly where this proposal already
  puts it — most of the work is shared with the primary path — but
  loses the RIP-relative addressing simplicity. Reason to prefer
  primary path.

### Backtrack C — split the trampoline into pre-flip and post-flip pages

The pre-flip trampoline holds only register-only ops + immediate-patched
CR3 flip; the post-flip trampoline lives in normal kernel `.text` and
does everything else. Requires a `jmp` after CR3 flip that spans two
mappings that agree on the target VA — possible because both PML4s map
`PML4[256]` and the target VA is in that slot, but the two mappings must
agree on the target page's presence. Straightforward but doubles the
trampoline surface. Reason to prefer primary path.

## 7. LOC estimate

| File                                                    | LOC delta |
|---------------------------------------------------------|-----------|
| `src/kernel/link.ld`                                    | +7        |
| `src/kernel/core/mm/kpti.pdx`                           | +18       |
| `src/kernel/core/syscall/trampoline_data.pdx` (new)     | +20       |
| `src/kernel/core/syscall/kernel_stack.pdx`              | −3        |
| `src/kernel/core/syscall/entry.pdx`                     | 0 (justif. update only) |
| `src/kernel/boot/kernel_main.pdx`                       | +25 (scratch canary) |
| `tests/r14b/expected-boot-r14b-kpti.txt`                | +1        |
| `design/audit/entries/r14b-m4-006b-syscall-entry-cr3-ordering.md` (new) | +40 |
| **Total**                                               | **~110**  |

Of the ~110 lines, only ~45 are *executable* .pdx code; the remainder is
linker script, fingerprint, and audit.

## 8. Tractability

**HIGH.** Fix is well-fenced:

- No new paideia-as compiler feature required for the primary path.
  Backtracks require encoder work; primary does not.
- All PT-plumbing lives inside `kpti_build_user_pml4` — a function
  whose contract already includes populating the trampoline PT chain.
- No change to the audited entry.pdx assembly sequence — the
  `r15-m3-005-syscall-slow-path.md` audit remains valid; only the
  KPTI mapping side of the invariant strengthens.
- Structural test canary is a straightforward extension of the
  existing `boot_r14b_kpti` witness — same file, same 5 s fingerprint
  harness.
- Cross-cutting risk (SMEP / SMAP / NXE interaction): all three are
  set before the KPTI witness runs and none conflict with a
  ring-0-only + XD trampoline data page.

Known follow-ups (out of scope for #645, filed as separate issues):

- **`r14b-m4-006c-syscall-entry-sysno-preserve`**: fix the `push rax`
  after `mov rax, cr3` semantic (§3.1).
- **`r15-m4-006d-per-cpu-trampoline-scratch`**: expand the RW-slot to
  N × per-CPU sub-slots when `MAX_CPUS > 1` (aligned with
  `r14b-m5-*` per-CPU work).
- **PA-R15-011**: paideia-as `@section(...)` attribute on `let mut`
  decls for allocated data placement outside `.bss`. Nice-to-have;
  linker-side workaround is acceptable.

## 9. References

- Issue: paideia-os#645
- Prior audit: `design/audit/entries/r15-m3-005-syscall-slow-path.md`
- Origin CR3 flip: r14b-m4-006 (#502)
- swapgs origin: r14b-m4-007 (#503)
- KPTI PT builder: r14b-m4-003 (#499),
  `src/kernel/core/mm/kpti.pdx:97..224`
- Kernel PML4 boot init: r14b-m4-004 (#500),
  `src/kernel/boot/kernel_main.pdx:70`
- Entry (current): `src/kernel/core/syscall/entry.pdx`
- Trampoline linker section: `src/kernel/link.ld:50..55`
- paideia-as GS-relative encoder: PA-R13-002
- paideia-as unsafe-block source-order fix: #1244
