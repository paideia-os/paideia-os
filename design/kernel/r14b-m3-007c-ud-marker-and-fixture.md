---
issue: 650
parent: 644 (r14b-m3-007b-idt-full-vector-wiring — closed)
milestone: R14.M3 higher-half kernel VMA + linker VMA/LMA split
subsystem: 1 (higher-half) / 5 (ring-transition ABI) — cross-cutting
prereq:
  - #644 (IDT vec 6 wired to trampoline_vec6 → _typed_handler_6 → handle_ud)
  - #526 (enter_userland_initial primitive)
  - #651 (relocate enter_userland_initial + CR3 flip)
  - #652 (ring-3 witness — provides the witness PML4, user code page,
          user stack, and the trap-frame-surgery-plus-resume pattern
          this issue reuses)
  - #648 (elf_lite_load runtime witness — proves user pages are truly
          user-executable via the substrate this issue rides on top of)
blocks:
  - r14b shell-demo AC (needs the #UD marker discipline as a defensive
    guard against an unimplemented opcode in the shell binary — a
    triple-fault-on-#UD kernel cannot ship the demo)
touching:
  - src/kernel/core/int/exceptions.pdx (rewrite _typed_handler_6)
  - src/kernel/boot/kernel_main.pdx (extend #652 payload from 1 → 3
    bytes, arm _ud_witness_active flag, add global)
  - tools/boot_stub.S (2 new rodata strings)
  - tests/r14b/expected-boot-r14b-ud.txt (new)
  - tools/run-smoke.sh (new mode case)
  - design/kernel/r14b-m3-007c-ud-marker-and-fixture.md (this file)
---

# R14B-M3-007c — `handle_ud` marker + `boot_r14b_ud` fixture (#650)

## 1. Scope

Convert `handle_ud` (currently `exc_handle(EXC_UD) → cpu_halt`) into a
recoverable handler that (a) prints the marker `R14 UD OK\n` to serial
and (b) resumes execution rather than halting. Add a `boot_r14b_ud`
smoke mode whose fingerprint proves the marker fires, the kernel
continues booting, and every downstream witness (ring-3 hello, IPI,
loader, ELF-load) still lands.

This closes the defensive gap called out at
`design/audit/entries/r14b-m3-007-idt-vector-thunks-audit.md`
§ "Latent risk": before #644, 255/256 vectors offset=0 → triple-fault
on any non-timer exception. #644 wired the handler to
`trampoline_vec6 → _typed_handler_6 → handle_ud`, but `handle_ud`
still halts. Any accidental `ud2` (loader emitting an unimplemented
opcode, a corrupted user text page, a canary in a debugger stub)
kills the machine. #650 makes `#UD` a soft, recoverable, marked event.

The witness discipline chosen for this issue **mirrors #652**:

- User `_start` is now **3 bytes**: `0F 0B F4` — `ud2` followed by
  `hlt`. The same witness PML4, user code page, and user stack
  substrate that #652 built continue to serve; only the first-byte
  write changes.
- Ring-3 executes `ud2` → CPU raises `#UD` → vector 6 dispatches
  through `trampoline_vec6` → `_typed_handler_6`.
- Rewritten `_typed_handler_6` checks a new `_ud_witness_active` flag.
  If set: emit `R14 UD OK\n`, advance the trap-frame RIP by 2 (past
  the `0F 0B`), and return normally through the trampoline. The
  trampoline's existing `add rsp,16 ; iretq` epilogue resumes ring-3
  at RIP+2 — which is `hlt`. `hlt` in ring-3 raises `#GP`,
  `_typed_handler_13` fires the existing #652 resume path, and the
  kernel returns to `boot_continue_after_ring3`.
- New smoke mode `boot_r14b_ud` validates the extended fingerprint.

The chained-witness design costs **~60 LOC of executable/config** —
one handler rewrite, one payload byte change (1 → 3 bytes), one
flag-arm, two rodata strings, one smoke case, one fingerprint file.
No new aspace, no new CR3 discipline, no `boot_continue_after_ud`
extraction — a self-contained rider on the substrate #652 already
proved.

## 2. Prereq check

### 2.1 What's in place (post-#652)

- `_typed_handler_6` at `src/kernel/core/int/exceptions.pdx:186..190`:
  currently `{ call handle_ud; ret }` (3-LOC halt-on-fault wrapper).
  `handle_ud` at line 109 delegates to `exc_handle(EXC_UD)` which sets
  `last_vector` and halts via `cpu_halt`.
- `trampoline_vec6` at `src/kernel/core/int/idt.pdx:114..132`:
  non-errcode variant, pushes 0 placeholder + vector + 15 GPRs,
  `mov rdi, rsp ; call _typed_handler_6`, pops GPRs, `add rsp,16`,
  `iretq`. Frame-ptr `rdi` points at r15 slot; RIP is at `[rdi + 136]`
  (15 GPRs × 8 = 120, +vec 8 = 128, +errcode-placeholder 8 = 136).
  Identical to `_typed_handler_13`'s frame layout — same trap-frame
  surgery works.
- `_ring3_witness_active` flag + `_kernel_resume_rsp` + `_kernel_pml4_pa`
  globals: populated at boot by kernel_main and #652's witness block.
- Witness PML4 (from `aspace_create(_kernel_pml4_pa)`), user code page
  mapped at `0x400000` (currently 1 byte: `0xF4`), user stack at
  `0x7FFFFFFFF000`: all built by kernel_main lines 265..380. This
  design extends only the code-page write; the rest of the setup
  is reused byte-identically.
- `uart_puts` at `src/kernel/boot/uart.pdx:81..98`: clobbers only
  `rax, rcx, rsi, rdi`. Callee-saved `r12, r13, r14, r15, rbx, rbp`
  survive — safe to stash `frame_ptr` in `r12` across the marker
  print.

### 2.2 What's deferred (bundled vs. separate)

- **General "swapgs-on-ring-3→ring-0-entry" discipline for every ISR
  stub** (`r15-m2-006c-exception-swapgs-discipline`, still open):
  the trampoline stubs never `swapgs`. Under the Meltdown-open witness
  PML4 this issue rides, `IA32_GS_BASE = 0` on ring-3 entry (set by
  `enter_userland_initial`'s pre-iretq `swapgs`), the handler doesn't
  touch `[gs:...]`, and `iretq` to ring-3 leaves `GS_BASE` untouched.
  So the #UD handler works correctly without any local `swapgs`
  discipline of its own. When `r15-m2-006c` lands and unifies swapgs
  across ISR entry, the #UD handler participates automatically. **Do
  not bundle** — it is a cross-vector fix, not a #UD fix.
- **Strict-KPTI witness PML4** (`r15-m2-005b-gdt-trampoline-mapping`,
  still open): would map GDT/IDT/TSS/ISR-stub pages inside a
  `aspace_create_user` PML4 so ring-3 → ring-0 fault delivery does
  not rely on kernel-higher-half aliasing. #650 inherits #652's
  Meltdown-open concession one-for-one; the follow-up retires it for
  both witnesses simultaneously. **Do not bundle.**
- **`handle_ud`'s ring-0 recovery path** (the ring-0 `ud2` case —
  kernel code deliberately or accidentally executing `0F 0B` in
  ring-0): currently unreachable in production (kernel code never
  emits `ud2` outside `enter_user.pdx`'s post-iretq sentinel, which
  by construction can never execute). Documented backtrack §7.1;
  not required for #650's AC.

## 3. Design

### 3.1 High-level flow

```
kernel_main_64 (unchanged through line 262)
  ├── ... (uart, banner, KPTI, phys_free, kpti_scratch, enter_reloc)
  ├── R15-M2-006b (#652) ring-3 witness block:
  │     - save _kernel_resume_rsp
  │     - build witness PML4
  │     - alloc user code page, write 3 bytes: 0F 0B F4  <-- NEW
  │     - alloc user stack
  │     - arm _ring3_witness_active AND _ud_witness_active   <-- NEW
  │     - call enter_userland_initial → iretq → ring-3
  │
  │  ring-3 execution (this is the interesting part):
  │     RIP=0x400000: ud2 (0F 0B)  →  #UD  ─────────┐
  │     RIP=0x400002: hlt (F4)     →  #GP  ─────┐   │
  │                                             │   ↓
  │                                             │  _typed_handler_6 (NEW rewrite):
  │                                             │    - check _ud_witness_active
  │                                             │    - emit "R14 UD OK\n"
  │                                             │    - clear flag
  │                                             │    - advance [r12+136] by 2
  │                                             │    - ret → trampoline iretq
  │                                             │    - ring-3 resumes at RIP+2
  │                                             ↓
  │                                          _typed_handler_13 (unchanged, #652):
  │                                            - check _ring3_witness_active
  │                                            - emit "R15 RING3 HELLO OK\n"
  │                                            - swapgs / mov cr3 / mov rsp
  │                                            - call boot_continue_after_ring3
  │
  └── boot_continue_after_ring3 (unchanged): IPI, LOADER, ELF, TaskA.
```

Two witnesses, one ring-3 traversal, one substrate build. Every marker
that shipped with #652 continues to fire in the same order; `R14 UD OK`
appears once, between `R15 ENTER RING3` (kernel_main line 383) and
`R15 RING3 HELLO OK` (from `_typed_handler_13`).

### 3.2 `_typed_handler_6` — trap-frame surgery to advance past `ud2`

The `ud2` opcode is exactly **2 bytes**: `0F 0B`. Intel SDM Vol 2A
UD2: "Generates an invalid opcode exception. This instruction is
provided for software testing to explicitly generate an invalid opcode
exception. Behavior in all other ways is identical to executing any
undefined instruction." `#UD` is a *fault*, so the CPU-pushed RIP
points at the `ud2` byte, not past it (Intel SDM Vol 3A §6.5,
"Faults: The saved instruction pointer points to the instruction that
caused the fault"). Advancing that RIP by 2 makes `iretq` land at
`hlt`.

`trampoline_vec6` frame layout on entry to `_typed_handler_6`:

```
rdi = rsp at the point of `mov rdi, rsp` in the trampoline
[rdi +   0 ..  +112]:  r15, r14, r13, r12, r11, r10, r9, r8,
                       rdi, rsi, rbp, rbx, rdx, rcx, rax   (15 × 8 = 120 B)
[rdi + 120]         :  vector (6)
[rdi + 128]         :  errcode placeholder (0 — #UD has no errcode)
[rdi + 136]         :  CPU-pushed RIP        ← advance by 2
[rdi + 144]         :  CPU-pushed CS
[rdi + 152]         :  CPU-pushed RFLAGS
[rdi + 160]         :  CPU-pushed user-RSP (ring-3 origin)
[rdi + 168]         :  CPU-pushed user-SS   (ring-3 origin)
```

The `_typed_handler_13` layout at `[rdi + 136]` for RIP is identical
(vector 13 is errcode-variant but the trampoline still pushes vector
LAST, so the same offset holds — see `trampoline_vec13` at idt.pdx:160).
Same offset math for both handlers is a substrate invariant worth
naming: **all IDT trampolines land in `_typed_handler_N` with
`[frame_ptr + 136] = CPU-pushed RIP`.**

Rewritten `_typed_handler_6` (mirrors `_typed_handler_13`'s check-flag
pattern):

```asm
; Save frame_ptr in callee-preserved r12 (survives uart_puts, which
; clobbers only rax/rcx/rsi/rdi per uart_puts's implementation).
mov r12, rdi;

; Ring-3 UD witness path: check flag first.
lea rax, [rip + _ud_witness_active];
mov rax, [rax];
cmp rax, 1;
jne typed6_normal_ud;

; One-shot: clear the flag so subsequent #UDs halt normally.
lea rax, [rip + _ud_witness_active];
mov rcx, 0;
mov [rax], rcx;

; Emit witness marker.
lea rdi, [rip + ud_witness_ok_msg];
call uart_puts;

; Advance the CPU-pushed RIP past the 2-byte ud2 opcode.
; r12 still holds frame_ptr (uart_puts preserved it — SysV callee-save).
mov rax, [r12 + 136];
lea rax, [rax + 2];
mov [r12 + 136], rax;

; Return to trampoline_vec6, which pops 15 GPRs, adds rsp by 16
; (discards vector+errcode-placeholder), iretq's back to ring-3 at
; the new RIP (= original + 2), which is the hlt byte. Ring-3 then
; raises #GP and _typed_handler_13's #652 witness path finishes the
; run.
ret;

; --- Normal path (unchanged: halt) ---
typed6_normal_ud:
call handle_ud;
ret
```

**Encoder discipline** — every operand form used here is exercised
elsewhere in the kernel:

| Instruction                     | Precedent                           |
|---------------------------------|-------------------------------------|
| `mov r12, rdi`                  | `_typed_handler_13` uses r12 across `uart_puts` implicitly via return |
| `lea rax, [rip + sym]` (32-bit) | `_typed_handler_13:207` and dozens more |
| `mov rax, [rax]` (deref)        | `_typed_handler_13:208` |
| `cmp rax, imm8`                 | `_typed_handler_13:209` |
| `jne label`                     | `_typed_handler_13:210` |
| `mov [rax], rcx`                | `_typed_handler_13:219` |
| `call sym`                      | ubiquitous |
| `mov rax, [r12 + 136]`          | `handle_timer:148` (`mov rax, [rdi + 172]`) |
| `lea rax, [rax + 2]`            | `handle_timer:149` (`lea rcx, [rax - 1]`) |
| `mov [r12 + 136], rax`          | `handle_timer:150` (`mov [rdi + 172], rcx`) |

No new paideia-as encoder capability required.

**Why `r12`?** SysV AMD64 ABI §3.2.1 marks `rbp, rbx, r12..r15` as
callee-saved. `uart_puts` is a `pub` function and paideia-as emits
SysV-conforming prologues/epilogues; it uses only `rax, rcx, rsi, rdi`
in its actual body (Uart module lines 84..96), all caller-saved. r12
is a safe stash. If a future `uart_puts` rewrite introduces r12 use,
that rewrite must respect SysV — no additional discipline burden
falls on this handler.

**Why not stash `frame_ptr` in memory?** Would require a new
`.data` global (e.g. `_ud_frame_scratch`) — one extra rip-relative
load/store pair, more state, no benefit. Register stash is idiomatic
(Linux's `do_invalid_op` in `arch/x86/kernel/traps.c` uses a stack
frame and pt_regs* passed through argument slot; the shape is
morally the same).

### 3.3 User `_start` payload — 3 bytes

Kernel_main's #652 witness block currently writes one byte (`0xF4`)
into the user code page at `[r13]` (line 328..329):

```asm
mov rax, 0xF4;
mov [r13], al;                           // write hlt byte
```

Extended to write three bytes: `0F 0B F4` (ud2 then hlt). Options:

**Option 1 (chosen) — three single-byte writes**:

```asm
mov rax, 0x0F;
mov [r13], al;                           // ud2 byte 1
mov rax, 0x0B;
mov [r13 + 1], al;                       // ud2 byte 2
mov rax, 0xF4;
mov [r13 + 2], al;                       // hlt
```

Precedent: matches the existing single-byte-store pattern (line 329)
byte-for-byte. No new encoder form.

**Option 2 (rejected) — one 24-bit write via `mov [r13], eax`**:

```asm
mov rax, 0x00F40B0F;                     ; F4 0B 0F 00 in memory (LE)
mov [r13], eax;                          ; 32-bit store overwrites 4 bytes
```

Rejected: writes a stray `0x00` at `[r13+3]` (harmless — page is
zero-init from `phys_alloc`, but the extra byte is a supply of noise
in the code page). Also, `mov [reg], eax` (32-bit store) hasn't been
audited on this path — Option 1 uses only patterns already exercised.

**Frame allocation for the code page is unchanged** — still one
`phys_alloc(0)` call, still mapped at `0x400000` with `U|P` (X=1 via
NX=0). The extra 2 bytes fit trivially in the 4 KiB frame.

### 3.4 Kernel state coordination

One new global in `kernel_main.pdx`, sibling to `_ring3_witness_active`:

```pdx
pub let mut _ud_witness_active : u64 = 0
```

Placed adjacent to the existing `_ring3_witness_active` and
`_kernel_resume_rsp` at the module tail (currently kernel_main.pdx:577..578).

Both flags are armed together in kernel_main's witness setup, right
before `call enter_userland_initial` (currently line 377..379):

```asm
// 5. Arm the witness flags (read by _typed_handler_6 and _typed_handler_13).
mov rax, 1;
lea rcx, [rip + _ring3_witness_active];
mov [rcx], rax;
lea rcx, [rip + _ud_witness_active];       // NEW
mov [rcx], rax;                            // NEW
```

The two flags MUST both be armed before iretq — arming them one-at-a-
time would be racy against a spurious NMI (which the Meltdown-open
concession explicitly does not rule out; see #652 §4.3). Batched arm
inside a `cli`-still-held window is defensive; `enter_userland_initial`
does `cli` before `iretq`, so the arm happens with interrupts
enabled but before the ring-3 window opens.

**No cross-module coupling risk** — both flags are `pub let mut`
top-level in kernel_main; `_typed_handler_6` and `_typed_handler_13`
reference them via `lea [rip + sym]`, the standard cross-module ELF
symbol resolution pattern that #652 already proved.

### 3.5 New rodata strings

Two additions to `tools/boot_stub.S` (append after the existing
`ring3_hello_ok_msg` block at line 297..299):

```asm
# R14B-M3-007c (#650): #UD witness success message.
.global ud_witness_ok_msg
.align 8
ud_witness_ok_msg: .ascii "R14 UD OK\n\0"

# R14B-M3-007c (#650): #UD witness failure message (armed but not fired).
.global ud_witness_fail_msg
.align 8
ud_witness_fail_msg: .ascii "R14 UD FAIL\n\0"
```

`ud_witness_fail_msg` is currently unreferenced — reserved for a
future kernel-side "expected UD, didn't fire" check (would require
distinguishing "flag still set at boot_continue_after_ring3 entry"
= handler never ran; see §7.3 backtrack C). Kept in the initial
landing so a future revision does not need to touch the boot stub
again.

**Naming discipline**: `R14 UD OK` uses the "R14" prefix rather than
"R15" to match the issue's milestone bucket (R14.M3). The marker is a
substrate discipline witness, not a ring-3 semantics witness — it
belongs to the IDT-vector-thunks family alongside `KPTI OK`, `IPI OK`,
`LOADER OK`, `HI VA FFFF8000`. The "R15 RING3 HELLO OK" phrasing is
reserved for the ring-3-CPL-enforcement witness proper.

### 3.6 CR3 / GS / RSP discipline

Nothing changes vs. #652. The #UD handler:

- Enters with CR3 = witness PML4 (unchanged from ring-3), which has
  kernel higher-half mapped (kernel .rodata for the marker string,
  kernel .text for `uart_puts` and the handler code itself, TSS/GDT
  descriptors — all resolvable). No `mov cr3` in the #UD path.
- Enters with `IA32_GS_BASE` = 0 (ring-3's post-`swapgs` value). Does
  not touch `[gs:...]`. Does not `swapgs`. Returns via trampoline
  `iretq` back to ring-3 with the same GS_BASE.
- Uses RSP0 (per-TSS.RSP0) as its stack. The trampoline's 15-GPR
  push + return-address push land on RSP0, get popped cleanly on
  the epilogue. No `mov rsp` in the #UD path.

The #GP handler that follows (the existing `_typed_handler_13`) is
the one that actually flips CR3 back to `_kernel_pml4_pa`, restores
`_kernel_resume_rsp`, and calls `boot_continue_after_ring3`. The
#UD path is architecturally a "read-only" pass through ring-0: it
observes the fault, marks the trace, and steps ring-3 forward.

This asymmetry — #UD handler resumes ring-3, #GP handler resumes
ring-0 — is deliberate and mirrors real-world OS discipline. Linux's
`do_invalid_op` (`arch/x86/kernel/traps.c`) similarly resumes user
context; only fatal faults (double-fault, unrecoverable page fault
in kernel context) do the "abandon frame, resume kernel" dance.

### 3.7 Interaction with #648 (elf_lite_load runtime witness)

#648 already runs at `boot_continue_after_ring3:507..522` — after the
ring-3 witness resumes. If #650 lands cleanly, the #UD witness fires
first (during the ring-3 traversal, at kernel_main line 395), the
#GP witness fires second, `boot_continue_after_ring3` runs the IPI
structural witness (line 459..477), then the loader structural witness
(482..499), then the ELF-load runtime witness (507..523). No ordering
change; #650 slots strictly before #648 with the same substrate.

If #650 lands *cleanly* but #648 regresses, that is a signal of a
substrate bug in the #UD → #GP handoff (e.g., trap-frame RIP advance
landed at the wrong offset, ring-3 resumed at a random RIP, kernel
saw a mystery fault). Diagnosable via the fingerprint:
`R14 UD OK` present + `R15 RING3 HELLO OK` absent → the #UD handler
worked but iretq to ring-3 landed at the wrong place. Do not touch
the fingerprint to hide the signal.

## 4. Test canary

### 4.1 Smoke mode: `boot_r14b_ud` (new)

New case in `tools/run-smoke.sh` (~7 LOC after the existing
`boot_r15_ring3` block at line 117..122):

```bash
boot_r14b_ud)
    FINGERPRINT_MODE=1
    FINGERPRINT_FILE="${REPO_ROOT}/tests/r14b/expected-boot-r14b-ud.txt"
    TIMEOUT=6
    EXPECTED=""
    ;;
```

6-second timeout matches `boot_r15_ring3` — same substrate, same
timing envelope.

### 4.2 Fingerprint file (new)

`tests/r14b/expected-boot-r14b-ud.txt`:

```
B
HI VA FFFF8000
PaideiaOS R8
PHYS FREE ROUNDTRIP OK
KPTI OK
KPTI SCRATCH OK
ENTER USER RELOC OK
R14 UD OK
R15 RING3 HELLO OK
IPI OK
LOADER OK
ELF LOAD OK
```

The `R14 UD OK` line proves the #UD handler ran and the marker
emitted. The `R15 RING3 HELLO OK` line immediately after proves
that the iretq back to ring-3 landed correctly and the second
fault (in ring-3) fired the #GP witness path. `IPI OK` / `LOADER
OK` / `ELF LOAD OK` prove the kernel resumed cleanly and the rest
of the boot ran to completion.

### 4.3 Existing fingerprints — no drift required

Contains-in-order matching absorbs the extra `R14 UD OK` line
transparently:

- `tests/r15/expected-boot-r15-ring3.txt`: has `ENTER USER RELOC OK`
  and `R15 RING3 HELLO OK` — the new `R14 UD OK` slot in between is
  ignored.
- `tests/r14b/expected-boot-r14b-kpti.txt`, `-ipi.txt`, `-loader.txt`,
  `-hivma.txt`, `tests/r10/expected-boot-r10.txt`, `r11`, `r12`,
  `r12-denial`: all check for markers before the ring-3 witness fires
  (or entirely orthogonal markers). Unaffected.

Any smoke that regresses is a signal of a real bug — do not touch the
fingerprints to hide it.

### 4.4 Objdump / structural discipline (optional)

Suggested manual checks while implementing (not required to land as
a script):

```bash
# 1. Global armed and readable.
nm build/kernel.elf | grep '_ud_witness_active'    # non-empty

# 2. Marker string present.
strings build/kernel.elf | grep 'R14 UD OK'        # exactly one hit

# 3. _typed_handler_6 contains the flag-check + RIP-advance pattern.
objdump -d build/kernel.elf | \
  sed -n '/<_typed_handler_6>:/,/^$/p' | \
  grep -E 'lea.*_ud_witness_active|\[.*136\]'      # both patterns present

# 4. User code page write emits three bytes.
objdump -d build/kernel.elf | \
  sed -n '/<kernel_main_64>:/,/<boot_continue_after_ring3>:/p' | \
  grep -c 'mov \[r13'                              # >= 3 (three byte writes)
```

### 4.5 Ring-3 execution proof (belt-and-braces)

The `boot_r14b_ud` fingerprint proves, in one atomic run:

1. Ring-3 was actually entered (`ENTER USER RELOC OK` from #651's
   pipeline; `R14 UD OK` requires ring-3 executing at 0x400000).
2. The `#UD` vector specifically was dispatched (`R14 UD OK`
   appears — a #PF or #GP at ring-3 entry would not produce it).
3. The #UD handler restored ring-3 correctly (`R15 RING3 HELLO OK`
   follows — proves iretq landed at RIP+2 = hlt, not at a random
   RIP that would have raised a further #UD or #PF).
4. Kernel resumed cleanly from the #GP handler (`IPI OK`, `LOADER
   OK`, `ELF LOAD OK` all appear in canonical order).

Together this is a complete witness of the #UD substrate: dispatch,
mark, resume. No `sys_debug_puts` required.

## 5. LOC estimate

| File                                                        | LOC delta |
|-------------------------------------------------------------|-----------|
| `src/kernel/core/int/exceptions.pdx` (`_typed_handler_6`)   | +25       |
| `src/kernel/boot/kernel_main.pdx` (payload + flag + global) | +12       |
| `tools/boot_stub.S` (2 rodata strings)                      | +10       |
| `tests/r14b/expected-boot-r14b-ud.txt` (new fingerprint)    | +12       |
| `tools/run-smoke.sh` (new mode case)                        | +7        |
| `design/kernel/r14b-m3-007c-ud-marker-and-fixture.md`       | +380      |
| **Total**                                                   | **~446**  |

Executable/config: **~66 LOC**. Design + fingerprint: ~380 LOC.

Substantially smaller than #652 (~90 LOC executable) — this issue is a
rider on the substrate #652 built, not a fresh substrate stack.

## 6. Tractability

**HIGH.** All new mechanism is a small delta on top of proven
substrate:

- No new paideia-as encoder capability. Every operand form is
  exercised elsewhere in the kernel (§3.2 encoder table).
- No new aspace / phys_alloc / user_stack machinery. Reuses #652's
  witness PML4 verbatim.
- No new CR3 / GS / RSP discipline for the #UD path. Handler is a
  pure trap-frame-RIP-advance, mirroring Linux's `do_invalid_op`
  shape.
- No cross-cutting changes to `boot_continue_after_ring3` or its
  extraction into further sub-functions. Single-kernel invariant
  preserved verbatim.
- Backwards-compatible with every existing smoke fingerprint via
  contains-in-order absorption.
- Diagnostic value is inherent — a broken RIP advance shows up as
  a distinctive fingerprint delta (`R14 UD OK` present +
  `R15 RING3 HELLO OK` missing), not a mystery hang.

Known follow-ups (not blockers for #650):

- **`r15-m2-005b-gdt-trampoline-mapping`**: retires the Meltdown-open
  witness PML4 concession that #650 inherits from #652. When it lands,
  both witnesses (this and #652) swap to a strict-KPTI PML4 in the
  same PR.
- **`r15-m2-006c-exception-swapgs-discipline`**: unifies swapgs across
  every ISR trampoline. Retires the "handler happens to not touch GS"
  invariant that #650 currently rides.
- **Ring-0 `handle_ud` recovery** (§7.1): a real production kernel
  wants `ud2` in ring-0 to also be recoverable (for BUG_ON()-style
  discipline). Defer until a caller wants it.
- **`ud_witness_fail_msg` consumer** (§7.3): a "witness armed but
  never fired" self-check on the kernel side. Defer until we have a
  witness-integrity discipline pattern shared across all witnesses.

## 7. Backtrack candidates

Ordered by preference.

### 7.1 Backtrack A — Ring-0 `ud2` fixture (skip ring-3 entirely)

Insert `ud2` at a labelled point in `kernel_main_64` (ring-0). Handler
does the same trap-frame RIP advance and iretq's back to ring-0. No
CR3, no aspace, no ring-3 traversal.

Pros: ~30 LOC total, no coupling to #652's ring-3 witness, works
even if #652 is disabled or regresses.

Cons: doesn't exercise the ring-3 → ring-0 fault-delivery path that
this milestone's discipline is about. The whole point of #644's
"latent risk" was ring-3-produced #UD triple-faulting; a ring-0
witness misses that shape.

**Reject as primary** — the ring-3 witness is the substrate this
issue's AC lives in. Retain as a fallback if the ring-3 RIP-advance
turns out to have a subtle iretq-back-to-ring-3 bug we can't cleanly
resolve. (In that fallback, `_typed_handler_6`'s witness path becomes
"emit marker, advance RIP, iretq back to ring-0", and kernel_main gets
a `ud2` sentinel at a labelled point BEFORE the #652 witness setup —
so #650 lands independently of #652 in the boot order.)

### 7.2 Backtrack B — Separate `boot_continue_after_ud` (mirror #652 more literally)

Instead of returning through the trampoline's iretq back to ring-3,
have `_typed_handler_6` do the same swapgs / mov cr3 / mov rsp /
call-boot_continue dance as `_typed_handler_13`. Requires extracting
a `boot_continue_after_ud` from the head of `boot_continue_after_ring3`
(paideia-as can't `lea` a bare local label; see #652 §3.4
justification).

Pros: symmetric with #652 — same "abandon frame, resume kernel"
pattern.

Cons: ~130 LOC delta (vs ~65 for the chained variant), requires
splitting `boot_continue_after_ring3` and introducing a second
kernel-tail continuation function. Doesn't exercise `iretq` back to
ring-3 — a substrate we WANT proven for the future syscall path.

**Reject as primary** — chained variant delivers a stronger witness
(iretq round-trip through ring-3 twice) at lower LOC cost.

### 7.3 Backtrack C — Add witness-integrity self-check

After the ring-3 witness resumes into `boot_continue_after_ring3`,
inspect `_ud_witness_active`: if still `1`, the #UD handler never
fired → emit `R14 UD FAIL\n`. This closes a subtle observability
gap: if the #UD handler is silently skipped (e.g., a bad flag
encoding, cross-module linkage broken), the smoke would only fail
via the *absence* of `R14 UD OK`, not via a positive signal.

Pros: stronger negative-space discipline, positive failure marker.

Cons: adds ~15 LOC to `boot_continue_after_ring3`, requires
plumbing the fail branch into the fingerprint discipline (do we
add a `boot_r14b_ud_fail` smoke that verifies FAIL fires when we
deliberately break the handler? Overkill for #650's AC).

**Reject as primary** — cleanup issue for later once we accumulate
enough witnesses to warrant a shared witness-integrity discipline.
`ud_witness_fail_msg` is landed in the boot stub anyway so the future
implementation of this backtrack does not need to touch `tools/boot_stub.S`.

### 7.4 Backtrack D — Payload via loader (`elf_lite_load` a ud2 stub)

Instead of runtime-writing 3 bytes into `phys_alloc`'d page,
embed a minimal ELF binary containing `ud2` at its entry point into
`.rodata.userbin` (mirroring `_shell_bin`) and call `elf_lite_load`
to install it. Uses the real loader substrate.

Pros: exercises the full loader path end-to-end, produces an ELF
witness for the shell-demo AC to reuse.

Cons: adds ELF-blob production tooling to paideia-as (or a
hand-assembled `.rodata` section), pulls in coupling to `_shell_bin`
naming discipline, ~40 LOC extra. Overkill for a #UD marker witness.

**Reject as primary** — retain as a future polish once we want a
canonical library of user-witness ELF stubs (`shell_bin`, `ud_bin`,
`syscall_bin`, etc.).

### 7.5 Backtrack E — Chain the witness via `int 6` instead of `ud2`

Software-generated `#UD` via `int 6` (opcode `CD 06`). Non-privileged
in ring-3 only if IDT gate DPL=3; current gate DPL=0, so `int 6` from
ring-3 would raise `#GP(6*8+2)` instead of dispatching to vec 6.

Pros: none for this issue.

Cons: requires opening the gate DPL, which is a real security
regression. `ud2` is the canonical software `#UD` primitive and does
not require any IDT-gate change.

**Reject** — `ud2` is architecturally correct; `int 6` is not
equivalent.

### 7.6 Backtrack F — Fold #650 into #652 retroactively

Since the chained-witness design is a small delta on #652's substrate,
one could argue for cherry-picking #650 into #652's original PR
history. Not applicable — #652 has landed. This backtrack is only for
posterity: future substrate additions of this kind (small handler +
marker + fingerprint deltas on top of an existing witness PML4) may
land inline with the parent witness rather than as separate issues.

Not a backtrack for #650 as currently posed.

## 8. Cross-cutting risks

- **Nested #UD during handler**: if the handler itself accidentally
  hits a `ud2` (e.g., a corrupted `uart_puts` linkage), we re-enter
  `_typed_handler_6` with the flag cleared (from the one-shot
  clear at the top of the witness path). Second entry takes the
  `typed6_normal_ud` branch → `handle_ud` → `cpu_halt`. No recursion,
  no corruption.
- **Nested #UD during ring-3 resume**: the ring-3 RIP+2 lands at
  `hlt` (`F4`). If the RIP advance is off (e.g., we advance by 1
  instead of 2), ring-3 resumes at `0B F4`, which decodes as
  `or [rax], al` (2 bytes), then `hlt`. That's a #PF (writing via
  rax=0 in ring-3 → null-page), not a #UD — the smoke would show
  `R14 UD OK` present, `R15 RING3 HELLO OK` absent, kernel hung
  in an unmapped #PF handler. Diagnosable, not corrupting.
- **Handler runs but marker omitted**: if `uart_puts` fails silently,
  `R14 UD OK` never appears in the log but the ring-3 witness still
  completes normally. Smoke fails with "line 8 not found"; not a
  silent pass.
- **RSP0 correctness**: same substrate assumption as #652 §9. TSS is
  installed at kernel_main line 83; if broken, entire boot is dead
  before this witness reaches.
- **Boot-time speculation leak**: unchanged from #652. Meltdown-open
  witness PML4 is present during the ring-3 traversal (~250 ns for
  ud2 → #UD → RIP advance → iretq → hlt → #GP). Retired by
  `r15-m2-005b`.

## 9. References

- Issue: paideia-os#650
- Parent issue: paideia-os#644 (IDT full vector wiring)
- Parent audit: `design/audit/entries/r14b-m3-007-idt-vector-thunks-audit.md`
- Sibling design (mirrored): `design/kernel/r15-m2-006b-boot-r15-ring3-hello.md`
  (#652 — ring-3 hello witness, provides the substrate this issue rides)
- Handler tables: `src/kernel/core/int/exceptions.pdx:186..190`
  (`_typed_handler_6` — current 3-LOC halt wrapper being rewritten),
  `src/kernel/core/int/exceptions.pdx:198..250` (`_typed_handler_13` —
  the design pattern being mirrored)
- Trampoline: `src/kernel/core/int/idt.pdx:114..132` (`trampoline_vec6`)
- Payload substrate: `src/kernel/boot/kernel_main.pdx:262..410` (#652 witness)
- Continuation: `src/kernel/boot/kernel_main.pdx:438..572`
  (`boot_continue_after_ring3` — unchanged by this issue)
- Rodata strings: `tools/boot_stub.S:88..340`
- Intel SDM Vol 2A — UD2 (opcode 0F 0B; raises #UD)
- Intel SDM Vol 3A §6.5 — Fault vs Trap RIP semantics
  (#UD is a fault; RIP points at the faulting instruction)
- Intel SDM Vol 3A §6.13 — Vector 6 (#UD) dispatch
- Linux `arch/x86/kernel/traps.c` `do_invalid_op` — precedent for
  the trap-frame-modify-and-return pattern
