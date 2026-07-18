---
issue: 651
parent: 526 (r15-m2-005 first ring-3 entry primitive)
milestone: R15.M2 (first ring-3 entry — follow-up)
subsystem: 6 — syscall/sysret ABI
prereq: [#645 (RW trampoline scratch slot), #499 (kpti_build_user_pml4), #503 (swapgs), PA-R13-004 (ud2, optional)]
blocks: [#650 (ring-3 witness marker), #652 (first user_ret target)]
touching:
  - src/kernel/link.ld
  - src/kernel/core/syscall/enter_user.pdx
  - src/kernel/core/syscall/trampoline_data.pdx
  - src/kernel/boot/kernel_main.pdx
  - tests/r14b/expected-boot-r14b-kpti.txt
---

# R15-M2-005-followup — Relocate `enter_userland_initial` into `.text.syscall_trampoline` + wire CR3 flip (#651)

## 1. Scope

Retire the "Meltdown-open MVP" caveat from
`src/kernel/core/syscall/enter_user.pdx`. The primitive
`enter_userland_initial(entry_rip, initial_rsp, user_pml4_pa)` currently
executes in regular kernel `.text` (higher-half via KERNEL_VMA_BASE
alias) and drops its third argument on the floor — `_user_pml4_pa`
is deliberately unused. Consequences under strict KPTI:

- No CR3 flip → the first `iretq` into ring-3 leaves kernel PML4
  active while CPL=3 executes. Meltdown-open. Documented but unshipped.
- Even if we naively add `mov cr3, rdx; iretq` at the tail, the `iretq`
  instruction sits in a `.text` page that is *not* present in the user
  PML4 (which under `kpti_build_user_pml4` maps only PT[260] trampoline
  text + PT[261] trampoline data). Fetching `iretq` after CR3 flip
  triple-faults exactly like the ordering bug #645 fixed on the entry
  side.
- Even if we relocate the code so the `iretq` fetch survives, the
  `iretq` frame must be readable under the target CR3 — and the
  frame is currently on whatever kernel stack the caller was using,
  none of which is mapped in the user PML4.

#651 fixes all three: relocates the primitive into the trampoline text
page, builds the `iretq` frame into a fixed slot in the trampoline
data page (extending the RW slot that #645 introduced), flips CR3
between the frame commit and the `iretq`, and drops a `ud2` sentinel
that catches any future accidental fall-through.

The primitive remains unused on the live boot path — no `kernel_main`
call site exists yet. The runtime end-to-end witness (drive
`enter_userland_initial` with a real payload, observe a ring-3
`sys_debug_puts` marker) is tracked at #650 / #652 and requires
substrate outside this issue. #651 delivers the *enabling* fix; the
structural fingerprint in §5 proves the relocation and the mapping
discipline are load-bearing.

## 2. Design choice — extend #645's RW trampoline scratch slot

The alternative to relocating the primitive is to leave it in `.text`
and gate the CR3 flip on the boot policy ("keep kernel higher-half
in user CR3 during boot"). That is exactly the non-strict-KPTI
concession #645 already retired. Re-introducing it undoes the
mitigation. Rejected.

The RW-slot approach that #645 chose for syscall entry generalises
cleanly:

- **Trampoline text page (PT[260])** already houses `syscall_entry`.
  Add `enter_userland_initial` to the same page via a linker-script
  wildcard on `enter_user.o(.text)`. No new PT plumbing.
- **Trampoline data page (PT[261])** already houses `_saved_user_rsp`,
  `_saved_user_pml4`, `_kernel_pml4_pa`. Add
  `_iretq_frame_scratch : [u64; 5]` (40 bytes at offset 24). No new
  PT plumbing.
- Both pages have identical mappings under kernel CR3 (boot-stub
  higher-half alias PML4[256] → PDPT[0..3] identity) and user CR3
  (the KPTI chain PML4[256] → shared PDPT → PD[0] → PT[260..261]).
  The primitive can read/write the scratch region and be executed
  under either CR3.

Two 4 KiB pages carry both ring-transition primitives. The single
higher-half alias makes VAs identical in both address spaces, so the
whole design collapses to "pick RIP-relative operands so their target
lands in one of the two mapped pages". That property is checkable by
`objdump` (§5.3) and by a structural fingerprint in `kernel_main`
(§5.1).

## 3. Section-move mechanics

### 3.1 Linker script (`src/kernel/link.ld:50..55`)

Current:

```ld
.text.syscall_trampoline : AT(...) ALIGN(4K) {
    _syscall_trampoline_start = .;
    KEEP(*core/syscall/entry.o(.text))
    _syscall_trampoline_end = .;
    . = ALIGN(4K);
} :text_high
```

Post-fix:

```ld
.text.syscall_trampoline : AT(...) ALIGN(4K) {
    _syscall_trampoline_start = .;
    KEEP(*core/syscall/entry.o(.text))
    KEEP(*core/syscall/enter_user.o(.text))
    _syscall_trampoline_end = .;
    . = ALIGN(4K);
} :text_high
```

This pulls the entire `.text` output of `enter_user.o` into the
trampoline page. `enter_user.pdx` presently defines only
`enter_userland_initial`; if the module later gains helpers that must
*not* live in the trampoline page (unlikely — a "boot-only ring-3
transition" module has one function), split them into a separate .pdx.

**Page-size invariant**: the trampoline text page is exactly 4 KiB
(single 4 KiB physical frame at LMA 0x104000, single PTE). Both
`syscall_entry` (~160 bytes) and `enter_userland_initial` (~100 bytes)
must fit. Current sizes leave ~3.7 KiB of headroom. If a future ring-
transition primitive pushes past 4 KiB, expand PT to cover PT[260..262]
or split into two text pages with a shared PDPT.

### 3.2 `src/kernel/core/syscall/trampoline_data.pdx`

Add one symbol at the end of the module:

```pdx
pub let mut _iretq_frame_scratch : [u64; 5] = uninit @align(8)
```

Layout post-fix (trampoline data page, VA 0xFFFF800000105000):

| Offset | Symbol                | Size | Purpose                          |
|--------|-----------------------|------|----------------------------------|
| 0x00   | `_saved_user_rsp`     | 8    | syscall entry: user RSP save     |
| 0x08   | `_saved_user_pml4`    | 8    | syscall entry: user CR3 save     |
| 0x10   | `_kernel_pml4_pa`     | 8    | kernel PML4 phys (populated boot)|
| 0x18   | `_iretq_frame_scratch`| 40   | RIP/CS/RFLAGS/RSP/SS staging     |
| 0x40   | reserved              | ~4032| future per-CPU sub-slots, etc.   |

Frame layout inside `_iretq_frame_scratch` follows Intel SDM Vol 2A
iretq pop order (from RSP upward): RIP, CS, RFLAGS, RSP, SS. Load RSP
to `&_iretq_frame_scratch[0]`; iretq pops five 8-byte slots in order.

At `MAX_CPUS = 1` a single frame slot is sufficient. When
`MAX_CPUS > 1` lands (`r14b-m5-*` per-CPU work), fan the scratch into
N × 64 B per-CPU sub-slots indexed by CPU id — same page, same
mapping, only offset arithmetic changes. Aligned with #645's
per-CPU expansion follow-up (`r15-m4-006d-per-cpu-trampoline-scratch`).

### 3.3 `src/kernel/core/syscall/enter_user.pdx`

Full rewrite of the module body (signature unchanged). The current
20 LOC assembly is replaced with ~35 LOC that:

1. Preserves arguments in callee-preserved-in-body registers r12/r13/r14.
2. Materialises the 5-slot iretq frame into
   `_iretq_frame_scratch` via RIP-relative stores.
3. `swapgs` (register-only; no memory access; safe under either CR3).
4. `cli` (guard the CR3-flipped, pre-iretq window — see §4.3).
5. `mov cr3, r14` (flip to user PML4 argument).
6. `lea rsp, [rip + _iretq_frame_scratch]` (RIP-relative; resolves to
   trampoline data VA present in user CR3).
7. `iretq` (CPL 0 → 3, IF=1 restored via popped RFLAGS).
8. `ud2` sentinel (paideia-as PA-R13-004; fall back to `hlt` if the
   submodule bump lags).

Draft body (canonical form; final justification string refreshed):

```asm
mov r12, rdi;                                    ; entry_rip
mov r13, rsi;                                    ; initial_rsp
mov r14, rdx;                                    ; user_pml4_pa

lea r15, [rip + _iretq_frame_scratch];
mov [r15 + 0],  r12;                             ; iretq RIP
mov rax, 0x2B;
mov [r15 + 8],  rax;                             ; iretq CS (user code, RPL=3)
mov rax, 0x202;
mov [r15 + 16], rax;                             ; iretq RFLAGS (IF=1 + reserved-1)
mov [r15 + 24], r13;                             ; iretq RSP (user stack)
mov rax, 0x23;
mov [r15 + 32], rax;                             ; iretq SS (user data, RPL=3)

swapgs;
cli;
mov cr3, r14;
lea rsp, [rip + _iretq_frame_scratch];
iretq;
ud2
```

The RIP-relative operands `[rip + _iretq_frame_scratch]` land inside
`.data.syscall_trampoline` — VA 0xFFFF800000105018 (offset 0x18 in
the data page). Trampoline data is RW / U=0 / XD in the user PML4
(#645 installed exactly these flags for PT[261]). Both stores and
RSP-load succeed under either CR3.

**Signature note**: the third parameter changes name from
`_user_pml4_pa` (unused) to `user_pml4_pa`. Type unchanged. Callers
(none live yet) must supply a valid user PML4 phys.

## 4. CR3 flip sequence

### 4.1 Frame commit order

The frame writes must complete *before* the CR3 flip. All frame
writes target `.data.syscall_trampoline` which is present in *both*
CR3s, so strictly speaking the order is not a correctness constraint
under either address space. It is, however, a *simplicity*
constraint: reasoning about half-committed frame state after a CR3
flip requires walking TLB / write-buffer ordering guarantees that
Intel SDM does not neatly document. Commit fully first, flip second,
iretq third.

### 4.2 CR3 flip and instruction stream

`mov cr3, r14` is a serializing instruction (SDM Vol 3A §7.5): it
completes all pending memory writes and invalidates non-global TLB
entries. Immediately after retirement:

- Instruction fetch continues from RIP+len(cr3-write). RIP is inside
  trampoline text (PT[260], PRESENT in user CR3). Fetch succeeds.
- Next instruction is `lea rsp, [rip + _iretq_frame_scratch]` — a
  register-only computation (LEA does not access memory). Succeeds
  trivially.
- Then `iretq` — reads 5 × 8 bytes from the new RSP. RSP is inside
  trampoline data (PT[261], PRESENT in user CR3). Reads succeed.
- iretq's CS check requires the target CS descriptor entry at
  GDT[5] (user code, DPL=3). GDT lives in kernel `.data`, but the
  CPU reads it via linear address stored in GDTR, resolved through
  the currently-active CR3. **Under user CR3 the GDT VA is not
  mapped** — this is the same Meltdown-open concession the current
  MVP tolerated, and #651 does not fix it.

**Deferred**: the GDT-under-user-CR3 gap is a separate concern
tracked upstream as an entry in `design/audit/pending/r15-m2-006`.
Options:

- (a) Map the GDT page into the KPTI trampoline PDPT chain at PT[262]
  (RO / U=0 / XD).
- (b) Reload GDTR after CR3 flip to point at a trampoline-mapped GDT
  alias.
- (c) Accept the concession for #651's structural landing; require
  #650's runtime witness to co-land with the GDT mapping.

Recommendation: **defer to a companion issue #651b (GDT trampoline
mapping)**. #651 lands the code-motion and CR3 discipline; the GDT
concession remains until the ring-3 runtime demand appears. The
structural fingerprint in §5.1 does not exercise iretq's descriptor
loads, so it passes with or without the GDT fix.

### 4.3 Interrupt gating (`cli`)

Between `mov cr3, r14` and `iretq` the CPU has:

- CPL = 0 (still ring-0)
- CR3 = user PML4 (only trampoline text + data mapped)
- IDT / handler code = kernel `.text` (NOT mapped in user CR3)

An interrupt in this window vectors through IDT descriptor lookup →
handler prologue fetch. IDT lookup uses IDTR's linear base; handler
fetch uses the descriptor's target RIP. Both land in kernel VA space,
neither is mapped under user CR3 → #PF on interrupt entry → double →
triple fault.

Two options:

- **`cli` before CR3 flip**. IF cleared for the ~4 instructions
  spanning `mov cr3, r14` through `iretq`. iretq's popped RFLAGS
  (0x202) sets IF=1 in ring-3.
- **Route all vectors through trampoline stubs**. Structural; blocks
  every IDT wiring.

`cli` is the surgical fix. Add one instruction (`cli;`) immediately
before `mov cr3, r14`. IF state on caller entry is preserved because
we restore it via iretq's RFLAGS pop, not via `sti`.

Non-maskable interrupts (NMI / #MC / #DB) still fire, and would still
land in unmapped IDT — this is a Meltdown-open concession on the
NMI vector under user CR3 that is not solvable without the GDT/IDT
trampoline mapping of §4.2. The window is 3 instructions wide, ~8 ns
on real hardware; probabilistic but non-zero. Track under the same
follow-up as GDT mapping.

### 4.4 swapgs ordering

`swapgs` is register-only (swaps IA32_GS_BASE and IA32_KERNEL_GS_BASE
MSRs). It has no memory operand and no CR3 dependency. Placement:
before `cli`, before `mov cr3`, after the frame commit. The kernel
GS_BASE is stashed on the way out; when the eventual ring-0 re-entry
happens via `syscall_entry`, that path's first instruction is
`swapgs` (per entry.pdx line 26) which restores the stash.

Between the pair, ring-3 has `IA32_GS_BASE` unset (0) — matching
Linux/xv6 discipline. Correct.

### 4.5 Register-liveness ledger through the flip

| Reg | Pre-swapgs      | Post-cr3-flip | Post-iretq (ring-3)   |
|-----|-----------------|---------------|-----------------------|
| r12 | entry_rip       | entry_rip     | preserved             |
| r13 | initial_rsp     | initial_rsp   | preserved             |
| r14 | user_pml4_pa    | user_pml4_pa  | preserved             |
| r15 | frame slot addr | frame slot    | preserved             |
| rax | scratch         | scratch       | preserved             |
| rdi | (was entry_rip) | scratch       | preserved             |
| rsi | (was init_rsp)  | scratch       | preserved             |
| rdx | (was pml4_pa)   | scratch       | preserved             |
| rsp | kernel stack    | kernel stack  | *user* stack (from frame) |
| rip | trampoline text | trampoline txt| *user* entry (from frame) |
| CS  | 0x08 (kernel)   | 0x08 (kernel) | 0x2B (user, RPL=3)    |
| SS  | 0x10 (kernel)   | 0x10 (kernel) | 0x23 (user, RPL=3)    |
| IF  | (caller's)      | 0 (cli)       | 1 (from RFLAGS pop)   |
| CR3 | kernel PML4     | user PML4     | user PML4             |
| GS  | kernel GS_BASE  | user (0)      | user (0)              |

Ring-3 does not see any kernel-scratch value in a general-purpose
register because the SysV boot ABI to init(1) fixes rdi = argc = 0
via the loader (`r15-m2-004`); other GPRs are "don't care" at first
entry. If future callers of `enter_userland_initial` want to pass
arguments in specific GPRs, they set them *before* calling — same
as any C ABI call.

## 5. Test canary

### 5.1 Structural (extends existing `boot_r14b_kpti`)

Add a witness block in `kernel_main.pdx` immediately after the KPTI
scratch-slot round-trip (which #645 landed at lines 158..171). New
block asserts:

1. `enter_userland_initial` resolves to a VA in
   `[_syscall_trampoline_start, _syscall_trampoline_end)` — proves
   the linker-script placement stuck.
2. `_iretq_frame_scratch` resolves to a VA in
   `[_syscall_trampoline_data_start, _syscall_trampoline_data_end)`
   — proves the trampoline-data addition stuck.
3. Write the canonical five-slot iretq frame (RIP=0xDEAD, CS=0x2B,
   RFL=0x202, RSP=0xBEEF, SS=0x23) to `_iretq_frame_scratch`, read
   each back, confirm. Proves the whole page is writable + readable
   from ring-0 with kernel CR3, and validates the offset arithmetic
   the primitive relies on.
4. Print `ENTER USER RELOC OK`.

Skeleton (append to kernel_main's existing kpti block; ~30 LOC):

```asm
; Assert enter_userland_initial in .text.syscall_trampoline
lea rax, [rip + enter_userland_initial];
lea rcx, [rip + _syscall_trampoline_start];
cmp rax, rcx;
jb  enter_reloc_fail;
lea rcx, [rip + _syscall_trampoline_end];
cmp rax, rcx;
jae enter_reloc_fail;

; Assert _iretq_frame_scratch in .data.syscall_trampoline
lea rax, [rip + _iretq_frame_scratch];
lea rcx, [rip + _syscall_trampoline_data_start];
cmp rax, rcx;
jb  enter_reloc_fail;
lea rcx, [rip + _syscall_trampoline_data_end];
cmp rax, rcx;
jae enter_reloc_fail;

; Round-trip write to the five iretq slots
lea r8, [rip + _iretq_frame_scratch];
mov rax, 0xDEAD;      mov [r8 + 0],  rax;
mov rax, 0x2B;        mov [r8 + 8],  rax;
mov rax, 0x202;       mov [r8 + 16], rax;
mov rax, 0xBEEF;      mov [r8 + 24], rax;
mov rax, 0x23;        mov [r8 + 32], rax;

mov rax, [r8 + 0];    mov rcx, 0xDEAD;  cmp rax, rcx;  jne enter_reloc_fail;
mov rax, [r8 + 32];   mov rcx, 0x23;    cmp rax, rcx;  jne enter_reloc_fail;

lea rdi, [rip + enter_reloc_ok_msg];
call uart_puts;
jmp enter_reloc_done;

enter_reloc_fail:
lea rdi, [rip + enter_reloc_fail_msg];
call uart_puts;

enter_reloc_done:
```

Message strings (add to `.rodata`):

```
enter_reloc_ok_msg   : "ENTER USER RELOC OK\n"
enter_reloc_fail_msg : "ENTER USER RELOC FAIL\n"
```

### 5.2 Fingerprint delta

`tests/r14b/expected-boot-r14b-kpti.txt` becomes:

```
B
HI VA FFFF8000
PaideiaOS R8
KPTI OK
KPTI SCRATCH OK
ENTER USER RELOC OK
```

Verification: `tools/run-smoke.sh boot_r14b_kpti` (5 s timeout).
No new smoke entry point — the existing dispatcher already covers
this fingerprint file.

### 5.3 Objdump discipline

Add to a `tools/verify-syscall-entry.sh` helper (spec'd but not
required to land):

```
objdump -d build/kernel.elf | sed -n '/<enter_userland_initial>:/,/^$/p'
```

must show:

- `swapgs`
- `cli`
- `mov cr3, r14`
- `iretq`
- `ud2` (or `hlt` if paideia-as bump lags)

And `nm build/kernel.elf | grep enter_userland_initial` must show
an address in `[0xFFFF800000104000, 0xFFFF800000105000)`.

### 5.4 Runtime witness (deferred)

The end-to-end demonstration — kernel_main calls
`enter_userland_initial(user_entry, user_rsp, user_pml4)`, ring-3
payload issues `syscall`, `sys_debug_puts("RING3 OK\n")` prints,
sysret returns to a hlt loop — requires:

- `#650` (ring-3 witness marker, sys_debug_puts implementation)
- `#652` (first user_ret target — a live callable entry)
- GDT trampoline mapping (see §4.2)

Each is separately trackable. #651 is scoped to the *enabling* fix
and its structural evidence; the runtime witness lands with those
followups.

## 6. LOC estimate

| File                                                                | LOC delta |
|---------------------------------------------------------------------|-----------|
| `src/kernel/link.ld`                                                | +1        |
| `src/kernel/core/syscall/enter_user.pdx`                            | +15 (rewrite: 20 → 35) |
| `src/kernel/core/syscall/trampoline_data.pdx`                       | +2        |
| `src/kernel/boot/kernel_main.pdx`                                   | +30       |
| `tests/r14b/expected-boot-r14b-kpti.txt`                            | +1        |
| `design/kernel/r15-m2-005-followup-relocate-enter-userland.md` (new)| +160      |
| **Total**                                                           | **~210**  |

Of the ~210 lines, ~50 are *executable* .pdx / linker / asm; the
remainder is design doc + fingerprint.

## 7. Backtrack candidates

Ordered by preference should the primary path hit blocking issues.

### Backtrack A — inline `iretq_frame_build` reuse

Keep `iretq_frame_build` as the frame-builder, relocate *it* into
the trampoline text page too, and switch RSP to the trampoline data
page *before* calling it. The helper writes the frame into the
trampoline scratch (which is the current RSP), returns, and the
caller's next instruction is `iretq`. Requires:

- Another linker `KEEP(*core/syscall/iretq_enter.o(.text))` line.
- `iretq_frame_build`'s pop/push discipline works against any stack
  that is 8-byte aligned and has 40+ bytes of headroom — the
  scratch region qualifies.

Trade-off: preserves helper reuse (currently one caller, so limited
value); adds an extra .o to the trampoline page (page-size headroom
is fine). Reject as primary — direct stores are simpler and audit
better than the pop/push/ret dance.

### Backtrack B — `sysret`-based first-entry primitive

Replace iretq with sysret. Requires the caller to pin CS/SS via
`IA32_STAR` (already set at `syscall_msr_init`), sets RIP from rcx
and RFLAGS from r11. No stack access on the return path — sysret
does not consume a frame. Advantage: no iretq frame slot needed,
no `cli` window (sysret is a single serialising step). Disadvantage:

- Semantic mismatch — `enter_userland_initial` is documented as
  the "first ring-3 entry" primitive; sysret is the "return from
  syscall" primitive. Using sysret for outbound-only-first-entry
  requires teaching the caller that this specific primitive uses
  a return-from-syscall vocabulary.
- Cannot set arbitrary RFLAGS bits — sysret masks r11 against
  `IA32_FMASK`; some flags do not survive.
- Cannot set arbitrary CS/SS — pinned via STAR.

Retain as a distant fallback should the GDT mapping deferral (§4.2)
turn out to be a hard blocker on iretq's descriptor loads.

### Backtrack C — dedicated per-CPU iretq scratch page

Instead of extending the shared trampoline data page, allocate a
per-CPU iretq scratch page mapped only in the process's user PML4.
Advantage: no shared-page contention when MAX_CPUS > 1.
Disadvantage: requires PT plumbing per CPU, plus per-aspace mapping
delta. Strictly more work than the primary path and premature
(single-CPU today). Land alongside `r15-m4-006d-per-cpu-trampoline-
scratch` when MAX_CPUS > 1 substrate arrives.

### Backtrack D — dispatch through a boot-mapped kernel-GDT alias

Rather than defer §4.2, land the GDT trampoline mapping inside
#651. Adds PT[262] population in `kpti_build_user_pml4`, adds an
optional GDTR reload in `enter_userland_initial`. Estimated +40
LOC across kpti.pdx + enter_user.pdx. Would let #651 stand alone
as a "safe ring-3 entry" without any Meltdown concession. Retain
as an option should the reviewer prefer a single fold-in over the
staged deferral.

## 8. Tractability

**HIGH.** Fix mirrors #645's discipline exactly one page over:

- No new paideia-as encoder feature required for the primary path.
  All addressing modes exercised (`[rip + sym]`, `[reg + disp8]`,
  `mov cr3, reg`, `iretq`, `swapgs`, `cli`) are already in use in
  entry.pdx or kpti.pdx.
- `ud2` is a nice-to-have; `hlt` is an acceptable fall-through
  sentinel for the interim if the paideia-as bump for PA-R13-004
  has not landed by the time #651 opens.
- Section move is a one-line linker script change plus a rewrite of
  a 20-line `.pdx` module; no cross-cutting refactor.
- Structural test canary is a straightforward extension of the
  existing `boot_r14b_kpti` witness — same file, same 5 s
  fingerprint harness, no new smoke entry point.
- Cross-cutting risk (GDT under user CR3, NMI in the CR3-flipped
  window) is called out with explicit follow-ups (§4.2, §4.3);
  neither blocks the structural fingerprint.

Known follow-ups (out of scope for #651, filed as separate issues):

- **`r15-m2-005b-gdt-trampoline-mapping`**: map GDT (and IDT) pages
  into the KPTI trampoline PDPT so iretq's descriptor loads succeed
  under user CR3 and the NMI-in-CR3-flipped-window race closes.
  Alternatively fold into #651 per Backtrack D.
- **`r15-m4-006d-per-cpu-trampoline-scratch`**: expand
  `_iretq_frame_scratch` (and #645's slots) to N × per-CPU sub-slots
  when MAX_CPUS > 1 substrate lands.
- **PA-R13-004 (paideia-as `ud2`)**: unblock the `ud2` sentinel.
  Fall-back to `hlt` is acceptable.

## 9. References

- Issue: paideia-os#651
- Prior audit: `design/audit/entries/r15-m3-005-syscall-slow-path.md`
- Prior audit: `design/audit/entries/r15-m2-006-first-user-ret-target.md`
- Sibling design: `design/kernel/r14b-m4-006b-syscall-entry-cr3-ordering.md`
  (#645 — trampoline data page landed here)
- Entry (current): `src/kernel/core/syscall/enter_user.pdx`
- Trampoline text section: `src/kernel/link.ld:50..55`
- Trampoline data section: `src/kernel/link.ld:57..62`
- KPTI PT builder: `src/kernel/core/mm/kpti.pdx:107..238`
- paideia-as `ud2`: PA-R13-004 (issue paideia-as#933)
