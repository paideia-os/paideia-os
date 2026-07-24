---
issue: 646
milestone: R14b.M5 (TLB shootdown / IPI substrate)
subsystem: 3 — TLB shootdown / IPI substrate
prereq:
  - "#356 (apic_enable — IA32_APIC_BASE bit 11)"
  - "#389 / R11-m1-002 (apic_svr_enable — LAPIC SVR bit 8 + spurious vec 0xFF)"
  - "#511 (_ipi_trampoline_f0/f1 + handlers + counters)"
  - "#512 (structural IPI witness in kernel_main)"
blocks:
  - "R15.M7 (scheduler cross-CPU reschedule uses vec 0xF1)"
  - "Any Path A SMP work that relies on real IPI delivery"
touching:
  - src/kernel/core/apic/ipi_self.pdx           (new)
  - src/kernel/core/apic/tpr.pdx                (new — or add to lapic_timer.pdx)
  - src/kernel/boot/kernel_main.pdx             (extend IPI witness in boot_continue_after_ring3)
  - tools/boot_stub.S                           (two new .ascii messages)
  - tests/r14b/expected-boot-r14b-ipi.txt       (+1 fingerprint line)
  - tests/r15/expected-boot-r15-ring3.txt       (+1 fingerprint line, same string)
---

# R14b-M5-007b — Self-IPI runtime delivery (#646)

## 1. Scope

The R14b.M5 IPI substrate is structurally complete:

- `_ipi_trampoline_f0` / `_ipi_trampoline_f1` in `src/kernel/core/ipi/vectors.pdx`
  save 15 GPRs, call `apic_eoi`, dispatch `_ipi_handler_f{0,1}`, restore,
  and `iretq`.
- Vectors 240 (`0xF0`) and 241 (`0xF1`) are wired in `Idt.idt_install`
  (`src/kernel/core/int/idt.pdx` lines 337–407).
- Handlers increment `_ipi_f0_count` / `_ipi_f1_count`.
- `boot_continue_after_ring3` in `src/kernel/boot/kernel_main.pdx`
  (lines 455–477) currently prints `IPI OK` on **structural** witness —
  it only verifies that the four symbols above resolve, and never
  actually delivers an interrupt.

The gap this issue closes: **exercise the delivery path once, at boot,
and verify the handler ran** — before R15.M7 relies on vec 0xF1 for
cross-CPU reschedule.

Explicitly **out of scope** for this issue:

- Real `send_ipi(target_cpu, vector)` — the stub in
  `src/kernel/core/ipi/tlb_shootdown.pdx` remains a `mov rax, rax`
  placeholder; Path A (SMP) will replace it with a per-target ICR write
  using APIC ID.
- x2APIC ICR-via-MSR path (`src/kernel/core/apic/x2apic.pdx`) — the
  witness stays on xAPIC MMIO. x2APIC enable is a Phase 15+ deliverable.
- LDR / DFR (logical destination mode) — SELF-shorthand bypasses both.

## 2. Root-cause analysis of the "counter stays 0" observation

The issue body lists four hypotheses. Reading the tree they collapse
to a single fact: **there is no ICR write anywhere in the kernel today.**

- `TlbShootdown.send_ipi` (`src/kernel/core/ipi/tlb_shootdown.pdx:48`)
  is an unsafe stub whose body is `mov rax, rax`. Its own justification
  admits: *"paideia-as 0.6.0 lacks the MMIO store operand; emitting mov
  rax, rax placeholder."*
- `CrossCpu.stub_ipi_send` (`src/kernel/core/ipi/cross_cpu.pdx:45`) is
  a typed `fn(...) -> 0` stub.
- Boot never calls either. The R14b-m5-007 witness at
  `kernel_main.pdx:459-477` performs only `lea rax, [rip + …]; cmp rax, 0`
  symbol-resolution checks.

