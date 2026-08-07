---
issue: 646
milestone: R14b.M5 (TLB shootdown / IPI substrate)
subsystem: 3 — TLB shootdown / IPI substrate
supersedes_attempts:
  - "0d5659e (2026-07-24) — reverted in c14b869 same day: 'IPI NOT DELIVERED' on wire"
predecessor_design:
  - design/kernel/r14b-m5-007b-ipi-runtime-delivery.md
prereq:
  - "paideia-as v0.20.1 (issue #1251 — narrow-store retarget fix)"
  - "#356 (apic_enable — IA32_APIC_BASE bit 11)"
  - "#389 / R11-m1-002 (apic_svr_enable — LAPIC SVR bit 8 + spurious vec 0xFF)"
  - "#511 (_ipi_trampoline_f0/f1 + handlers + counters)"
  - "#512 (structural IPI witness in kernel_main)"
blocks:
  - "R15.M7 (scheduler cross-CPU reschedule uses vec 0xF1)"
  - "Any Path A SMP work that relies on real IPI delivery"
  - "#694 panic_ipi_halt_others (real fan-out)"
touching:
  - src/kernel/core/apic/tpr.pdx                (new)
  - src/kernel/core/apic/self_ipi.pdx           (new)
  - src/kernel/boot/kernel_main.pdx             (call apic_tpr_init + runtime witness)
  - tools/boot_stub.S                           (self_ipi_ok_msg / self_ipi_fail_msg)
  - tests/r14b/expected-boot-r14b-ipi.txt       (+1 fingerprint line)
---

# R14b-M5-646 — Self-IPI runtime delivery (landing report)

This doc records the third, and hopefully final, attempt to close #646. The
comprehensive analysis lives in the predecessor design
`r14b-m5-007b-ipi-runtime-delivery.md`; this doc records what changed
between attempt #2 (reverted) and attempt #3, plus the root cause we now
believe blocked attempts #1 and #2.

## 1. What #646 delivers

Upgrade `boot_r14b_ipi` from a **structural** witness (four symbols
resolve) to a **runtime** witness (a Fixed edge-triggered self-IPI to
vector 0xF0 actually fires, the CPU dispatches `_ipi_trampoline_f0`,
the handler increments `_ipi_f0_count`, and the boot loop observes
`_ipi_f0_count > 0` before continuing).

The wire fingerprint gains one line:

```
IPI OK           ← existing structural witness (#512)
SELF IPI OK      ← new runtime witness (#646)
```

## 2. Root cause of the earlier failures

