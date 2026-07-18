---
issue: 652
parent: 527 (r15-m2-006 first user_ret target — audit)
milestone: R15.M2 (first ring-3 entry — runtime witness)
subsystem: 5 — ring-transition ABI
prereq: [#526 (enter_userland_initial primitive), #645 (KPTI scratch slot), #651 (relocate + CR3 flip), #644 (IDT #GP wired)]
blocks: [none — shell demo AC has this as its ring-3 witness]
touching:
  - src/kernel/boot/kernel_main.pdx
  - src/kernel/core/int/exceptions.pdx
  - tests/r15/expected-boot-r15-ring3.txt (new)
  - tools/run-smoke.sh
  - design/kernel/r15-m2-006b-boot-r15-ring3-hello.md (this file)
---

# R15-M2-006b — Boot-r15-ring3-hello: user `_start = hlt` + `#GP` marker + smoke fixture (#652)

## 1. Scope

Deliver the first RUNTIME witness that ring-3 execution actually happens
on PaideiaOS. #526 shipped `enter_userland_initial` (the iretq primitive);
#651 relocated it into the trampoline text page and wired the CR3 flip.
Nothing calls it yet. #652 wires the first live call and captures the
witness.

Ring-3 witness discipline chosen for this issue:

- User `_start` is one byte, `0xF4` (`hlt`). Ring-3 `hlt` is privileged
  (Intel SDM Vol 2A HLT: "a general-protection exception (#GP) is
  generated when the current privilege level is not 0"). Executing it
  raises `#GP(0)`.
- Kernel `#GP` path (`_typed_handler_13`) detects the "ring-3 witness
  active" flag, emits `R15 RING3 HELLO OK\n` to serial, and resumes
  `kernel_main` via trap-frame surgery so the rest of the boot
  (task-A/B alternation, IPI witness, loader witness) continues to
  execute normally under a single kernel binary.
- New smoke mode `boot_r15_ring3` validates the marker fingerprint.
- No syscall path is exercised — `#650`'s `sys_debug_puts` and the
  strict-KPTI trampoline mappings remain deferred.

This is exactly the "runtime witness" listed as deferred at
`design/kernel/r15-m2-005-followup-relocate-enter-userland.md` §5.4
("The end-to-end demonstration [...] requires #650, #652, GDT trampoline
mapping"). #652 lands *without* the GDT trampoline mapping by using a
**Meltdown-open witness PML4** (§3.2 below) that shares kernel higher-
half with the ring-3 code + stack pages. This is an explicit,
witnessed concession — strict KPTI enforcement moves to a filed
follow-up (§2.2).

## 2. Prereq check

### 2.1 What's in place

- `enter_userland_initial` (#526 + #651): callable, CR3-flip-clean.
  Lives in `.text.syscall_trampoline` (PT[260]). Frame slot lives in
  `.data.syscall_trampoline` (PT[261]).
- `_iretq_frame_scratch`: 5-slot RIP/CS/RFLAGS/RSP/SS staging (§3.2 of
  the parent doc).
- `_kernel_pml4_pa`: populated at boot line 70 (`kernel_main` reads
  `_pml4_addr` from the boot stub, stores to
  `_kernel_pml4_pa`). Needed for CR3 flip-back in the resume path
  (§4.5).
- `aspace_create(kernel_pml4)`: makes a fresh PML4 with kernel
  higher-half [256..511] copied and user half [0..255] zeroed.
  (`src/kernel/core/mm/aspace_create.pdx:38..93`.) The witness PML4
  is built via this, NOT via `aspace_create_user` (which would give
  a strict-KPTI PML4 with only trampoline pages).
- `aspace_map(as, va, pa, flags)`: 4-level walker, allocates
  intermediate tables. Used to install the user code page + stack.
- `phys_alloc(order)`: physical frame allocator. Available since
  `cap_smoke` (which allocates) already runs upstream of the witness
  site.
- `user_stack_alloc(aspace, size_pages)`: R+W+U+NX at
  `0x7FFFFFFFF000 - N*4096`. Guard page below is P=0. Returns
  canonical top-of-user-stack VA.
- `handle_gp` / `_typed_handler_13` / `trampoline_vec13`: IDT slot
  13 is wired (#644). Errcode variant of the trampoline pushes
  errcode + 15 GPRs before dispatching. Current handler halts on
  entry — #652 rewrites `_typed_handler_13` (not `handle_gp`) so
  the halt-on-normal-#GP semantics stay intact for non-witness
  callers.

### 2.2 What's deferred (bundled vs. separate)

The parent doc §4.2 called out one concession:

> Under user CR3 the GDT VA is not mapped [...] `iretq`'s CS descriptor
> read faults, IDT vector lookup faults, NMI window is unsafe.

**Recommendation: file separately, do NOT bundle into #652.**

Rationale:

- The GDT / IDT / TSS / ISR-stub trampoline mapping is a substantial
  chunk of PT plumbing — expand `kpti_build_user_pml4` to populate
  PT[262..N] with RO GDT + RO IDT + RW TSS + RX ISR-stub, add helper
  functions, teach the walker about the new slots. Estimated 200-300
  LOC across `kpti.pdx`, new stub-relocation section, and possibly a
  new module for the trampoline stubs. That is a milestone-sized
  piece of work, not a rider on the witness issue.
- The witness value of #652 is orthogonal to strict KPTI: proving
  ring-3 landed + can trap needs iretq to *succeed*, which only
  requires the target PML4 to have GDT/IDT/TSS/handlers mapped
  *somewhere*. Kernel higher-half is such a mapping. Meltdown-open
  means speculative-execution reads may leak — not "the code
  doesn't run".
- Bundling would push #652 past the milestone's tempo. #651 landed
  clean; #652 should land clean at similar tempo, with the strict-
  KPTI follow-up filed and tackled separately.

**Filed as new issue** (companion, non-blocker):
`r15-m2-005b-gdt-trampoline-mapping` — map GDT/IDT/TSS + relocate
ISR entry stubs so iretq's descriptor loads and the ring-3-to-ring-0
exception path both succeed under strict-KPTI user CR3. Blocks:
retiring the Meltdown-open concession of #652.

## 3. Design

### 3.1 High-level flow

```
kernel_main
  ├── uart_init + banner
  ├── smokes (cap, ipc, dispatch)
  ├── gdt/idt/tss/smep/smap/nx install
  ├── KPTI witness (#645)
  ├── ENTER_USER_RELOC witness (#651)
  ├── RING3 WITNESS (this issue): --------------+
  │     - save _kernel_resume_rsp, resume_rip   |
  │     - build witness PML4                    |
  │     - map user _start (1 byte: hlt)         |
  │     - alloc user stack                      |
  │     - set _ring3_witness_active = 1         |
  │     - call enter_userland_initial(...)      |
  │     - iretq → ring-3 → hlt → #GP ───────────┘
  │       (never returns via call/ret)
  │
  ├── ring3_witness_resume:  ← _typed_handler_13 jumps here
  │     - "R15 RING3 HELLO OK" already printed by handler
  │
  ├── IPI witness / loader witness
  ├── lapic_timer_init / sched_init
  └── task_a_entry (coop yield loop; runs forever)
```

Kernel binary is a **single** `build/kernel.elf`. All existing smokes
(`boot_r14b_kpti`, `boot_r14b_ipi`, `boot_r14b_loader`, `boot_r10`,
`boot_r11`, `boot_r12`) continue to pass because the witness ends by
resuming `kernel_main` at the next instruction after the witness
block. The witness marker `R15 RING3 HELLO OK` is emitted between
`ENTER USER RELOC OK` and `IPI STRUCT OK`; contains-in-order
fingerprint matching means it does not break any earlier or later
smoke's expected file (extra lines are ignored).

### 3.2 Witness PML4 construction

The witness needs a PML4 that:

- Maps kernel higher-half (so IDT/GDT/TSS/ISR-stubs/handler-code
  resolve when `#GP` fires under user CR3).
- Maps a user code page at some canonical low-half VA with `U=1 | X=1
  | R=1` (writeable not required — the payload is 1 byte).
- Maps a user stack at `0x7FFFFFFFF000` (top-of-user-VA) with
  `U=1 | W=1 | R=1 | NX=1`.

`aspace_create(kernel_pml4)` builds a PML4 with kernel higher-half
already copied and user half zeroed. Adding the user code + stack
mappings on top gives exactly the Meltdown-open witness PML4 we
want. `aspace_create_user` is deliberately NOT used — its output is
a strict-KPTI PML4 with only the trampoline pages, which would
require the deferred GDT trampoline mapping to actually iretq.

User code page:

- Fixed VA: `0x0000000000400000` (canonical positive, low, non-null,
  clear of everything else). Same 2 MiB alignment as ELF text
  segments per SysV ABI; matters when we later swap to a real ELF
  loader.
- Phys backing: allocated at witness setup via `phys_alloc(0)` (one
  4 KiB frame). Byte 0 written to `0xF4` (hlt) via the boot-stub
  higher-half alias `KERNEL_VMA_BASE + phys`. Bytes 1..4095 remain
  zero (any speculative fetch past `hlt` would decode to `add [rax],
  al` — irrelevant, we never reach it).
- Flags for `aspace_map`: `0x05` = `U | P` (no W, no NX). Note NX
  bit is 63; leaving it clear leaves the page executable. Kernel-
  side alias of the same phys frame stays U=0 and R+W (default for
  identity aliases), so SMEP is not violated.

User stack:

- Fixed VA: `0x7FFFFFFFF000` (via `user_stack_alloc`).
- 1 page — hlt does not push anything, so a single-page stack with
  guard-below is defensively fine.

### 3.3 User `_start` payload

Literally one byte: `0xF4`. Kernel-side buffer:

Option A (runtime allocation, **chosen**): `phys_alloc(0)` a frame,
write `0xF4` at offset 0 via `[KERNEL_VMA_BASE + phys]`, map at
`0x400000` in witness PML4 with `U|P`. Advantages: no linker-script
changes, no new .rodata section, symmetric with how the loader
substrate maps user code. Disadvantage: allocation can OOM (fail-
message printed, witness marks fail).

Option B (linker-section embed, rejected): Add a
`.rodata.user_hlt_stub` section carrying one byte, referenced by
symbols `_user_hlt_stub_start / _end`. Kernel-side stays R+X+U=0
(inherited from `.rodata` PT flags); we'd map the phys frame with
U=1 in the witness PML4. Cleaner in principle (deterministic phys
addr, no allocator dependency); rejected because a whole new PT-
mapped section for one byte does not pay for itself, and #652 is a
witness, not a substrate.

### 3.4 `#GP` handler — trap-frame surgery for kernel resume

`_typed_handler_13` (in `src/kernel/core/int/exceptions.pdx:198`)
is rewritten. Skeleton:

```asm
; --- Ring-3 witness path: check flag first ---
lea rax, [rip + _ring3_witness_active];
mov rax, [rax];
cmp rax, 1;
jne typed13_normal_gp;

; One-shot: clear the flag so subsequent #GPs halt normally.
lea rax, [rip + _ring3_witness_active];
mov rcx, 0;
mov [rax], rcx;

; Emit witness marker.
lea rdi, [rip + ring3_hello_ok_msg];
call uart_puts;

; Flip CR3 back to kernel PML4 (drops the Meltdown-open witness PML4).
mov rax, [rip + _kernel_pml4_pa];
mov cr3, rax;

; Restore kernel RSP + jump to kernel_main resume label.
mov rsp, [rip + _kernel_resume_rsp];
lea rax, [rip + _kernel_resume_rip];
mov rax, [rax];
jmp rax;

; --- Normal path (unchanged: halt) ---
typed13_normal_gp:
call handle_gp;
ret
```

The trap frame + the 15 saved GPRs on RSP0 are abandoned. Since
this is a one-shot witness and RSP0 is a fixed per-CPU kernel stack,
the next interrupt/exception reuses the same stack from top — no
persistent leak.

`swapgs` state on entry to `_typed_handler_13`:

- Ring-3 was running with kernel `GS_BASE = 0` (set by
  `enter_userland_initial`'s `swapgs`, which swapped kernel-GS out).
- The trampoline_vec13 stub does NOT swapgs (there's no swapgs
  discipline on the IDT stubs yet). So `IA32_GS_BASE` on entry is
  still the user (0) value.
- We must `swapgs` back before returning to kernel context (so
  `[gs:off]` per-CPU access still works in the resumed
  `kernel_main`).

Refined snippet, inserting `swapgs` before the CR3 flip:

```asm
swapgs;                                  ; restore kernel GS_BASE
mov rax, [rip + _kernel_pml4_pa];
mov cr3, rax;
mov rsp, [rip + _kernel_resume_rsp];
lea rax, [rip + _kernel_resume_rip];
mov rax, [rax];
jmp rax;
```

`_ring3_witness_active` is checked *before* `swapgs` (uses only RIP-
relative memory operand, no GS access). Ordering:
`check-flag → clear-flag → uart_puts → swapgs → cr3-flip → rsp-restore → jmp`.

`uart_puts` uses `out dx, al` (no GS), so it works with either GS
state. Placing `swapgs` after `uart_puts` keeps the surface small.

### 3.5 Kernel resume state

Two new mutable globals, defined in `kernel_main.pdx` (near the top
of the module body, alongside other file-locals):

```pdx
pub let mut _ring3_witness_active : u64 = 0
pub let mut _kernel_resume_rsp    : u64 = 0
pub let mut _kernel_resume_rip    : u64 = 0
```

`pub` so `_typed_handler_13` (in `exceptions.pdx`) can reference them
via `[rip + sym]` cross-module — the same idiom used at
`exceptions.pdx:155` for `_preempt_needed`.

Populated at the start of the witness block:

```asm
; Save kernel state for the #GP-handler resume path.
mov rax, rsp;
lea rcx, [rip + _kernel_resume_rsp];
mov [rcx], rax;
lea rax, [rip + ring3_witness_resume];   ; the resume label
lea rcx, [rip + _kernel_resume_rip];
mov [rcx], rax;
```

### 3.6 Witness block, complete draft

Inserted into `kernel_main.pdx` immediately after
`enter_reloc_done:` (line 216 in the current file) and before
`kpti_done:`:

```asm
; ============================================================
; R15-M2-006b (#652): first ring-3 witness — user _start = hlt.
; ============================================================

; 1. Save kernel resume state (for #GP handler trap-frame surgery).
mov rax, rsp;
lea rcx, [rip + _kernel_resume_rsp];
mov [rcx], rax;
lea rax, [rip + ring3_witness_resume];
lea rcx, [rip + _kernel_resume_rip];
mov [rcx], rax;

; 2. Build witness PML4 (kernel higher-half copy + zero user half).
mov rdi, [rip + _kernel_pml4_pa];
call aspace_create;
mov rcx, 0xFFFFFFFF;
cmp rax, rcx;
je  ring3_witness_fail;
mov r12, rax;                            ; r12 = witness_pml4_pa

; 3. Allocate a phys frame + write 0xF4 (hlt) + map at 0x400000.
mov rdi, 0;
call phys_alloc;
cmp rax, 0;
je  ring3_witness_fail;
mov r13, rax;                            ; r13 = user_code_pa

mov rcx, 0xFFFF800000000000;             ; KERNEL_VMA_BASE
add rcx, r13;                            ; rcx = kernel VA alias of r13
mov rax, 0xF4;
mov [rcx], al;                           ; write hlt byte

mov rdi, r12;                            ; aspace
mov rsi, 0x400000;                       ; user VA
mov rdx, r13;                            ; phys
mov rcx, 0x05;                           ; P | U (X=1 via cleared NX)
call aspace_map;
cmp rax, 0;
jne ring3_witness_fail;                  ; MAP_OOM = 0xFFFFFFFE, non-zero

; 4. Allocate user stack in witness PML4.
mov rdi, r12;
mov rsi, 1;                              ; 1 page
call user_stack_alloc;
cmp rax, 0;
je  ring3_witness_fail;
mov r14, rax;                            ; r14 = user_rsp (0x7FFFFFFFF000)

; 5. Arm the witness flag (read by _typed_handler_13).
mov rax, 1;
lea rcx, [rip + _ring3_witness_active];
mov [rcx], rax;

; 6. Enter userland. iretq → ring-3 → hlt → #GP → handler resumes below.
mov rdi, 0x400000;                       ; entry_rip
mov rsi, r14;                            ; initial_rsp
mov rdx, r12;                            ; user_pml4_pa
call enter_userland_initial;

; UNREACHABLE — enter_userland_initial iretq's into ring-3. Fall-through
; here would only happen if the primitive returned normally, which its
; ud2 sentinel forbids. Belt-and-braces sentinel:
hlt;
jmp ring3_witness_fail;

ring3_witness_resume:
; Reached from _typed_handler_13's trap-frame surgery. RSP was
; restored, CR3 flipped back to _kernel_pml4_pa, GS restored via
; swapgs. Marker already emitted. Fall through to normal boot.
jmp ring3_witness_done;

ring3_witness_fail:
lea rdi, [rip + ring3_fail_msg];
call uart_puts;

ring3_witness_done:
```

Rodata strings (append to existing block):

```
ring3_hello_ok_msg : "R15 RING3 HELLO OK\n"
ring3_fail_msg     : "R15 RING3 FAIL\n"
```

Layout after this: control falls through to the existing
`ipi_fail: / ipi_done:` witness (which is currently right below the
`kpti_done:` label). No re-plumbing.

## 4. CR3 / interrupt / GS ordering discipline

### 4.1 CR3 state across the witness

| Point                                       | CR3               |
|---------------------------------------------|-------------------|
| kernel_main entry to witness block          | kernel PML4       |
| after `enter_userland_initial`'s `mov cr3`  | witness PML4      |
| during ring-3 execution (hlt)               | witness PML4      |
| #GP dispatched, `_typed_handler_13` entered | witness PML4      |
| after handler's `mov cr3, _kernel_pml4_pa`  | kernel PML4       |
| resumed `kernel_main` (`ring3_witness_resume`) | kernel PML4    |

The witness PML4 has kernel higher-half mapped (via `aspace_create`
copying entries 256..511), so all kernel accesses during ring-3
execution and #GP handling succeed under witness CR3. The Meltdown-
open aspect is that speculative execution from ring-3 could probe
kernel VAs — architecturally protected by U=0 on kernel pages, but
observably present. Explicit concession; strict-KPTI is the follow-up
(§2.2).

### 4.2 IDT / GDT / TSS reads under witness CR3

Because kernel higher-half is present in the witness PML4:

- IDTR base (kernel .rodata) is resolvable → vec 13 descriptor
  loaded → RIP points at trampoline_vec13.
- CS switches to `0x08` (kernel code, GDT[1]). GDTR base is
  kernel `.data` — mapped → descriptor loads.
- CPU switches to RSP0 (from TSS). TSS is in kernel `.bss.data` —
  mapped → RSP0 = kernel stack.
- Trampoline_vec13 body is in `.text` — mapped → executes.

All four descriptor / handler accesses that would fault under strict
KPTI succeed here. This is what "Meltdown-open witness" buys.

### 4.3 NMI window during ring-3 execution

While CR3 = witness PML4, an NMI in ring-3 vectors through the same
IDT + trampoline + handler chain as #GP. All targets are mapped
(kernel higher-half present). NMI is safe under the witness PML4
concession.

Under strict-KPTI (`aspace_create_user` PML4), the NMI window is the
concession called out at parent doc §4.3. #652 does not carry that
concession because it does not use a strict-KPTI PML4. When
`r15-m2-005b` lands and swaps the witness over to a strict-KPTI
PML4, the NMI-under-user-CR3 discipline moves with it.

### 4.4 GS discipline

`enter_userland_initial` does `swapgs` before ring-3 entry — kernel
`GS_BASE` is stashed into `IA32_KERNEL_GS_BASE`, ring-3 sees
`GS_BASE = 0`.

Under ring-3 `hlt`, the #GP dispatch flow is:

1. CPU pushes trap frame to RSP0 (from TSS), switches to CS=0x08.
2. Executes `trampoline_vec13` — **does not swapgs** (existing
   handler discipline; the ISR stubs never swapgs).
3. Enters `_typed_handler_13` with `IA32_GS_BASE = 0` (user).

Adding `swapgs` inside the witness path of `_typed_handler_13`
restores kernel GS before we resume kernel_main.

Long-term note: the exception-handler entry path *should* swapgs
via a "swapgs-if-came-from-ring-3" check (compare pushed CS.RPL to
0). That work is filed under `r15-m2-006c-exception-swapgs-discipline`
as a follow-up. For #652's one-shot witness, the local swapgs in the
witness path is sufficient — the handler's normal path (halt) does
not need GS.

### 4.5 SMEP / SMAP / NX interactions

- **SMEP** (ring-0 fetch from U=1 page traps): does NOT fire during
  the witness. Ring-3 executes `hlt` at `0x400000` (U=1). Ring-0 code
  fetches happen at kernel VAs (U=0), which SMEP permits.
- **SMAP** (ring-0 access to U=1 page traps): does NOT fire. The
  witness setup writes `0xF4` via the *higher-half alias*
  (`KERNEL_VMA_BASE + phys`), which is U=0 in the boot PML4 — not
  U=1. SMAP would only trap if we wrote via `0x400000` under kernel
  CR3, which we don't.
- **NX**: user code page has NX=0 (executable). Kernel-side higher-
  half alias of the same phys frame has NX per whatever the boot PT
  sets — likely NX=0 for now. Immaterial for the witness.

## 5. Test canary

### 5.1 Smoke mode: `boot_r15_ring3`

New mode in `tools/run-smoke.sh`:

```bash
boot_r15_ring3)
    FINGERPRINT_MODE=1
    FINGERPRINT_FILE="${REPO_ROOT}/tests/r15/expected-boot-r15-ring3.txt"
    TIMEOUT=6
    EXPECTED=""
    ;;
```

6 s timeout: the witness runs early (~200 ms into boot on QEMU-TCG),
the marker appears, and kernel continues into task-A yield loop —
the smoke passes as soon as the fingerprint matches.

### 5.2 Fingerprint file (new)

`tests/r15/expected-boot-r15-ring3.txt`:

```
B
HI VA FFFF8000
PaideiaOS R8
KPTI OK
KPTI SCRATCH OK
ENTER USER RELOC OK
R15 RING3 HELLO OK
IPI STRUCT OK
```

Optional final line `IPI STRUCT OK` proves the kernel resumed cleanly
after the witness (otherwise the marker could theoretically be
emitted from any kernel-mode "GP-in-ring-0" fluke, which isn't
plausible but the resume-witness closes it airtight).

`mkdir -p tests/r15/` — no prior tests in `tests/r15/`.

### 5.3 Existing fingerprints — no drift

`tests/r14b/expected-boot-r14b-kpti.txt` is unchanged — its
required lines all still appear in the same order (contains-in-order
matching ignores the extra `R15 RING3 HELLO OK` line).

`tests/r14b/expected-boot-r14b-ipi.txt`,
`tests/r14b/expected-boot-r14b-loader.txt`,
`tests/r10/expected-boot-r10.txt`,
`tests/r11/expected-boot-r11.txt`,
`tests/r12/expected-boot-r12.txt`,
`tests/r12/expected-boot-r12-denial.txt` — same reasoning. All
continue to pass because the ring-3 witness resumes kernel_main and
the rest of boot proceeds unchanged.

Any smoke that regresses is a signal of a real bug in the resume
path — do not touch fingerprints to hide it.

### 5.4 Objdump / structural discipline

Add to `tools/verify-syscall-entry.sh` (or a new
`tools/verify-ring3-witness.sh`):

- `nm build/kernel.elf | grep '_ring3_witness_active'` — non-empty.
- `nm build/kernel.elf | grep '_kernel_resume_rsp'` — non-empty.
- `nm build/kernel.elf | grep '_kernel_resume_rip'` — non-empty.
- `objdump -d build/kernel.elf | sed -n '/<_typed_handler_13>:/,/^$/p'`
  must contain `cli`, `swapgs`, `mov cr3, `, and a `jmp rax` (the
  resume tail).

Not required to land as a script; running these by hand while
implementing is sufficient discipline.

### 5.5 Ring-3 execution *proof* (belt-and-braces)

The smoke as designed proves:

1. `enter_userland_initial`'s iretq did not triple-fault (else no
   marker).
2. Ring-3 executed at least one instruction (`hlt`) — else no #GP.
3. The GP was delivered to the *#GP* vector specifically (not
   #UD or #PF) — else the wrong handler runs and no marker.
4. The kernel resumed `kernel_main` cleanly — else `IPI STRUCT OK`
   does not appear.

Together this is a complete witness of ring-3 execution and clean
return-to-kernel discipline. No sys_debug_puts is required. #650
remains an independent piece of substrate (marker discipline for
`#UD`, still valuable, still deferred).

## 6. LOC estimate

| File                                                                | LOC delta |
|---------------------------------------------------------------------|-----------|
| `src/kernel/boot/kernel_main.pdx`                                   | +55       |
| `src/kernel/core/int/exceptions.pdx` (`_typed_handler_13` rewrite)  | +20       |
| `tests/r15/expected-boot-r15-ring3.txt` (new)                       | +8        |
| `tools/run-smoke.sh` (new mode case)                                | +7        |
| `design/kernel/r15-m2-006b-boot-r15-ring3-hello.md` (new)           | +330      |
| **Total**                                                           | **~420**  |

Executable/config: ~90 LOC. Design + fingerprint: ~330 LOC.

## 7. Backtrack candidates

Ordered by preference.

### 7.1 Backtrack A — Skip trap-frame surgery, halt on witness marker

Simpler `_typed_handler_13`: emit marker, cpu_halt. Kernel does not
resume. Consequence: every other smoke (`boot_r10/11/12`, IPI,
loader) breaks — they'd need their own kernel binary or a build-
flag switch. Doubles CI cost or requires a two-kernel build.

Reject as primary — trap-frame surgery is ~20 LOC and preserves the
single-kernel invariant. Retain as fallback should the resume path
turn out to have an ordering bug we can't cleanly resolve.

### 7.2 Backtrack B — Two-kernel build

`build.sh` produces `kernel.elf` (normal) and `kernel-r15-ring3.elf`
(witness variant with halt-on-marker). `run-smoke.sh` dispatches
based on mode. Requires a build-flag mechanism in paideia-as (or a
per-target kernel_main variant).

Downsides: build time roughly 2x for the r15 tempo; introduces
kernel-variant discipline that has to be maintained forever;
prevents any future "witness + continue" pattern from being simple.

Reject unless multiple future issues need the halt-on-witness
pattern; #652 alone does not justify it.

### 7.3 Backtrack C — Bundle GDT trampoline mapping (retire the concession now)

Fold `r15-m2-005b-gdt-trampoline-mapping` into #652: expand
`kpti_build_user_pml4` to map GDT/IDT/TSS/ISR-stub pages, relocate
the trampoline_vec* stubs into `.text.isr_trampoline`, teach
`_typed_handler_13`'s witness path to handle strict-KPTI CR3
flipping via the scratch frame. Estimated +250 LOC.

Reject as primary — pushes the milestone tempo and the GDT mapping
is architecturally its own thing. Retain as an option if the
reviewer wants the Meltdown-open concession retired now.

### 7.4 Backtrack D — `int3` instead of `hlt`

User `_start = 0xCC` (`int3`, unprivileged in ring-3, raises `#BP`
vector 3). Handler is `_typed_handler_3` → `handle_bp`. #BP is
architecturally cleaner (no privilege check needed — you can hit
`int3` from any CPL), so it doesn't demonstrate the "ring-3
privilege enforcement" property.

Reject — the *point* of #652 is to prove ring-3 CPL enforcement
fires. `hlt` in ring-3 raising `#GP` is a stronger witness than
`int3` in ring-3 raising `#BP`.

### 7.5 Backtrack E — Use loader / elf_lite instead of raw byte map

Instead of `phys_alloc + memset(0xF4)`, drop a tiny ELF into
`.rodata.userbin`, call `elf_lite_load(witness_pml4)` to install
segments, hand back an entry point. Uses the exact loader path
that shell demo will use.

Reject as primary — introduces a coupling to `elf_lite_load` (`#648`
still lists deferrals) and pulls in more substrate than the witness
needs. Retain as follow-up polish once `#648` retires.

### 7.6 Backtrack F — Ring-3 witness via `syscall` (deferred to #650)

User `_start` executes `syscall`; syscall entry emits marker.
Requires `sys_debug_puts` (#650) and MSR init already firing
correctly under strict-KPTI (which needs the GDT trampoline
mapping too). Strictly more substrate than #652 needs; deferred as
noted in `design/audit/entries/r15-m2-006-first-user-ret-target.md`.

Not a backtrack for *this* issue — different substrate goal. Track
under #650 + the shell-demo AC.

## 8. Tractability

**HIGH.** The whole issue is ~90 LOC of executable across two files
and one shell-script insertion:

- No new paideia-as encoder capability required. All addressing
  modes (`[rip + sym]`, `[reg + reg*8]`, `mov cr3, reg`, `iretq`,
  `swapgs`, `cli`, `hlt`) are exercised elsewhere in the kernel.
- No new IDT / TSS / GDT plumbing — the existing #GP vector, TSS
  RSP0, and trampoline_vec13 all work as-is under a Meltdown-open
  witness PML4.
- No new .rodata section — the hlt byte is a runtime allocation
  via existing `phys_alloc`.
- No new PT layout — `aspace_create` + `aspace_map` + `user_stack_alloc`
  are the existing substrate.
- Trap-frame surgery in `_typed_handler_13` is 20 LOC and
  parallels the well-understood "resume from fault" pattern used
  by Linux for signal delivery.
- Single-kernel invariant preserved — all existing smokes pass
  unchanged.
- Meltdown-open concession is explicit, documented, and filed as a
  separate follow-up (`r15-m2-005b`).

Known follow-ups (not blockers for #652):

- **`r15-m2-005b-gdt-trampoline-mapping`**: map GDT/IDT/TSS/ISR-stub
  pages in strict-KPTI user CR3 so `enter_userland_initial` can iretq
  under `aspace_create_user` PML4 without kernel-higher-half aliasing.
- **`r15-m2-006c-exception-swapgs-discipline`**: general "swapgs on
  ring-3 → ring-0 entry" pattern in all ISR stubs, not just the
  witness path. Currently the witness handles it locally.
- **#650**: `#UD` marker + iretq-back-to-caller, still valuable.
- **Runtime ELF-load witness**: once `#648` retires the
  `elf_lite_load` false-positive, swap the raw-byte witness for
  a real 1-instruction ELF payload.

## 9. Cross-cutting risks

- **Nested #GP during witness setup**: if `aspace_create` /
  `phys_alloc` / `aspace_map` / `user_stack_alloc` do something
  that faults, we hit `_typed_handler_13` before the flag is set —
  which correctly falls through to `call handle_gp; ret` (halt).
  Diagnosable via the halt-before-marker signal. No corruption
  risk.
- **Nested #GP during resume**: if the witness `swapgs / mov cr3 /
  mov rsp / jmp` sequence in `_typed_handler_13` faults (e.g.,
  bad `_kernel_resume_rip`), we recurse — but the flag has been
  cleared already, so the recursion halts on the second entry. No
  infinite loop.
- **Boot-time speculation leak**: with kernel higher-half in the
  witness PML4, ring-3 has ~150 ns before `#GP` fires during which
  speculative reads to kernel VAs are architecturally protected
  but observable via cache side-channels. Explicit concession,
  documented, retired by `r15-m2-005b`.
- **RSP0 correctness**: the witness assumes TSS.RSP0 points at a
  valid kernel stack. `tss_install` is called at line 83 of
  `kernel_main`, well before the witness. If TSS is misinstalled,
  the entire boot is broken already — orthogonal to #652.

## 10. References

- Issue: paideia-os#652
- Parent audit: `design/audit/entries/r15-m2-006-first-user-ret-target.md`
- Parent design: `design/kernel/r15-m2-005-followup-relocate-enter-userland.md`
  (#651 — relocate + CR3 flip)
- Sibling: `design/kernel/r14b-m4-006b-syscall-entry-cr3-ordering.md`
  (#645 — RW trampoline scratch slot)
- Primitive: `src/kernel/core/syscall/enter_user.pdx`
- #GP dispatch: `src/kernel/core/int/idt.pdx:155..172`
  (`trampoline_vec13`) + `src/kernel/core/int/exceptions.pdx:198..202`
  (`_typed_handler_13`)
- Witness PML4 builder: `src/kernel/core/mm/aspace_create.pdx:38..93`
  (`aspace_create`)
- User stack allocator: `src/kernel/core/mm/user_stack.pdx`
- User code page mapper: `src/kernel/core/mm/aspace_map.pdx`
- Intel SDM Vol 2A — HLT (ring-3 hlt → #GP)
- Intel SDM Vol 3A §6.13 — exception vector discipline
- Intel SDM Vol 3A §4.5 — 4-level paging (walker discipline)