So the counter stays 0 not because delivery is broken but because no
interrupt is ever issued. `#512` workerbee saw the counter at zero and
inferred a delivery failure; the tree state says the delivery was never
attempted.

Two secondary concerns remain valid and must be handled defensively:

- **TPR is never programmed.** After INIT the LAPIC's Task Priority
  Register (MMIO 0xFEE00080) is architecturally 0, but QEMU-TCG's LAPIC
  model has historically shipped bugs where TPR carries a stale value
  across `-kernel` reloads. Programming TPR = 0 explicitly costs one
  MMIO store and removes an entire class of "why won't this fire"
  debug session.
- **RFLAGS.IF (interrupts enabled)** — the current `sti` is at
  `kernel_main.pdx:559`, well downstream of the point where the IPI
  witness would want to run. The witness must open its own
  `sti`/`cli` window around the ICR write.

## 3. LAPIC init sequence — additions

### 3.1 New: `apic_tpr_init` (Task Priority Register)

**Location:** either a new `src/kernel/core/apic/tpr.pdx` or an
append to `src/kernel/core/apic/lapic_timer.pdx`. Recommend a new file
for cross-milestone auditability (it stays a two-line module).

```paideia
module Tpr = structure {
  // LAPIC TPR — MMIO offset 0x80, 32-bit RW.
  // Intel SDM Vol 3A §10.8.3.1: TPR[7:4] = priority class (0..15).
  // Interrupts whose vector[7:4] <= TPR[7:4] are blocked.
  // TPR = 0 means "accept all vectors".
  pub let apic_tpr_init : () -> () !{sysreg, mem} @{boot} = fn() -> unsafe {
    effects: {sysreg, mem}, capabilities: {boot},
    justification: "R14b-M5-007b: write LAPIC TPR MMIO 0xFEE00080 = 0 so the
      LAPIC accepts interrupts of every priority class (needed for self-IPI
      to vec 0xF0 = priority class 0xF). Per Intel SDM Vol 3A §10.8.3.1.
      QEMU-TCG has historically shipped LAPIC-emulation states where TPR
      is not zero at startup; the explicit write removes that ambiguity.",
    block: {
      mov rax, 0xFEE00080;
      xor rcx, rcx;
      mov [rax], ecx;    // 32-bit write, TPR = 0
      ret
    }
  }
}
```

### 3.2 New: `apic_ipi_self` (self-targeted ICR write)

**Location:** `src/kernel/core/apic/ipi_self.pdx` (new).

ICR layout (xAPIC, MMIO 0xFEE00300 low DW):

| Bits  | Field              | Value for self-IPI vec 0xF0                |
| ----- | ------------------ | ------------------------------------------ |
| 7:0   | Vector             | 0xF0 (caller-supplied, in RDI)             |
| 10:8  | Delivery mode      | 000 = Fixed                                |
| 11    | Destination mode   | 0 = Physical (unused for SELF shorthand)   |
| 12    | Delivery status    | R/O — poll for 0                           |
| 14    | Level              | 1 = Assert                                 |
| 15    | Trigger mode       | 0 = Edge                                   |
| 19:18 | Destination shorthand | 01 = **Self**                           |

Composed constant with vector bits masked in: `(1 << 18) | (1 << 14) | (vec & 0xFF)`
= `0x40000 | 0x4000 | vec` = `0x440F0` for vec 0xF0.

