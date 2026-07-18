---
issue: 553
milestone: R15.M6 (fork / exec / wait / _exit)
subsystem: 9 — fork / exec / wait / _exit
prereq:
  - "#559 (frame_meta[1024] + incref/get + refcount-aware phys_free — LANDED)"
  - "#649 (phys_free real body — LANDED; refcount decref-guard consumes the CoW split)"
  - Subsystem 3, item 4 (tlb_shootdown_local — LANDED at src/kernel/core/ipi/tlb_shootdown.pdx:59)
  - "#552 (aspace_clone_cow — RESET; NOT a hard prereq — this issue tests in isolation via manual PTE setup, exactly the standalone-witness pivot #559 §0 pioneered)"
blocks:
  - "R15.M6 acceptance close (fork + write-share round-trip once #552 relands)"
touching:
  - src/kernel/core/mm/pf_handler.pdx                          (REPLACE 12-line stub with ~180 LOC real body)
  - src/kernel/core/int/exceptions.pdx                          (_typed_handler_14 rewrite: check _cow_witness_active, dispatch to pf_handle_cow instead of handle_pf; ~15 LOC diff)
  - src/kernel/boot/kernel_main.pdx                             (witness block, ~120 LOC — two sub-tests)
  - tools/boot_stub.S                                           (3 rodata strings, +12 lines; _cow_witness_active/_cow_test_page/_cow_shared_pa nobss slots)
  - tests/r15/expected-boot-r15-ring3.txt                       (marker line "R15 PF COW OK", contains-in-order)
  - tests/r15/expected-boot-r15-process.txt                     (marker line "R15 PF COW OK", contains-in-order)
  - design/kernel/r15-m6-002-pf-handler-cow-split.md            (this file)
related:
  - design/kernel/r15-m6-008-cow-refcount-frame-metadata.md    (§0 standalone-witness pivot pattern; §5 witness structure inherited)
  - design/kernel/cow-multishare.md                             (§CMS-D1/D2 semantics this handler enforces at single-CPU altitude)
  - design/kernel/r15-m1-010-phys-free-real-body.md            (§4 VA/PA normalizer — phys_free path this handler drives)
  - src/kernel/core/mm/aspace_map.pdx                           (walker template: PML4→PDPT→PD→PT descent + KERNEL_VMA_BASE PA↔VA discipline)
  - src/kernel/core/int/idt.pdx                                 (trampoline_vec14 push order → trap frame layout §3.2)
---

# R15-M6-002 — pf_handler real body: single-CPU CoW split/flip on write to R-only + PTE_COW page (#553)

## 0. Landing posture — STANDALONE, ahead of #552 (inherits #559 pivot pattern)

#552 (`aspace_clone_cow` walker) was RESET after its co-landing with
#559 (refcount metadata) merged two failure surfaces. #559 was salvaged
via the standalone-witness pivot documented in
`r15-m6-008-cow-refcount-frame-metadata.md` §0: land the primitive with
manual driver code that proves each contract in isolation, then let
#552 relanding target a **known-good substrate**.

**#553 inherits that pattern.** The pf_handler CoW split is proved
against manual PTE-setup driver code in `kernel_main_64`, not against a
real fork. The witness constructs the exact PTE shape that
`aspace_clone_cow` will eventually produce (R-only + PTE_COW +
refcount≥1), then drives the fault path and observes the split /
flip. When #552 lands, its clone walker feeds this same handler with
no changes — the handler doesn't care whether the CoW-marked PTE was
produced by a fork walker or by a witness's hand.

Cross-subsystem interlock respected: this issue writes only
`pf_handler.pdx` (the acceptance-touched file), `exceptions.pdx`
(one-line dispatch flag check — same shape as `_ring3_witness_active`
in `_typed_handler_13`, `_ud_witness_active` in `_typed_handler_6`),
and driver/rodata files. `aspace_clone_cow` is not modified.

**Why now, ahead of #552's relanding:** the fault handler is the
receiver in the CoW protocol. Proving it in isolation gives #552's
walker a stable target: any bug that later surfaces on a real fork is
localized to the walker (issuer side), not the handler (receiver
side). Inverse ordering — landing #552 first with a stub handler —
would panic-trace every fork write and provide no signal about which
side is wrong.

