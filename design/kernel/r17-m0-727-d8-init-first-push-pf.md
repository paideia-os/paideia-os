# r17-m0-727-d8 — init's first post-fork user-stack push #PF (blocks #723 AC)

**Issue:** paideia-os #727 (aka #724 D8)
**Status:** landed
**Blocks:** #723 (init reaches shell prompt)
**Commit:** see git log — "Fix #727 (#724 D8): ..."

## Symptom on wire (baseline before this fix)

```
INIT BOOT OK
INIT ENTERED RING3
0000000015ce635e|0|P|INT_|EXC HALT
```

Init's very first ring-3 emission (the `sys_debug_puts("INIT ENTERED RING3\n")`
call at `_start`'s entry) succeeds. Every subsequent instruction faults with

```
v=0e e=0007 IP=0x4000d4 CR2=0x7fffffffeff8
```

Decoding:
- `v=0e` = #PF.
- `e=0x07` = P=1, W=1, U=1 (page IS present, write denied to user).
- `IP=0x4000d4` = `call sys_debug_puts` in init's PARENT branch, printing
  "INIT OK" after `sys_fork` returns child_pid (per `objdump -d init.elf` —
  see below).
- `CR2=0x7fffffffeff8` = `rsp - 8` for a push, with `rsp = 0x7ffffffff000`
  (the user stack top). The faulting page is at `0x7ffff_fffe_000`.

## What actually happens

`objdump -d init.elf`:

```
000000000040005b <_start>:
  40005b:  lea    0x22e(%rip),%rdi        # 400290 <entered_msg>
  400062:  mov    $0x13,%rsi
  400069:  call   4001fd <sys_debug_puts>      ; INIT ENTERED RING3 — WORKS
  40006e:  ...   sys_open, dup2 x3, close
  4000b4:  call   40021b <sys_fork>            ; parent gets child_pid, child gets 0
  4000b9:  mov    %rax,%r12
  4000bc:  cmp    $0x0,%rax
  4000c0:  je     4000de <_start+0x83>          ; child branch
  4000c6:  lea    0x19d(%rip),%rdi        # 40026a <init_msg>
  4000cd:  mov    $0x8,%rsi
  4000d4:  call   4001fd <sys_debug_puts>      ; parent's INIT OK — FAULTS
```

Between the first working `call sys_debug_puts` at `0x400069` and the faulting
one at `0x4000d4` sits exactly one `call sys_fork`. That call transits into
`sys_fork_body`, which invokes `aspace_clone_cow(parent_pml4, child_pml4)`
(see `src/kernel/core/mm/aspace_clone.pdx`). `aspace_clone_cow`'s L4 leaf loop
does, for every present user-half PTE in the parent's aspace:

```
// L4 leaf @ aspace_clone.pdx:186-199
mov r11, 0x8000000000000FFF;   // PTE_FLAGS_MASK
mov rdx, rax;
and rdx, r11;                  // preserved_flags
mov r11, 0xFFFFFFFFFFFFFFFD;   // ~PTE_RW
and rdx, r11;                  // rdx = preserved_flags & ~PTE_RW  ← strips RW
or  rdx, 0x200;                // rdx |= PTE_COW                    ← sets CoW
...
mov [r10 + rbx*8], rax;        // rewrite src PTE in place (RO+COW)
```

So immediately after `sys_fork` returns, every user page in the parent's
aspace — including the four stack pages mapped by `user_stack_alloc` at
`[0x7ffff_fffb_000, 0x7ffff_ffff_000)` — has PTE = present + read-only + CoW.
The parent's next user write (the RA push inside `call sys_debug_puts` at
`0x4000d4`, which decrements `rsp` from `0x7ffff_ffff_000` to `0x7ffff_fffe_ff8`
and stores the return address) hits the RO PTE with `CR0.WP=1` and raises
#PF with err = 0x07.

That #PF is exactly the CoW-fault trigger the design intended. But the CoW
handler never runs. Instead we get `EXC HALT`.

## Root cause (three defects in one hop)

The reason `EXC HALT` appears despite pf_handle_cow existing and working is
a three-layer collapse:

### Defect 1 (primary) — `_typed_handler_14` gated CoW dispatch on a witness flag

In `src/kernel/core/int/exceptions.pdx` the vector-14 typed handler was
written for the R14b-M5-008 CoW witness at kernel_main:1200-1334. It only
called `pf_handle_cow` when `_cow_witness_active == 1`:

```
// pre-#727 exceptions.pdx L316-345
lea rax, [rip + _cow_witness_active];
mov rax, [rax];
cmp rax, 1;
jne typed14_normal_pf;               // ← falls straight to handle_pf → EXC HALT

mov rdi, r12;
call pf_handle_cow;
...
```

`_cow_witness_active` is only ever set inside the boot-time witness block
that verifies pf_handle_cow's fast-flip path, then immediately cleared. It
was NEVER set for production ring-3 faults. Every real #PF from user space
therefore skipped `pf_handle_cow` entirely and went straight to
`handle_pf → exc_handle → klog_panic` = **EXC HALT**.

This is the immediate reason init's `INIT OK` push never survived.

### Defect 2 (would have surfaced next) — `pf_handle_cow` reads live CR3

Even had defect 1 been fixed, `pf_handle_cow` walks page tables rooted at
whatever CR3 currently holds:

```
// pre-#727 pf_handler.pdx L87-90
mov rax, cr3;
and rax, 0xFFFFFFFFFFFFF000;
mov rcx, 0xFFFF800000000000;
add rax, rcx;                    // rax = PML4 virtual address
```