```paideia
module IpiSelf = structure {
  let LAPIC_ICR_LO   : u64 = 0x00000300
  let LAPIC_ICR_HI   : u64 = 0x00000310
  let LAPIC_MMIO_BASE: u64 = 0xFEE00000

  // (Self << 18) | (Assert << 14) = 0x40000 | 0x4000 = 0x44000
  let ICR_SELF_ASSERT_BASE : u64 = 0x44000

  // Deliver an IPI to *this* CPU using the SELF shorthand.
  // RDI (input): vector number (0..255).
  // Blocks until the LAPIC clears the delivery-status bit.
  pub let apic_ipi_self : (u64) -> () !{sysreg, mem} @{boot} =
    fn (vec: u64) -> unsafe {
      effects: {sysreg, mem}, capabilities: {boot},
      justification: "R14b-M5-007b (#646) self-IPI issue via SELF shorthand.
        ICR_HI (0xFEE00310) is a don't-care under SELF shorthand but written
        to 0 for hygiene. ICR_LO (0xFEE00300) receives
        (SELF_SHORTHAND << 18) | (ASSERT << 14) | (Fixed << 8) | (vec & 0xFF).
        The MMIO write itself triggers delivery; the poll loop reads bit 12
        (delivery status) until it clears to 0 (Intel SDM Vol 3A §10.6.1).
        Preconditions: apic_svr_enable + apic_tpr_init have been called;
        IDT entry for `vec` exists and RFLAGS.IF is set when this returns.",
      block: {
        // ICR_HI = 0 (dest field unused for SELF shorthand).
        mov rax, 0xFEE00310;
        xor rcx, rcx;
        mov [rax], ecx;

        // ICR_LO = 0x44000 | (vec & 0xFF)  — this write kicks delivery.
        mov rax, rdi;
        and rax, 0xFF;
        or  rax, 0x44000;
        mov rcx, rax;
        mov rax, 0xFEE00300;
        mov [rax], ecx;

        // Poll ICR_LO bit 12 (delivery status). QEMU-TCG typically clears
        // this within a handful of MMIO reads; keep the loop bounded to
        // avoid a smoke-mode hang if delivery status never clears.
        mov rax, 0xFEE00300;
        mov rcx, 100000;              // bound = 100k reads
        icr_wait_loop:
          mov edx, [rax];
          test edx, 0x1000;           // bit 12 = delivery status
          jz icr_wait_done;
          sub rcx, 1;
          jnz icr_wait_loop;
        icr_wait_done:
          ret
      }
    }
}
```

### 3.3 Call-site: `boot_continue_after_ring3`

The current sequence (`kernel_main.pdx:451-478`) is:

```
call apic_enable;
call apic_svr_enable;
call pic_mask_all;

; --- structural witness begins ---
lea rax, [rip + _ipi_trampoline_f0];   cmp rax, 0; je ipi_fail;
lea rax, [rip + _ipi_trampoline_f1];   cmp rax, 0; je ipi_fail;
lea rax, [rip + _ipi_f0_count];        cmp rax, 0; je ipi_fail;
lea rax, [rip + _ipi_f1_count];        cmp rax, 0; je ipi_fail;
lea rdi, [rip + ipi_ok_msg];  call uart_puts;   jmp ipi_done;
ipi_fail:
lea rdi, [rip + ipi_fail_msg]; call uart_puts;
ipi_done:
```

Post-fix (delta only):

```
call apic_enable;
call apic_svr_enable;
call apic_tpr_init;          ; NEW — TPR = 0
call pic_mask_all;

; --- structural witness (unchanged) ---
[four lea/cmp checks, ipi_ok_msg or ipi_fail_msg]

; --- NEW runtime delivery witness ---
; Precondition: LAPIC SVR + TPR programmed, PIC masked, timer NOT armed.
;               IDT vec 0xF0 wired. Interrupts currently disabled.

sti;                         ; open IF window
mov rdi, 240;                ; vec 0xF0
call apic_ipi_self;

; Bounded spin on _ipi_f0_count.
lea rbx, [rip + _ipi_f0_count];
mov rcx, 1000000;            ; bound (~ms of CPU time on TCG)
wait_ipi_loop:
  mov rax, [rbx];
  cmp rax, 0;
  jne wait_ipi_done;
  sub rcx, 1;
  jnz wait_ipi_loop;
wait_ipi_done:
cli;                         ; close IF window before the rest of boot

mov rax, [rbx];
cmp rax, 0;
je  ipi_deliver_fail;
lea rdi, [rip + ipi_delivered_msg];
call uart_puts;
jmp ipi_deliver_done;

ipi_deliver_fail:
lea rdi, [rip + ipi_not_delivered_msg];
call uart_puts;
ipi_deliver_done:

; ... loader witness continues unchanged ...
```

