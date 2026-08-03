---
issue: 660
milestone: R14b.M5 (CR0.WP + pf_handler CoW substrate — blocker chain for #553)
subsystem: 4 — MM / page-fault path
prereq:
  - "#559 (frame_meta[1024] + incref/get + refcount-aware phys_free — LANDED)"
  - "#649 (phys_free real body — LANDED)"
  - "#645 (KPTI scratch slot + swapgs discipline foundations — LANDED)"
  - "#652 (enter_userland_initial CR3 VA/PA precedent — LANDED)"
  - "#657 (kernel-mode swapgs discipline — REFERENCED for vec14 audit)"
blocks:
  - "#553 (pf_handler CoW split — depends on WP=1 to observe ring-0 CoW writes)"
  - "#552 (aspace_clone_cow — indirectly, via #553)"
  - "#554 (sys_fork end-to-end — indirectly, via #553)"
touching:
  - tools/boot_stub.S                                           (Phase A: CR0.WP bit in the long-mode CR0 write; Phase C: 2 rodata strings + 1 bss slot for _cow_witness_active)
  - src/kernel/core/mm/pf_handler.pdx                           (Phase C: 12-line stub → ~90 LOC fast-flip-only body; split path deferred to #553)
  - src/kernel/core/int/exceptions.pdx                          (Phase C: fix read_cr2 placeholder to real `mov rax, cr2`; rewrite _typed_handler_14 to dispatch on _cow_witness_active)
  - src/kernel/boot/kernel_main.pdx                             (Phase A: emit `R14B CR0 WP OK` marker; Phase C: sub-test B fast-flip witness ~110 LOC)
  - tests/r14b/expected-boot-r14b-kpti.txt                      (+1 line `R14B CR0 WP OK`)
  - tests/r15/expected-boot-r15-ring3.txt                       (+2 lines `R14B CR0 WP OK`, `R14B PF FLIP OK`)
related:
  - design/kernel/r15-m6-002-pf-handler-cow-split.md            (#553 parent design; §3.7 fast-flip specification; §3.8 split-path spec — split deferred here)
  - design/kernel/r15-m6-008-cow-refcount-frame-metadata.md    (standalone-witness pivot pattern inherited)
  - src/kernel/core/mm/aspace_map.pdx                           (walker template + VA/PA normalizer discipline)
  - src/kernel/core/mm/kpti.pdx                                 (KPTI PT[260] is R-only + X — audit item under Phase B)
  - src/kernel/core/int/idt.pdx                                 (trampoline_vec14 push order + IST-14 stack switch)
---

# R14b-M5-008 — CR0.WP enablement + pf_handler fast-flip substrate (#660)

## 0. Landing posture — pf_handler substrate ahead of #553's split path

#553 (`r15-m6-002-pf-handler-cow-split.md`) attempted to land the full CoW
handler (fast-flip + split), witness driver, and _typed_handler_14 dispatch
as a single unit. The debugger session recorded in issue #660 exposed four
sequenced root causes; the first three are integration bugs in the witness
harness (fixable per #660 hints, preserved in git stash
`553-debugger-findings-preserved`) and are consumed by #553's re-attempt.
The **fourth root cause is a substrate concern**: CR0.WP is never enabled,
so ring-0 writes bypass R-only PTEs and no #PF ever reaches
`_typed_handler_14`. This issue lands the substrate (CR0.WP + one-shot
fast-flip verification) so that #553 relands against a known-good handler
receiver.

**Landing posture inherits the standalone-witness pivot from #559/#553:**
prove the CoW fast-flip path in isolation, with manual PTE setup and a
refcount==1 page, before #553 layers the split path (refcount>1) and its
walker-agnostic dispatch on top. Rationale:

- **Substrate isolation.** CR0.WP is a system-wide invariant. Any latent
  R-only-in-PT kernel data page becomes a triple-fault at boot the moment
  WP flips. Landing WP + a boot-continuation marker (`R14B CR0 WP OK`)
  before any CoW split logic proves the substrate is safe *by itself*.
  Deferring WP to #553's own witness block conflates two failure surfaces.

- **Fast-flip is the smaller half of #553.** Fast-flip is ~65 assembly
  instructions after the walker (§3.7 of #553); split path (§3.8) is
  ~130 (memcpy, refcount decref, PTE preservation, phys_free). Splitting
  the landing gives us evidence on the simpler receiver before the harder
  one is written.

- **swapgs discipline verification.** The very first real #PF-write-from-ring-0
  in this kernel's history fires here. If `trampoline_vec14` mishandles
  swapgs (per #657 audit surface), the fast-flip witness catches it now,
  not later during a fork.

This issue's AC is `R14B CR0 WP OK` (boot survives WP=1) and `R14B PF FLIP OK`
(one fast-flip round-trip completes). #553's AC (refcount>1 split + full
fork acceptance) remains intact and consumes this substrate.

## 1. Scope

Three phases, each self-contained and independently witnessable:

**Phase A — Enable CR0.WP (boot substrate).**
One-line change in `tools/boot_stub.S`: extend the existing `movl %eax, %cr0`
with `PG|PE` at line 61 to also set bit 16 (WP). Emits `R14B CR0 WP OK`
via `uart_puts` in `kernel_main_64` after IDT is armed but before any
page-fault-generating witness runs.

**Phase B — Audit kernel-mode writes to R-only pages.**
Static audit of every path that (1) writes to kernel-mapped memory and
(2) crosses a PTE with `PTE_RW=0`. Findings §4. Zero pre-existing kernel
data pages are R-only under the boot PML4 (all backed by 1 GiB huge pages
with flags 0x83 = P|RW|PS). The KPTI trampoline code page (PT[260], flags
0x001) is R-only+X and is *only* executed, never written, from ring-0.
Conclusion: WP=1 is safe by construction.

**Phase C — pf_handler_cow fast-flip body + witness.**
Replace the 12-line stub `pf_handler.pdx` with a fast-flip-only real body
(~90 LOC). Rewrite `_typed_handler_14` to check `_cow_witness_active` and
dispatch to `pf_handle_cow`. Fix `read_cr2` placeholder. Emit witness
sub-test B in `kernel_main_64` between the frame_meta witness and the KPTI
structural witness. Emits `R14B PF FLIP OK` on success.

Explicitly **out of scope**:

- **CoW split path (refcount > 1).** Deferred to #553. This handler
  returns `PF_HANDLE_KILL` on refcount > 1, and the witness never drives
  that path. #553's relanding replaces the KILL branch with the split
  body (§3.8 of `r15-m6-002-pf-handler-cow-split.md`) and adds sub-test B'.

- **Ring-3 CoW writes.** #660 sub-test B fires the CoW write from ring 0.
  Ring-3 CoW requires swapgs discipline in `trampoline_vec14` (see §5.2);
  #553 or a paired issue owns that once fork lands.

- **Real fork acceptance (parent + child divergent writes).** #553.

- **Splitting `aspace_map` behavior around CoW-marked PTEs.** #552.

- **PANIC integration / task-kill on non-CoW #PF.** R16+.

## 2. Prereq check

### 2.1 What's in place

| Primitive                              | Location                                | Contract used by #660                                                  |
|----------------------------------------|-----------------------------------------|------------------------------------------------------------------------|
| Boot PML4 with R+W 1 GiB huge pages    | `tools/boot_stub.S:26-33`               | All boot-mapped low+high VAs are R+W; WP=1 does not affect any kernel data page here. |
| CR0.PG|PE write site                   | `tools/boot_stub.S:60-62`               | Phase A extends the same movl to also OR bit 16 (WP). |
| `_kernel_pml4_pa` populated at boot    | `src/kernel/boot/kernel_main.pdx:69-70` | Fast-flip witness references it for CR3 restore. |
| `aspace_create` (KERNEL_PGD factory)   | `src/kernel/core/mm/aspace_create.pdx:38` | Sub-test B builds fresh PML4 with kernel higher-half copy. |
| `aspace_map`                           | `src/kernel/core/mm/aspace_map.pdx:47`  | Sub-test B maps the test page with flags = 0x001 (P only). |
| `phys_alloc` / `phys_free`             | `core/mm/phys_alloc.pdx:22`, `phys_free.pdx:17` | Sub-test B allocates page + frees post-flip. |
| `frame_meta_get`                       | `core/mm/frame_meta.pdx:134`            | Fast-flip reads refcount; expects 1 for phys_alloc-fresh page. |
| `tlb_shootdown_local`                  | `core/ipi/tlb_shootdown.pdx:59`         | Fast-flip post-write invlpg. |
| `_typed_handler_14` frame_ptr in RDI   | `core/int/exceptions.pdx:289`           | Rewrite dispatches to pf_handle_cow when flag set. |
| Trap frame push order + errcode slot   | `core/int/idt.pdx:174-192`              | error_code=+128, RIP=+136 (fault-semantic re-execute on iretq). |
| `_syscall_kernel_stack` (higher-half)  | `core/syscall/kernel_stack.pdx:10`      | Sub-test B switches to this stack before CR3 flip (per #660 fix #2). |
| Witness-active flag pattern            | `core/int/exceptions.pdx:195` (`_ud_witness_active`), `:244` (`_ring3_witness_active`) | Same shape: `pub let mut _cow_witness_active : u64 = 0` in `kernel_main.pdx`. |

### 2.2 What is not in place — encoder gaps and structural changes needed

- **`mov rax, cr2` encoder gap E-1** (per #553 §2.3). `exceptions.pdx:94`'s
  `read_cr2` still emits `mov rax, rax` placeholder. Fix per §3.3.

- **`_cow_witness_active` flag slot.** New `pub let mut` in
  `kernel_main.pdx` mirroring `_ud_witness_active` / `_ring3_witness_active`.

- **`_kernel_resume_rsp_cow_scratch`** — separate scratch for CoW witness
  RSP save/restore (per #660 fix #2 pattern) so we don't collide with
  #652's `_kernel_resume_rsp` if runs interleave.

### 2.3 Fixes preserved from stash `553-debugger-findings-preserved`

Per #660 issue body, the git stash contains three witness-integration
fixes (CR3 VA/PA, kernel stack in low half, aspace_map double-subtract)
and 250 LOC of `pf_handler` body. This design consumes:

- **CR3 VA/PA fix**: sub-test B applies the `sub rdx, KERNEL_VMA_BASE`
  at the last moment before `mov cr3` (mirrors `enter_userland_initial`
  #652 precedent and #553 witness code).
- **Kernel stack switch**: sub-test B saves original RSP, switches to
  `_syscall_kernel_stack`'s top, and restores on teardown.
- **aspace_map raw-VA form**: passes `phys_alloc`'s VA-form return
  directly to `aspace_map` (per #649 convention); no double-conversion.

The 250 LOC of pf_handler body (fast-flip only from stash — split path is
in the same stash but excluded here) is the seed for Phase C's body;
this design updates it to match the finalized flag/marker names.

## 3. Design

### 3.1 Phase A — CR0.WP enablement

**Placement decision: in `tools/boot_stub.S`, same `movl %eax, %cr0`
write that sets PG|PE.**

Alternatives considered:

| Site                                 | Pros                                                             | Cons                                                                 | Verdict |
|--------------------------------------|------------------------------------------------------------------|----------------------------------------------------------------------|---------|
| **A. boot_stub.S, same CR0 write**   | Zero extra instructions. WP is a boot invariant from cycle one.  | If an unexpected R-only kernel page exists pre-IDT, triple-faults.   | **Chosen** — Phase B audit shows no such page exists. |
| B. kernel_main_64, after `idt_install` | Any WP-induced #PF has a handler installed and can trap+halt with a marker. | Delays exposure; needs a separate `enable_cr0_wp` primitive. Two writes to CR0 (PG|PE early, WP later) instead of one. | Fallback if Phase B audit surfaces a suspect page. |
| C. kernel_main_64, after all boot init but before witness | Latest safe point; minimum blast radius. | Silently allows the entire boot sequence to run WP=0. Doesn't match "boot invariant". | Rejected — no substrate benefit. |

**Rationale for A**: The boot PDPT (built in `boot_stub.S` lines 26-33)
maps 0..4 GiB via 1 GiB huge pages with flags `0x83` = `P | RW | PS`.
Every kernel byte (code, rodata, data, bss, stack) lives inside this
window and is R+W in the hardware PT. WP=1 changes exactly zero page
walks for pre-#553 code. The kernel higher-half aliasing at PML4[256]
(line 41) shares the same PDPT, so higher-half execution (post R14B-M3-000
VMA relocation) inherits R+W as well.

**Change (single-line):**

```asm
# tools/boot_stub.S — line 60-62 pre:
#     movl %cr0, %eax
#     orl  $0x80000001, %eax
#     movl %eax, %cr0
#
# post:
    movl %cr0, %eax
    orl  $0x80010001, %eax                 # PG | WP | PE (bit 31 | bit 16 | bit 0)
    movl %eax, %cr0
```

CR0 bit definitions (Intel SDM Vol 3A §2.5):
- **Bit 0 (PE)**  = 0x00000001 — Protected mode.
- **Bit 16 (WP)** = 0x00010000 — Write Protect. When 1, ring-0 writes fault
  on PTEs with `PTE_RW=0`. When 0, ring-0 writes bypass R-only PTEs
  (legacy 386 behavior — the source of #660 root cause 4).
- **Bit 31 (PG)** = 0x80000000 — Paging.

Combined mask: `0x80010001`. All three bits set atomically in the same
`mov cr0` — no intermediate state where PG is on and WP is off.

**Marker emit in `kernel_main_64`:** immediately after `nx_enable` (line 88)
and before the phys_free witness (line 91-131), add:

```asm
lea rdi, [rip + cr0_wp_ok_msg]
call uart_puts
```

Rodata addition to `tools/boot_stub.S` (near existing markers):

```asm
.global cr0_wp_ok_msg
.align 8
cr0_wp_ok_msg: .ascii "R14B CR0 WP OK\n\0"
```

If this marker prints, Phase A has succeeded end-to-end: the CR0 write
did not cause any silent kernel-data-page fault between `long_mode_trampoline`
and this point (the trampoline, GDT install, IDT install, TSS install,
SMEP/SMAP/NX enable, and all UART traffic all completed with WP=1).

### 3.2 Phase B — Audit of kernel-mode writes to R-only pages

Every kernel-mode write must go to a page whose active-PT PTE has
`PTE_RW=1`, else WP=1 triggers #PF. Systematically:

#### 3.2.1 Boot PML4 (active until first user process)

Mapped via `tools/boot_stub.S:20-42`:
- `PML4[0]` → `pdpt` with flags `0x03` = `P | RW`.
- `PDPT[0..3]` → 1 GiB huge pages 0..3 GiB with flags `0x83` = `P | RW | PS`.
- `PML4[256]` → same `pdpt` (higher-half alias) with flags `0x03`.

Every address the kernel touches under boot PML4 resolves through R+W
PTEs. **Safe.**

#### 3.2.2 KPTI USER_PGD (installed on aspace_create_user path)

`kpti_build_user_pml4` (`core/mm/kpti.pdx:107-238`) creates a per-user
PML4[256] → PDPT → PD → PT chain mapping only:
- `PT[260]` = `_syscall_trampoline_start` phys | `0x1` — **R-only, U=0**
  (line 188: `or rcx, 0x1;`). Trampoline code page.
- `PT[261]` = `_syscall_trampoline_data_start` phys | `0x8000000000000003`
  — R+W, NX, U=0 (line 194).

`PT[260]` is R-only from the kernel's perspective. **However, the CPU
only fetches instructions from it** (via `syscall`/`sysret` entry) —
kernel code never writes to `_syscall_trampoline_start`. WP=1 does not
alter fetch semantics; WP only gates writes. **Safe.**

If a future refactor writes to `_syscall_trampoline_start` from ring-0
(e.g. patching an instruction), WP=1 will trap it — this is a *feature*
(catches a real bug), not a Phase B blocker.

#### 3.2.3 aspace_map-produced PTEs

`aspace_map` (`core/mm/aspace_map.pdx:47`) always sets `PTE_PRESENT`
(`or rax, 1;` line 187) and OR's caller-supplied flags. Callers:

- **`elf_lite_load`** (`core/loader/elf_lite.pdx:466-473`): computes
  translated flags per ELF `p_flags`. `.text` segments = `PF_R|PF_X`
  → PTE flags `U` only → R-only + X (kernel-perspective R-only, user PT_US).
  **Kernel does not write to these pages**; the loader itself writes to
  the *physical frame* via a VA obtained from `phys_alloc` (which returns
  a directly-writable VA, not a walked PT lookup — see #649 fix). The
  loader's `mov [rdi], r11b` at line 429 writes to the phys_alloc VA,
  not to the aspace-mapped `p_vaddr` VA. **Safe** — no VA→R-only-PTE
  crossing during load.

- **#652 ring-3 witness** (`kernel_main.pdx:420-450`): maps `0x400000` +
  user stack. Writes to `0x400000` (writing `hlt` byte) go through
  `phys_alloc`'s VA (line 400 comment: "r13 is ALREADY a directly-writable
  kernel VA"), *not* through the mapped user VA. **Safe** — same discipline
  as elf_lite_load.

- **#660 sub-test B witness**: sets flags = `0x001` (P only, no RW, no US).
  Then manually OR's `PTE_COW=0x200` onto the leaf. This *deliberately*
  creates the R-only + COW PTE the fast-flip fires on. **Intended** —
  this is the test.

#### 3.2.4 aspace_create-produced PML4s

`aspace_create` (`core/mm/aspace_create.pdx:38`) zeroes `PML4[0..255]`
and copies `PML4[256..511]` from kernel PML4. The copied entries point
at boot's PDPT — the same 1 GiB R+W huge pages. **Kernel higher-half
under any aspace_create-produced PML4 is R+W.** Safe.

#### 3.2.5 Kernel stack after CR3 flip to fresh witness PML4

Per #660 root cause 2: `kernel_main_64`'s RSP is at low-half `0x6ed8` (boot
stack, unmapped after CR3 flip to a fresh witness PML4). This is orthogonal
to WP=1 — it fires the same way whether WP is on or off (write to
unmapped page → #PF regardless). The fix (switch to `_syscall_kernel_stack`
in higher-half before CR3 flip) is preserved from the stash and applies
identically here.

#### 3.2.6 Summary

**Zero pre-existing kernel data pages are R-only-in-PT.** WP=1 is safe.
The only R-only page in any active kernel PT is the KPTI trampoline code
page, which is never written by kernel code. Phase A can land as a
one-line boot_stub.S change with no compensating audit fixes.

### 3.3 Phase C — pf_handler_cow fast-flip body

Replace `src/kernel/core/mm/pf_handler.pdx` (currently 12 lines of
constants) with a real body implementing **fast-flip only**. Split path
(refcount > 1) is deferred to #553 as documented in §5.5 of the parent
design; here the split branch returns `PF_HANDLE_KILL` and the witness
never exercises it.

#### 3.3.1 read_cr2 encoder fix

`src/kernel/core/int/exceptions.pdx:94-102`'s `read_cr2` currently emits
`mov rax, rax` (placeholder documented in that function's justification).
Replace with the real x86-64 encoding of `mov rax, cr2`, which is `0F 20 D0`
(ModR/M byte differs from `mov rax, cr3` = `0F 20 D8` only in the `reg`
field: 2 vs 3). paideia-as v0.11.0+ has landed `mov rax, cr3` in
`kpti.pdx:247`; the CR2 variant is a one-encoder-slot extension.

```asm
# exceptions.pdx read_cr2 body — pre:
        mov rax, rax        # placeholder
# post:
        mov rax, cr2
```

If paideia-as's encoder does not yet expose the `cr2` operand form
(only `cr3`/`cr4`/`cr0`), fall back to option 2 from #553 §2.3: inline
the read in `pf_handle_cow` itself as a raw `.byte 0x0F, 0x20, 0xD0`
sequence. Adopt this fallback only after empirically confirming the
encoder gap — no proactive workaround.

#### 3.3.2 pf_handle_cow — signature and flow

```
pf_handle_cow(frame_ptr) -> u64  !{mem, sysreg} @{boot}

Return values:
  PF_HANDLE_OK    (0)  — flip complete, iretq re-executes write
  PF_HANDLE_KILL  (1)  — non-CoW or unsupported (refcount>1 stub) → fall through to handle_pf
```

Handler body outline (matches #553 §3.6 walker + §3.7 fast-flip):

```
Prologue: push rbx, r12, r13, r14, r15         ; 5 SysV callee-saves
          mov rbx, rdi                         ; frame_ptr (surviving)

Read CR2 and error_code:
          mov r12, cr2                         ; faulting VA (or via read_cr2 call)
          mov r13, [rbx + 128]                 ; error_code

Validate error_code (fast-flip requires: P=1, W=1, RSVD=0, ID=0, PK=0, SS=0, SGX=0):
          mov rax, r13
          mov rcx, 0x8069                      ; ERR_P|ERR_W|ERR_RSVD|ERR_ID|ERR_PK|ERR_SS|ERR_SGX
          and rax, rcx
          cmp rax, 0x3                         ; exactly ERR_P|ERR_W
          jne pf_real_fault

Walk cr3 → PT[i]:                              ; read-only descent per #553 §3.6
          mov rax, cr3
          and rax, PTE_FRAME_MASK
          mov rcx, KERNEL_VMA_BASE
          add rax, rcx                         ; PML4 VA
          ; PML4[idx = cr2>>39 & 0x1FF] → present-check + huge-check → next
          ; PDPT[idx = cr2>>30 & 0x1FF] → present-check + huge-check → next
          ; PD[idx = cr2>>21 & 0x1FF]   → present-check + huge-check → next
          ; PT[idx = cr2>>12 & 0x1FF]:
          lea r14, [rax + rcx * 8]             ; r14 = &PT[i] (surviving)
          mov r15, [r14]                       ; r15 = leaf PTE (surviving)

Validate PTE shape (must be P=1, RW=0, COW=1):
          test r15, PTE_PRESENT
          jz pf_real_fault
          test r15, PTE_RW
          jnz pf_real_fault
          test r15, PTE_COW
          jz pf_real_fault

Read refcount:
          mov rax, r15
          mov rcx, PTE_FRAME_MASK
          and rax, rcx                         ; old_pa
          mov rdi, rax
          call frame_meta_get                  ; rax = refcount

Branch on refcount:
          cmp rax, 1
          je pf_cow_flip                       ; fast-flip path
          ; refcount > 1 or 0: split-path stub — return KILL
          jmp pf_handle_cow_kill

pf_cow_flip:
          mov rax, r15
          or  rax, PTE_RW                      ; set writable
          mov rcx, PTE_COW
          not rcx
          and rax, rcx                         ; clear PTE_COW
          mov [r14], rax                       ; store new PTE
          mov rdi, r12                         ; cr2
          call tlb_shootdown_local
          xor rax, rax                         ; PF_HANDLE_OK
          jmp pf_handle_cow_epilogue

pf_handle_cow_kill:
          mov rax, 1                           ; PF_HANDLE_KILL
          jmp pf_handle_cow_epilogue

pf_real_fault:
          ; Non-CoW fault: return KILL; caller falls through to handle_pf.
          mov rax, 1
          jmp pf_handle_cow_epilogue

pf_handle_cow_epilogue:
          pop r15; pop r14; pop r13; pop r12; pop rbx
          ret
```

**Constants defined in pf_handler.pdx module scope:**
```
PTE_PRESENT      = 0x001
PTE_RW           = 0x002
PTE_US           = 0x004
PTE_PS           = 0x080
PTE_COW          = 0x200         ; per #553 §3.4
PTE_FRAME_MASK   = 0x000FFFFFFFFFF000
KERNEL_VMA_BASE  = 0xFFFF800000000000
PF_HANDLE_OK     = 0
PF_HANDLE_KILL   = 1
```

**Callee-save discipline**: 5 pushes (rbx, r12-r15) — inherited from #553
§3.5. Odd count relative to trap-frame's alignment invariant is discussed
in #553 §3.5 (5-push lands nested `call`s aligned given trampoline's
16-push GPR save); no change needed here.

#### 3.3.3 _typed_handler_14 rewrite

Same shape as `_typed_handler_6` (line 186) and `_typed_handler_13` (line 235):
check flag, dispatch on match, fall through to normal handler otherwise.

```asm
# exceptions.pdx _typed_handler_14 — pre:
      block: { call handle_pf; ret }

# post:
      block: {
        # CoW witness dispatch — same shape as _typed_handler_6.
        mov r12, rdi                           ; preserve frame_ptr
        lea rax, [rip + _cow_witness_active]
        mov rax, [rax]
        cmp rax, 1
        jne typed14_normal_pf

        # Armed — call pf_handle_cow.
        mov rdi, r12                           ; frame_ptr
        call pf_handle_cow
        cmp rax, 0                             ; PF_HANDLE_OK?
        je typed14_return                      ; yes — iretq re-executes write

        # KILL — fall through to normal panic path.
        jmp typed14_normal_pf

      typed14_return:
        ret

      typed14_normal_pf:
        call handle_pf
        ret
      }
```

**No swapgs.** Kernel-mode #PF at #660 scope — sub-test B fires from
ring 0 with kernel CS. GS_BASE is already the kernel per-CPU pointer.
Ring-3 CoW (#553) will require gating swapgs on the CS field in the
trap frame (`[rbx + 144] & 3 != 0` → ring-3 → swapgs); §5.2 lists this
as a follow-up.

#### 3.3.4 _cow_witness_active flag

Add to `src/kernel/boot/kernel_main.pdx` alongside existing pattern
(around line 1276-1282):

```
pub let mut _cow_witness_active : u64 = 0
```

Rationale for placement in `kernel_main.pdx` (not `boot_stub.S`): matches
`_ud_witness_active` / `_ring3_witness_active` which are also `pub let mut`
in `kernel_main.pdx`. paideia-as elaboration + linker export path is
audited for this pattern.

### 3.4 Sub-test B — fast-flip witness in kernel_main_64

Placement: **after** the frame_meta witness (line ~209) and **before**
the KPTI structural witness (line 211). Follows #553 §5.1 rationale.

Setup (mirrors #553 §5.2 with fixes 1-3 applied):

```
# Save original RSP for restore after test
lea rax, [rip + _kernel_resume_rsp_cow_scratch]
mov [rax], rsp

# Switch to _syscall_kernel_stack top (higher-half, otherwise-dead at this milestone)
lea rax, [rip + _syscall_kernel_stack]
add rax, 16384                                 ; top of 2048-u64 stack = 16 KiB
mov rsp, rax

# 1. Arm flag
lea rcx, [rip + _cow_witness_active]
mov rax, 1
mov [rcx], rax

# 2. Build witness PML4 with kernel higher-half copy
mov rdi, [rip + _kernel_pml4_pa]
call aspace_create
mov rcx, 4294967295
cmp rax, rcx
je pf_flip_fail
mov r12, rax                                   ; r12 = witness_pml4 VA-form (per #649 convention)

# 3. Allocate a fresh 4 KiB frame (born with refcount=1 via #559 wire-in)
mov rdi, 0
call phys_alloc
cmp rax, 0
je pf_flip_fail
mov r13, rax                                   ; r13 = frame VA (writable directly, per #649)

# 4. Write canary at offset 0 via the VA form (not through the mapped user VA)
mov qword ptr [r13], 0xDEADBEEFCAFEF00D

# 5. Map into witness PML4 at 0x400000 with flags = 0x001 (P only; no US, no RW)
#    This creates a kernel R-only page (PTE_US=0 → SMAP-safe for ring-0 access)
mov rdi, r12                                   ; witness_pml4 VA-form
mov rsi, 0x400000                              ; vaddr
mov rdx, r13                                   ; paddr (VA-form; aspace_map's #652 fix subtracts KERNEL_VMA_BASE at the store site)
mov rcx, 0x001                                 ; flags: P only
call aspace_map
cmp rax, 0
jne pf_flip_fail                               ; MAP_OK == 0

# 6. Manually OR PTE_COW onto PT[0] (the leaf slot for VA 0x400000)
#    Walk r12 → PDPT → PD → PT to locate leaf slot. All indices are 0
#    (VA 0x400000 = 0.0.2.0 shifted; 0x400000 >> 12 = 0x400, and 0x400 & 0x1FF = 0)
#    but the PD index is bit 21 = 2. Compute the walk inline for the leaf address.
#    NB: aspace_map returned VA-form addresses stored in table slots. Read PT[0] and OR 0x200.
mov rax, r12                                   ; PML4 base VA
mov rax, [rax + 0]                             ; PML4[0]
mov rcx, PTE_FRAME_MASK
and rax, rcx                                   ; PDPT PA
mov rcx, 0xFFFF800000000000                    ; KERNEL_VMA_BASE
add rax, rcx                                   ; PDPT VA
mov rax, [rax + 0]                             ; PDPT[0]
and rax, PTE_FRAME_MASK
add rax, rcx                                   ; PD VA
mov rax, [rax + 16]                            ; PD[2] (VA 0x400000 → PD idx 2)
and rax, PTE_FRAME_MASK
add rax, rcx                                   ; PT VA
mov rdx, [rax + 0]                             ; PT[0]
or rdx, 0x200                                  ; set PTE_COW
mov [rax + 0], rdx

# 7. Save current CR3 and flip
mov rax, cr3
lea rcx, [rip + _kernel_resume_cr3_cow_scratch]
mov [rcx], rax

mov rdx, r12                                   ; witness PML4 VA-form
mov rax, 0xFFFF800000000000                    ; KERNEL_VMA_BASE (per #652 precedent)
sub rdx, rax                                   ; genuine PA for CR3
mov cr3, rdx
```

Drive:

```
# 8. Read canary first (R-only allows read; verify frame content survived)
mov rax, [0x400000]
mov rcx, 0xDEADBEEFCAFEF00D
cmp rax, rcx
jne pf_flip_fail

# 9. Write triggers #PF (WP=1 + PTE_RW=0)
#    Handler fires:
#      _typed_handler_14 sees _cow_witness_active=1 → calls pf_handle_cow
#      pf_handle_cow reads CR2=0x400000, error_code has W=1,P=1
#      walks to PT[0], sees PTE_COW=1, PTE_RW=0
#      frame_meta_get returns 1
#      fast-flip: OR PTE_RW, AND ~PTE_COW, store
#      tlb_shootdown_local(0x400000)
#      returns PF_HANDLE_OK
#    trampoline_vec14 pops GPRs, iretq re-executes the write
#    write lands
mov rax, 0x11111111_22222222
mov [0x400000], rax
```

Verify:

```
# 10. Read back new value
mov rax, [0x400000]
mov rcx, 0x11111111_22222222
cmp rax, rcx
jne pf_flip_fail

# 11. Walk PT[0] and assert PTE_RW=1, PTE_COW=0
#    (Same walk as step 6, but read + assert)
# ... (asserts) ...

# 12. frame_meta_get(frame_pa) still == 1
mov rdi, r13
call frame_meta_get
cmp rax, 1
jne pf_flip_fail
```

Teardown:

```
# 13. Restore CR3
lea rax, [rip + _kernel_resume_cr3_cow_scratch]
mov rax, [rax]
mov cr3, rax

# 14. Restore original RSP
lea rax, [rip + _kernel_resume_rsp_cow_scratch]
mov rsp, [rax]

# 15. Free frame + PML4
mov rdi, r13
xor rsi, rsi
call phys_free

mov rdi, r12
mov rcx, 0xFFFF800000000000
sub rdi, rcx                                   ; PA for phys_free (per #649 convention: raw VA form OK)
# Actually #649's phys_free normalizer handles both regimes; pass raw VA (r12) as-is:
# mov rdi, r12
xor rsi, rsi
call phys_free

# 16. Clear flag
lea rcx, [rip + _cow_witness_active]
xor rax, rax
mov [rcx], rax

# 17. Emit success marker
lea rdi, [rip + pf_flip_ok_msg]
call uart_puts
jmp pf_flip_done

pf_flip_fail:
lea rdi, [rip + pf_flip_fail_msg]
call uart_puts

pf_flip_done:
```

**Rodata additions in `tools/boot_stub.S`:**

```asm
.global pf_flip_ok_msg
.align 8
pf_flip_ok_msg: .ascii "R14B PF FLIP OK\n\0"

.global pf_flip_fail_msg
.align 8
pf_flip_fail_msg: .ascii "R14B PF FLIP FAIL\n\0"
```

**BSS additions in `tools/boot_stub.S`** (or as `pub let mut` in `kernel_main.pdx`
— match the `_ring3_witness_active` precedent, which is in `kernel_main.pdx`):

```
pub let mut _cow_witness_active            : u64 = 0
pub let mut _kernel_resume_rsp_cow_scratch : u64 = 0
pub let mut _kernel_resume_cr3_cow_scratch : u64 = 0
```

## 4. Phase B audit findings — summary

| Kernel VA range         | Backing PT flags                              | Active in     | R-only? | WP=1 impact          |
|-------------------------|-----------------------------------------------|---------------|---------|----------------------|
| 0..4 GiB low identity   | boot PDPT huge-pages 0x83 = P|RW|PS           | Boot PML4     | No      | None                 |
| FFFF8000_0..3 GiB alias | same PDPT (via PML4[256])                     | Boot PML4     | No      | None                 |
| KPTI PT[260] trampoline | 0x001 = P (R-only + X, U=0)                   | KPTI USER_PGD | Yes     | Kernel never writes → **no fault** |
| KPTI PT[261] scratch    | 0x8000_0000_0000_0003 = P|RW|NX (U=0)         | KPTI USER_PGD | No      | None                 |
| ELF-loaded user .text   | aspace_map flags = 0x4 (U) → R-only + X user  | aspace_create_user | Yes (from kernel view) | Kernel writes via phys_alloc VA, not user VA → **no fault** |
| ELF-loaded user .data   | aspace_map flags = 0x6 (U|RW)                 | aspace_create_user | No      | None                 |
| #660 sub-test B page    | aspace_map flags = 0x1 (P) + manual OR 0x200  | witness PML4  | **Yes (intended)** | Kernel write → #PF → pf_handle_cow fast-flip → **desired behavior** |

**Conclusion**: No latent R-only kernel data page. Phase A is safe to land
as a single-line boot_stub.S change. WP=1 changes only the intended path
(the CoW test page).

## 5. Fast-flip path audit — findings requiring follow-up

### 5.1 read_cr2 placeholder — must fix in this issue

`exceptions.pdx:94-102` `read_cr2` emits `mov rax, rax`. If this remains
uncorrected, `pf_handle_cow` reads CR2 = value of RAX (garbage from
whatever the trampoline's `add rsp, 16` left), walks PT for garbage VA,
almost certainly falls into `pf_real_fault`, returns KILL, sub-test B
prints FAIL. **Blocks Phase C.** Fix per §3.3.1.

### 5.2 swapgs discipline in trampoline_vec14 — follow-up required for #553

`trampoline_vec14` (`idt.pdx:174-192`) has **no swapgs**. For kernel-mode
#PF (our sub-test B, and any pre-#552 CoW use), this is correct: GS_BASE
already holds the kernel per-CPU pointer, no swap needed.

For ring-3 #PF (any real fork after #552 lands), the CS field on the
trap frame (`[rbp + 144]` in trampoline_vec14's push order) has RPL=3.
Missing swapgs at entry means `pf_handle_cow`'s calls to
`tlb_shootdown_local` / `frame_meta_get` / etc. run with user GS_BASE,
producing wildly wrong reads on any `[gs:off]` access.

**#660 does not fix this** — sub-test B fires from ring 0. **File a
follow-up issue** ("trampoline_vec14 swapgs discipline for ring-3 #PF")
tracking the CS-check gate; #553 or #552 consumes it. Alternatively,
because pf_handle_cow at #660 scope does not touch GS_BASE (no `[gs:off]`
accesses in the fast-flip body), the fix can be deferred until a real
GS_BASE dependency emerges — but the audit must document the invariant.

Fix pattern (for the follow-up issue, not this one):

```asm
# trampoline_vec14 pre — no swapgs, wrong for ring-3
    mov rax, 14; push rax
    push rax; push rcx; push rdx; push rbx; push rbp
    ...

# trampoline_vec14 post — CS-gated swapgs
    mov rax, 14; push rax
    push rax; push rcx; push rdx; push rbx; push rbp
    push rsi; push rdi; push r8; push r9; push r10
    push r11; push r12; push r13; push r14; push r15
    mov rax, [rsp + 16*8 + 8]                # CS from CPU-pushed frame
    and rax, 3                               # RPL
    jz vec14_no_swapgs
    swapgs
vec14_no_swapgs:
    mov rdi, rsp
    call _typed_handler_14
    ; symmetric swapgs before iretq if we did one on entry
    ...
```

### 5.3 iretq semantics on #PF — no frame surgery needed

#PF is a fault (Intel SDM Vol 3A §6.14): the CPU pushes the RIP of the
faulting instruction (not the following instruction). On `iretq` with
an unmodified trap frame, the CPU re-executes the write. If the PTE was
promoted between fault and iretq, the retry succeeds.

`_typed_handler_14`'s post-`pf_handle_cow` path does NOT touch RIP in
the trap frame (unlike `_typed_handler_6`'s +2 advance past `ud2`). Correct.

### 5.4 PTE mutation atomicity

Fast-flip performs a **single 8-byte aligned store** to the PT slot
(line labeled `pf_cow_flip` in §3.3.2). On x86-64, aligned 8-byte stores
are atomic per Intel SDM Vol 3A §8.1.1. No compare-and-swap needed at
single-CPU altitude. TLB invalidation follows the store (via
`tlb_shootdown_local(cr2)`).

### 5.5 invlpg operand

`tlb_shootdown_local` (`core/ipi/tlb_shootdown.pdx:59`) issues
`invlpg [rdi]`. Handler passes CR2 in RDI. Single-CPU invalidation is
sufficient at R15.M6 (single logical CPU).

## 6. Test canary — sub-tests and fingerprint drift

### 6.1 Sub-test A (Phase A witness) — `R14B CR0 WP OK`

Emit path: `kernel_main_64` after `nx_enable` (line 88), before phys_free
witness (line 91).

Success semantics: reaching the emit point implies the kernel survived
CR0.WP=1 through:
1. `long_mode_trampoline` (data segment reload, jump to `_start`)
2. `_kernel_pml4_pa` populate (writes to `[rip + _kernel_pml4_pa]`)
3. `uart_init` (7 I/O port writes — memory-mapped I/O bypasses PT)
4. Banner + cap_smoke + ipc_smoke + cap_dispatch_smoke (data writes to `.bss`)
5. GDT install (writes to GDT bytes)
6. IDT install (writes to IDT bytes)
7. TSS install (writes to TSS bytes)
8. SMEP/SMAP/NX enable (CR4/EFER writes only, no PT writes)

If any of these writes crosses an R-only PTE, sub-test A does not emit
and the boot silently hangs (no IDT-installed handler for the pre-IDT
faults; post-IDT faults would spam `handle_pf → cpu_halt`).

Failure diagnosis: if boot dies between `KPTI OK` and this marker, walk
back through the boot sequence to find the offending write and confirm
its VA's PTE. Given Phase B audit, this should not happen.

### 6.2 Sub-test B (Phase C witness) — `R14B PF FLIP OK`

Emit path: `kernel_main_64` after frame_meta witness (line ~209), before
KPTI structural witness (line 211).

Success semantics: reaching `pf_flip_ok_msg` implies:
1. Manual PTE setup produced the intended `PTE_PRESENT | PTE_COW, PTE_RW=0`
   shape.
2. CR3 flip to witness PML4 did not disturb the kernel stack (proves the
   stash's fix #2 works: `_syscall_kernel_stack` in higher-half is mapped).
3. Ring-0 write to VA `0x400000` triggered #PF (proves WP=1 is active —
   sub-test A's marker corroborates but this is the observable proof).
4. `trampoline_vec14 → _typed_handler_14 → pf_handle_cow` dispatched
   correctly (proves flag-check + call chain).
5. `read_cr2` returned 0x400000 (proves encoder fix).
6. Walker descended PML4→PDPT→PD→PT and found the leaf (proves walker
   template + VA/PA discipline).
7. Fast-flip mutated PTE atomically (proves single-store, invlpg,
   iretq-retry sequence).
8. Post-flip write landed and read-back matches (proves PT-mutation
   semantics: retry-after-iretq).
9. frame_meta refcount unchanged (proves no false decref path).
10. Teardown restored CR3 + RSP + freed frames without disturbing kernel
    invariants (proves teardown sequence).

### 6.3 Fingerprint drift

**`tests/r14b/expected-boot-r14b-kpti.txt`**: +1 line (contains-in-order)

```diff
 TSS OK
+R14B CR0 WP OK
 KPTI OK
```

**`tests/r15/expected-boot-r15-ring3.txt`** and
**`tests/r15/expected-boot-r15-process.txt`**: +2 lines each (contains-in-order)

```diff
 TSS OK
+R14B CR0 WP OK
 PHYS FREE ROUNDTRIP OK
 R15 FRAME META OK
+R14B PF FLIP OK
 KPTI OK
```

The `boot_r8_only`, `boot_r10`, `boot_r11`, `boot_r12`, `boot_r12_denial`
fingerprints exit before `kernel_main_64`'s `nx_enable` completes — no
change required. `boot_r14b_kpti` fingerprint gets sub-test A only
(pre-phys_free witness). `boot_r14b_ipi` and `boot_r14b_loader` should be
verified: they run `kernel_main_64` past the phys_free/frame_meta witness
region and will emit sub-test B's marker. Bench required to determine
whether their fingerprints get the marker line or exit before it.

## 7. LOC estimate

| File                                                             | LOC delta |
|------------------------------------------------------------------|-----------|
| `tools/boot_stub.S` (CR0.WP bit + 4 rodata + 3 bss slots)        | +15       |
| `src/kernel/core/mm/pf_handler.pdx` (12 → ~100 LOC)              | +90       |
| `src/kernel/core/int/exceptions.pdx` (_typed_handler_14 + read_cr2) | +25    |
| `src/kernel/boot/kernel_main.pdx` (sub-test A marker + sub-test B body + 3 flag/scratch slots) | +130 |
| `tests/r14b/expected-boot-r14b-kpti.txt`                         | +1        |
| `tests/r15/expected-boot-r15-ring3.txt`                          | +2        |
| `tests/r15/expected-boot-r15-process.txt`                        | +2        |
| `design/kernel/r14b-m5-008-cr0-wp-substrate.md` (this)           | +~600     |
| **Kernel + witness executable code**                             | **~260**  |
| **Fingerprint + design**                                         | **~605**  |
| **Total**                                                        | **~865**  |

About 25% smaller than #553's ~1190 LOC — this issue lands only fast-flip
+ substrate; split path adds the rest.

## 8. Backtrack candidates

### 8.1 Backtrack A — WP in kernel_main_64, not boot_stub.S

If Phase B audit turns out to miss an R-only kernel data page and boot
triple-faults with WP in boot_stub.S, back out to enable WP in
`kernel_main_64` after `idt_install` (line 80) and add a boot-time
witness to walk suspect regions before flipping. This costs one extra
CR0 write but gives the IDT a chance to trap and halt with a marker
instead of a silent triple-fault.

Trigger: if `qemu` boot dies before `IDT OK` marker after Phase A lands.

### 8.2 Backtrack B — Inline `mov rax, cr2` in pf_handle_cow instead of extending read_cr2

If paideia-as encoder does not support the `cr2` operand form (only
`cr3`/`cr4`/`cr0`), inline the raw opcode bytes `0F 20 D0` at the CR2
read site in `pf_handle_cow`. Documented in #553 §2.3 as option 2.

Trigger: if the pdx compiler rejects `mov rax, cr2` in `read_cr2`.

### 8.3 Backtrack C — Sub-test B on ring-0 only, defer swapgs audit

If §5.2's swapgs follow-up surfaces as blocking (e.g., sub-test B
inadvertently touches `[gs:off]` via a called primitive), pare the
called primitives down to the minimum (`frame_meta_get`,
`tlb_shootdown_local`) and audit each for GS_BASE independence.
`frame_meta_get` reads `_frame_meta[]` via RIP-relative — no GS.
`tlb_shootdown_local` is `invlpg [rdi]` — no GS. Safe.

Trigger: if any called primitive turns out to use `[gs:off]`.

### 8.4 Backtrack D — Sub-test B without CR3 flip (single PML4 test)

If witness PML4 CR3 flip proves fragile (e.g., a fix #2-adjacent
regression), test the fast-flip against the *boot* PML4 by adding a new
PT entry to the kernel higher-half. Downside: leaks a persistent
R-only+COW page into the kernel aspace for the rest of the boot,
requiring explicit teardown. Only use if backtracks A/B/C exhausted.

## 9. Follow-up issues to file

Recommended sub-issues arising from this design's audit:

1. **"trampoline_vec14 swapgs discipline for ring-3 #PF"** (§5.2) —
   consumed by #553 (ring-3 CoW witness or fork acceptance).

2. **"pf_handle_cow split path (refcount > 1)"** — this is #553 itself;
   no new issue needed, but #553's scope should now be tightened to
   "add split path to existing fast-flip skeleton" rather than "write
   pf_handler from scratch".

3. **"paideia-as: mov rax, cr2 encoder"** (§5.1) — file only if
   Backtrack B triggers. Nominally a paideia-as issue.

4. **"kernel_main.pdx: unify _kernel_resume_rsp_* scratch slots"** —
   the boot now has three: `_kernel_resume_rsp` (#652), the CoW witness
   scratch, and any future exception-resume path. Consolidate under a
   single per-CPU scratch struct at R14b or R15b close. Non-blocking.

## 10. Risks and open questions

### 10.1 Risk: Phase B audit misses a suspect page

Mitigation: Backtrack A (§8.1). Phase A is a single-line change, easy
to revert if boot dies. The IDT is up before any witness runs, so
post-IDT faults print `handle_pf → cpu_halt` diagnostics on the UART
(vector 14 trace), which fingers the offending VA.

### 10.2 Risk: paideia-as CR2 encoder missing

Mitigation: Backtrack B (§8.2). No new encoder work is on the critical
path — the fallback is raw opcode bytes in a single unsafe block.

### 10.3 Open question: does `_syscall_kernel_stack` overlap active RSP0?

TSS's RSP0 field (per `core/int/tss.pdx`) is set to `_syscall_kernel_stack`
top as well (per R13-m4-002 discipline). If sub-test B switches RSP to
the same stack, a nested interrupt (LAPIC timer, for instance) that
loads RSP0 from TSS will land on top of our current frame.

**Mitigation**: `cli` before RSP switch, `sti` after teardown (or defer
sti-enable until later in `kernel_main_64` — currently done at
`boot_continue_after_ring3`). Since sub-test B runs before
`apic_svr_enable`/`sti`, this is naturally safe. **Confirmed no
overlap concern at this landing site.**

### 10.4 Open question: fingerprint drift for boot_r14b_ipi / boot_r14b_loader

Requires empirical bench to determine whether sub-test B's marker
appears in these fingerprints. If yes, add the line to their
`expected-*.txt` (+1 or +2 lines). If no, they exit before the witness
runs.

## 11. Acceptance criteria

- `boot_stub.S` sets `CR0.WP=1` in the same `mov cr0` that sets `PG|PE`.
- `kernel_main_64` prints `R14B CR0 WP OK` before phys_free witness.
- `_typed_handler_14` dispatches to `pf_handle_cow` when `_cow_witness_active=1`.
- `pf_handle_cow` handles refcount==1 with fast-flip (single PT store +
  invlpg + return OK). Returns KILL for all other shapes (deferred to #553).
- `read_cr2` emits real `mov rax, cr2` (or documented `.byte 0x0F, 0x20, 0xD0`
  fallback).
- `kernel_main_64` sub-test B prints `R14B PF FLIP OK` after successfully
  driving one fast-flip end-to-end.
- All existing fingerprints continue passing with the +1/+2 marker lines.
- No regression in ring-3 witness (#652), UD witness (#650), KPTI structural
  witness (#505/#645), IPI runtime witness (#646), or ELF loader witness (#648).
- Design doc landed at `design/kernel/r14b-m5-008-cr0-wp-substrate.md`.

## 12. Landing sequence

Recommended commit granularity (each independently verifiable):

1. **Commit A**: `tools/boot_stub.S` — CR0.WP bit + `cr0_wp_ok_msg` rodata.
   `kernel_main.pdx` — emit marker. Fingerprint diffs.
   Verify: `qemu` boot reaches `R14B CR0 WP OK` and remaining witnesses
   still pass.

2. **Commit B**: `exceptions.pdx` — `read_cr2` encoder fix (or bytes
   fallback). No behavior change yet (nothing calls it in the write path).

3. **Commit C**: `pf_handler.pdx` — replace 12-line stub with fast-flip
   body. `exceptions.pdx` — `_typed_handler_14` rewrite with dispatch on
   `_cow_witness_active`. `kernel_main.pdx` — `_cow_witness_active` +
   scratches. No behavior change yet (flag defaults to 0, dispatch
   falls through to `handle_pf`).

4. **Commit D**: `kernel_main.pdx` — sub-test B witness body.
   `tools/boot_stub.S` — `pf_flip_ok_msg` / `pf_flip_fail_msg` rodata.
   Fingerprint diffs.
   Verify: `qemu` boot reaches `R14B PF FLIP OK` after `R15 FRAME META OK`.

5. **Commit E** (optional): file follow-up issue for §5.2 swapgs audit.

Each commit gates the next; a failing verify on commit A rewinds only
that commit and triggers Backtrack A investigation.