Under strict KPTI (post-#720/#721), the ring-3 → ring-0 exception dispatch
runs `_isr_stub_14`, which **flips CR3 to `_kernel_pml4_pa`** on entry when
the fault came from CPL=3:

```
// src/kernel/core/int/isr_trampoline.pdx L164-177
mov [rip + _isr_scratch_rax], rax;
mov rax, [rsp + 16];
and rax, 3;
je stub14_kernel;
swapgs;
mov rax, cr3;
mov [rip + _user_cr3_save], rax;
mov rax, [rip + _kernel_pml4_pa];
mov cr3, rax;                      // ← CR3 becomes kernel_pml4 before pf_handle_cow runs
```

So by the time `pf_handle_cow` executes, CR3 = kernel_pml4_pa. The kernel
PML4 is the boot PML4: identity-maps [0, 4 GiB) with huge pages (PS=1) via
PML4[0]/PDPT[0], and higher-half kernel via PML4[256]. **It has NO
per-process user PTEs** for PML4[1..255]. Walking user VA 0x7fff_ffff_eff8
under kernel PML4 lands on PML4[255] (empty in kernel PML4) → pf_handle_cow
rejects at `pf_cow_err_pml4` (PML4 !PRESENT) → KILL → EXC HALT.

Note the boot witness (kernel_main.pdx:1200-1334) is a **ring-0** write
into an aliased WITNESS_VA installed directly in `_kernel_pml4_pa`, so its
CR3-read happens to point at the right PML4 (kernel_pml4, which has the
witness mapping). That's why the witness passed unchanged before #727 —
its aspace and pf_handle_cow's CR3-read matched by construction.

### Defect 3 (latent) — leaf-frame PA mask leaves NX bit in

Even had defects 1 and 2 been fixed, the leaf-PTE frame-address extraction
in `pf_handle_cow` uses the wrong mask:

```
// pre-#727 pf_handler.pdx L189
mov rax, r15;                    // r15 = leaf PTE
and rax, 0xFFFFFFFFFFFFF000;     // ← mask keeps bits 12..63, INCLUDING bit 63 (NX)
mov rdi, rax;                    // frame_pa → rdi for frame_meta_get
call frame_meta_get;             // rax = refcount
```

`0xFFFFFFFFFFFFF000` is `bits 12..63 set`. But the leaf PTE frame field is
bits **12..51 only** (40 bits per Intel SDM Vol 3A §4.5, "M-1 downto 12"
with M=52 on x86_64). Bit 63 is the XD/NX flag. Every user page mapped by
`user_stack_alloc` (and `elf_lite_load`'s non-executable segments) is
tagged NX per `USTACK_FLAGS = 0x8000000000000007`, so the leaf PTE has
bit 63 = 1. The wrong mask therefore leaks NX into `rax`.

`frame_meta_get`'s normalize step (`frame_meta.pdx:151-155`) treats any
address ≥ `0xFFFF800000000000` as an already-normalized VA. `rax` with
just bit 63 set (0x8000_0000_XXXX_X000) is **less than** `0xFFFF800000000000`
(bits 63..48 = 0x8000 vs 0xFFFF) — so `jae` is NOT taken, we fall into the
`add` branch which pushes rdi to `0x7FFF_800X_XXXX_X000` (a huge unsigned
value, wraps modulo 2^64 to a bogus "VA"), then subtracts
`_phys_page_pool` VA which sends us far past the 4 MiB pool extent →
`fmi_invalid` → returns `FRAME_META_INVALID` (0xFFFFFFFFFFFFFFFF).

Back in `pf_handle_cow`, that sentinel triggers `pf_cow_err_refcount` →
KILL → EXC HALT. Wire trace with `_cow_witness_verbose=1` after defects
1+2 were fixed:

```
PF COW ENTRY cr2=0x00007fffffffeff8
PF COW REFCNT len=0xffffffffffffffff
EXC HALT
```

The intermediate PDPT/PD/PT descent uses the same wrong mask (lines
106/135/149/163) but happens to work today because `aspace_map` sets
intermediate table entries via `or r11, 0x07` (P|W|U, no NX), so bit 63 is
zero and the erroneous mask bits carry nothing. That's a latent hazard the
fix eliminates by moving the whole file to the correct 40-bit mask.

## Fix

Three changes, all in `src/kernel/core/int/exceptions.pdx` and
`src/kernel/core/mm/pf_handler.pdx`.

### Fix 1 — always attempt CoW resolution for #PF (retire witness gate)

`_typed_handler_14` unconditionally invokes `pf_handle_cow`; only if that
returns `PF_HANDLE_KILL` do we fall through to the normal panic path.
`pf_handle_cow` self-validates (err = P|W with no reserved bits, PTE has
COW bit, refcount is 1 or ≥2) and returns KILL for any non-CoW fault, so
this is safe. The `_cow_witness_active` flag remains readable but no
longer gates dispatch; `_cow_witness_verbose` still gates the internal
klog markers so production doesn't drown in per-#PF traffic.

### Fix 2 — walk the user PML4 for user-mode faults

`pf_handle_cow` dispatches by error-code bit 2 (U):

- **U=1** (ring-3 fault): read `_current_tcb.user_pml4_va` at offset 16.
  This is a phys_alloc-form kernel VA (bit 63 set, higher-half alias of
  the user PML4 frame per the #658 boundary contract), directly
  dereferenceable from kernel context regardless of what CR3 currently
  holds. NULL guards on `_current_tcb` and the field itself route
  degenerate cases (task teardown race, early-boot fault) to
  `pf_cow_err_pml4` → KILL → panic (correct — those really aren't CoWs).

- **U=0** (ring-0 fault, e.g. the #661 kernel-side fast-flip witness which
  installs its CoW mapping into `_kernel_pml4_pa`): read live CR3 and
  walk it, matching the pre-#727 behaviour so the witness continues to
  pass.

The dispatch happens in-place in `pf_handle_cow`, so both callers (the
witness and the real ring-3 CoW path) share the same code past the
PML4-root selection.

### Fix 3 — correct PTE frame mask throughout `pf_handle_cow`

All five uses of the erroneous `0xFFFFFFFFFFFFF000` inside `pf_handle_cow`
are replaced with `0x000FFFFFFFFFF000`. The immediate need is at line 189
(leaf-frame extraction for `frame_meta_get`); the intermediate-table
descent sites (106/135/149/163) were latent, working today by coincidence
of `aspace_map`'s intermediate-flag choice — the fix removes the trap.

## Wire-trace confirmation

Log after all three fixes land (with `_cow_witness_verbose=1` temporarily
enabled to observe the dispatch path):

```
INIT BOOT OK
INIT ENTERED RING3
PF COW ENTRY cr2=0x00007fffffffeff8
PF COW SPLIT OK                        ← parent takes private copy (refcount==2 → SPLIT)
INIT OK                                ← push RA landed, sys_debug_puts printed
PF COW ENTRY cr2=0x00007fffffffeff8
PF COW FLIP OK                         ← child's first-write on the same VA → refcount==1 → fast-flip
INIT OK                                ← child's post-execve failure path (init_error prints init_msg)
```

Production log (verbose disabled — final wiring):

```
INIT BOOT OK
INIT ENTERED RING3
INIT OK
```

Init parent now successfully prints "INIT OK\n" via the second
`sys_debug_puts`, which is the very next syscall after `sys_fork`. The
smoke fingerprint at `tests/r17/expected-boot-r17-init.txt` extends by
one line accordingly (24 → 25 lines).

## Verification

- `tools/run-smoke.sh boot_r17_init` — passes with new INIT OK anchor.
- Pre-push regression matrix (10 modes: opcode-canary + boot_r8_only,
  boot_r10, boot_r11, boot_r12, boot_r12_denial, boot_r14b_hivma,
  boot_r14b_kpti, boot_r14b_ipi, boot_r14b_loader) — all pass.
- Extended matrix (9 modes: boot_r14b_ud, boot_r15_ring3, boot_r15_process,
  boot_r17_init, boot_panic, boot_panic_halt, boot_exc3, boot_tick,
  boot_banner) — all pass. Full 19-mode matrix green.
- Boot-time `PF COW ENTRY cr2=0x0000008000000000` → `PF COW FLIP OK`
  witness at kernel_main:1200 remains green (verified via wire trace) —
  the U=0 dispatch preserves the ring-0 witness's original semantics.

## Related latent hazards addressed

1. **Intermediate PDPT/PD/PT mask (Fix 3)** — the same wrong 52-bit mask
   at four intermediate-descent sites is a latent trap for any future
   change that adds NX (or the reserved-for-PKS bits 59..62) to
   intermediate table entries. Fixing here removes the class.
2. **`_cow_witness_active` residue** — the flag remains, unread by the
   dispatch path. Future cleanup can retire it, but the current wiring
   keeps kernel_main:1287/1299/1329's arm/disarm scaffolding compilable
   without touching that block.

## Why the earlier "USTACK_FLAGS missing RW" theory was wrong

Prior theory said USTACK_FLAGS or aspace_map was miscomputing the RW bit.
Debugger already verified `USTACK_FLAGS = 0x8000000000000007` (P+RW+U+NX),
aspace_map's `or rax, r15` correctly ORs RW into the leaf, intermediate
PML4/PDPT/PD entries are stamped 0x07 by aspace_map itself, and the
initial four pushes (from sys_debug_puts, sys_open, sys_dup2 ×3, sys_close,
sys_fork calls) all succeed — confirming user_stack_alloc's mappings are
correctly RW at setup. The PTE was RW **until sys_fork ran
aspace_clone_cow**, which stripped RW as CoW discipline demands. The
fault is expected; the bug is that pf_handle_cow was never reached, and
when it eventually was reached (after Fix 1), it walked the wrong PML4
(Fix 2) and read the wrong frame PA (Fix 3).

## What's next (D9)

The wire trace with verbose logging enabled shows a second INIT OK
(printed by init_error in init.pdx after the child's `sys_execve /bin/sh`
returns) and then EXC HALT. That's D9 (paideia-os #728, "execve/open
read user VA under kernel CR3") — the child's execve path likely repeats
the D4-class mistake elsewhere (kernel reading user memory under kernel
CR3 without walking the user PML4). Track separately.

Distance to #723 AC:
- ✅ D1 (init_error fallthrough)
- ✅ D2 (sys_exit real termination)
- ✅ D4 (init post-iretq #GP)
- ✅ D5 (sys_wait real block)
- ✅ D6 (fork enqueue + regs_save init)
- ✅ D8 (this — user stack CoW never serviced)
- ⏳ D9 (execve/open user-VA reads under kernel CR3)
- Remaining: shell startup after init reaps; unclear #-count.