Order rationale:

1. **`apic_tpr_init` between SVR-enable and PIC-mask.** SVR must be on
   before TPR is meaningful; PIC mask isn't a precondition but grouping
   the three LAPIC-init calls before the two witnesses keeps the audit
   readable.
2. **Runtime witness *after* the structural witness.** If a future
   refactor drops one of the four symbols the structural witness fails
   fast with a clear message before we try to actually fire an IPI.
3. **Local `sti`/`cli` window.** `lapic_timer_init` hasn't been called
   yet at this program point, so IF=1 exposes only IPI delivery — no
   spurious timer, no pre-scheduler task pointer deref.
4. **Runtime witness *before* the loader witness.** The loader witness
   already tolerates trailing `sti` (it does not); reordering keeps the
   IF window minimal and adjacent to the IPI issue.

## 4. Boot fingerprint updates

`tools/boot_stub.S` — add two `.ascii` globals alongside
`ipi_ok_msg` / `ipi_fail_msg`:

```
.global ipi_delivered_msg
.align 8
ipi_delivered_msg:      .ascii "IPI DELIVERED\n\0"

.global ipi_not_delivered_msg
.align 8
ipi_not_delivered_msg:  .ascii "IPI NOT DELIVERED\n\0"
```

`tests/r14b/expected-boot-r14b-ipi.txt` — append one line:

```
B
HI VA FFFF8000
PaideiaOS R8
IPI OK
IPI DELIVERED
```

`tests/r15/expected-boot-r15-ring3.txt` — append `IPI DELIVERED`
immediately after the existing `IPI OK` line (line 9). The existing
`LOADER OK` and `ELF LOAD OK` lines shift down by one.

## 5. Test canary — `boot_r14b_ipi`

Smoke mode is already registered in `tools/run-smoke.sh:105-111`; no
new mode is required. The fingerprint file (§4) is the only test-side
change.

Runtime canary (what the mode now proves):

- LAPIC SVR programmed → LAPIC will accept ICR writes.
- LAPIC TPR programmed → priority filter open.
- IDT vec 240 dispatch → `_ipi_trampoline_f0` runs on interrupt.
- Trampoline discipline → 15-GPR save, `apic_eoi`, handler call,
  15-GPR restore, `iretq` — all correct because we return to boot and
  keep executing.
