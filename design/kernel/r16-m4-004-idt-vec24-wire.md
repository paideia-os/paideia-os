---
issue: 598
milestone: R16.M4 (UART input driver — 16550 RX interrupt-driven)
subsystem: 14 — UART input driver (16550 RX interrupt-driven)
topic: idt vector 0x24 (36 decimal) install — trampoline that saves 15 GPRs, calls uart_rx_isr, restores, iretqs
prereq:
  - "R9-m1-002 / #252 (LANDED; core/int/idt.pdx.idt_install — the 256-vector build+lidt loop this issue extends with one additional cmp/je branch)"
  - "R10-m1-002 / #644 (LANDED; freezes the exception-vector `direct lea r9, [rip + trampoline_vecN]` inside-loop dispatch pattern this issue copies for vec 36)"
  - "R14b-m5-006 / #511 (LANDED; core/ipi/vectors.pdx — freezes the `pub let _<name>_trampoline` + 15-GPR-push + `call <isr>` + 15-pop + `add rsp, 16` + `iretq` template for non-exception IRQ trampolines. The IPI trampolines are the correct structural template for this issue, NOT trampoline_vec32.)"
  - "R16-M4-001 / #595 (LANDED; establishes core/uart/ directory)"
  - "R16-M4-002 / #596 (LANDED; core/uart/rx_ring.pdx)"
  - "R16-M4-003 / #597 (LANDED; core/uart/rx_isr.pdx.uart_rx_isr — the sole target of this trampoline. Signature `() -> () !{sysreg, mem} @{boot}`; runs with IF=0; calls apic_eoi in its body)"
blocks:
  - "#599 (r16-m4-005 ioapic-route-irq4 — first moment at which the trampoline installed here actually fires against a real IRQ 4. Without #598 in place, #599's IOAPIC RTE would route IRQ 4 to a stub gate and #GP the first delivery.)"
  - "#600 (r16-m4-006 uart_rx_notification_cap — indirectly, via the trampoline→isr→ring→cap chain)"
  - "#601 (r16-m4-007 RX smoke — end-to-end AC via QEMU stdin)"
touching:
  - src/kernel/core/uart/rx_trampoline.pdx               (new module — ~50 LOC incl. justification)
  - src/kernel/core/int/idt.pdx                          (extend idt_install with one cmp/je branch + one direct-lea label — ~10 LOC delta)
  - src/kernel/boot/kernel_main.pdx                      (witness block — ~55 LOC after last-landed R16.M4 witness)
  - tools/boot_stub.S                                    (2 rodata additions: ok_msg, fail_msg)
  - tests/r14b/expected-boot-r14b-loader.txt             (marker: `R16 IDT VEC24 OK`)
  - tests/r15/expected-boot-r15-ring3.txt                (marker)
  - tests/r15/expected-boot-r15-process.txt              (marker)
  - design/kernel/r16-m4-004-idt-vec24-wire.md           (this doc)