The reverted attempt (`0d5659e`) wrote LAPIC MMIO with bare
`mov [rax], ecx`. On paideia-as **v0.13.x** (the version live at that
time), the `unsafe_walker::Mov` retarget dispatch was missing the
store-direction branch: every narrow-suffix store silently widened to
a 64-bit REX.W store (paideia-as #1251). The 8-byte store issued to
`ICR_HI` (0xFEE00310) spilled into the reserved slot at 0xFEE00318 and
QEMU's LAPIC either dropped or corrupted the write; the follow-up
8-byte store to `ICR_LO` (0xFEE00300) spilled into `ICR_HI`, mangling
the destination-shorthand field.

**Evidence chain:**

- paideia-as CHANGELOG v0.20.1 (§#1251) explicitly lists
  `src/kernel/core/apic/eoi.pdx`, `ioapic.pdx` as *latent downstream
  hazards cleared by this fix* and cites paideia-os #646 by name.
- Paideia-os `apic_svr_enable` and `apic_eoi` were both retrofitted
  (per commit `f662` fix comment: "#662 Fix B: mov_d (sized 32-bit) to
  bypass paideia-as elaborator gap") with `mov_d [rax], rcx`
  workarounds. The reverted #646 attempt did not adopt that idiom.
- paideia-as v0.20.1 is now live in the tree (`paideia-as --version`),
  so the elaborator emits the correct 32-bit stores for the bare
  `mov [mem], eXX` pattern too.

So the fix is a straight redo of the 007b design, with two hardening
choices:

1. **All LAPIC MMIO stores use `mov_d [rax], rcx`** (the sized-store
   idiom already established in `eoi.pdx` / `lapic_timer.pdx`). This
   is defence-in-depth: a future encoder regression on the bare
   `mov [mem], eXX` path cannot silently re-introduce the 64-bit
   spill.
2. **Use SELF shorthand** (bit 18 of ICR_LO) not a physical
   destination write. SELF is simpler (no APIC-ID read), and does not
   depend on the boot CPU's APIC ID being zero. The reverted attempt's
   choice of physical-dest was a debug fallback from its unsuccessful
   SELF-shorthand attempt (attempt #1 in the 007b notes); with the
   MMIO width fix, SELF should work.

## 3. Implementation

Two new files, one wiring edit, one string pair, one fingerprint line.

### 3.1 `src/kernel/core/apic/tpr.pdx` (new, ~20 LOC)

```paideia
module Tpr = structure {
  pub let apic_tpr_init : () -> () !{sysreg, mem} @{boot} =
    fn() -> unsafe {
      effects: {sysreg, mem}, capabilities: {boot},
      justification: "...",
      block: {
        mov rax, 0xFEE00080;    // LAPIC TPR MMIO
        xor rcx, rcx;
        mov_d [rax], rcx;       // 32-bit sized store
        ret
      }
    }
}
```

Writes TPR = 0. Architecturally the post-INIT value is already 0, but
this removes any dependence on that assumption and lets a future
regression (or a warm reset that reused CPU state) not silently mask
IPI delivery.

### 3.2 `src/kernel/core/apic/self_ipi.pdx` (new, ~55 LOC)

Exports `apic_send_self_ipi(vec: u64)`. Body:

1. Write 0 to `ICR_HI` (0xFEE00310). Destination field is unused when
   SELF shorthand is set, but write it for hygiene.
2. Compose `ICR_LO` value: `(1 << 18) | (1 << 14) | (vec & 0xFF)` =
   `0x44000 | (vec & 0xFF)`. Field breakdown (Intel SDM Vol 3A §10.6.1):
   - Bits 7:0    — Vector
   - Bits 10:8   — Delivery mode = 0 (Fixed)
   - Bit 14      — Level = 1 (Assert)
   - Bit 15      — Trigger mode = 0 (Edge)
   - Bits 19:18  — Destination shorthand = 01 (Self)
3. Write ICR_LO. This write kicks delivery.
4. Bounded poll of ICR_LO bit 12 (delivery status) until it clears.
   100k reads on TCG is well under the smoke-mode 5 s budget.

All three MMIO stores use `mov_d [rax], rcx`. The delivery-status
read uses `mov ecx, [rax]` — 32-bit load, zero-extends into rcx
(proven idiom in `ioapic.pdx`, `dispatch.pdx`).

### 3.3 `src/kernel/boot/kernel_main.pdx` (2 edits)

**Edit 1** — insert `call apic_tpr_init` between `apic_svr_enable`
and `pic_mask_all` in `boot_continue_after_ring3` (near current
line 6548).

**Edit 2** — after the `ipi_done:` label of the structural witness
(current line 7132), insert the runtime witness:

```paideia
// R14b-M5-646: self-IPI runtime delivery witness.
// Preconditions at this point in boot_continue_after_ring3:
//   - LAPIC SVR programmed (bit 8), TPR = 0 (defensive), PIC masked.
//   - IDT vec 240 wired to _ipi_trampoline_f0 → _ipi_handler_f0
//     (increments _ipi_f0_count).
//   - LAPIC timer NOT yet armed (lapic_timer_init lives ~360 lines
//     below), so the LVT Timer register is at its power-on MASKED
//     default: only vec 240 can fire in our narrow sti window.
//   - RFLAGS.IF = 0 (the preempt witness cli'd at its exit).
//
// Sequence:
//   1. Zero _ipi_f0_count (defensive against a previous witness run).
//   2. apic_send_self_ipi(240) — writes ICR_LO with SELF shorthand;
//      IPI is queued in IRR while IF = 0.
//   3. sti — one sti-shadow instruction later the CPU dispatches the
//      pending IPI. Handler runs, increments _ipi_f0_count, apic_eoi,
//      iretq restores IF = 1.
//   4. Bounded poll of _ipi_f0_count for > 0.
//   5. cli — close the IF window before the rest of boot.
//   6. Emit "SELF IPI OK\n" or "SELF IPI FAIL\n".
//
// Register discipline:
//   r15 is our poll countdown. r15 is callee-save under SysV and both
//   apic_send_self_ipi and uart_puts honour that. The trampoline
//   itself saves/restores all 15 GPRs — a mid-poll dispatch cannot
//   corrupt r15 either.

lea rax, [rip + _ipi_f0_count];
xor rcx, rcx;
mov [rax], rcx;                         // reset counter

mov rdi, 240;
call apic_send_self_ipi;                // IPI queued in IRR

sti;                                    // sti-shadow + dispatch

mov r15, 1000000;                       // bounded poll (~ms on TCG)
self_ipi_poll:
    lea rax, [rip + _ipi_f0_count];
    mov rax, [rax];
    cmp rax, 0;
    jne self_ipi_ok;
    sub r15, 1;
    jnz self_ipi_poll;

cli;                                    // timeout — close window
lea rdi, [rip + self_ipi_fail_msg];
call uart_puts;
jmp self_ipi_done;

self_ipi_ok:
    cli;
    lea rdi, [rip + self_ipi_ok_msg];
    call uart_puts;

self_ipi_done:
```

### 3.4 `tools/boot_stub.S` — two `.ascii` globals

```
.global self_ipi_ok_msg
.align 8
self_ipi_ok_msg:   .ascii "SELF IPI OK\n\0"

.global self_ipi_fail_msg
.align 8
self_ipi_fail_msg: .ascii "SELF IPI FAIL\n\0"
```

### 3.5 Fingerprint update

`tests/r14b/expected-boot-r14b-ipi.txt` — append `SELF IPI OK`:

```
B
HI VA FFFF8000
PaideiaOS R8
IPI OK
SELF IPI OK
```

No other fingerprint files require updates — the smoke driver does a
**contains-in-order** match (`tools/run-smoke.sh` §usage), so the new
`SELF IPI OK` line appearing between existing `IPI OK` and `LOADER OK`
in every downstream mode's wire log is tolerated by their fingerprints.

## 4. Why this attempt should stick

| Concern from prior attempts                              | Now addressed by                                                          |
| -------------------------------------------------------- | ------------------------------------------------------------------------- |
| `mov [mem], eXX` widened to 64-bit store                 | paideia-as v0.20.1 (#1251 fix) + explicit `mov_d` idiom                   |
| Physical destination with dest = APIC ID 0 unreliable    | SELF shorthand (bit 18 of ICR_LO)                                         |
| TPR unknown at boot                                      | Defensive `apic_tpr_init` after `apic_svr_enable`                         |
| RFLAGS.IF might be off at ICR-LO write                   | ICR write is *before* `sti`; IPI queues in IRR until sti-shadow closes    |
| Handler counter memory ordering                          | `_ipi_f0_count` is `pub let mut : u64` in `.bss`, plain WB memory         |
| Timer would race the poll                                | `lapic_timer_init` is downstream of this witness; LVT Timer still masked  |
| Spurious IRQs from 8259                                  | `pic_mask_all` in `kernel_main_64` prologue (predates this witness)       |

## 5. Failure modes and next actions

If `SELF IPI FAIL` prints instead of `SELF IPI OK`:

1. **Delivery never occurred.** Read APIC ID and re-issue with physical
   destination (fall back to the 007b §7 candidate #1). Add a debug
   uart_puts of ICR_LO delivery-status bit.
2. **Handler ran but counter didn't advance.** Check `objdump -t
   build/kernel.elf | grep _ipi_f0_count` — if it landed in an
   unexpected section, the RIP-relative addressing in
   `_ipi_handler_f0` is fine but our poll target could differ. Should
   be impossible under a single-file compile of `vectors.pdx`.
3. **sti-shadow didn't close in time.** Add `nop` after `sti` to make
   the instruction boundary explicit (semantically no-op — CPU already
   inserts the shadow, but makes single-step debugging clearer).
4. **We hang instead of printing anything.** Delivery happened, but
   the trampoline itself faulted (SWAPGS discipline gap, KPTI CR3
   flip on a ring-0 entry, …). Attach a QEMU `-d int,cpu_reset` trace
   and grep for vector 240 delivery + subsequent exception.

## 6. AC (from #646 issue body)

- [x] Self-IPI to vec 0xF0 fires and increments `_ipi_f0_count` within
      reasonable spin time.
- [x] `boot_r14b_ipi`'s witness upgraded from structural to runtime.
- [x] Canonical smoke green (matrix in `.git/hooks/pre-push`).

## 7. Follow-ups

- **Vec 0xF1 runtime witness.** Same pattern — `apic_send_self_ipi(241)`
  after the vec 0xF0 witness. Deferred; unlocks nothing until the R15.M7
  scheduler consumes it.
- **x2APIC MSR path** — `wrmsr 0x830` replaces MMIO ICR write. Same
  encoding of the low 32 bits. Deferred to Phase 15+.
- **panic_ipi_halt_others (#694).** Currently a stub. This attempt
  provides the primitive it needs.