- Handler → `_ipi_f0_count` write is visible to the polling boot code
  (memory-ordering witness for the trampoline's `mov [rax], rcx`).

Failure signature is either:

- `IPI NOT DELIVERED` on the serial log (fingerprint mismatch, smoke
  exits non-zero) — LAPIC accepted the ICR but the handler never ran
  (candidates in §7).
- Boot hangs with `IPI OK` as last line — CPU triple-faulted inside
  the trampoline or the bounded spin never terminated (candidate: bit
  12 delivery status never clears; already bounded to 100k reads).

## 6. paideia-as encoder coverage

All instructions used in §3.1–§3.3 are already emitted elsewhere in
the tree:

- `mov [rax], ecx` — 32-bit MMIO store: used by `apic_svr_enable`,
  `apic_eoi`, `lapic_timer_init`.
- `mov edx, [rax]` — 32-bit MMIO load with 32-bit dest: **verify**.
  The tree does not yet emit this pattern (all existing MMIO reads use
  `mov rax, [rax]`). If missing, escalate as PA-R14-003 and fall back
  to `mov rcx, [rax]; and rcx, 0x1000; jz` in the polling loop.
- `test edx, 0x1000` — 32-bit `test` with imm32: verify against
  `paideia-as` v0.20.x tables; fallback `and rcx, 0x1000; jz` is
  always available.
- `sti` / `cli` — used at `kernel_main.pdx:559`.
- All other instructions (`mov`, `xor`, `or`, `and`, `sub`, `cmp`,
  `jne`, `je`, `lea rax, [rip+sym]`, `call`, `ret`) are exercised in
  every existing module.

No `paideia-as` version bump anticipated. If `mov edx, [mem]` is
missing, the workaround above holds the runtime-delivery witness
without blocking on a compiler landing.

## 7. Backtrack candidates (ordered by likelihood)

If `IPI NOT DELIVERED` is observed despite the design landing intact:

1. **QEMU-TCG SELF-shorthand quirk.** Some older TCG versions ignore
   SELF and require an explicit destination. Fallback: read APIC ID
   from `[0xFEE00020]` bits 31:24, write it into `ICR_HI` bits 31:24,
   drop the SELF-shorthand bits from `ICR_LO` (use `0x4000 | vec`
   = Fixed + Assert + physical dest 0). One extra MMIO read at boot.

2. **Delivery status bit 12 semantics on TCG.** TCG's LAPIC has at
   times reported bit 12 as always-clear or as sticky. The 100k-read
   bound in §3.2 protects against a sticky bit. If it is
   always-clear-but-never-delivers, the outer spin on
   `_ipi_f0_count` still catches the failure; the fingerprint reports
   it cleanly.

3. **Handler counter memory ordering.** The trampoline's
   `mov [rax], rcx` and the boot poll's `mov rax, [rbx]` are both
   plain MMIO-adjacent stores/loads to normal WB memory in `.bss`;
   x86 TSO guarantees the store is visible. If a
   compiler / linker regression places `_ipi_f0_count` in an
   unexpected section, `objdump -t build/kernel.elf | grep _ipi_f0_count`
   will show it; the fix is a `pub let mut` audit in
   `src/kernel/core/ipi/vectors.pdx`.

4. **RFLAGS.IF not actually set at the ICR write.** If a future
   `apic_tpr_init` or `apic_svr_enable` refactor accidentally
   emits a `cli` (or an interrupt-gated call that IRET restores IF
   from a saved frame), the `sti` window closes silently. Debug hook:
   `pushfq; pop rax; test rax, 0x200; jz ipi_deliver_fail_iF` before
   the ICR write.

5. **TPR still non-zero.** If `apic_tpr_init` is dropped (or its
   `mov [rax], ecx` is silently no-op'd by a future encoder
   regression), TPR class ≥ 0xF blocks vec 0xF0. Debug hook:
   read `[0xFEE00080]` and print the low byte. Simplest permanent fix
   is to bracket the runtime witness with a `mov [rax], ecx;
   mov ecx, [rax]; cmp ecx, 0; jne fail` self-check.

6. **PIC still driving spurious IRQs.** `pic_mask_all` is called
   before the runtime witness in the revised sequence; the mask
   discipline is unchanged from what R11-m1-003 already proves.

7. **Vec 0xF0 IDT entry mis-encoded.** `Idt.idt_install` at
   lines 337–407 has an explicit `idt_setup_ipi_f0` branch. Cross-check
   by `objdump -d build/kernel.elf | grep -A2 "_ipi_trampoline_f0>:"`
   and matching the `push 240` in the trampoline.

## 8. Register-clobber discipline (context: recent debugger sessions)

The runtime witness in `boot_continue_after_ring3` uses `RBX` and
`RCX` as the polling loop's index/counter. `RBX` is preserved by
`_ipi_trampoline_f0` (in its 15-GPR save/restore band); `RCX` is
saved by the trampoline too. Therefore the poll survives an in-loop
interrupt correctly.

However, `apic_ipi_self` in §3.2 clobbers `RAX`, `RCX`, `RDX` in
its own body (and reuses `RDI` as its input). Callers that expect
these registers to survive the call must save them. In the boot
witness above we set `RBX = &_ipi_f0_count` *before* the call so
the polling loop starts from a callee-saved register — this is the
"register-clobber pattern" the context flags.

## 9. LOC estimate

| File                                                 | New LOC | Delta LOC |
| ---------------------------------------------------- | ------- | --------- |
| `src/kernel/core/apic/tpr.pdx` (new)                 | ~18     | +18       |
| `src/kernel/core/apic/ipi_self.pdx` (new)            | ~40     | +40       |
| `src/kernel/boot/kernel_main.pdx` (witness upgrade)  | —       | +35       |
| `tools/boot_stub.S` (two `.ascii` globals)           | ~10     | +10       |
| `tests/r14b/expected-boot-r14b-ipi.txt`              | —       | +1        |
| `tests/r15/expected-boot-r15-ring3.txt`              | —       | +1        |
| **Total**                                            | **~58** | **~105**  |

No refactors of existing files beyond the two fingerprint appends and
the witness insertion. No `paideia-as` change anticipated (see §6).

## 10. Acceptance criteria

- [ ] `apic_tpr_init` and `apic_ipi_self` land in `src/kernel/core/apic/`.
- [ ] `boot_continue_after_ring3` calls `apic_tpr_init` after
      `apic_svr_enable` and runs the runtime witness described in §3.3.
- [ ] `boot_r14b_ipi` smoke prints `IPI OK` **and** `IPI DELIVERED` on
      3/3 consecutive runs.
- [ ] `boot_r15_ring3` smoke passes with the updated fingerprint
      (`IPI DELIVERED` inserted between existing `IPI OK` and
      `LOADER OK`).
- [ ] Canonical 8-mode smoke remains green.
- [ ] No `paideia-as` version bump (or, if `mov edx, [rax]` is missing,
      escalate PA-R14-003 and use the RCX-fallback poll).

## 11. Forward hooks

- Path A (SMP) replaces `apic_ipi_self` callers with a
  `apic_ipi_send(target_apic_id, vector)` that writes ICR_HI = APIC ID
  and ICR_LO = Fixed + Assert + vec (no SELF shorthand). The IPI
  substrate is unchanged; only the composer differs.
- x2APIC migration turns MMIO-ICR into `wrmsr` to MSR `0x830`. TPR
  becomes MSR `0x808`. Same values; same sequence.
- Vec 0xF1 (reschedule) reuses `apic_ipi_self(241)` in the R15.M7
  scheduler when preempting the currently-running task.

## 12. R14b-M5-007b amendment (#646 landed)

The runtime-delivery gap identified in this doc is fixed by two new modules
and a wiring delta:

1. `src/kernel/core/apic/tpr.pdx` — defensive TPR=0 write so vec 0xF0 is
   not gated by priority class.
2. `src/kernel/core/apic/ipi_self.pdx` — `apic_ipi_self(vec)` that writes
   ICR_LO with SELF-shorthand encoding (0x44000 | vec) and bounded-polls
   delivery-status bit 12.
3. `boot_continue_after_ring3` (`kernel_main.pdx`) calls `apic_tpr_init`
   after `apic_svr_enable`, and after the structural `IPI OK` marker
   fires a self-IPI to vec 0xF0, polls `_ipi_f0_count` in a bounded spin
   loop, and emits `IPI DELIVERED` (or `IPI NOT DELIVERED` on timeout —
   does NOT halt).

MMIO width caveat: paideia-as #1251 causes `mov [mem], eX` to silently
widen to 64-bit REX.W stores. For LAPIC MMIO this is benign — SDM Vol 3A
§10.4.1 says the LAPIC ignores upper 32 bits of a 64-bit access — but is
tracked as latent risk for real-hardware/KVM once #1251 lands.