related:
  - src/kernel/core/int/idt.pdx                          (R9-m1-002 / #252 — the module this issue extends. Trampolines
                                                          for exception vectors 0/3/6/8/13/14/33 use direct-lea inside
                                                          the loop (lines 411-435). Trampolines for IRQ vectors 32/240/
                                                          241 use preload-outside-loop + mov-inside-loop (lines 335-339,
                                                          397, 402, 406). This issue adopts the direct-lea idiom, matching
                                                          the more recent exception-vector pattern.)
  - src/kernel/core/ipi/vectors.pdx                      (R14b-m5-006 / #511 — freezes the trampoline template this
                                                          issue's _uart_rx_trampoline copies verbatim modulo the vector
                                                          number and the called ISR. Key structural difference from
                                                          trampoline_vec32 (idt.pdx:195): the IPI trampolines do NOT
                                                          embed a preemption-check tail, and they emit apic_eoi from
                                                          the trampoline body rather than the ISR. This issue emits
                                                          apic_eoi from the ISR body (uart_rx_isr already calls it —
                                                          see #597 §3.4), so this trampoline does NOT include a
                                                          `call apic_eoi` — matching trampoline_vec32's delegation.)
  - src/kernel/core/uart/rx_isr.pdx                      (R16-M4-003 / #597 — the sole target. uart_rx_isr signature:
                                                          `() -> () !{sysreg, mem} @{boot}`. Body calls apic_eoi at end.)
  - src/kernel/core/int/exceptions.pdx                   (R10-m1-002, R11-m4-001 — trampoline_vec32 in idt.pdx delegates
                                                          into handle_timer here; conceptual parallel: our trampoline
                                                          delegates into uart_rx_isr in rx_isr.pdx. Timer trampoline
                                                          includes preempt-check tail (r11 sched_pick_next); our
                                                          trampoline deliberately omits — RX has no per-tick preemption
                                                          semantic. See §3.4.)
  - design/milestones/r14b-tactical-plan.md              §Subsystem 14, item 4 (this issue's plan pointer)
  - design/kernel/r16-m4-003-uart-rx-isr.md              §1.2 explicitly reserves this issue as the trampoline installer;
                                                          §5.1 confirms uart_rx_isr's SysV alignment is safe under a
                                                          trampoline caller.
---

# R16-M4-004 — `idt vector 0x24 wire`: install `_uart_rx_trampoline` at IDT slot 36 (#598)

## 1. Scope

Land the fourth R16.M4 subsystem-14 issue: the **IDT gate**
that turns IRQ 4 delivery from the IOAPIC into a call of
`uart_rx_isr`. Concretely:

- **New file `src/kernel/core/uart/rx_trampoline.pdx`** exporting
  a single symbol `_uart_rx_trampoline`. Real body: push
  errcode-placeholder + vector 36, save 15 GPRs, `mov rdi, rsp`,
  `call uart_rx_isr`, restore 15 GPRs, discard vector+errcode
  via `add rsp, 16`, `iretq`. Structurally identical to
  `_ipi_trampoline_f0` (ipi/vectors.pdx:17) modulo the vector
  number and the called ISR.
- **One-line dispatch extension** to `idt_install` at
  `src/kernel/core/int/idt.pdx`: add `cmp rcx, 36; je
  idt_setup_vec36` inside the existing 256-vector build loop, plus
  a new `idt_setup_vec36:` label that does `lea r9, [rip +
  _uart_rx_trampoline]; jmp idt_pack_entry;` — matching the
  exception-vector direct-lea idiom (idt.pdx:411-435).

Acceptance (issue AC): **idt dump shows vector 0x24 populated.**
The kernel_main witness reads the packed IDT entry at
`_idt_storage[36 * 16]`, reconstructs the handler offset from
its lo16/mid16/hi32 fields, and verifies it equals the address
of `_uart_rx_trampoline`. Also verifies the gate type byte
(offset 5) = `0x8E` (present, DPL=0, 64-bit interrupt gate).

### 1.1 What this issue proves

- **The IDT-entry packing loop composes cleanly with a new
  vector.** #252/#644 established a monolithic
  cmp/je/direct-lea dispatch inside a single 256-iteration
  loop; #598 extends it with one additional branch. No new
  packing code, no second `lidt`, no side-write into
  `_idt_storage` after the fact.
- **A subsystem-owned trampoline can live under
  `src/kernel/core/uart/`** rather than being smeared into
  `core/int/`. The IPI subsystem (R14b-m5-006) established this
  discipline; this issue extends it to UART RX. `core/int/idt.pdx`
  now owns *no* trampoline code — every trampoline body lives
  under its owning subsystem's directory.
- **The IRQ (non-exception) trampoline template is
  reusable.** `_ipi_trampoline_f0` is copied verbatim modulo
  the vector number and the called ISR, verifying the template
  is subsystem-agnostic.
- **The witness can round-trip a packed IDT entry.** Reading
  the 16-byte gate at `_idt_storage + 576` (36 * 16) and
  reconstructing lo16 | mid16<<16 | hi32<<32 back to a
  64-bit function pointer, then comparing against `[rip +
  _uart_rx_trampoline]`, exercises every field of the pack
  arithmetic in `idt_install` for this vector — including the
  cross-boundary `offset_mid << 48` shift that produced the
  encoder gap resolved at paideia-as #1249.

### 1.2 What this issue deliberately does NOT do

- **No IOAPIC routing.** #599 programs the IOAPIC RTE so IRQ 4
  reaches vector 0x24. Without that routing, even with this
  trampoline installed, IRQ 4 never reaches the CPU. The
  witness therefore does NOT observe a real interrupt — it
  observes only the installed gate. Safe by construction: even
  if the trampoline is wrong (e.g., unbalanced stack), no path
  invokes it at witness time.
- **No cli/sti at witness time.** The witness runs in the same
  interrupt-disabled window as every other R16.M4 witness
  (kernel_main is `cli` until `sti` after `_current_tcb`
  init). No interrupt can preempt the IDT read-back. Also
  matches every other IDT witness (R14b-m5-007's IPI
  structural witness at `kernel_main.pdx:4259`).
- **No self-IPI to synthesize a vec 0x24 delivery.** Rejected —
  see §6.2. Software-generating IRQ 4 via LAPIC ICR would
  require the LAPIC to be software-enabled (`apic_svr_enable`
  hasn't run at witness time — see §4.2 for placement), *and*
  would end up executing the actual `uart_rx_isr` body against
  an empty COM1 (indistinguishable from #597's witness), *and*
  would need EOI accounting for a live in-service bit. Zero
  incremental coverage vs. the field-reconstruction witness
  planned here.
- **No pic_mask_all reorder.** `pic_mask_all` runs at
  `kernel_main.pdx:3871` (well after this witness's placement
  at ~3857). No change to that ordering. The 8259 PIC is not
  yet the source of IRQ 4 (that comes from the IOAPIC per
  #599); the mask ordering is unchanged.
- **No new gate-type constant module.** `GATE_INTERRUPT =
  0x8E` is already defined at `idt.pdx:32`. Reused via literal
  in the witness comparison (`cmp al, 0x8E`).
- **No LAPIC EOI at trampoline entry or exit.** The ISR body
  (uart_rx_isr, #597) already calls `apic_eoi` at its epilogue.
  Emitting EOI from the trampoline would double-write LAPIC
  MMIO 0xFEE000B0. This matches `trampoline_vec32` (idt.pdx:195),
  which delegates EOI to `handle_timer` (exceptions.pdx:162).
  Diverges from `_ipi_trampoline_f0` (ipi/vectors.pdx:27),
  which calls `apic_eoi` before the handler — the IPI handlers
  are stubs that do NOT call apic_eoi themselves.
- **No renaming of `_uart_rx_trampoline` to `trampoline_vec36`
  for symmetry with `trampoline_vec32`.** Rejected — the R14b
  IPI-era naming (`_<subsystem>_trampoline_<suffix>`) is the
  going-forward pattern. `trampoline_vec32/33/0/3/6/8/13/14`
  are historical (R9-R10 era). Consistency with the newest
  IRQ trampoline naming (`_ipi_trampoline_f0/f1`) wins.
- **No changes to `_idt_descriptor` or the lidt call site.**
  The IDT descriptor is 10 bytes (limit=4095 + base=&_idt_storage);
  vector count is unchanged (still 256). No lidt-twice. The
  extend-idt_install approach is the only correct wire.

## 2. Prereq check

### 2.1 What is in place

| Primitive                       | Location                                    | Contract used                                                                              |
|---------------------------------|---------------------------------------------|--------------------------------------------------------------------------------------------|
| `core/uart/` directory          | `src/kernel/core/uart/rx_isr.pdx`           | R16-M4-001..003 established the directory. This issue adds `rx_trampoline.pdx` as sibling. |
| `uart_rx_isr`                   | `core/uart/rx_isr.pdx:48` (R16-M4-003 #597) | `() -> () !{sysreg, mem} @{boot}`. Calls `apic_eoi` at epilogue. Runs with IF=0.           |
| `idt_install`                   | `core/int/idt.pdx:311` (R9-m1-002 #252)     | Monolithic build+lidt loop; extend via one cmp/je branch.                                  |
| `_idt_storage`                  | `core/int/idt.pdx:302`                      | `[u64; 512]` — 4096 bytes; entry N at byte offset N*16.                                    |
| IDT entry packing (word0/word1) | `core/int/idt.pdx:439-472`                  | Fields: offset_lo (bits 0-15), sel (16-31), ist (32-39), type (40-47), offset_mid (48-63); word1: offset_hi (0-31). |
| Direct `lea r9, [rip + sym]` inside idt_install loop | `core/int/idt.pdx:411-435` (R10-m1-002 #644) | Exception vec 0/3/6/8/13/14/33 dispatch pattern; verbatim template.       |
| 15-GPR push/pop macro           | `core/int/idt.pdx:78-89, 199-228`; `core/ipi/vectors.pdx:24-33, 46-55` | Canonical trampoline shape.                                     |
| `iretq` mnemonic                | Ubiquitous in trampolines (idt.pdx, ipi/vectors.pdx) | Paideia-as encoder support proven since R10-m1-002.                              |
| `mov rdi, rsp` for frame ptr    | `core/int/idt.pdx:205`; `core/ipi/vectors.pdx:28`   | SysV arg 0 = trap-frame pointer; ISR ignores it here.                            |
| `add rsp, 16` epilogue          | Every trampoline in tree                    | Discards pushed errcode-placeholder + vector-number before iretq.                          |

### 2.2 What is NOT in place

- **`_uart_rx_trampoline` symbol.** Introduced by this module.
- **`idt_setup_vec36:` label and the cmp/je branch** in
  `idt_install`. Added by this issue as a strictly additive
  4-line edit.
- **`R16 IDT VEC24 OK` / `R16 IDT VEC24 FAIL` rodata strings.**
  Added to `boot_stub.S` alongside the last-landed R16.M4
  witness strings.
- **Any IOAPIC routing.** #599's concern; explicitly *not*
  wired here.

### 2.3 Encoder gaps

**None.** Every mnemonic used has landed precedent, including
the cross-module `lea r9, [rip + _uart_rx_trampoline]` reference
(idt.pdx already leas the cross-module `_ipi_trampoline_f0` and
`_ipi_trampoline_f1` from ipi/vectors.pdx per R14b-m5-006).

| Mnemonic form                        | Proven at                                                         |
|--------------------------------------|-------------------------------------------------------------------|
| `push rax` / `push rN`               | Every trampoline (idt.pdx:78-89, ipi/vectors.pdx:24-27).          |
| `mov rax, imm; push rax`             | Every trampoline errcode-placeholder + vector-push pair.          |
| `mov rdi, rsp`                       | `core/int/idt.pdx:205`; `core/ipi/vectors.pdx:28`.                |
| `call sym` (cross-module)            | `core/ipi/vectors.pdx:29` (`call _ipi_handler_f0`).               |
| `pop r15`..`pop rax` (15 pops)       | Every trampoline.                                                 |
| `add rsp, 16`                        | Every trampoline (discard vector + errcode-placeholder).          |
| `iretq`                              | Every trampoline (idt.pdx:88, 229; ipi/vectors.pdx:34, 56).       |
| `cmp rcx, imm8` + `je label`         | `core/int/idt.pdx:360-390`.                                       |
| `lea r9, [rip + sym]` (cross-module) | `core/int/idt.pdx:411-435` for same-module; #644 pattern extends  |
|                                      | to cross-module: idt.pdx:338-339 already leas cross-module        |
|                                      | `_ipi_trampoline_f0/f1` from ipi/vectors.pdx (into r14/r13 outside |
|                                      | the loop). Direct in-branch cross-module lea is the same encoding. |
| Byte compare from packed entry field | `core/fs/path.pdx:*` (`mov_b`/`xor+mov_b` idiom); see §5.2.       |
| `mov rax, [rip + sym]`               | Ubiquitous.                                                       |
| `shl rax, imm8` (48)                 | `core/int/idt.pdx:462` (`shl r10, 48`).                           |
| `shr rax, imm8` (16, 32, 48)         | `core/int/idt.pdx:460, 471`.                                      |
| `and rax, imm32` (0xFFFF)            | `core/int/idt.pdx:461`.                                           |
| `or rax, rcx` field-reassembly       | `core/int/idt.pdx:448, 456, 464`.                                 |

No SIB. No REX.B on extended-register variants beyond what
`_ipi_trampoline_f0` already uses. No MMIO. **Cross-repo
escalation not needed.**

## 3. Design

### 3.1 File and module structure

**New file**: `src/kernel/core/uart/rx_trampoline.pdx`. Sits
alongside the siblings landed at R16-M4-001..003:

```
src/kernel/core/uart/
    rx_init.pdx        (#595, LANDED — IER=0x01)
    rx_ring.pdx        (#596, LANDED — 256-slot SPSC ring)
    rx_isr.pdx         (#597, LANDED — drain + EOI)
    rx_trampoline.pdx  <-- THIS ISSUE (#598 — IDT vec 0x24 entry point)
    rx_notify.pdx      (#600, planned — notification cap wake-up)
```

Module name: `RxTrampoline`. Public export:
`_uart_rx_trampoline`. No storage symbols. Justification: the
subsystem-14 discipline established by #595/#596/#597 keeps every
RX file under `core/uart/`. `core/int/idt.pdx` continues to own
*only* the packing arithmetic + `lidt` — no trampoline bodies.

**Extended file**: `src/kernel/core/int/idt.pdx`. Delta: one
additional `cmp/je` branch inside `idt_install`'s dispatch chain
(after `cmp rcx, 33; je idt_setup_vec33;`, before the default
stub fallthrough), and one new label `idt_setup_vec36:` that does
`lea r9, [rip + _uart_rx_trampoline]; jmp idt_pack_entry;`. No
new pack arithmetic, no restructuring, no new outside-loop
register preload.

### 3.2 Register discipline (trampoline)

The trampoline runs as an ISR entry point — called by the CPU on
IRQ 4 delivery via IDT gate 0x24. It:

- **Preserves all 15 GPRs** (rax through r15). All are pushed
  before the ISR body call; all are popped in reverse before
  iretq. This is the canonical trampoline shape — see the six
  exception trampolines (idt.pdx:78-232) and the two IPI
  trampolines (ipi/vectors.pdx:24-56).
- **Uses no callee-save register** for local state. All state
  is on the stack in the pushed GPR block.
- **Passes the trap-frame pointer to the ISR in `rdi`** via
  `mov rdi, rsp` (SysV arg 0). `uart_rx_isr` ignores the
  argument (its signature is `() -> ()`), but supplying `rdi`
  matches `trampoline_vec32` and every IPI trampoline — a
  future frame-decode instrumentation (R17+) inherits the
  hook for free. One instruction of cost per interrupt; free.
- **Alignment on ISR-body entry**: after the 15 pushes + the
  errcode-placeholder push + the vector push (17 x 8 = 136
  bytes), rsp is offset 136 mod 16 = 8. Add the CPU's
  auto-pushed RIP+CS+RFLAGS+RSP+SS frame (5 x 8 = 40 bytes)
  gives 176 = 11 * 16 → rsp%16 == 0 at the CPU-entry
  boundary, then after our 17 push_qwords the offset is
  0 + 17*8 = 136 → rsp%16 == 8, which is the SysV
  entry-alignment convention. `uart_rx_isr`'s own `sub rsp,
  8` at entry then makes rsp%16 == 0 for its nested calls.
  **Same alignment discipline as trampoline_vec32.**

### 3.3 Trampoline body — full instruction sequence

```asm
    ; --- CPU auto-pushed frame: SS, RSP, RFLAGS, CS, RIP ---
    ; (no errcode: IRQ, not exception — CPU does NOT push errcode for vec 36)

    mov rax, 0;    push rax                    ; errcode placeholder for stack uniformity
    mov rax, 36;   push rax                    ; vector number (canonical position)

    push rax; push rcx; push rdx; push rbx; push rbp
    push rsi; push rdi; push r8;  push r9;  push r10
    push r11; push r12; push r13; push r14; push r15   ; 15 GPRs saved

    mov rdi, rsp                                ; trap-frame ptr (unused by ISR, kept for symmetry)
    call uart_rx_isr                            ; drains RBR, calls apic_eoi, returns

    pop r15; pop r14; pop r13; pop r12; pop r11
    pop r10; pop r9;  pop r8;  pop rdi; pop rsi
    pop rbp; pop rbx; pop rdx; pop rcx; pop rax  ; 15 GPRs restored

    add rsp, 16                                 ; discard vector + errcode-placeholder
    iretq                                       ; CPU-frame pop
```

**Instruction count**: 2 (errcode+vector) + 15 (GPR pushes) + 2
(mov rdi, rsp + call) + 15 (GPR pops) + 2 (add + iretq) = **36
instructions**. Identical to `_ipi_trampoline_f0` (which is 36
instructions modulo the extra `call apic_eoi` — trampoline_vec32
is 36 + preempt-tail).

**Why no `swapgs` at entry/exit.** IRQ 4 delivery at R16.M4
originates only from ring-0 kernel code (the shell isn't
running; no user-space is producing UART traffic to itself).
`swapgs` is required only when the interrupted context was
ring 3 — the CPU pushes CS on the trap frame, and a ring-3
CS bit ({CS & 3} != 0) is the correct guard. Ring-0-only
interrupts (timer, IPI, this) skip `swapgs`. Matches
`trampoline_vec32` and both IPI trampolines. When ring-3 UART
usage lands (R17+ shell reads /dev/ttyS0), the ring-3 guard
+ swapgs must be added to *every* R16.M4-era trampoline in
one coordinated PR — deferred; documented as a follow-up in
§6.5.

**Why no `cli`/`sti` inside the trampoline.** The CPU enters
an interrupt gate with IF=0 automatically (per IDT gate type
0x8E — interrupt gate, not trap gate). `iretq` restores the
pre-interrupt RFLAGS, which restores IF to its prior value.
No manual masking needed. Matches every other trampoline in
the tree.

### 3.4 Why NOT include an `apic_eoi` call in the trampoline

The two prior IRQ-trampoline shapes diverge on EOI placement:

- **`trampoline_vec32` (timer)** delegates EOI to `handle_timer`.
- **`_ipi_trampoline_f0/f1`** calls `apic_eoi` before the handler.

`uart_rx_isr` follows the timer discipline: it calls `apic_eoi`
at its own epilogue (rx_isr.pdx:75). Adding a second `call
apic_eoi` in the trampoline would:

1. Double-write LAPIC MMIO 0xFEE000B0. First write clears the
   in-service bit; second write is a no-op on a
   no-in-service-bit LAPIC, but generates spurious LAPIC
   traffic and violates the "single EOI per IRQ" invariant.
2. Break the RX driver's design contract in #597 §3.6 (EOI is
   the ISR body's job).
3. Diverge from timer discipline for no reason (RX and timer
   are structurally symmetric — both have real ISR bodies
   that do meaningful post-processing).

**Delegation to the ISR body is chosen.** Documented in the
trampoline's justification block and reflected in §3.3's
instruction count (no `call apic_eoi`).

### 3.5 Why NOT include a preemption-check tail

`trampoline_vec32` has a distinct post-`handle_timer` epilogue
that checks `_preempt_needed` and, if set, calls
`sched_pick_next_r11` + `sched_preempt_to` before the 15-pop
tail (idt.pdx:208-222). This is a timer-specific concern:
budget-driven preemption is triggered on the tick boundary.

RX interrupts have no scheduling semantic. Byte arrival is
producer-into-ring only; the consumer (`sys_read`) is woken via
the notification cap at #600, not preempted here. Adding a
preempt-check tail would:

1. Interfere with the R17 SMP RX steering design (RX runs on
   CPU 0 only; scheduling is a per-CPU concern that shouldn't
   piggy-back on an IRQ handler with a different CPU affinity).
2. Introduce a coupling between the UART driver and the
   scheduler that #597 §3.7 explicitly documented as absent.

**Preempt-check omitted.** Matches every IPI trampoline (none
of which check `_preempt_needed`).

### 3.6 IDT wire — extend `idt_install` in-place

The existing dispatch pattern for a new vector is a strictly
additive 4-line edit to `idt_install`:

```asm
      ; existing chain (idt.pdx:389-390):
      cmp rcx, 33;
      je idt_setup_vec33;

      ; --- NEW: R16-M4-004 (#598) ---
      cmp rcx, 36;
      je idt_setup_vec36;

      ; existing default fallthrough (idt.pdx:392-394):
      xor r9, r9;
      jmp idt_pack_entry;
```

And a new label appended after `idt_setup_vec33:` (idt.pdx:434):

```asm
      idt_setup_vec36:
        lea r9, [rip + _uart_rx_trampoline];
        jmp idt_pack_entry;
```

**Why in-line the `lea` rather than preload outside the loop.**
Two conventions coexist in idt.pdx:

- **Preload-then-mov**: outside-loop `lea r15, [rip +
  trampoline_vec32]; lea r14, [rip + _ipi_trampoline_f0]; lea
  r13, [rip + _ipi_trampoline_f1]` (idt.pdx:335-339), then
  inside-loop `mov r9, r15/r14/r13` (lines 397, 402, 406).
- **Direct lea in branch**: exception vectors 0/3/6/8/13/14/33
  use `lea r9, [rip + trampoline_vecN]` directly inside their
  respective branch labels (lines 411-435).

Preload wins when a vector's trampoline address is hot (the
loop runs 256 iterations, so preloading avoids 256 `lea` from
memory each time; effectively one `mov r9, rN` per matched
iteration). But it consumes a callee-save register (r13, r14,
r15) and needs an outside-loop setup line.

**Direct-lea wins for a low-frequency addition**: (a) one match
per boot means the `lea` executes exactly once, (b) no register
budget consumed, (c) the branch label + jmp is
self-contained — future readers see the wire in one place.
Since idt_install runs once at boot, the perf argument for
preload is moot.

**Decision: direct-lea.** Matches the newer R10-m1-002 pattern
(exception vectors) rather than the older R9-m1-002 pattern
(timer). Consistency with the going-forward convention.

### 3.7 Alternatives considered — trampoline location

| Variant                                             | Rejected because                                                                                          |
|-----------------------------------------------------|-----------------------------------------------------------------------------------------------------------|
| **New file `core/uart/rx_trampoline.pdx` (chosen)** | Matches R14b-m5-006 IPI convention. Keeps subsystem-14 concerns under `core/uart/`. `core/int/` owns only pack+lidt. |
| Add trampoline body to `core/uart/rx_isr.pdx`       | Mixes trampoline (IDT entry, called only by CPU) and ISR body (call target, also invoked by witness) in one file. Two distinct callers with different alignment contracts; separation aids code review. |
| Add trampoline body to `core/int/idt.pdx`           | The R9-R10 convention for trampoline_vec32 and vec0/3/6/8/13/14/33. R14b-m5-006 explicitly moved IPI trampolines out of idt.pdx into their own subsystem file; this issue follows suit. Continuing to accrete trampolines in idt.pdx defeats the modularization work already done for IPI. |
| Add trampoline body to `core/int/exceptions.pdx`    | exceptions.pdx is for CPU-exception handler bodies (handle_de, handle_pf, etc.). UART RX is an IRQ, not an exception. Wrong module. |

### 3.8 Alternatives considered — IDT wire mechanism

| Variant                                             | Rejected because                                                                                          |
|-----------------------------------------------------|-----------------------------------------------------------------------------------------------------------|
| **Extend `idt_install` with one cmp/je (chosen)**   | Strictly additive; matches every other wire (10 already in place). Preserves the "one lidt per boot" invariant. |
| New `idt_install_uart_rx()` function called after `idt_install` | Requires either (a) a second `lidt` (broken — IDTR is a single pointer, second lidt overwrites the first with the same base but pointless), or (b) a side-write into `_idt_storage[36*16]` after `idt_install` runs (duplicates the packing arithmetic in a second site — bisect-hostile if the packing changes). |
| New `idt_wire_vec(vec, handler_addr)` generic helper | Worth doing eventually — R17+ device driver plane will accumulate ≥8 IRQ vectors. But refactoring the monolithic `idt_install` to call this helper 10 times touches every wired vector; hostile to bisect for the R16.M4 landing. Filed as a follow-up in §6.3. |
| Rebuild the entire IDT from a table constant        | Cleanest end-state, but requires paideia-as data-table + init-list support that isn't landed. Deferred to R17+ hardening. |

### 3.9 File contents — `rx_trampoline.pdx`

```pdx
// src/kernel/core/uart/rx_trampoline.pdx — R16-M4-004 (#598)
// IDT vector 0x24 (36) entry point for IRQ 4 (16550 RX).
//
// Trampoline shape: push errcode placeholder + vector number,
// save 15 GPRs, mov rdi, rsp (trap-frame ptr, unused by ISR but
// kept for symmetry with every other IRQ trampoline in the tree),
// call uart_rx_isr, pop 15 GPRs, discard vector + errcode via
// add rsp, 16, iretq.
//
// Structurally identical to _ipi_trampoline_f0 (core/ipi/
// vectors.pdx:17) modulo the vector number (36 vs 240) and the
// called ISR (uart_rx_isr vs _ipi_handler_f0). Two structural
// differences from IPI:
//   (a) No `call apic_eoi` in the trampoline — uart_rx_isr calls
//       apic_eoi at its own epilogue (rx_isr.pdx:75). Adding a
//       second EOI here would double-write LAPIC MMIO 0xFEE000B0.
//       Matches trampoline_vec32 (idt.pdx:195), which delegates
//       EOI to handle_timer.
//   (b) No preemption-check tail — RX has no per-tick preemption
//       semantic. Byte arrival is producer-into-ring only; the
//       consumer wake is via notification cap at #600.
//
// Contract:
//   Entry: CPU has auto-pushed the 5-qword interrupt frame (SS,
//          RSP, RFLAGS, CS, RIP). No errcode (IRQ, not exception).
//          IF=0 (interrupt gate).
//   Exit:  iretq restores the auto-pushed frame; RFLAGS restore
//          restores IF to its pre-interrupt state.
//   Called from: CPU on IRQ 4 delivery through IDT slot 36 (once
//                #599 lands the IOAPIC RTE). At R16.M4-004 landing,
//                no path invokes this trampoline (IOAPIC route
//                not programmed, 8259 masked); the witness only
//                verifies the IDT gate is populated.
//
// See design/kernel/r16-m4-004-idt-vec24-wire.md for full contract.

module RxTrampoline = structure {
  // ==========================================================================
  // _uart_rx_trampoline — IDT vec 0x24 entry point
  //
  // Input:  (CPU-pushed frame + zero-arg convention)
  // Output: (iretq)
  //
  // Side effects:
  //   Full state save/restore around a call to uart_rx_isr, which
  //   drains COM1 16550 RBR into the software RX ring and writes
  //   LAPIC EOI.
  //
  // Clobbers:
  //   None (all 15 GPRs saved/restored across the ISR call;
  //   iretq restores RFLAGS/RIP/CS/RSP/SS).
  // ==========================================================================
  pub let _uart_rx_trampoline : () -> () !{sysreg, mem} @{boot} = fn () -> unsafe {
    effects: { sysreg, mem },
    capabilities: { boot },
    justification: "R16-M4-004 (#598): IDT vector 0x24 (36) trampoline for IRQ 4 (16550 RX). Push errcode placeholder + vector 36, save 15 GPRs, mov rdi, rsp (SysV arg 0 = trap-frame ptr; ignored by uart_rx_isr but kept for symmetry with trampoline_vec32 and IPI trampolines — hook for future frame decode). Call uart_rx_isr (core/uart/rx_isr.pdx:48, R16-M4-003 #597), which drains COM1 RBR into the software ring and writes LAPIC EOI at 0xFEE000B0. Pop 15 GPRs, add rsp, 16 to discard vector + errcode placeholder, iretq to restore CPU-pushed frame. No `call apic_eoi` in this trampoline — uart_rx_isr already calls it; a second EOI would double-write LAPIC MMIO. Matches trampoline_vec32 (idt.pdx:195, R9-m4) which delegates EOI to handle_timer. Diverges from _ipi_trampoline_f0 (ipi/vectors.pdx:17) which calls apic_eoi in the trampoline because its handler is a counter-bump stub. No preemption-check tail — RX has no scheduler coupling; consumer wake is via notification cap at #600 (not preemption here). Runs with IF=0 (IDT gate type 0x8E = interrupt gate clears IF on entry; iretq restores caller RFLAGS). No swapgs — R16.M4 IRQ 4 originates only from ring-0 kernel context; ring-3 UART usage lands at R17+ shell and will require coordinated ring-3-CS-check + swapgs added to this trampoline (documented as followup in design §6.5). Alignment: 15 GPR pushes + 2 placeholder qwords + CPU-pushed 5-qword frame = 176 bytes = 11 * 16 → rsp%16 == 0 at CPU-entry boundary; after our pushes rsp%16 == 8, matching SysV entry convention for uart_rx_isr's `sub rsp, 8` prelude. Encoder: zero paideia-as gaps; every mnemonic proven — see design §2.3. Cross-module symbol reference: idt_install (core/int/idt.pdx) leas [rip + _uart_rx_trampoline] via the same encoder path already used for _ipi_trampoline_f0/f1 (idt.pdx:338-339). Audit: r16-m4-004-idt-vec24-wire.",
    block: {
      // Push errcode placeholder + vector number.
      mov rax, 0;   push rax;                   // errcode placeholder (IRQ, no CPU push)
      mov rax, 36;  push rax;                   // vector number = 0x24

      // Save 15 GPRs (canonical trampoline order).
      push rax; push rcx; push rdx; push rbx; push rbp
      push rsi; push rdi; push r8;  push r9;  push r10
      push r11; push r12; push r13; push r14; push r15

      // Trap-frame ptr in rdi (SysV arg 0). uart_rx_isr ignores.
      mov rdi, rsp
      call uart_rx_isr

      // Restore 15 GPRs (reverse order).
      pop r15; pop r14; pop r13; pop r12; pop r11
      pop r10; pop r9;  pop r8;  pop rdi; pop rsi
      pop rbp; pop rbx; pop rdx; pop rcx; pop rax

      // Discard vector + errcode placeholder; return via iretq.
      add rsp, 16
      iretq
    }
  }
}
```

**Instruction count**: 36 mnemonic lines (see §3.3 breakdown).
Matches `_ipi_trampoline_f0` structure exactly, minus the
`call apic_eoi` line. Line-for-line comparison with
ipi/vectors.pdx:17-36 verifies the shape.

### 3.10 File contents — `idt.pdx` diff

Two hunks, both strictly additive.

**Hunk 1** — new cmp/je in the dispatch chain (after line 390):

```
          cmp rcx, 33;
          je idt_setup_vec33;

+         // R16-M4-004 (#598): UART RX IRQ 4 → vector 0x24
+         cmp rcx, 36;
+         je idt_setup_vec36;
+
          // Default: stub handler at offset 0.
          xor r9, r9;
```

**Hunk 2** — new label after `idt_setup_vec33:` (after line 436):

```
          idt_setup_vec33:
            lea r9, [rip + trampoline_vec33];
            jmp idt_pack_entry;

+         // R16-M4-004 (#598): UART RX IRQ 4 handler
+         idt_setup_vec36:
+           lea r9, [rip + _uart_rx_trampoline];
+           jmp idt_pack_entry;
+
          idt_pack_entry:
```

**Total idt.pdx delta**: 10 added lines (5 per hunk including
comments and spacing). No lines removed, no lines reordered.
The existing pack arithmetic at `idt_pack_entry:` handles the
new vector's entry with zero changes.

**Justification block update** to `idt_install` (line 315):
extend the existing multi-paragraph justification with one
sentence:

```
+ R16-M4-004 (#598): Vector 36 (IRQ 4, UART RX) wired to
+ _uart_rx_trampoline from RxTrampoline module via cross-module
+ direct-lea inside the loop dispatch. Matches the R10-m1-002
+ exception-vector direct-lea idiom (contrast with the timer/IPI
+ preload-outside pattern).
```

## 4. Witness placement

### 4.1 Position in kernel_main.pdx

Inserted after the last-landed R16.M4 witness `_done` label
(`uart_rx_isr_witness_done:` at approximately
`kernel_main.pdx:3857`). Insertion point:

```
      uart_rx_isr_witness_done:
          pop  r12;

      <-- INSERT R16.M4-004 WITNESS HERE

      // R14b-m5-002 (#507): IA32_GS_BASE = &_cpu_locals[0] on CPU0.
      lea rax, [rip + _cpu_locals];
```

Structurally independent — no data flow into or out of any
preceding witness. The GS_BASE/process_init/apic_svr_enable
sequence that follows is unaffected: the IDT read-back writes
nothing observable to any later-witness state.

### 4.2 Ordering constraints — safety

- **Must run AFTER `idt_install`**. `idt_install` is called at
  `kernel_main.pdx:80` (very early in boot). The witness runs
  at ~3857 (well after). `_idt_storage[36]` is populated by
  this point.
- **Must run BEFORE `apic_svr_enable`** (line 3869). Not
  strictly required (the LAPIC SVR being off makes IRQ delivery
  impossible regardless of IDT state), but preserving this
  ordering means no interrupt can fire while the witness reads
  the IDT — even in a hypothetical future where a stale IRQ 4
  pending bit exists at LAPIC-enable time. Belt-and-braces.
- **Must run BEFORE any IOAPIC RTE for IRQ 4** (#599 lands
  post-#598). #598's witness is a static-inspection test only;
  a live IRQ during witness execution would cause an
  interrupt-return-mid-witness scenario that's provably safe
  (the trampoline saves all GPRs) but harder to reason about.
  Placing the witness before #599's routing eliminates the
  question.
- **Must run in the same `cli` window** as the other R16.M4
  witnesses. The `sti` at `kernel_main.pdx:*` (after
  `_current_tcb` init) is after all R16.M4 witnesses. Preserved
  by placing the witness immediately after
  `uart_rx_isr_witness_done`.

### 4.3 No witness slab needed

The witness reads `_idt_storage` (a pub static already
declared in idt.pdx) and computes on register-local values.
No new .bss symbols, no fixture data.

## 5. Test canary — kernel_main witness block

### 5.1 Sub-test structure

**Three sub-tests**, all mandatory:

- **Sub-test A — Presence**: `_idt_storage[36*16]` (the entry's
  first u64 word) must be non-zero. A default-stub entry has
  offset=0, selector=0x08, ist=0, type=0x8E, which packs to
  `0x8E00_0800_0000_0000` (non-zero) — so this test cannot
  distinguish "installed" from "stub". Instead, sub-test A
  checks that the **lower 16 bits** of word0 (which pack
  `offset_lo`) match the lower 16 bits of `_uart_rx_trampoline`.
  A stub entry has offset_lo == 0; the trampoline address is
  ~64K-aligned only by coincidence, so offset_lo == 0 has
  probability ~1/65536 for a non-stub match. Cheap and strong.
  (Ruled-in: catches the "cmp/je branch never taken" bug.)
- **Sub-test B — Gate type**: byte 5 of the entry (offset 5
  within the 16-byte gate, i.e. the second byte of word0 above
  bits 32) must equal `0x8E` — Present=1, DPL=0, gate
  type=0xE (64-bit interrupt gate). Reads word0 (u64) at
  `_idt_storage + 576`, shifts right by 40, masks with `0xFF`.
  (Ruled-in: catches "type field mis-packed" — the shift/mask
  arithmetic in `idt_install` bakes 0x8E into bits 40-47 of
  word0; verifying that specific position exercises the pack
  correctness.)
- **Sub-test C — Handler address round-trip**: reconstruct
  the full 64-bit handler offset from the three packed
  fields (offset_lo bits 0-15 of word0; offset_mid bits 48-63
  of word0; offset_hi bits 0-31 of word1) and compare against
  `[rip + _uart_rx_trampoline]`. This is the strongest
  proof — verifies the packing arithmetic, the direct-lea
  branch, and the cross-module symbol resolution all in one
  shot. If any of the three fields is mis-packed, the
  reassembled address diverges and the test fails.

**Why three sub-tests, not one.** Sub-test C is a superset of
A and B in principle, but a Sub-test C failure alone gives
"address mismatch" — hard to bisect. Sub-tests A and B
localize the failure:

- **A fails, C fails** → offset_lo pack broken (or dispatch
  branch not taken).
- **A passes, B fails, C fails** → type field pack broken.
- **A passes, B passes, C fails** → offset_mid or offset_hi
  pack broken.

The three-sub-test structure matches the R16-M4-002
uart_rx_ring witness discipline (4 sub-tests covering empty,
single, multi, wrap) — cheap in code, high in diagnostic
resolution.

### 5.2 Witness assembly (complete block)

```asm
; ============================================================
; R16-M4-004 (#598): idt vector 0x24 wire — 3 sub-tests
; ============================================================
;
; IDT entry layout (Intel SDM Vol 3A §6.14.1, 64-bit interrupt gate):
;   Bytes 0-1:  offset_lo (u16)
;   Bytes 2-3:  segment selector (u16, = 0x08 KERNEL_CS)
;   Byte  4:    IST (bits 0-2) + reserved (bits 3-7); = 0 for vec 36
;   Byte  5:    type_attr (u8): P=1 | DPL=0 | 0 | type=0xE → 0x8E
;   Bytes 6-7:  offset_mid (u16)
;   Bytes 8-11: offset_hi (u32)
;   Bytes 12-15: reserved (u32, = 0)
;
; word0 (u64 at offset 0):
;   bits  0-15: offset_lo
;   bits 16-31: selector (0x08)
;   bits 32-39: IST
;   bits 40-47: type_attr (0x8E)
;   bits 48-63: offset_mid
;
; word1 (u64 at offset 8):
;   bits  0-31: offset_hi
;   bits 32-63: reserved (0)

idt_vec24_witness:
    push r12                                  ; callee-save: trampoline address survives all sub-tests
    push r13                                  ; callee-save: word0 survives sub-tests B and C

    ; Load trampoline address once; used by sub-tests A and C.
    lea  r12, [rip + _uart_rx_trampoline]

    ; Compute base address of IDT entry 36 (byte offset = 36 * 16 = 576).
    lea  rax, [rip + _idt_storage]
    add  rax, 576                             ; rax = &_idt_storage[36]

    ; Load word0 into r13 for sub-tests A and B.
    mov  r13, [rax]

    ; -------------------------------------------------------------
    ; Sub-test A: offset_lo (word0 bits 0-15) == trampoline & 0xFFFF
    ; -------------------------------------------------------------
    mov  rcx, r13
    mov  rdx, 0xFFFF
    and  rcx, rdx                             ; rcx = offset_lo from packed entry
    mov  rsi, r12
    and  rsi, rdx                             ; rsi = trampoline low16
    cmp  rcx, rsi
    jne  idt_vec24_witness_fail

    ; -------------------------------------------------------------
    ; Sub-test B: type_attr (word0 bits 40-47) == 0x8E
    ; -------------------------------------------------------------
    mov  rcx, r13
    shr  rcx, 40                              ; rcx = type_attr | offset_mid<<8 | ...
    mov  rdx, 0xFF
    and  rcx, rdx                             ; rcx = type_attr byte
    cmp  rcx, 0x8E
    jne  idt_vec24_witness_fail

    ; -------------------------------------------------------------
    ; Sub-test C: reassembled handler offset == trampoline
    ;   reassembled = (word0 & 0xFFFF)                       ; offset_lo
    ;               | ((word0 >> 48) & 0xFFFF) << 16         ; offset_mid
    ;               | (word1 & 0xFFFFFFFF) << 32             ; offset_hi
    ; -------------------------------------------------------------
    ; offset_lo → rcx (low 16 bits of reassembled)
    mov  rcx, r13
    mov  rdx, 0xFFFF
    and  rcx, rdx                             ; rcx = offset_lo (positions 0-15)

    ; offset_mid → rdi, then shift to positions 16-31, OR into rcx
    mov  rdi, r13
    shr  rdi, 48                              ; rdi = offset_mid (positions 0-15)
    and  rdi, rdx                             ; explicit mask (defensive)
    shl  rdi, 16                              ; rdi = offset_mid (positions 16-31)
    or   rcx, rdi

    ; offset_hi from word1 → rdi, shift to positions 32-63, OR
    mov  rdi, [rax + 8]                       ; rdi = word1
    mov  rdx, 0xFFFFFFFF
    and  rdi, rdx                             ; rdi = offset_hi (positions 0-31)
    shl  rdi, 32                              ; rdi = offset_hi (positions 32-63)
    or   rcx, rdi

    ; Compare reassembled offset against trampoline address.
    cmp  rcx, r12
    jne  idt_vec24_witness_fail

    ; --- All green ---
    lea  rdi, [rip + idt_vec24_ok_msg]
    call uart_puts
    jmp  idt_vec24_witness_done

idt_vec24_witness_fail:
    lea  rdi, [rip + idt_vec24_fail_msg]
    call uart_puts

idt_vec24_witness_done:
    pop  r13
    pop  r12
```

Total: ~65 lines including labels, comments, and blank lines.
~45 lines of instructions.

**Label uniqueness.** All labels prefixed `idt_vec24_witness_*`
to avoid clashes with prior R16.M4 witnesses.

**Register discipline.** r12 and r13 are SysV callee-save.
`push r12` / `push r13` at entry preserves outer kernel_main
values; `pop r13` / `pop r12` at exit restores. `uart_puts`
does not touch r12/r13 (SysV callee-save discipline preserved
by every prior witness's `push r12`/`pop r12` pattern —
see uart_rx_isr_witness at kernel_main.pdx:3832).

**No nested `sub rsp, 8` needed.** The witness makes exactly
one call (`call uart_puts`) per outcome branch; the SysV entry
convention gives rsp%16 == 8 at witness entry (post-call from
outer flow), and the two `push`es adjust rsp by 16, restoring
rsp%16 == 8 — the correct alignment for the nested `call
uart_puts`. Same discipline as every prior R16.M4 witness.

### 5.3 Marker

On all three sub-tests green:

```
R16 IDT VEC24 OK
```

Emitted via `uart_puts` on `idt_vec24_ok_msg`. Fingerprint
added to all three R14B/R15 expected-output files, inserted
immediately after `R16 UART RX ISR OK`.

### 5.4 String data — `tools/boot_stub.S`

Append after the last-landed R16.M4-003 witness strings:

```asm
# R16-M4-004 (#598): idt vector 0x24 witness success message
.global idt_vec24_ok_msg
.align 8
idt_vec24_ok_msg: .ascii "R16 IDT VEC24 OK\n\0"

# R16-M4-004 (#598): idt vector 0x24 witness failure message
.global idt_vec24_fail_msg
.align 8
idt_vec24_fail_msg: .ascii "R16 IDT VEC24 FAIL\n\0"
```

Single-line failure message — matches R16.M4-001/002/003
discipline. The three sub-tests share one FAIL marker; the
first failing sub-test aborts the chain, so the operator
inspects source to see which cmp/jne caught it.

**Alternative considered**: three per-sub-test failure
markers (`R16 IDT VEC24 FAIL A/B/C`). Rejected — the sub-test
grouping in §5.1 already gives bisect resolution *from the
FAIL symptom alone* (sub-test A tests offset_lo; if A passes
and C fails, the offset_lo pack is proven correct so the bug
is in offset_mid or offset_hi; etc.). The operator inspects the
`_idt_storage[36]` bytes via QEMU monitor / gdb `x/2gx` to
localize further. Three failure strings add rodata bytes with
no diagnostic gain that isn't already recoverable.

### 5.5 Fingerprint files — marker insertion

Insert `R16 IDT VEC24 OK` in three files:

| File                                        | Insert after            | Insert before          |
|---------------------------------------------|-------------------------|------------------------|
| `tests/r14b/expected-boot-r14b-loader.txt`  | `R16 UART RX ISR OK`    | `LOADER OK`            |
| `tests/r15/expected-boot-r15-ring3.txt`     | `R16 UART RX ISR OK`    | `R15 IDLE TASK OK`     |
| `tests/r15/expected-boot-r15-process.txt`   | `R16 UART RX ISR OK`    | `R15 IDLE TASK OK`     |

Contains-in-order matching makes the addition strictly additive.
5-mode smoke stages that do not observe R16 markers
(`boot_r8_only`, `boot_r10`, `boot_r11`, `boot_r12`,
`boot_r12_denial`) stay byte-identically green.

## 6. Alternatives considered / follow-ups

### 6.1 Include a runtime self-IPI trigger to prove IRQ 4 delivery

**Rejected — belongs at #601 (RX smoke).**

The runtime path — IOAPIC RTE for IRQ 4 → 16550 raises IRQ 4
on byte arrival → LAPIC delivers vector 0x24 → CPU walks IDT
entry → trampoline saves state → calls uart_rx_isr → drains RBR
→ EOI → iretq — requires #598, #599, and a stdin injection
harness at #601. Any subset short of all three cannot
demonstrate end-to-end.

Software-generating IRQ 4 via LAPIC ICR at witness time is
possible in principle but hostile:

- `apic_svr_enable` runs *after* this witness (§4.2). LAPIC ICR
  writes are undefined when SVR.enabled=0 (Intel SDM §10.4.7.1).
- Even with LAPIC enabled, self-IPI to vector 0x24 would
  execute the *actual* uart_rx_isr against empty COM1 —
  indistinguishable from #597's witness. Zero incremental
  coverage.
- EOI accounting would need care: self-IPI raises an
  in-service bit that must be cleared by the trampoline's
  call to uart_rx_isr's apic_eoi. If any of that chain is
  broken, the LAPIC stays in-service and the next timer IRQ
  is blocked — corrupting all subsequent witnesses.

The chosen static IDT-inspection witness is strictly
static/read-only. Zero LAPIC / IOAPIC state touched.

### 6.2 Combine with #599 (IOAPIC route IRQ 4) in one PR

**Rejected.** Same rationale as #597 §6.1: keep each issue's
regression surface minimal. #598 verifies IDT gate presence;
#599 verifies IOAPIC RTE contents. Merging them would leave
the trampoline untested until IOAPIC routing works, and would
require inventing an IOAPIC witness that isn't part of this
issue's AC.

### 6.3 Refactor `idt_install` to call `idt_wire_vec(vec, addr)` helper

**Deferred to a future hardening issue.** The current 10-vector
cmp/je chain is at ~50 LOC and growing by ~5 LOC per new
wired vector. At 20+ vectors (R17 device driver plane) the
chain becomes a maintenance liability. A generic
`idt_wire_vec(vec: u64, handler_addr: u64) -> ()` helper
called 10 times from `idt_install` after the default fill
would collapse the chain to a data-driven form.

Not this issue's concern. #598's landing must not touch any
of the 10 already-wired vectors — the risk of accidentally
regressing timer/IPI/exception delivery outweighs the
consolidation win.

### 6.4 Move `_uart_rx_trampoline` symbol to `core/int/idt.pdx`

**Rejected.** See §3.7 alternatives table. The R14b-m5-006
convention (IPI trampolines under `core/ipi/`) is the correct
going-forward pattern. Adding a new trampoline into idt.pdx
would fork the going-forward convention for no reason.

### 6.5 Add ring-3-CS-check + swapgs to trampoline for future ring-3 UART usage

**Deferred to R17+ shell integration.** At R16.M4, IRQ 4
originates only from ring-0 (no user-space is producing UART
traffic; the shell isn't running). No swapgs needed.

When R17's shell reads /dev/ttyS0 in ring 3, and a keyboard
event arrives while the shell is scheduled, IRQ 4 fires from
ring 3. That is when *every* R16.M4-era trampoline (this one,
timer, IPI) needs the standard {test CS & 3; jz skip; swapgs;
...; skip:} guard added. That's a coordinated ring-3-safety PR
touching all trampolines at once — bisect-safer than adding
swapgs to just this one and later realizing timer needed it too.

Documented; not blocking this issue.

### 6.6 Emit `R16 IDT VEC24 OK` from inside `_uart_rx_trampoline`

**Rejected.** Same discipline as every prior R16 subsystem:
the primitive is silent, the witness emits. Printing from a
trampoline would flood the console at any real IRQ rate and
destroy the console UX. Keeps `_uart_rx_trampoline` usable in
production paths (#599/#600 will invoke it dozens of times per
second under keyboard input).

### 6.7 Verify byte 4 (IST field) is 0 in a fourth sub-test

**Rejected as sub-test D.** The IST field for vec 36 is 0
(IST_NONE per idt.pdx:35); the default fill in `idt_install`
also uses IST=0 (line 452, "IST=0 for all vectors" comment).
A vec-36-specific IST check would pass identically for a stub
entry — zero diagnostic value. If a future issue introduces
IST=N for vec 36 (say, isolating the RX interrupt onto a
dedicated stack under a DoS scenario), the sub-test can be
added then.

### 6.8 Use `handle_timer`-style preload-outside-loop for the vec36 trampoline

**Rejected.** See §3.6 decision matrix. Direct-lea (matching
R10-m1-002 exception vectors) is the going-forward pattern; the
preload-outside-loop pattern in idt.pdx (r13/r14/r15 for IPI +
timer) is historical and doesn't need to grow.

## 7. Invariants

### 7.1 `_idt_storage[36].offset_lo` == `_uart_rx_trampoline & 0xFFFF`

- **Base case**: `idt_install` runs at boot; when the loop
  iteration for rcx=36 executes, the cmp/je branch takes to
  `idt_setup_vec36`, which sets r9 = &_uart_rx_trampoline.
- **Pack**: `idt_pack_entry` masks r9 with 0xFFFF and stores
  the result as bits 0-15 of word0 (idt.pdx:442-443,
  466-467).
- **Postcondition**: word0 & 0xFFFF == trampoline & 0xFFFF.

Verified by sub-test A.

### 7.2 `_idt_storage[36].type` == 0x8E

- **Base case**: `idt_install` sets `type_attr = 0x8E`
  unconditionally (idt.pdx:454-456), then packs it into bits
  40-47 of word0.
- **Postcondition**: (word0 >> 40) & 0xFF == 0x8E.

Verified by sub-test B.

### 7.3 Full handler offset reassembles to `_uart_rx_trampoline`

- **Base case**: same as 7.1.
- **Pack** (idt.pdx:442-472):
  - word0 bits 0-15 = offset_lo = trampoline & 0xFFFF
  - word0 bits 48-63 = offset_mid = (trampoline >> 16) & 0xFFFF
  - word1 bits 0-31 = offset_hi = (trampoline >> 32) & 0xFFFFFFFF
- **Reassembly** in the witness (§5.2):
  - reassembled = offset_lo | (offset_mid << 16) | (offset_hi << 32)
- **Postcondition**: reassembled == trampoline.

Verified by sub-test C. This invariant transitively implies
7.1 (the same offset_lo bits are checked in both A and C).

### 7.4 Trampoline preserves all callee state across a spurious call

- **Structure**: the 15 pushes and 15 pops are symmetric;
  the `add rsp, 16` matches the two pushed placeholder
  qwords; `iretq` pops exactly the 5 CPU-pushed frame
  qwords.
- **Consequence**: if the trampoline is invoked (from an IRQ
  or a synthesized call), no register state is corrupted on
  return. Timer / scheduler / other-CPU-state invariants
  hold across an IRQ 4 event.

Not exercised at R16.M4-004 (no real IRQ delivery). Property
is by-construction — verified structurally against
`_ipi_trampoline_f0` (a proven-correct template).

### 7.5 No stack imbalance from ISR body

- **`uart_rx_isr` signature**: `() -> ()`, calling convention
  SysV, entry with rsp%16 == 8, exit with rsp%16 == 8.
- **Trampoline's alignment ledger**:
  - CPU pushes 5 qwords → rsp%16 == 0.
  - We push 2 placeholder qwords → rsp%16 == 0 (still).
  - We push 15 GPR qwords → rsp%16 == 8 (17 * 8 = 136;
    136 % 16 = 8).
  - `call uart_rx_isr` pushes 8 → rsp%16 == 0 at ISR body
    entry (BUT SysV entry convention is rsp%16 == 8...
    wait — SysV specifies rsp%16 == 0 immediately **before**
    the call, i.e. rsp%16 == 8 at callee entry after the
    call pushes 8 bytes of return addr. So callee sees
    rsp%16 == 8 as expected. ✓)
  - ISR body's `sub rsp, 8` → rsp%16 == 0 for its nested
    calls; `add rsp, 8` at ISR exit undoes it.
  - `ret` from ISR pops 8 → we're back at rsp%16 == 8.
  - We pop 15 GPR qwords → rsp%16 == 8 (still, 15*8=120,
    120%16=8, previous was 8, delta 8 mod 16 = 8, but
    starting from 8 and popping 120 → 8-120 mod 16 = -112
    mod 16 = 0. Wait, this needs to be recomputed.

  Let me redo the ledger. Denote rsp%16 as `A` starting from
  the state after CPU pushes the 5-qword frame. CPU push
  brings rsp down by 40 bytes; 40 mod 16 = 8. Whatever `A`
  was pre-interrupt, post-CPU-push rsp%16 = (A - 8) mod 16 =
  (A + 8) mod 16.

  The pre-interrupt rsp%16 is 0 (interrupt fires between
  instructions on a well-aligned kernel stack). So
  post-CPU-push rsp%16 = 8. From there:

  - +2 placeholder pushes = 16 bytes: rsp%16 = 8 (16 mod 16 = 0).

  Actually 8 + 0 = 8. So rsp%16 = 8 after placeholders.
  - +15 GPR pushes = 120 bytes; 120 mod 16 = 8; rsp%16 =
    (8 - 8) mod 16 = 0.
  - `call uart_rx_isr` pushes 8; rsp%16 = 8 at ISR entry.
    ✓ Matches SysV convention. `uart_rx_isr`'s `sub rsp,
    8` makes it 0 for its nested calls (uart_rx_enqueue,
    apic_eoi). `add rsp, 8` restores 8. `ret` pops 8; back
    at trampoline with rsp%16 = 0.
  - 15 GPR pops = 120 bytes; rsp%16 = (0 + 8) mod 16 = 8.
  - `add rsp, 16` = 16 bytes; rsp%16 = 8 (16 mod 16 = 0).
  - `iretq` pops 40; rsp%16 = (8 + 8) mod 16 = 0.

  ✓ Kernel stack alignment restored.

Every push and pop cancels; every alignment adjustment cancels.
Verified by construction; witnessed indirectly at every real
IRQ 4 delivery (from #599 onward).

## 8. Cross-cutting risks

- **`_uart_rx_trampoline` symbol collision with a hypothetical
  future rename.** The chosen name matches the R14b-m5-006 IPI
  convention (`_ipi_trampoline_f0`). A future
  `trampoline_vecNN` renaming pass would need to rename this too.
  Low risk — the naming convention is stable per R14b.
- **`_idt_storage[36]` overwrite by a later boot step.** No boot
  step after `idt_install` writes into `_idt_storage`. Verified
  by `grep -n _idt_storage src/`. If a future issue adds a
  post-install IST-rewire for vec 36 (analogous to
  `idt_apply_ist_fields` for DF/NMI/MC/PF at idt.pdx:257-298),
  it would OR into byte 4 (IST field) without touching bytes
  0-3 or 5-15, so sub-tests A/B/C still pass. Documented.
- **Witness runs before any IRQ 4 is possible.** By construction
  (§4.2). If a future refactor reorders the R16.M4 witnesses
  after IOAPIC RTE programming (#599), a live IRQ 4 during
  witness execution would trigger the trampoline, which would
  drain COM1 (empty) and EOI. No observable state changes
  visible to sub-tests A/B/C (the IDT is read-only from the
  trampoline's perspective). Safe under a witness-execution
  IRQ, but the ordering constraint is documented in §4.2 for
  future maintainers.
- **paideia-as encoder regression on `shl imm 48`**. Sub-test
  B uses `shr rcx, 40` and sub-test C uses `shl rdi, 16`, `shl
  rdi, 32`. All three shift-amounts land in encoder-proven
  space (see `idt.pdx:462` for `shl r10, 48`). If a future
  paideia-as version breaks any of these encodings, the witness
  fails — but so does `idt_install` itself, so the smoke suite
  detects the regression before it ships. No R16.M4-004-specific
  encoder-risk added.
- **Race with a spurious interrupt during witness r13 load**. The
  witness reads `_idt_storage + 576` into r13, then computes.
  If (impossibly, at witness time — IF=0 in kernel_main window)
  an IRQ fired between the two reads, the trampoline would
  clobber r13 (a caller-save from the trampoline's perspective,
  but the trampoline pushes r13 in its 15-GPR save block, so
  it's restored on iretq). Even if the race were possible, r13
  survives. Documented as a belt-and-braces observation, not
  a bug.

## 9. LOC estimate

| File                                                        | LOC        |
|-------------------------------------------------------------|------------|
| `src/kernel/core/uart/rx_trampoline.pdx` (new)              | ~50        |
|   - module boilerplate + justification                      |   ~30      |
|   - `_uart_rx_trampoline` body (36 instructions)            |   ~18      |
|   - inline comments                                         |    ~2      |
| `src/kernel/core/int/idt.pdx` (extend idt_install)          | ~10        |
|   - hunk 1: cmp/je branch + comment                         |    ~4      |
|   - hunk 2: idt_setup_vec36 label + lea + jmp + comment     |    ~4      |
|   - justification block extension                           |    ~2      |
| `src/kernel/boot/kernel_main.pdx` (witness block)           | ~65        |
|   - 3 sub-tests + labels + comments                         |   ~50      |
|   - preceding/trailing comment banner                       |    ~5      |
|   - IDT layout doc-comment inside the witness               |   ~10      |
| `tools/boot_stub.S` (2 messages)                            | ~8         |
| 3 expected-output fingerprint files (1 marker each)         | ~3         |
| `design/kernel/r16-m4-004-idt-vec24-wire.md` (this doc)     | (this)     |
| **Total executable / testing / test-data**                  | **~136**   |

Executable code path: ~60 LOC (trampoline + idt wire). Witness
+ fingerprint: ~76 LOC. Larger than R16.M4-003 (~91 LOC) because
the witness has three sub-tests with field-reconstruction
arithmetic, but still well within a single workerbee session.

## 10. Tractability

**HIGH — comparable to R16.M4-003.**

- **Zero paideia-as encoder gap.** Every mnemonic proven in
  ipi/vectors.pdx (trampoline shape), idt.pdx (dispatch chain
  + pack arithmetic + shift/mask), and every witness in the
  tree (r12/r13 callee-save discipline, uart_puts call, cmp/jne
  branches). See §2.3.
- **Strictly additive to `idt.pdx`.** 10 lines of delta; no
  existing lines removed or reordered; no touch to the 10
  already-wired vectors' dispatch code.
- **New file follows an established convention.** `rx_trampoline.pdx`
  copies the ipi/vectors.pdx layout verbatim modulo the
  vector-specific parts.
- **Witness is inspection-only.** No state mutation; no IRQ
  fired; no LAPIC/IOAPIC touched. Read-modify-check chain over
  a static in-memory data structure.
- **Marker line is contains-in-order** — strictly additive.
- **No cross-repo escalation risk.** No new paideia-as mnemonic
  needed.
- **Sizing (~136 LOC total)** is comparable to R16.M4-003
  (~91 LOC), well within a single workerbee session.

Estimated implementation time: **~50 minutes of a workerbee
session** — slightly longer than R16.M4-003 because the witness
has three sub-tests with field-reconstruction arithmetic (vs.
R16.M4-003's single head-unchanged check), but no new
mnemonics.

Estimated risk of regressing an existing smoke mode:
**near-zero** — purely additive (one new module, one 10-line
idt.pdx extension, one new witness block, one new emit line,
two new rodata strings).

**Wire location decision**: **extend `idt_install`** with the
cmp/je + direct-lea branch — do NOT create a separate
`idt_install_uart_rx()` function. Rationale in §3.8:

- Separate function requires either a second `lidt` (broken)
  or a side-write into `_idt_storage` after `idt_install`
  runs (duplicates pack arithmetic — bisect-hostile).
- Extending `idt_install` matches the pattern for all 10
  already-wired vectors.
- Preserves the "one lidt per boot" invariant.

**Known follow-ups (do NOT block #598's landing)**:

- **#599 (ioapic route IRQ 4)** — programs the IOAPIC RTE so
  IRQ 4 → vector 0x24 on CPU 0. First moment the trampoline
  installed here fires from a real interrupt.
- **#600 (uart_rx_notification_cap)** — wires the ring to a
  KIND_NOTIFICATION cap so sys_read unblocks on ring-non-empty.
- **#601 (RX smoke)** — end-to-end AC verification via QEMU
  stdin injection.
- **`idt_wire_vec(vec, addr)` helper** — future refactor to
  collapse the cmp/je chain; see §6.3.
- **Ring-3-CS-check + swapgs across all R16.M4-era trampolines**
  — see §6.5.

## 11. References

- Issue: paideia-os#598
- Milestone: paideia-os R16.M4 (UART input driver — 16550 RX
  interrupt-driven)
- Prereq issues: #252 (idt_install), #644 (R10-m1-002 exception
  trampolines direct-lea pattern), #511 (R14b-m5-006 IPI
  trampoline template), #595 (uart_rx_init), #596 (uart_rx_ring),
  #597 (uart_rx_isr)
- Blocks: #599, #600, #601
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 14, item 4
- Master plan: `design/milestones/r14b-master-plan.md` §M20
  (UART input)
- Prior-art trampoline template: `src/kernel/core/ipi/vectors.pdx:17`
  (`_ipi_trampoline_f0`) — verbatim modulo vector number and
  called ISR
- Prior-art IDT wire extension: `src/kernel/core/int/idt.pdx:389-390,
  434-436` (vec 33 cmp/je branch + idt_setup_vec33 label + direct-lea)
- Prior-art IDT-entry inspection witness (structural): `src/kernel/
  boot/kernel_main.pdx:4259-4283` (R14b-m5-007 IPI structural
  witness) — same pattern (lea + cmp + branch on non-zero).
  This issue extends the pattern with field-reconstruction.
- Prior-art witness r12/r13 discipline: uart_rx_isr_witness
  (kernel_main.pdx:3832-3857), uart_rx_ring_witness
  (kernel_main.pdx:3733-3826)
- Intel SDM Vol 3A §6.14.1 (64-bit interrupt gate layout),
  §10.4.7.1 (LAPIC software enable), §10.8.5 (EOI)
- IDT storage: `src/kernel/core/int/idt.pdx:302` (`_idt_storage :
  [u64; 512]` — 4096 bytes, 256 x 16-byte entries)
- Pack arithmetic: `src/kernel/core/int/idt.pdx:438-472`
  (`idt_pack_entry` label — the packing logic sub-test C
  reverses to prove correctness)