The AC in the issue body ("fixture forks, child writes; parent reads
original value; child reads new") is **satisfied here by two manual
sub-tests** — sub-test A (refcount==1 fast flip, parent already reaped
in the metaphor), sub-test B (refcount==2 split — the fork core case).
Once #552 lands, a follow-up smoke pass will run the same round-trip
via `sys_fork`; expected: byte-identical PF handler behavior, one
extra layer above (the walker).

## 1. Scope

Replace the 12-line stub `pf_handler.pdx` (currently just exports
`PF_HANDLE_OK` / `PF_HANDLE_KILL` constants) with a real body,
`pf_handle_cow`, dispatched from `_typed_handler_14` when the
`_cow_witness_active` flag is set (extensible to real fork
consumers in #552).

Handler contract:
1. Read CR2 (faulting linear address).
2. Read error_code from trap frame (bit 1 = W write, bit 0 = P
   present, bit 2 = U user, bit 3 = RSVD, bit 4 = ID inst-fetch).
3. Walk current-CR3 PML4 → PDPT → PD → PT to locate the leaf PTE
   for CR2. Any missing/huge level ⇒ panic-out (not our fault type).
4. Validate PTE shape: PTE_PRESENT set, PTE_RW clear, PTE_COW set.
   Any other shape ⇒ real fault, panic.
5. Extract old PA from PTE bits 12..51.
6. Read `frame_meta_get(old_pa)` refcount.
7. Branch:
   - **Fast path (refcount == 1)**: last owner. Flip PTE R/W bit,
     clear PTE_COW bit, store back. `tlb_shootdown_local(cr2)`.
     `iretq` (via trampoline epilogue). No allocator activity.
   - **Split path (refcount > 1)**: alloc new frame via
     `phys_alloc(0)`. Copy 4 KiB from old to new. Build new PTE =
     `(new_pa_field | PTE_PRESENT | PTE_RW | PTE_US | preserved-flags)`
     with PTE_COW cleared. Store PTE. `tlb_shootdown_local(cr2)`.
     `phys_free(old_pa, 0)` — this drives the refcount decref-guard
     which detects `n → n-1 ≥ 1` and returns OK without clearing the
     bitmap bit (the frame stays live for the other sharers).

Explicitly **out of scope** (deferred):

- **Non-CoW #PF resolution.** Faults with error_code shapes other
  than "write-to-present + PTE_COW set" panic through
  `handle_pf → exc_handle → cpu_halt`. Demand paging, stack-guard
  extension, mmap-lazy-population are R16+ MM altitudes.
- **SMP TLB shootdown.** `tlb_shootdown_local` alone suffices for
  R15.M6's single-CPU regime. `tlb_shootdown_broadcast` is already
  present (`ipi/tlb_shootdown.pdx:87`) as an inline `invlpg` loop
  over the local CPU only, per its R14B collapse note. The IPI
  broadcast side is R15.M7+ (Path A/SMP), and the pf_handler diff to
  adopt broadcast is one call-site substitution.
- **Fork acceptance-round-trip witness.** Requires #552's walker.
  The AC is discharged by sub-tests A + B; a follow-up smoke pass
  after #552 relands is documented in §11.
- **PTE_COW propagation on `aspace_map`.** `aspace_map` produces
  R+W+P PTEs by design. Setting PTE_COW is `aspace_clone_cow`'s
  job (#552); this handler consumes the marked PTEs without
  producing new marked PTEs itself.
- **PANIC integration.** On non-CoW fault, the handler falls through
  to the existing `handle_pf`/`exc_handle` panic path — no new
  panic UI. R16+ replaces the halt with a task-kill.
- **Refcount overflow guard on incref.** Not incref'd by this
  handler; §7.5 of #559 already parked overflow as deferred.
- **PKS / MPK / SGX bits in error_code.** Read but not acted on;
  panic if present. §3.3 lists the decode; §7 backtrack C covers a
  future PKE-aware branch.

## 2. Prereq check

### 2.1 What's in place

| Primitive                              | Location                                | Contract used by #553                                                  |
|----------------------------------------|-----------------------------------------|------------------------------------------------------------------------|
| `frame_meta_get(page) -> u64`          | `core/mm/frame_meta.pdx:134`            | Read refcount; branches fast-flip vs split.                            |
| `phys_alloc(0) -> u64`                 | `core/mm/phys_alloc.pdx:22`             | Split path: new frame, born with refcount=1 (via #559 wire-in).        |
| `phys_free(page, 0)`                   | `core/mm/phys_free.pdx:17`              | Split path: decref old frame. #559 guard keeps the frame live if refcount stays ≥ 1. |
| `tlb_shootdown_local(va)`              | `core/ipi/tlb_shootdown.pdx:59`         | Post-PTE-write `invlpg`; single-CPU sufficient at R15.M6.              |
| `_typed_handler_14` frame_ptr in RDI   | `core/int/exceptions.pdx:289`           | Trap frame at offset 0..168 (§3.2); rewrite dispatches to `pf_handle_cow` when flag set. |
| Trap frame push order + error_code slot| `core/int/idt.pdx:174` (`trampoline_vec14`) | RIP=+136, CS=+144, RFLAGS=+152, RSP=+160, SS=+168, error_code=+128, vector=+120. |
| KERNEL_VMA_BASE = `0xFFFF800000000000` | `link.ld` + `phys_free.pdx:26`         | PA↔VA conversion for PTE-field↔copy-source.                            |
| 4-level walk pattern                    | `core/mm/aspace_map.pdx:62-174`         | Level shifts (39/30/21/12), index mask (0x1FF), present-check (bit 0), huge-check (bit 7), stored-PA-vs-indexing-VA discipline. |
| PTE_COW marker bit 9 (§3.4)             | New this issue                          | 0x200 mask; OS-available (Intel SDM Vol 3A §4.11.1 marks bits 9..11 as ignored by hardware). |
| CR2 read (`mov rax, cr2`)               | `core/int/exceptions.pdx:94` (`read_cr2`) | R6.5-006 primitive; today emits `mov rax, rax` placeholder — see §2.3 encoder gap. |
| Callee-save 5-push discipline           | `core/mm/aspace_map.pdx:52-55` (`push r12..r15`) + phys_alloc's #649 fix | 5-push prologue for multi-call bodies (§3.5). |

### 2.2 What is not in place (and not required)

- **Real `mov rax, cr2` encoder.** Existing `read_cr2` at
  `exceptions.pdx:94` is a placeholder emitting `mov rax, rax`. This
  handler needs the real form; see §2.3 for the encoder-gap risk
  and mitigation.
- **aspace_clone_cow walker.** #552. The handler is agnostic — it
  reads whichever PTEs the current CR3 tables produce. When #552
  lands, its produced PTE shape (R-only + PTE_US + PTE_COW +
  refcount≥1) exactly matches the sub-test setup.
- **SMP broadcast.** Not required at R15.M6; `tlb_shootdown_local`
  already lands the invalidation on the running CPU.

### 2.3 Encoder gaps (paideia-as)

Two encoder audits, both mitigable:

**Gap E-1: `mov rax, cr2` operand form.**
`exceptions.pdx:94`'s `read_cr2` still emits the `mov rax, rax`
placeholder because paideia-as 0.6.0 didn't cover the CR2 read. Since
R14B/R15 boot depends on the CR3/CR4 forms already landing (see
`kpti.pdx:*mov rax, cr3*`, `smep.pdx:33`), the encoder path is
audited for `mov {rax}, {crN}` — the `cr2` selector is the only
delta from `cr3`. Two options:

1. **Preferred**: extend `read_cr2` to emit `mov rax, cr2` — the
   ModR/M byte differs from `mov rax, cr3` only in the `reg` field
   (2 vs 3). Same audit trail as `kpti_switch_to_kernel`'s CR3 read.
2. **Fallback**: read CR2 in inline assembly inside `pf_handle_cow`
   itself, sidestepping the `read_cr2` function. This is what the
   ring-3 witness does with CR3 reads.

We pick option 1 in this issue. §7 backtrack A parks option 2 for
recovery.

**Gap E-2: Load current CR3 for PML4 walk.**
`mov rax, cr3` is used in several places (`kpti.pdx`). The exact
operand form is on the audited path. Same shape as gap E-1.

Neither gap is a blocker; both are one-instruction extensions to
existing audited operand shapes.

## 3. Design

### 3.1 High-level shape

```
pf_handler.pdx  (12 lines → ~180 lines)
├─ constants:
│    PTE_PRESENT   = 0x001
│    PTE_RW        = 0x002
│    PTE_US        = 0x004
│    PTE_PS        = 0x080   (huge-page bit; presence at PDPT/PD ⇒ panic)
│    PTE_COW       = 0x200   (§3.4 — bit 9, OS-available)
│    PTE_FRAME_MASK= 0x000FFFFFFFFFF000
│    ERR_P         = 0x1     (bit 0: 1 = present, 0 = not-present)
│    ERR_W         = 0x2     (bit 1: 1 = write, 0 = read)
│    ERR_U         = 0x4     (bit 2: 1 = ring 3)
│    ERR_RSVD      = 0x8
│    ERR_ID        = 0x10    (bit 4: instruction fetch — NX)
│    KERNEL_VMA_BASE = 0xFFFF800000000000
│    PAGE_SIZE     = 4096
│
├─ pf_handle_cow(frame_ptr) -> u64 !{mem,sysreg} @{boot}
│  ├─ push rbx, r12, r13, r14, r15                  (5-push, SysV callee-saves)
│  ├─ rbx  ← frame_ptr                              (surviving nested calls)
│  ├─ r12  ← cr2                                    (faulting VA)
│  ├─ r13  ← error_code = [rbx + 128]
│  ├─ (validate: r13 & (ERR_P|ERR_W) == (ERR_P|ERR_W) — else fall to real-fault panic)
│  ├─ (validate: r13 & (ERR_RSVD|ERR_ID) == 0 — else panic)
│  ├─ walk cr3→PML4→PDPT→PD→PT   (mirrors aspace_map descent, read-only)
│  │    r14 ← &PT[idx]           (leaf slot address, VA-form for indexing)
│  │    r15 ← *r14               (leaf PTE value)
│  ├─ (validate: r15 & PTE_PRESENT != 0 — else panic)
│  ├─ (validate: r15 & PTE_RW == 0     — else panic; unexpected write-to-writable)
│  ├─ (validate: r15 & PTE_COW != 0    — else panic; unexpected R-only fault)
│  ├─ old_pa ← r15 & PTE_FRAME_MASK   (into rdi for frame_meta_get)
│  ├─ refcount ← frame_meta_get(old_pa)
│  ├─ if refcount == 1:  goto pf_cow_flip
│  ├─ if refcount >  1:  goto pf_cow_split
│  └─ (refcount == 0 or FRAME_META_INVALID ⇒ panic; caller broke invariant)
│
│  pf_cow_flip:
│  ├─ new_pte = (r15 | PTE_RW) & ~PTE_COW           (last owner: promote in place)
│  ├─ [r14] ← new_pte
│  ├─ tlb_shootdown_local(cr2 = r12)
│  ├─ pop r15..rbx; return PF_HANDLE_OK
│
│  pf_cow_split:
│  ├─ new_va ← phys_alloc(0)                        (fresh frame, refcount=1)
│  ├─ (validate: new_va != 0 — else panic; R15 has no OOM signalling to userland yet)
│  ├─ old_va ← old_pa + KERNEL_VMA_BASE             (source: existing PA form → VA)
│  ├─ memcpy_page(new_va, old_va, 512)               (512 × u64 = 4096 bytes; unrolled tight loop)
│  ├─ new_pa ← new_va - KERNEL_VMA_BASE             (PA field for PTE)
│  ├─ preserve_flags = r15 & (PTE_US | 0x8000000000000000)  (bit 2 U + bit 63 NX)
│  ├─ new_pte = new_pa | PTE_PRESENT | PTE_RW | preserve_flags   (PTE_COW cleared)
│  ├─ [r14] ← new_pte
│  ├─ tlb_shootdown_local(cr2 = r12)
│  ├─ phys_free(old_pa, 0)                          (drives refcount decref-guard: n→n-1≥1 → keep bit)
│  ├─ pop r15..rbx; return PF_HANDLE_OK
│
└─ pf_real_fault:
   ├─ pop r15..rbx
   └─ call handle_pf (existing panic path in exceptions.pdx)

exceptions.pdx
└─ _typed_handler_14 rewrite (~15 LOC diff, same shape as vec6/vec13 witness dispatch):
   ├─ Load _cow_witness_active flag
   ├─ If set: call pf_handle_cow with rdi = frame_ptr; ret
   ├─ Else: call handle_pf (existing panic path); ret
```

### 3.2 Trap frame layout (what `frame_ptr` in RDI points at)

`trampoline_vec14` (`idt.pdx:174-192`) push sequence and CPU-pushed
frame:

```
CPU pushes on #PF (Intel SDM Vol 3A §6.14):
  SS       ← rsp+168
  RSP      ← rsp+160         (user rsp at fault)
  RFLAGS   ← rsp+152
  CS       ← rsp+144
  RIP      ← rsp+136         (faulting instruction's IP; #PF is a fault, RIP is re-executed)
  errcode  ← rsp+128         (bit 0=P, 1=W, 2=U, 3=RSVD, 4=ID, 5=PK, 15=SS, ...)

Trampoline pushes:
  vector   ← rsp+120         (14, decimal)
  rax      ← rsp+112
  rcx      ← rsp+104
  rdx      ← rsp+96
  rbx      ← rsp+88
  rbp      ← rsp+80
  rsi      ← rsp+72
  rdi      ← rsp+64
  r8       ← rsp+56
  r9       ← rsp+48
  r10      ← rsp+40
  r11      ← rsp+32
  r12      ← rsp+24
  r13      ← rsp+16
  r14      ← rsp+8
  r15      ← rsp+0            <-- rdi in typed_handler = &r15
```

Handler needs offsets:
- **error_code**: `[rbx + 128]`
- **faulting RIP**: `[rbx + 136]` (for future diagnostics; not modified by handler — #PF is a fault, CPU will re-execute the write on `iretq`, and the promoted PTE makes it succeed).
- **CS** (=+144): used only if we want to check ring-3 vs ring-0 for
  policy; not read at R15.M6.
- **RFLAGS** (=+152), user RSP (=+160), SS (=+168): untouched.

Since this matches `_typed_handler_6`'s existing use of
`[r12 + 136]` for RIP advancement, the offset arithmetic is
independently audited.

**No frame surgery is required.** Unlike vec6 (advance RIP past
ud2) or vec13 (redirect to kernel resume), a #PF is a *fault*:
CPU-pushed RIP points at the faulting write, and once the PTE is
promoted (fast path) or replaced (split path), the CPU
transparently re-executes the write on `iretq`.

### 3.3 Error-code decode (`[rbx + 128]`)

Bits per Intel SDM Vol 3A §6.14:

| Bit | Mnemonic | Meaning                                                                    | Handler action |
|-----|----------|----------------------------------------------------------------------------|----------------|
| 0   | P        | 1 = page-level protection violation; 0 = non-present.                     | **MUST be 1** for CoW (page is mapped R-only). If 0 ⇒ real fault (demand-page). Panic. |
| 1   | W/R      | 1 = write access; 0 = read.                                               | **MUST be 1** for CoW (only writes trigger split). If 0 ⇒ unexpected read-fault on a present page — panic (SMEP violation? PKE?). |
| 2   | U/S      | 1 = ring 3; 0 = ring 0.                                                   | Not decoded at R15.M6. §7 backtrack C parks a "user-only CoW" mode. |
| 3   | RSVD     | 1 = reserved bit set in a PTE ancestor.                                    | **MUST be 0**. If 1 ⇒ page-table corruption. Panic. |
| 4   | I/D      | 1 = instruction fetch (only when NX enforced).                             | **MUST be 0** (CoW is a data-write fault). Panic. |
| 5   | PK       | 1 = protection-key violation.                                             | **MUST be 0**. R15 doesn't enable IA32_PKRS. Panic. |
| 6   | SS       | 1 = shadow-stack (CET).                                                    | **MUST be 0**. R15 doesn't enable CET. Panic. |
| 15  | SGX      | 1 = SGX-EPCM violation.                                                   | **MUST be 0**. QEMU without `-cpu +sgx`. Panic. |

Handler validation collapse (single mask+cmp):

```asm
mov rax, r13                           ; r13 = error_code
mov rcx, 0x8069                        ; ERR_P | ERR_W | ERR_RSVD | ERR_ID | ERR_PK | ERR_SS | ERR_SGX
and rax, rcx                           ; keep only the classify bits we look at
cmp rax, 0x3                           ; must be exactly ERR_P|ERR_W, none of RSVD/ID/PK/SS/SGX
jne pf_real_fault
```

Bit 2 (U/S) is deliberately masked out — CoW is valid from ring 0
(kernel writes to a CoW-mapped page, e.g. the sub-test A/B witnesses
in §5) *and* from ring 3 (fork'd child writes shared page). See §7
backtrack C for a "ring-3-only" hardening variant.

### 3.4 PTE bit assignment for CoW marker — bit 9 (mask 0x200)

**Chosen: PTE bit 9 (mask 0x0000000000000200).**

x86_64 4-KiB leaf PTE format (Intel SDM Vol 3A §4.11.1, "PS=0 leaf"):

```
 63    62..59    58..52    51......12   11..9   8   7   6   5   4   3   2   1   0
 XD  |  PKE  |  AVL   | phys frame | AVL | G | PAT| D | A |PCD|PWT| U | RW| P
```

Bits 9, 10, 11 are the "AVL" (available) slots defined by Intel as
"ignored by hardware". Bit fields 52..58 are also AVL but participate
in **CET shadow-stack** (bit 60), **PKS/PKE** (bits 59..62), and
**5-level paging** future-encodings. Choosing an AVL bit from the
[9..11] window is the only future-proof pick.

**Why bit 9 specifically:**

1. **Convention match with Linux `_PAGE_BIT_SOFTW1` (bit 9).** Every
   memory-management developer reads bit 9 as "OS metadata" on
   first glance. Bit 10 and 11 are used in Linux for
   `_PAGE_BIT_SOFTW2/SOFTW3` (numa hinting, uffd_wp) — bit 9
   is the reserved-for-generic-CoW slot in Linux terminology.
   Aligning with mainstream x86 kernel convention lowers the
   cognitive-load cost for future contributors (and for
   architectural readers coming from Linux/xv6/seL4).
2. **Encoder friendliness.** `0x200` is a 10-bit immediate — fits in
   any x86 immediate-mode ALU op without a `movabs`. Compare with
   bit 52 = `0x0010000000000000`, which requires `movabs` staging
   for both set and clear operations, doubling the instruction
   count.
3. **No collision with existing PaideiaOS PTE bits.** `aspace_map`
   composes flags `PTE_PRESENT | PTE_RW | PTE_US` = bits 0/1/2 and
   sometimes bit 63 (NX). None of these touch bit 9. A grep for
   `0x200` in `core/mm/` shows only CR4 SMAP (`smap.pdx:33`)
   which is a control-register mask, not a PTE mask — no
   file-level ambiguity.
4. **Consistency with `aspace_clone_cow`'s eventual write site.**
   #552 will `OR PTE_COW` when copying a writable PTE into a
   child aspace; bit 9 keeps that composition to a single
   register-register OR.

**Non-choices:**

- **Bit 10 (0x400)**: also OS-available, also 10-bit immediate.
  Chosen against for convention-mismatch (Linux `_PAGE_BIT_SOFTW2`
  is numa-hinting), but a valid alternative — §7 backtrack B.
- **Bit 52 (0x0010000000000000)**: OS-available but requires
  `movabs` staging on set/clear paths; also collides with future
  5-level paging metadata. §7 backtrack B rejects.
- **Bit 63 (NX/XD)**: architecturally defined, not available.
- **Bit 6 (D = dirty)**: hardware-managed; hijacking would confuse
  future dirty-tracking (page daemon at R17+).

**Interaction with the huge-page bit (PS=1, bit 7)**: at leaf-PT
level (4 KiB), bit 7 is PAT, not PS. At PDPT/PD levels PS=1 means
huge-page; `aspace_map.pdx:129,167` already handles huge-page
descent by returning `MAP_HUGE`. This handler mirrors the check: any
PS=1 encountered during descent ⇒ real fault (huge pages are not
CoW-marked at R15.M6; §7 backtrack E parks 2-MiB CoW split).

### 3.5 Register discipline — 5-push prologue

Handler body drives:
- `frame_meta_get` (uses rax, rcx, rdi only — from #559 §3.3)
- `phys_alloc` (preserves r12..r15; #649 fix — see phys_alloc.pdx:30)
- `phys_free` (uses caller-save r8..r11 + rdi/rsi/rax; preserves r12..r15)
- `tlb_shootdown_local` (uses rdi only; per its own body)

None of the callees preserve rbx, rbp beyond SysV. We need
**five callee-save slots** across the whole body:

| Reg | Live through phase                                                                 | Why callee-save |
|-----|------------------------------------------------------------------------------------|-----------------|
| rbx | `frame_ptr` — survives every call to fetch RIP for future diagnostics if needed.  | frame_ptr must survive the whole body; rdi is clobbered by every callee. |
| r12 | `cr2` (faulting VA) — needed at split, tlb_shootdown_local, potential invalidation. | Read once, used at write-PTE, tlb, and possibly retry point. |
| r13 | `error_code` — used for real-fault decision + panic diagnostics.                   | Read once from stack, may be re-consulted at panic branch. |
| r14 | `&PT[idx]` — leaf-PTE slot address — written to on both fast and split paths.      | Must survive `frame_meta_get`, `phys_alloc`, memcpy loop, `phys_free`. |
| r15 | leaf PTE value (raw). Used to derive old_pa, preserve U/NX flags on split.         | Must survive `frame_meta_get`, `phys_alloc`, memcpy loop. |

Prologue (echoes `aspace_map.pdx:52-55` + one more for rbx):

```asm
push rbx;     ; frame_ptr survives all calls
push r12;     ; cr2
push r13;     ; error_code
push r14;     ; &PT[idx]
push r15;     ; PTE value
mov rbx, rdi; ; frame_ptr
```

Epilogue (both PF_HANDLE_OK exits):

```asm
pop r15; pop r14; pop r13; pop r12; pop rbx
xor rax, rax          ; PF_HANDLE_OK
ret
```

Real-fault epilogue:
```asm
pop r15; pop r14; pop r13; pop r12; pop rbx
call handle_pf         ; fall into the existing panic path
ret
```

**5-push stack alignment**: 5 × 8 = 40 bytes = odd multiple of 8.
The SysV ABI requires `rsp % 16 == 0` at `call`-site entry.
`_typed_handler_14`'s outer trampoline lands with `rsp` mis-aligned
by 8 (16 CPU-pushed qwords + vector = odd count). Adding 5 pushes
lands the internal `call`s aligned. If audits show otherwise (e.g.
IST switch changes the invariant), pad one dummy push (`push rbp;
mov rbp, rsp`) — same shape as `aspace_map`'s 4-push. §7 backtrack F
covers the mitigation.

**Memcpy inline vs library**: no `memcpy` primitive lands until
R17+. Inline a tight loop:

```asm
; rdi = new_va, rsi = old_va, rcx = 512 (u64 count)
xor rax, rax        ; loop index
memcpy_loop:
  cmp rax, 512
  jae memcpy_done
  mov r8, [rsi + rax*8]
  mov [rdi + rax*8], r8
  add rax, 1
  jmp memcpy_loop
memcpy_done:
```

~10 instructions; unrolls trivially at future optimization. Uses
rax/r8/rcx (all caller-save) — no additional callee-save pressure.

### 3.6 Walker sequence — mirror of `aspace_map` (read-only)

The handler needs a read-only PML4→PDPT→PD→PT descent from
current CR3. Mirror `aspace_map.pdx:62-174` but:

- **No intermediate allocation** — if any level's entry is absent
  (present bit 0), that's `pf_real_fault`. CoW faults land on
  fully-populated tables (something is mapped there, just R-only).
- **No PTE_US injection or huge-page splitting** — huge PS=1 at
  PDPT/PD ⇒ `pf_real_fault` (§7 backtrack E parks 2-MiB CoW).
- **VA/PA discipline identical**: stored table-pointer PA gets
  `+ KERNEL_VMA_BASE` restored for [reg + idx*8] indexing.

Skeleton (VA extract → PML4[i] → present-check → next):

```asm
; ---- Level 4: PML4 ----
mov rax, cr3
and rax, PTE_FRAME_MASK                ; strip PCID etc
mov rcx, KERNEL_VMA_BASE
add rax, rcx                            ; PML4 VA
mov r9, r12                             ; r9 = cr2 (VA to walk)
mov rcx, r9
shr rcx, 39
and rcx, 0x1FF                          ; PML4 index
mov r10, [rax + rcx * 8]                ; r10 = PML4[i]
test r10, PTE_PRESENT
jz pf_real_fault
test r10, 0x80                          ; PS bit — invalid at PML4 (should be 0)
jnz pf_real_fault

; ---- Level 3: PDPT ----
mov rax, r10
and rax, PTE_FRAME_MASK
mov rcx, KERNEL_VMA_BASE
add rax, rcx                            ; PDPT VA
mov rcx, r12
shr rcx, 30
and rcx, 0x1FF
mov r10, [rax + rcx * 8]
test r10, PTE_PRESENT
jz pf_real_fault
test r10, 0x80                          ; huge 1GiB ⇒ not our fault
jnz pf_real_fault

; ---- Level 2: PD ----
mov rax, r10
and rax, PTE_FRAME_MASK
mov rcx, KERNEL_VMA_BASE
add rax, rcx                            ; PD VA
mov rcx, r12
shr rcx, 21
and rcx, 0x1FF
mov r10, [rax + rcx * 8]
test r10, PTE_PRESENT
jz pf_real_fault
test r10, 0x80                          ; huge 2MiB ⇒ not our fault
jnz pf_real_fault

; ---- Level 1: PT leaf ----
mov rax, r10
and rax, PTE_FRAME_MASK
mov rcx, KERNEL_VMA_BASE
add rax, rcx                            ; PT VA
mov rcx, r12
shr rcx, 12
and rcx, 0x1FF
lea r14, [rax + rcx * 8]                ; r14 = &PT[i] (surviving)
mov r15, [r14]                          ; r15 = leaf PTE
```

Reuse pattern from `aspace_map` — walker altitude is a known-good
substrate. This is a **read-only** walk: no phys_alloc, no writes,
no invlpg during descent. The one write happens at the leaf,
followed by one invlpg on the faulting VA.

### 3.7 Fast-flip path (refcount == 1) — 6 instructions after walk

```asm
; r15 = current PTE, r14 = &PT[i], r12 = cr2
mov rax, r15
or  rax, PTE_RW                         ; set writable
mov rcx, PTE_COW
not rcx
and rax, rcx                            ; clear PTE_COW (0x200 → 0)
mov [r14], rax                          ; store new PTE
mov rdi, r12                            ; cr2
call tlb_shootdown_local
```

Rationale for keeping PTE_COW-clear: once the last owner promotes to
R+W, the page is no longer a CoW subject. A future
`aspace_clone_cow` re-share would re-set PTE_COW on both sides.
This invariant matches the `_frame_meta[i] >= 1 ⇔ bitmap bit set`
invariant from #559 — a page with refcount 1 and PTE_COW = 0 is a
normal, writable, singly-owned page.

Preserving vs stripping non-touched flag bits: `or PTE_RW; and
~PTE_COW` mutates only bits 1 and 9. Bits 2 (U/S), 63 (NX), 3..8
(PWT/PCD/A/D/PAT/G), and the frame-field 12..51 are preserved
verbatim. This is the intended shape — the page keeps its
user-accessibility and NX policy across the flip.

### 3.8 Split path (refcount > 1) — call-heavy but bounded

Full sequence after the walk (r15=PTE, r14=&PT[i], r12=cr2,
old_pa = r15 & PTE_FRAME_MASK):

```asm
mov rdi, 0
call phys_alloc                         ; new frame; refcount=1 (via #559)
cmp rax, 0
je pf_real_fault                        ; OOM at R15.M6 → panic (no OOM-signal to user)
mov r8, rax                             ; r8 = new_va (VA form from phys_alloc)

; --- copy old → new (4 KiB = 512 × u64) ---
mov rax, r15
mov rcx, PTE_FRAME_MASK
and rax, rcx                            ; old_pa
mov rcx, KERNEL_VMA_BASE
add rax, rcx                            ; old_va
mov rsi, rax                            ; rsi = old_va (source)
mov rdi, r8                             ; rdi = new_va (dest)
xor rax, rax
memcpy_loop:
  cmp rax, 512
  jae memcpy_done
  mov r9, [rsi + rax * 8]
  mov [rdi + rax * 8], r9
  add rax, 1
  jmp memcpy_loop
memcpy_done:

; --- build new PTE = new_pa | PTE_PRESENT | PTE_RW | preserved flags ---
mov rax, r8
mov rcx, KERNEL_VMA_BASE
sub rax, rcx                            ; rax = new_pa
mov rcx, PTE_FRAME_MASK
and rax, rcx                            ; frame field
; preserve U (bit 2) + NX (bit 63) from old PTE
mov r9, r15
mov r10, 0x8000000000000004             ; NX | US mask
and r9, r10
or  rax, r9                             ; add preserved flags
or  rax, 0x3                            ; | PTE_PRESENT | PTE_RW
mov [r14], rax                          ; store new PTE (PTE_COW naturally 0)

; --- invalidate TLB for the faulting VA ---
mov rdi, r12
call tlb_shootdown_local

; --- decref old frame (drives #559's decref-guard: n → n-1 ≥ 1 → keep bit) ---
mov rax, r15
mov rcx, PTE_FRAME_MASK
and rax, rcx                            ; old_pa
mov rdi, rax
xor rsi, rsi                            ; order = 0
call phys_free
```

Then epilogue (5-pop + PF_HANDLE_OK).

**Why decref *after* the PTE write**: if the write faulted mid-way
(NMI, MCE), we'd still have the old frame reachable via the other
sharer's aspace — freeing it prematurely would risk a stale
reference. Ordering: (1) new frame written into current PTE, (2)
TLB invalidated, (3) old frame decref'd. This is the same
ordering Linux uses in `do_wp_page` (mm/memory.c wp_page_copy).

**PTE_COW cleared implicitly**: the split-path build uses
`or rax, 0x3` — bit 1 (RW) is set, bit 9 (COW) is neither read nor
set. The new PTE has PTE_COW=0.

**Second sharer keeps PTE_COW=1**: the other aspace's PTE (call it
PTE_B) is untouched. When *that* aspace's process next writes to
the page, its own #PF fires, its own pf_handler runs, sees
refcount==1 (this was the last sharer), and takes the fast-flip
path. This matches CMS-D2 (first-writer-wins split, last writer
gets the original frame back R+W).

**refcount==0 or FRAME_META_INVALID**: caller broke the invariant.
Fall through to `pf_real_fault` (panic).

### 3.9 Invariant preservation

The frame_meta invariant (`bitmap bit i == 1 ⇔ _frame_meta[i] ≥ 1`
from #559 §3.6) must survive the CoW split. Walk the states:

**Fast flip (refcount == 1)**:
- Before: `(bit=1, refcount=1)`. No allocator activity.
- PTE flipped R-only + COW → R+W.
- After: `(bit=1, refcount=1)`. Invariant holds.

**Split (refcount == n ≥ 2)**:
1. Before: old frame `(bit=1, refcount=n)`.
2. `phys_alloc` returns new frame: new `(bit=1, refcount=1)`,
   old unchanged. Invariant holds on both.
3. `phys_free(old_pa, 0)`: #559's guard decrements `n → n-1 ≥ 1`,
   does *not* clear the bitmap bit. Old becomes `(bit=1,
   refcount=n-1)`. Invariant holds.

After the second sharer's own fault fires and takes the fast-flip
path, old becomes `(bit=1, refcount=1, PTE_COW=0, PTE_RW=1)` — a
normal singly-owned page. Full CoW round-trip complete.

**Loose-end audit**: no path leaves a frame with `PTE_COW=1` and
`refcount==1` — the fast-flip clears PTE_COW. This prevents a
stale-COW scenario where a future write would try to split against
itself.

## 4. Interaction with the VA/PA landmine (#658) and #649's normalizer

### 4.1 VA/PA discipline points

The handler crosses the VA/PA boundary at three sites; each mirrors
existing, audited discipline:

1. **CR3 → PML4 VA**: current CR3 stores a genuine PA. Add
   `KERNEL_VMA_BASE` for software indexing (`aspace_map.pdx:97-98`
   pattern).
2. **Stored table pointer → next-level VA**: same
   `mask & PTE_FRAME_MASK; add KERNEL_VMA_BASE` shape as
   `aspace_map` PDPT / PD / PT descents.
3. **PTE frame field**: PA. `phys_alloc` returns VA (bit 63 set —
   #658 landmine). Convert VA↔PA at both write-PTE (VA→PA) and
   copy-source (PA→VA).

The handler is passed to `phys_free` in **PA form** (extracted
from PTE bits 12..51 — genuine hardware PA). #559's phys_free
normalizer handles both regimes via the bit-63 test; the PA path
adds `KERNEL_VMA_BASE` and continues. Same 5-instruction preamble
as `phys_free.pdx:26-30` — no new normalizer surface.

### 4.2 #658 landing order — not gating

- **If #658 lands first** (phys_alloc returns real PAs): the
  handler's VA↔PA conversions become simpler (fewer `add
  KERNEL_VMA_BASE` sites). Rewrite is mechanical.
- **If #658 lands after #553**: current mixed regime works. The
  handler's VA↔PA discipline is symmetric with `aspace_map` — any
  future normalization pass touches both consistently.

Neither ordering is a blocker. Same landing-order-agnostic
property as #559.

## 5. Test canary — kernel_main witness block (two sub-tests)

### 5.1 Witness placement

Insert the CoW witness in `boot/kernel_main.pdx`'s `kernel_main_64`
immediately **after** the frame_meta witness block (currently at
lines 133-209, ending at label `fm_done:`), and **before** the KPTI
structural witness. Placement rationale:

- Runs after `R15 FRAME META OK` — so if frame_meta broke, we see
  its FAIL first and don't attribute the regression to pf_handler.
- Runs before the KPTI / ring-3 / loader witnesses — so any
  subsequent boot progression is empirical evidence that this
  block didn't disturb subsequent state (CR3 restored, PTE state
  restored, frame_meta state consistent).

### 5.2 Sub-test A — single-owner fast-flip (refcount == 1)

Purpose: prove the fast-flip path fires when refcount is 1.

**Setup**:
1. `_cow_witness_active = 1` (armed).
2. Build a fresh witness PML4 (`aspace_create(_kernel_pml4_pa)`).
3. `new_pa = phys_alloc(0)` — refcount born at 1 (#559 wire-in).
4. Fill `[new_va]` with a canary (e.g. `0xDEADBEEF_CAFEF00D`) at
   offset 0.
5. `aspace_map(witness_pml4, 0x400000, new_pa, 0x005)` — flags
   R-only + U + P (bit 1 W = 0). No PTE_COW yet.
6. Then walk the witness PML4 and OR PTE_COW (0x200) onto the leaf
   PTE at PT[idx=0]. No refcount change (still 1).
7. Save current CR3 into `_kernel_resume_cr3_scratch`.
8. `mov cr3, witness_pml4_pa`.

**Drive**:
9. `mov rax, [0x400000]` — read canary succeeds (R-only allows
   read). Verify contents == `0xDEADBEEF_CAFEF00D`. Written as
   witness assertion.
10. `mov qword [0x400000], 0x11111111_22222222` — **write triggers
    #PF** (bit W=1, PTE_RW=0). Handler fires:
    - Reads CR2 = 0x400000
    - Walks: PT[0] shows PTE with PTE_PRESENT + PTE_COW +
      PTE_RW=0.
    - Reads refcount = 1.
    - Fast-flip: OR PTE_RW, AND ~PTE_COW → PTE_PRESENT | PTE_RW |
      PTE_US, frame unchanged.
    - `tlb_shootdown_local(0x400000)`.
    - `iretq` → CPU retries the write; PTE is now writable; write
      succeeds.

**Verify**:
11. `mov rax, [0x400000]` — reads back `0x11111111_22222222`.
    Write landed. Assert.
12. Walk the witness PML4 to inspect PT[0]:
    - PTE_PRESENT set (bit 0 = 1). Assert.
    - PTE_RW set (bit 1 = 1). Assert.
    - PTE_COW clear (bit 9 = 0). Assert.
    - Frame field == `new_pa` (unchanged — fast flip, no realloc).
      Assert.
13. `frame_meta_get(new_pa) == 1` (unchanged). Assert.
14. `phys_alloc_free_count()` unchanged from start of sub-test A.
    Assert.

**Teardown**:
15. Restore CR3 to kernel PML4 (`_kernel_resume_cr3_scratch`).
16. `phys_free(new_pa, 0)` — refcount 1 → 0, bit cleared.
17. `phys_free(witness_pml4_pa, 0)`. (aspace_teardown is
    subsystem-1 concern; MVP witness explicitly frees the PML4
    frame.)
18. `_cow_witness_active = 0`.

### 5.3 Sub-test B — multi-owner split (refcount == 2)

Purpose: prove the split path fires when refcount > 1, and only
the *writing* aspace's PTE is rebound.

**Setup**:
1. `_cow_witness_active = 1` (still armed from A — or re-armed).
2. Build two witness PML4s (`aspace_A_pa`, `aspace_B_pa`), each
   with kernel higher-half copy.
3. `shared_pa = phys_alloc(0)` — refcount 1.
4. Fill `[shared_va]` with canary `0xAAAAAAAA_BBBBBBBB` at offset
   0.
5. `aspace_map(aspace_A_pa, 0x400000, shared_pa, 0x005)` — R-only
   + U + P.
6. OR PTE_COW onto A's PT[0].
7. `aspace_map(aspace_B_pa, 0x400000, shared_pa, 0x005)` — R-only
   + U + P.
8. OR PTE_COW onto B's PT[0].
9. `frame_meta_incref(shared_pa)` — refcount 1 → 2. Simulates the
   #552 walker step; the pf_handler is agnostic to who did the
   incref.
10. Assert `frame_meta_get(shared_pa) == 2`.
11. Save CR3 into `_kernel_resume_cr3_scratch`.
12. `mov cr3, aspace_A_pa` (activate aspace A).

**Drive from A**:
13. Read canary at 0x400000 (aspace A) — succeeds. Assert.
14. `mov qword [0x400000], 0x00000000_DEADCAFE` — **triggers #PF**.
    Handler fires:
    - Reads CR2 = 0x400000.
    - Walks aspace A's PML4 → PT[0].
    - Reads refcount = 2. Split path.
    - `phys_alloc` returns `new_pa_A` (refcount born at 1).
    - Copies 4 KiB from `shared_pa+KERNEL_VMA_BASE` to
      `new_pa_A+KERNEL_VMA_BASE` (=phys_alloc's VA return).
    - Writes A's PT[0] to `new_pa_A | 0x007` (P+RW+US).
      PTE_COW=0.
    - `tlb_shootdown_local(0x400000)`.
    - `phys_free(shared_pa, 0)` — #559 guard: refcount 2→1, bit
      stays set.
    - `iretq` → CPU retries the write; PTE is now writable and
      points at `new_pa_A`; write lands in new frame.

**Verify from A**:
15. `mov rax, [0x400000]` reads `0x00000000_DEADCAFE` (new
    contents). Assert.
16. Walk aspace A's PT[0]: frame field == `new_pa_A`, PTE_COW = 0,
    PTE_RW = 1. Assert.
17. `frame_meta_get(shared_pa) == 1`. Assert (down from 2).
18. `frame_meta_get(new_pa_A) == 1`. Assert.

**Cross-check via aspace B (activate to inspect)**:
19. `mov cr3, aspace_B_pa`.
20. `mov rax, [0x400000]` — reads `0xAAAAAAAA_BBBBBBBB` (original
    canary in `shared_pa`). Assert.
21. Walk B's PT[0]: frame field == `shared_pa` (unchanged),
    PTE_COW = 1 (unchanged), PTE_RW = 0 (unchanged). Assert.

**Teardown**:
22. Restore CR3 to kernel PML4.
23. `phys_free(shared_pa, 0)` — refcount 1 → 0, bit cleared.
24. `phys_free(new_pa_A, 0)` — refcount 1 → 0, bit cleared.
25. `phys_free(aspace_A_pa, 0)`.
26. `phys_free(aspace_B_pa, 0)`.
27. `_cow_witness_active = 0`.

### 5.4 Combined witness marker

If both A and B pass:
```asm
lea rdi, [rip + pf_cow_ok_msg]
call uart_puts
```

Emits `R15 PF COW OK`. Any FAIL: emit `R15 PF COW FAIL`.

### 5.5 Ring-0 vs ring-3 driver choice

Both sub-tests fire the write **from ring 0**. Rationale:

- The handler's contract is agnostic to CS ring — CR2, error_code
  bit W, PML4 walk, PTE shape are identical for ring-0 and ring-3
  writes. Ring-0 keeps the witness self-contained: no ring-3
  entry/exit plumbing, no need to route the fault back to a
  kernel resume path (compare #652's `_ring3_witness_active`
  drama).
- Ring-3 CoW is the same code path with error_code bit 2 = 1.
  #552's fork fixture will exercise ring-3 CoW natively at
  R15.M6 close (once #552 relands); the witness is not obligated
  to double-book that.
- SMAP/SMEP interactions: SMAP raises #PF (not #GP) on ring-0
  read/write of PTE_US=1 pages *only when EFLAGS.AC=0*. The
  witness runs after `smap_enable`, so ring-0 writes to
  PTE_US=1 pages would be SMAP-blocked. §7 backtrack D covers
  the mitigation — either `stac`/`clac` around the witness
  writes, or map the CoW page with PTE_US=0 for the witness
  (still exercises the R-only + PTE_COW path).

**Preferred mitigation**: sub-tests A and B map the CoW page with
`flags = 0x003` (P + RW=0 pre-mask, actually `0x001` — just P; we
manually OR PTE_COW). No PTE_US bit → SMAP does not object to
ring-0 access. When #552 lands, its clone walker will produce
`P | US | COW` PTEs, which pf_handler consumes identically —
the U bit is preserved verbatim by the split path (§3.8) and by
the flip path (§3.7).

Actually more precisely: sub-tests set flags = `0x001` (just P),
then OR `PTE_COW = 0x200`. Handler expects PTE_PRESENT set (bit
0), PTE_RW clear (bit 1), PTE_COW set (bit 9). PTE_US is
irrelevant to handler validation — the "preserved-flags" pipe
carries whatever U bit was there through the promotion.

### 5.6 Rodata / bss additions (`tools/boot_stub.S`)

```asm
# R15-M6-002 (#553): pf_handler CoW witness success message
.global pf_cow_ok_msg
.align 8
pf_cow_ok_msg: .ascii "R15 PF COW OK\n\0"

# R15-M6-002 (#553): pf_handler CoW witness failure message
.global pf_cow_fail_msg
.align 8
pf_cow_fail_msg: .ascii "R15 PF COW FAIL\n\0"

# R15-M6-002 (#553): dispatch flag consumed by _typed_handler_14
.section .bss
.global _cow_witness_active
.align 8
_cow_witness_active: .skip 8

# R15-M6-002 (#553): CR3-restore scratch for CoW witness teardown
.global _kernel_resume_cr3_scratch
.align 8
_kernel_resume_cr3_scratch: .skip 8
```

Placement: after `frame_meta_fail_msg` (line 424), before
`exit_marker_msg`.

### 5.7 Fingerprint drift

Extend two fingerprint files (contains-in-order):

`tests/r15/expected-boot-r15-ring3.txt`:
```diff
 R15 FRAME META OK
+R15 PF COW OK
 KPTI OK
```

`tests/r15/expected-boot-r15-process.txt`:
```diff
 R15 FRAME META OK
+R15 PF COW OK
 KPTI OK
```

The `boot_r8_only`, `boot_r10`, `boot_r11`, `boot_r12`, and
`boot_r12_denial` fingerprints are pre-`phys_alloc` substrate; no
change required (they exit before `kernel_main_64` reaches the CoW
witness).

### 5.8 Callee-save discipline in the witness

The witness uses r12..r15 across nested `phys_alloc`, `phys_free`,
`aspace_create`, `aspace_map`, `frame_meta_get`,
`frame_meta_incref`, `uart_puts` calls — all preserve r12..r15
(audited via `phys_alloc.pdx:30-33` prologue, `aspace_map.pdx:52-55`,
`aspace_create.pdx:43-45`, #559 §5.6). No push/pop needed inside
the witness beyond scope-local scratches.

## 6. LOC estimate

| File                                                             | LOC delta |
|------------------------------------------------------------------|-----------|
| `src/kernel/core/mm/pf_handler.pdx` (12 → ~180 LOC)              | **+170**  |
| `src/kernel/core/int/exceptions.pdx` (_typed_handler_14 rewrite) | +18       |
| `src/kernel/boot/kernel_main.pdx` (2-sub-test witness block)     | +140      |
| `tools/boot_stub.S` (3 rodata + 2 bss slots)                     | +20       |
| `tests/r15/expected-boot-r15-ring3.txt`                          | +1        |
| `tests/r15/expected-boot-r15-process.txt`                        | +1        |
| `design/kernel/r15-m6-002-pf-handler-cow-split.md` (this)        | +840      |
| **Total**                                                        | **~1190** |

Executable + rodata + fingerprint: ~350 LOC. Design: ~840 LOC.
About 1.4× the size of #559 (~773 LOC total); the extra sits in
the two-sub-test witness (setup + drive + verify + teardown for
two distinct CoW scenarios) and the deeper walker sequence.
Well within milestone budget.

## 7. Backtrack candidates

Ordered by preference.

### 7.1 Backtrack A — Move `mov rax, cr2` into `read_cr2` primitive (recommended primary path)

Extend `exceptions.pdx:94`'s `read_cr2` to emit the real instruction
`mov rax, cr2` (encoding `0F 20 D0`), replacing the current `mov rax,
rax` placeholder. Then `pf_handle_cow` calls `read_cr2` instead of
inlining.

**Advantages**: Single audit site for CR2 reads. `read_cr2` becomes
useful for future non-CoW #PF diagnostics (demand paging, guard
extension).

**Disadvantages**: Extra `call`/`ret` on the fault-hot path (~10
cycles). Negligible at R15 substrate.

**Adopt as primary path**.

### 7.2 Backtrack B — CoW marker on bit 10 or 52

Use PTE bit 10 (mask 0x400) or bit 52 (0x0010000000000000) instead
of bit 9.

**Advantages**: Bit 10 avoids potential future collision if Linux's
`_PAGE_BIT_SOFTW1` convention drifts. Bit 52 is architecturally
partitioned into "OS-only" per Intel SDM.

**Disadvantages**: Bit 10 breaks Linux-convention alignment (higher
cognitive-load cost for readers). Bit 52 requires `movabs` staging
on set/clear paths — doubles instruction count on fast flip.
Bit 52 collides with 5-level paging future encodings and CET.

**Reject**. Bit 9 is the right pick; §3.4 justifies. Would only
revisit if future architectural work (`_PAGE_BIT_EXCLUSIVE` for
zero-page CoW, etc.) needs bit 9.

### 7.3 Backtrack C — Ring-only CoW enforcement

Reject CoW faults from ring 0. Check `error_code & ERR_U` in the
handler; if 0, panic even on otherwise-valid CoW shape.

**Advantages**: Prevents accidental kernel-mode CoW faults (which
should never occur once #552 lands and only user code triggers
CoW).

**Disadvantages**: Breaks sub-tests A and B (both drive from ring
0). Requires a different witness strategy (real ring-3 entry, which
means enter-userland+resume-from-#PF plumbing, comparable in
complexity to #652 but for a data-fault-then-continue rather than a
one-shot GP fault → kernel resume). Adds real-fork-fixture-shape
churn.

**Reject at R15.M6**. Revisit at R16 when a task-kill primitive
lands and can replace the ring-0 CoW witness with a fork fixture.

### 7.4 Backtrack D — SMAP interaction: witness maps CoW page with PTE_US=0

Sub-tests map the CoW page with PTE_US=0 (kernel-only) to sidestep
SMAP objections. §5.5 already picks this.

**Advantages**: No `stac`/`clac` dance. Handler behavior identical
regardless of U bit (§3.8 preserves U across split).

**Disadvantages**: Doesn't exercise the U=1 path in the witness. #552's
fork fixture will exercise U=1 CoW natively.

**Adopt for §5 witness. Deferred to #552 for U=1 coverage.**

### 7.5 Backtrack E — 2-MiB huge-page CoW split

Extend the handler to handle CoW on PS=1 (2-MiB PD) leaves: allocate
9 order-0 frames (or one order-9 buddy allocation, when buddy
activates), copy 2 MiB, rewrite the PD entry as a PT pointer,
demote to 512 × 4-KiB PTEs, split refcounts.

**Advantages**: Enables CoW on 2-MiB backed regions (e.g. shell
BSS if it uses huge pages).

**Disadvantages**: R15 doesn't use 2-MiB pages in user aspaces
(aspace_map only 4-KiB). Adds allocator pressure. Adds
huge-to-small demotion complexity.

**Reject at R15.M6**. Follow-up `pf-handler-huge-cow` when huge-page
policy lands.

### 7.6 Backtrack F — Stack-alignment via 6-push prologue

If a boot-time audit shows `rsp % 16 == 8` at
`_typed_handler_14` entry, add a 6th push (`push rbp; mov rbp, rsp`)
to realign. §3.5 predicts alignment; this is the recovery.

**Advantages**: Zero downstream churn on rbp discipline.

**Disadvantages**: One extra push+pop per fault.

**Deferred contingency**. Activate only if audit surfaces
misalignment.

### 7.7 Backtrack G — Combine flip + split via unified store

Instead of two branch arms, unconditionally do:
- `new_pa = (refcount==1) ? old_pa : phys_alloc()`
- Build new PTE = new_pa | PTE_PRESENT | PTE_RW | preserved (COW=0)
- Store PTE, invlpg
- If refcount > 1: memcpy + phys_free

**Advantages**: Fewer jumps, more uniform control flow.

**Disadvantages**: Fast path grows: even refcount==1 executes the
"preserve-flags" mask + full PTE-rebuild instead of two OR/AND
instructions. Split path grows because the memcpy has to happen
*after* the PTE write (breaking the "point at new frame, then
copy" ordering) — problematic under speculative execution: the CPU
could see stale bytes on a concurrent read from the same aspace
(irrelevant at single-CPU but sets a bad precedent).

**Reject**. Two-arm shape is clearer and preserves the Linux-style
"alloc → copy → point → decref" ordering.

### 7.8 Backtrack H — Ship refcount-only decref decision (no memcpy)

Land handler with refcount decref but without the memcpy loop —
just re-map the *same* frame with PTE_RW=1 and PTE_COW=0
unconditionally, decref the refcount.

**Advantages**: Smaller diff.

**Disadvantages**: WRONG SEMANTICS. If refcount > 1, promoting the
shared frame to R+W would let *this* writer's writes bleed into the
other sharer's view. Loses the C in CoW.

**Reject with prejudice**. Documented for completeness — a
diff-minimization temptation to guard against in code review.

## 8. Tractability

**HIGH**.

- No new paideia-as encoder gap beyond `mov rax, cr2` (E-1 §2.3),
  which is a one-instruction sibling of `mov rax, cr3` already on
  the audited path.
- No new smoke mode. Existing `boot_r15_ring3` and
  `boot_r15_process` fingerprints absorb one new line each.
- No new module. `core/mm/pf_handler.pdx` already exists as a stub.
- The walker sequence mirrors `aspace_map` (audited by #422/#488/
  #652 witnesses); read-only variant has less failure surface (no
  writes during descent, no allocator during descent).
- `phys_alloc` / `phys_free` / `frame_meta_get` / `tlb_shootdown_local`
  all landed and audited.
- `_typed_handler_14` rewrite is one-flag dispatch — the same
  shape as `_typed_handler_6` (#650 ring-3 UD) and
  `_typed_handler_13` (#652 ring-3 GP). Zero new dispatch surface.
- 5-push prologue matches the shape audited by #649's callee-save
  fix.
- Witness setup reuses `aspace_create` + `aspace_map` patterns
  already exercised in the #652 ring-3 witness (line 358 onward in
  `kernel_main.pdx`).
- **No dependency on #552 (RESET).** Standalone-witness pattern
  proven by #559.
- **No dependency on #658** (VA/PA discipline is symmetric with
  aspace_map and phys_free).

Known follow-ups (not blockers for #553):

- **#552 aspace_clone_cow walker relanding** — will produce PTE
  shapes that this handler consumes identically.
- **fork fixture round-trip smoke pass** — proves the AC
  end-to-end once #552 relands (§11).
- **SMP TLB broadcast** — one-line handler diff when
  `tlb_shootdown_broadcast` grows real IPI logic at R15.M7+.
- **`pf-handler-huge-cow`** (§7.5) — huge-page split path.
- **`pf-handler-ring3-only`** (§7.3) — ring-3-only enforcement.

## 9. Cross-cutting risks

- **`_cow_witness_active` racing with real faults**. Once #552
  lands, real CoW faults from ring 3 will arrive at
  `_typed_handler_14`. The flag mechanism handles this cleanly:
  the witness sets the flag, drives its own faults, clears the
  flag. Between witness cycles, the flag is 0 → `handle_pf`
  panic path runs. When #552's fork-write fault arrives with
  the flag still 0 (real fork, not witness), we must have
  already-swapped dispatch semantics: flag or not, if the
  error_code shape matches CoW, dispatch to `pf_handle_cow`.
  **Design decision: at R15.M6 close, remove the flag gate.**
  For #553 landing alone, keep the gate so witness FAILs
  don't panic-silent everything else.
- **`_typed_handler_14` gets a real `handle_pf` fallback**. The
  existing `handle_pf` (`exceptions.pdx:112`) still panics via
  `cpu_halt`. Handler contract: on non-CoW shape, fall through
  to `handle_pf`. This preserves the existing panic contract.
- **CR3 activation risk in the witness**. Sub-tests A and B
  load `mov cr3, witness_pml4_pa`. The witness PML4 must have
  the kernel higher-half copied (via `aspace_create`) so that
  after CR3 flip, `uart_puts`, `frame_meta_get`, `phys_alloc`,
  etc. — all higher-half symbols — remain reachable. This is
  the same discipline #652 witness proved with
  `aspace_create(_kernel_pml4_pa)`.
- **Restoring CR3 in the witness**. Save-into-mem-slot pattern
  (like `_kernel_resume_rsp` for #652). No CR3 restore ⇒ next
  kernel_main step (KPTI witness) uses witness's PML4, which
  has less than the full kernel PML4 (only the higher-half
  entries; if KPTI touches user-half of the kernel PML4, it
  would fault). Mitigation: save/restore CR3 explicitly with
  `mov cr3, [_kernel_resume_cr3_scratch]`.
- **Faulting inside the fault handler**. If the walker itself
  faults (e.g. one of the higher-half addresses were unmapped —
  shouldn't be possible, but hypothesized), it produces a
  double-fault (#DF, vec 8), routed to its own IST-1 stack
  (`ist.pdx`). Bounded by IST discipline; would panic-halt via
  `handle_df`. Not a new risk — every current #PF has the same
  property.
- **Speculative execution of the promoted PTE**. After
  `mov [r14], new_pte; call tlb_shootdown_local`, the CPU may
  speculatively fetch from the promoted PTE before the
  `invlpg` retires. Since the fault handler returns via
  `iretq` (fully serializing after `invlpg`), the retire
  happens before the user's next-write attempts. x86 TSO
  guarantees.
- **Refcount underflow during split**. The split path calls
  `phys_free(old_pa, 0)`. #559's decref-guard rejects
  refcount==0 as no-op. If refcount was already 0 at split
  entry (impossible per invariant, but hypothesized), the
  guard silently returns OK. Would produce an over-decremented
  metadata word — but §3.9 shows the invariant blocks this.
- **Witness runs before #552 lands**. Sub-tests A and B set up
  refcount==1 and refcount==2 manually via `frame_meta_incref`.
  The handler doesn't care whether the incref came from #552's
  walker or from a witness driver. When #552 lands, existing
  witness continues to pass; a new fork smoke test lands as
  the round-trip regression signal.
- **memcpy loop correctness**. 512 iterations, r8 as scratch.
  Off-by-one risk if the `cmp rax, 512; jae` is written as
  `jg` (would copy 513 qwords, overwriting the next frame's
  first qword). §3.8 uses `jae` — audit at code-review time.

## 10. Backtrack markers (for debugger if witness reports FAIL)

| Symptom                                        | Root cause hypothesis                                     | Where to look                                                                                                     |
|------------------------------------------------|-----------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------|
| Sub-test A FAIL: kernel panics after write     | `_cow_witness_active` not set / dispatch not adopted     | `exceptions.pdx` _typed_handler_14: verify flag read + branch. `kernel_main`: verify flag store BEFORE cr3 load.  |
| Sub-test A FAIL: `#PF` re-fires (double-fault) | PTE_RW not actually set, or invlpg not issued            | `pf_handler.pdx`: verify `or PTE_RW` before `mov [r14]`; verify `tlb_shootdown_local` before ret.                 |
| Sub-test A FAIL: canary post-write is wrong    | PTE frame field changed on fast-flip (shouldn't)         | `pf_handler.pdx` flip path: verify `mov rax, r15; or PTE_RW; and ~PTE_COW` — no touching of frame bits 12..51.    |
| Sub-test A FAIL: refcount != 1 after           | Fast path accidentally called `phys_free`                | `pf_handler.pdx`: verify fast path DOES NOT reach phys_free label; branch `je pf_cow_flip; jmp pf_cow_split`.    |
| Sub-test B FAIL: A reads B's canary            | Split path didn't rewrite A's PT[0] to new_pa            | `pf_handler.pdx`: verify `mov [r14], new_pte` runs on split; verify `new_pte` frame field ≠ old_pa.               |
| Sub-test B FAIL: B reads A's new value         | Split path corrupted shared_pa (memcpy target wrong)     | `pf_handler.pdx`: verify memcpy `rdi = new_va; rsi = old_va` (not swapped).                                       |
| Sub-test B FAIL: refcount(shared_pa) != 1      | phys_free(old_pa) not called OR decref-guard broken       | `pf_handler.pdx`: verify `mov rdi, old_pa; call phys_free` on split path; walk #559 §3.5 code path.               |
| Sub-test B FAIL: aspace B's PT[0] mutated      | Split accidentally wrote to global bitmap-mapped PTE      | `pf_handler.pdx`: verify PT VA computed from *current CR3* (aspace A), not from `shared_pa` or `aspace_B_pa`.     |
| Both sub-tests hang silently                   | Handler entered but never `iretq`'d — infinite fault loop | `qemu -d int` trace shows repeating #PF at same RIP. Check invlpg call site; check PTE_RW actually stored (mov [r14]). |
| Boot hangs after "R15 FRAME META OK"           | CR3 flip in witness broke higher-half access              | Check `aspace_create(_kernel_pml4_pa)` was called; assert PML4[256..511] copied.                                 |
| KPTI OK stops appearing                        | CR3 not restored after witness — KPTI sees witness PML4  | Verify `mov cr3, [_kernel_resume_cr3_scratch]` runs on both witness-exit paths.                                   |

## 11. Post-#552 acceptance-round-trip

Once #552's `aspace_clone_cow` walker relands, the round-trip
witness that discharges the issue-body AC verbatim:

```
1. Build parent aspace with 1 mapped page containing canary A.
2. sys_fork → creates child aspace via aspace_clone_cow
   (which sets both parent and child PTEs R-only + PTE_COW and
   incref's the shared frame to refcount=2).
3. Child sys_write's a new value B to the shared VA.
4. #PF fires in child aspace (CR3 = child):
   - Split path (refcount=2)
   - Child ends up with new_pa_child mapped R+W, containing B.
   - Parent frame decref'd to refcount=1.
5. Child reads back → B (new frame).
6. Parent reads → A (original frame, refcount=1, PTE_COW still
   set — parent's next write will fast-flip).
```

This lands as a smoke variant `boot_r15_fork_cow` at R15.M6 close.
Not gating for #553.

## 12. References

- Issue: paideia-os#553
- Sibling / related issues (this milestone):
  - #559 (frame_meta refcount — LANDED; substrate for this handler)
  - #552 (aspace_clone_cow — RESET; walker consumer of PTE_COW)
  - #554 (sys_fork), #555 (sys_execve — LANDED), #556 (sys_wait —
    LANDED), #557 (sys_exit — LANDED)
- Predecessor design docs:
  - `design/kernel/r15-m6-008-cow-refcount-frame-metadata.md`
    (standalone-witness pivot pattern this issue inherits; §5
    witness structure)
  - `design/kernel/r15-m1-010-phys-free-real-body.md` (§4 VA/PA
    normalizer this handler drives via phys_free)
  - `design/kernel/cow-multishare.md` §CMS-D1/CMS-D2/CMS-D3
    (semantics this handler enforces at single-CPU altitude)
- Source (touching):
  - `src/kernel/core/mm/pf_handler.pdx` (12-line stub → real body)
  - `src/kernel/core/int/exceptions.pdx:289-293`
    (`_typed_handler_14` — rewrite mirroring #650/#652 flag-dispatch
    shape)
  - `src/kernel/boot/kernel_main.pdx` (post-frame_meta insertion at
    line 209)
  - `tools/boot_stub.S:424+` (rodata + bss additions)
- Source (referenced, unmodified):
  - `src/kernel/core/mm/aspace_map.pdx:52-174` (walker template)
  - `src/kernel/core/mm/frame_meta.pdx:134` (`frame_meta_get`)
  - `src/kernel/core/mm/phys_alloc.pdx:22`
  - `src/kernel/core/mm/phys_free.pdx:17`
  - `src/kernel/core/ipi/tlb_shootdown.pdx:59`
    (`tlb_shootdown_local`)
  - `src/kernel/core/int/idt.pdx:174` (`trampoline_vec14` — trap
    frame layout auth)
  - `src/kernel/core/int/exceptions.pdx:94` (`read_cr2` — encoder
    gap E-1)
- Fingerprints (touching):
  - `tests/r15/expected-boot-r15-ring3.txt`
  - `tests/r15/expected-boot-r15-process.txt`
- Constants:
  - `KERNEL_VMA_BASE = 0xFFFF800000000000` (`link.ld`)
  - `PTE_COW = 0x200` (this document, §3.4; introduces
    convention)
- Prior-art discipline:
  - #649 phys_alloc callee-save prologue fix (commit `f6195ed`) —
    template for the 5-push discipline (§3.5).
  - #650 ring-3 UD witness dispatch pattern
    (`_typed_handler_6`) — template for the `_cow_witness_active`
    flag gate.
  - #652 ring-3 GP witness dispatch pattern
    (`_typed_handler_13`) — template for CR3-save/restore around
    aspace-flip.
- Intel SDM references:
  - Vol 3A §4.5 (Paging), §4.10.4.1 (INVLPG), §4.11.1 (PTE
    format — bit 9 AVL), §6.14 (Page-Fault Exception & error
    code), §6.13 (which vectors push error codes).
