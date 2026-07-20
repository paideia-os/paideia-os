---
issue: 597
milestone: R16.M4 (UART input driver — 16550 RX interrupt-driven)
subsystem: 14 — UART input driver (16550 RX interrupt-driven)
topic: uart_rx_isr — drain LSR/RBR into ring; call apic_eoi; ret (ISR body, not the IDT trampoline)
prereq:
  - "P1-006/007 (LANDED; boot/uart.pdx freezes the `mov dx, imm16; in_al al` / `out_al al` byte-port idioms and leaves COM1 in DLAB=0 so port 0x3F8 aliases RBR when read and 0x3FD aliases LSR)"
  - "R9-m2-003 / #358 (LANDED; core/apic/eoi.pdx.apic_eoi — 4-instruction MMIO write of 0 to 0xFEE000B0. This issue's sole external non-ring call.)"
  - "R16-M4-002 / #596 (LANDED; core/uart/rx_ring.pdx.uart_rx_enqueue — sole downstream consumer of every RBR byte read here.)"
  - "R16-M4-001 / #595 (LANDED; establishes core/uart/ directory. This issue extends it with rx_isr.pdx.)"
  - "R16-M1-003 / #572 (LANDED; core/fs/vops.pdx freezes the `sub rsp, 8` / `call reg-or-sym` / `add rsp, 8` alignment idiom used verbatim here for the two nested calls (uart_rx_enqueue, apic_eoi).)"
blocks:
  - "#598 (r16-m4-004 idt-vector-24 wire — installs a trampoline at IDT slot 0x24 that saves 15 GPRs, calls uart_rx_isr, restores, iretq. This issue's function is the target of that trampoline.)"
  - "#599 (r16-m4-005 ioapic-route-irq4 — routes IRQ 4 → vector 0x24 on CPU 0; first moment at which the trampoline installed by #598 actually fires against this ISR body.)"
  - "#600 (r16-m4-006 uart_rx_notification_cap — wires the ISR to a KIND_NOTIFICATION cap unblocking sys_read; hangs off the same producer path.)"
  - "#601 (r16-m4-007 RX smoke — end-to-end AC (\"typing a character in qemu monitor stdin lands in ring\"); only observable once #598 and #599 land.)"
touching:
  - src/kernel/core/uart/rx_isr.pdx                     (new module — ~55 LOC incl. justification)
  - src/kernel/boot/kernel_main.pdx                     (witness block — ~25 LOC after last-landed R16.M4 witness)
  - tools/boot_stub.S                                   (2 rodata additions: ok_msg, fail_msg)
  - tests/r14b/expected-boot-r14b-loader.txt            (marker: `R16 UART RX ISR OK`)
  - tests/r15/expected-boot-r15-ring3.txt               (marker)
  - tests/r15/expected-boot-r15-process.txt             (marker)
  - design/kernel/r16-m4-003-uart-rx-isr.md             (this doc)
related:
  - src/kernel/core/uart/rx_init.pdx                    (R16-M4-001 / #595 — sibling in core/uart/; sets IER=0x01
                                                          so the ISR will *eventually* have a delivery path once
                                                          #598/#599 land. No data-flow between rx_init and rx_isr
                                                          at R16.M4-003 — this issue's witness runs while IRQ 4
                                                          delivery is still blocked at the IOAPIC.)
  - src/kernel/core/uart/rx_ring.pdx                    (R16-M4-002 / #596 — sole downstream. uart_rx_enqueue is
                                                          called once per RBR read. Contract read: `rdi = byte`,
                                                          `rax = 0 or 1`; on rax=1 the byte is dropped per §3.5.)
  - src/kernel/core/apic/eoi.pdx                        (R9-m2-003 / #358 — apic_eoi. Sole external non-ring
                                                          call. Writes 0 to MMIO 0xFEE000B0. This issue does NOT
                                                          re-encode the EOI write inline — it uses the existing
                                                          primitive, matching handle_timer (exceptions.pdx:162)
                                                          and every IPI trampoline (ipi/vectors.pdx:27,49).)
  - src/kernel/core/int/exceptions.pdx                  (R10/R11 — handle_timer ISR body at line 138; closest
                                                          prior-art shape. Same discipline: ISR body (not
                                                          trampoline) that calls nested subroutines and
                                                          apic_eoi before returning. Structural template.)
  - src/kernel/core/fs/vops.pdx                         (R16-M1-003 / #572 — freezes the `sub rsp, 8` / nested
                                                          call / `add rsp, 8` alignment idiom for post-outer-call
                                                          ISR-body-shaped functions that make nested SysV calls.)
  - src/kernel/boot/uart.pdx                            (P1-006/007 — uart_putc at line 55 freezes the polling-
                                                          read pattern `mov dx, 0x3FD; in_al al; and rax, 0x20`
                                                          which this issue's LSR-poll loop copies verbatim modulo
                                                          the mask value (0x01 for DR instead of 0x20 for THRE).)
  - design/milestones/r14b-tactical-plan.md             §Subsystem 14, item 3 (this issue's plan pointer)
  - design/kernel/r16-m4-001-uart-rx-init.md            (structural template for this doc)
  - design/kernel/r16-m4-002-uart-rx-ring.md            (structural template; §3.9 producer/consumer discipline
                                                          — this issue *is* the producer named there.)
---

# R16-M4-003 — `uart_rx_isr`: drain 16550 RBR into ring, then EOI (#597)

## 1. Scope

Land the third R16.M4 subsystem-14 issue: the interrupt-service
routine **body** that drains all bytes currently available at
COM1's Receive Buffer Register (RBR) into the software ring
buffer landed at #596, then acknowledges the LAPIC via the
existing `apic_eoi` primitive (#358) so the next IRQ 4 can
deliver.

```
uart_rx_isr() -> ()
    input:  (none)
    output: (none)
    side effect: drains up to 256 bytes from COM1 RBR (each into
                 _uart_rx_ring via uart_rx_enqueue); on ring full,
                 the byte is *read from the hardware FIFO* (required
                 for LSR.DR to clear) but *dropped* from the software
                 ring per §3.7 overrun policy. Then writes 0 to
                 LAPIC EOI (MMIO 0xFEE000B0) via apic_eoi.
```

Acceptance (issue AC): **typing a character in qemu monitor stdin
lands in ring.** That AC is *not directly observable* at this
issue's landing — IDT vector 0x24 is not installed (#598), the
IOAPIC does not yet route IRQ 4 (#599), and the smoke harness has
no stdin injection. The end-to-end proof is deferred to #601
(R16-m4-007 RX smoke). This issue's witness is a **degenerate
manual-invocation test** proving the ISR body is structurally
sound: called with LSR.DR = 0 (no bytes at COM1), it returns
without enqueueing anything, without underflowing the ring, and
without faulting on the LAPIC EOI write.

### 1.1 What this issue proves

- **A 16550 FIFO drain loop is expressible in the current
  paideia-as encoder surface** using only proven mnemonics
  (`mov dx, imm16`, `in_al al`, `and rax, imm8`, `cmp rax, imm8`,
  branches, `call sym`, `sub rsp, 8`, `add rsp, 8`, `ret`). Zero
  encoder gap — see §2.3.
- **The RX driver's producer half composes end-to-end.** With
  #595 (IER=0x01) + #596 (ring) + this issue, every layer of the
  RX pipeline exists *except* the interrupt-vector wiring
  (#598/#599). Any subsequent regression in one of the three
  landed pieces (IER setup, ring correctness, ISR shape) bisects
  to one of three ~50-LOC modules.
- **The ISR body's SysV alignment discipline is correct.** The
  witness calls uart_rx_isr from a properly-aligned kernel_main
  context; uart_rx_isr in turn calls two nested SysV functions
  (uart_rx_enqueue and apic_eoi). The `sub rsp, 8` / `add rsp, 8`
  pair around the drain loop keeps rsp%16 == 8 at both nested
  callees' entry — matches the vops.pdx idiom frozen at
  R16-M1-003 (#572).
- **The empty-drain path is faultless.** LSR.DR is 0 at witness
  time (no user has typed anything on QEMU stdin; the smoke
  harness feeds nothing to serial). The loop exits on the first
  iteration; apic_eoi writes 0 to LAPIC MMIO 0xFEE000B0; ret. The
  witness verifies `_uart_rx_head` is unchanged after the call,
  proving no spurious enqueue occurred.

### 1.2 What this issue deliberately does NOT do

- **No IDT vector 0x24 install.** #598 is the trampoline that
  saves 15 GPRs, calls this function, restores, and iretqs. At
  this issue's landing, the IDT slot for 0x24 remains at
  `typed_handler_default` (per idt.pdx); no IRQ 4 delivery is
  possible. Safe by construction — no interrupt can fire this ISR
  spuriously.
- **No IOAPIC routing.** #599 programs the IOAPIC RTE so IRQ 4
  reaches vector 0x24. Without that routing, even if a UART byte
  arrives (IER=0x01 is set by #595) and the 16550 raises IRQ 4,
  the IOAPIC drops the signal.
- **No cli/sti in the body.** IDT-delivered interrupts on x86
  enter with IF cleared by the CPU (per IDT gate type = interrupt
  gate). The trampoline (#598) preserves that state until iretq
  restores caller RFLAGS. This ISR body therefore *runs with
  interrupts disabled* implicitly; no explicit `cli` needed. This
  matches every other ISR body in the tree (handle_timer,
  _typed_handler_*, _ipi_handler_*). Adding `cli` would be
  redundant and hostile to nested-interrupt semantics R17 SMP
  will need.
- **No overrun accounting.** #596 §6.5 explicitly deferred
  `_uart_rx_dropped_count` to this issue. On mature reflection
  the counter belongs at the point where a byte is *proven*
  dropped — that is here (the ISR reads RBR unconditionally, then
  calls enqueue and discards a `rax==1` return). But R16.M4-003's
  AC is *not* "count drops"; it is "typing a char lands in the
  ring". Adding the counter here would introduce a new .bss
  symbol, an atomic-add contract question for R17 SMP, and a
  witness sub-test to check the counter — all outside AC. The
  counter is re-deferred to **#600** (rx_notify) or, more
  cleanly, to a future R16.M4 tail issue. Documented in §6.4.
- **No LSR error-flag handling.** LSR bits 1..4 signal Overrun,
  Parity, Framing, and Break Interrupt. Reading LSR *does* clear
  bits 1..4 as a side effect (per NS PC16550D §3.1.4), so a
  passing LSR-read in the drain loop naturally clears any stale
  error state. The current design intentionally ignores the
  error bits — even a byte with a parity error is passed to
  enqueue as-is. Explicit error accounting is left to a future
  R17 hardening pass; documented in §6.5.
- **No FIFO trigger reconfiguration.** `uart_init`
  (boot/uart.pdx:46) programs FCR=0xC7 (14-byte trigger, FIFO
  enabled). The drain loop will typically run once per interrupt
  and consume 14–16 bytes. Any FIFO-tuning belongs at a future
  performance issue; not at R16.M4-003.
- **No wake-up of a blocked sys_read.** That is the sole
  responsibility of #600 (uart_rx_notification_cap). This issue
  produces bytes into the ring; the wake-up cap invocation is
  the layer above.
- **No 32-bit port I/O.** All 16550 registers used here (LSR at
  0x3FD, RBR at 0x3F8) are 8-bit. `in_al al` is the correct
  width per NS PC16550D.
- **No inline EOI encoding.** This ISR *calls* `apic_eoi` rather
  than inlining `mov rax, 0xFEE000B0; xor rcx, rcx; mov [rax], ecx`.
  Rationale in §3.6: a single source of truth for LAPIC EOI is
  worth one extra `call/ret` per interrupt. Same discipline as
  `handle_timer` (exceptions.pdx:162) and every IPI trampoline.

## 2. Prereq check

### 2.1 What is in place

| Primitive                | Location                                    | Contract used                                                                          |
|--------------------------|---------------------------------------------|----------------------------------------------------------------------------------------|
| `core/uart/` directory   | `src/kernel/core/uart/rx_init.pdx`          | R16-M4-001 established the directory. This issue adds `rx_isr.pdx` as a sibling.       |
| `uart_rx_enqueue`        | `core/uart/rx_ring.pdx:43` (R16-M4-002)     | `rdi = byte; -> rax = 0 (OK) | 1 (FULL)`. Ignored `rax` on caller side = drop-on-full. |
| `apic_eoi`               | `core/apic/eoi.pdx:30` (R9-m2-003, #358)    | `() -> ()`; writes 0 to MMIO 0xFEE000B0.  Sig: `!{sysreg, mem} @{boot}`.               |
| `_uart_rx_head` (u64)    | `core/uart/rx_ring.pdx:25`                  | Read-only from the witness perspective. Producer cursor advanced by uart_rx_enqueue.   |
| `in_al al` idiom         | `boot/uart.pdx:63` (B3-002)                 | `mov dx, imm16` + `in_al al` reads port DX into AL, upper RAX bits untouched.          |
| `and rax, imm8`          | `boot/uart.pdx:64` (`and rax, 0x20`)        | Isolates a specific LSR bit; here the mask is `0x01` (DR) instead of `0x20` (THRE).    |
| `sub rsp, 8` / `add rsp, 8` | `core/fs/vops.pdx:78..242` (R16-M1-003)  | Alignment idiom for post-outer-call function bodies making nested SysV calls.          |
| Direct `call sym` / `ret`| Ubiquitous.                                 | Non-leaf function calling nested SysV subroutines.                                     |
| `handle_timer` shape     | `core/int/exceptions.pdx:138-165`           | Reference ISR body: nested `call ...` then `call apic_eoi; ret`. Copied structurally.  |
| LAPIC MMIO accessibility | `core/apic/lapic_timer.pdx:53,73,88,93`     | Multiple LAPIC MMIO writes at 0xFEE00xxx succeed in the kernel path; region is mapped. |

### 2.2 What is NOT in place

- **`uart_rx_isr` symbol.** Introduced by this module.
- **`uart_rx_isr_ok_msg` / `uart_rx_isr_fail_msg` symbols in
  `boot_stub.S`.** Added alongside the last-landed R16.M4 witness
  strings (see §5.4).
- **A trampoline at IDT slot 0x24.** #598's concern; explicitly
  *not* wired at this landing (see §1.2).
- **An IOAPIC RTE for IRQ 4.** #599's concern.
- **`_uart_rx_dropped_count` counter.** Deferred; see §6.4.

### 2.3 Encoder gaps

**None.** Every mnemonic used has landed precedent.

| Mnemonic form                        | Proven at                                                         |
|--------------------------------------|-------------------------------------------------------------------|
| `sub rsp, 8`                         | `core/fs/vops.pdx:78,105,132,159,187,215,242` (R16-M1-003).       |
| `add rsp, 8`                         | Same file (`add rsp, 8` paired with each `sub rsp, 8`).           |
| `mov dx, imm16`                      | `boot/uart.pdx:41-47` (7 sites) — port-address load.              |
| `in_al al`                           | `boot/uart.pdx:63`.                                               |
| `and rax, imm8`                      | `boot/uart.pdx:64`; `core/uart/rx_ring.pdx:60`.                   |
| `cmp rax, imm8`                      | Ubiquitous.                                                       |
| `je` / `jne` / `jmp`                 | Ubiquitous.                                                       |
| `mov rax, [rip + _sym]`              | `core/sched/wake_block.pdx:41`; `core/uart/rx_ring.pdx:49`.        |
| `mov rdi, rax`                       | `boot/uart.pdx:66`; ubiquitous SysV-arg staging.                  |
| `call sym` (direct)                  | Ubiquitous (see exceptions.pdx:161-162 for a two-call sequence).  |
| `ret`                                | Ubiquitous.                                                       |

No SIB. No REX.B on extended registers. No 32-bit port I/O. No
MMIO write from within *this* module (the MMIO write lives inside
apic_eoi, already landed). **Cross-repo escalation not needed.**

## 3. Design

### 3.1 File and module structure

New file: `src/kernel/core/uart/rx_isr.pdx`. Sits alongside the
siblings landed at R16-M4-001 and R16-M4-002:

```
src/kernel/core/uart/
    rx_init.pdx     (#595, LANDED — IER=0x01)
    rx_ring.pdx     (#596, LANDED — 256-slot SPSC ring + enqueue/dequeue)
    rx_isr.pdx      <-- THIS ISSUE (#597 — drain + EOI)
    rx_notify.pdx   (#600, planned — notification cap wake-up)
```

Module name: `RxIsr`. Public export: `uart_rx_isr`. No new
storage symbols — this issue is pure code that reads
`_uart_rx_head` (indirectly via enqueue) and writes to nothing of
its own.

### 3.2 Register discipline and stack alignment

`uart_rx_isr` is **non-leaf**. It makes up to N + 1 nested calls
per invocation, where N is the count of bytes drained in the
loop:

- Zero or more `call uart_rx_enqueue` (one per RBR byte read)
- Exactly one `call apic_eoi` after the drain

The function takes no arguments and returns no value. No callee-
save register is written; all loop state (LSR read, RBR read,
enqueue argument) lives in caller-save scratch (`rax`, `rdx`,
`rdi`).

**Alignment.** Under SysV AMD64, a function's entry sees
`rsp%16 == 8` (return address just pushed on a previously-16-aligned
stack). Before any nested `call` the callee must adjust so the
next callee sees `rsp%16 == 8` again — i.e. the caller must have
`rsp%16 == 0` immediately *before* the `call`. The standard fix
(also used verbatim by every dispatcher in `core/fs/vops.pdx`
per R16-M1-003) is:

```
    sub rsp, 8         ; rsp%16: 8 -> 0
    ...loop with nested calls; every call sees rsp%16==0, callee entry rsp%16==8...
    add rsp, 8         ; rsp%16: 0 -> 8 (restore SysV entry state)
    ret                ; pops return addr; caller sees rsp%16==0 again
```

**Why not follow `handle_timer`'s no-align pattern.**
`handle_timer` (exceptions.pdx:138) skips the `sub rsp, 8` and
works only because `apic_eoi` and `lapic_timer_rearm` avoid SSE
and don't rely on 16-alignment. It has been latent-buggy since
R10-m2-003. `vops.pdx` (R16-M1-003) is the newer, correct
discipline — a verify-pass explicitly corrected the alignment
inversion. This issue adopts the newer discipline.

**Clobbers (SysV caller-save).** After `uart_rx_isr` returns:
`rax`, `rcx`, `rdx`, `rdi`, `rsi`, `r8`, `r9`, `r10`, `r11` are
all considered volatile (per SysV). The trampoline (#598) pushes
all 15 GPRs regardless — no clobber list needs to be tightened
here.

### 3.3 Drain loop shape

```
    ; --- LSR poll for Data Ready ---
    mov dx, 0x3FD                 ; LSR = COM1 base (0x3F8) + 5
    in_al al                      ; rax bits 0..7 = LSR value
    and rax, 0x01                 ; isolate DR (bit 0)
    cmp rax, 0                    ; if DR == 0, drain complete
    je  urxi_drain_done

    ; --- Consume one byte from RBR and enqueue it ---
    mov dx, 0x3F8                 ; RBR = COM1 base
    in_al al                      ; rax bits 0..7 = byte; upper 56 stale
    and rax, 0xFF                 ; explicit zero-extend from AL to RAX
    mov rdi, rax                  ; SysV arg 0 = byte
    call uart_rx_enqueue          ; rax = 0 (OK) or 1 (FULL); dropped

    jmp urxi_drain_loop
```

**Why explicit `and rax, 0xFF` after `in_al al`.** `in_al al`
writes AL (low 8 bits of RAX) but leaves bits 8..63 untouched.
In this ISR the upper bits may hold stale values from the LSR
read one iteration earlier (which we masked to 0x01 for the
`cmp`), but that stale bit does not propagate — the mask cleared
everything above bit 0, so upper bits were 0 before the RBR
read. The `and rax, 0xFF` is therefore *strictly redundant* on
this specific control-flow, but it costs one instruction, is a
free correctness safety net, and makes the drain loop's byte-load
identical to the enqueue witness's byte-load — a small win for
readability under bisect.

Documented in the justification as a defensive redundancy so no
future refactor of the LSR check accidentally removes it.

**Loop terminates.** The 16550's FIFO holds at most 16 bytes. In
the absence of a producer refilling the FIFO faster than the CPU
drains it, the loop iterates at most 16 times and then LSR.DR
reads 0. Even under an *adversarial* producer (byte arrives just
as we read LSR), the CPU is faster than a 115200-baud UART by a
factor of ~10^5 per byte, so the loop cannot livelock. Formal
worst-case is bounded by the ring capacity — 256 bytes — beyond
which every enqueue returns FULL and the byte is dropped but LSR
still clears, so the loop still terminates.

### 3.4 EOI epilogue

```
  urxi_drain_done:
    call apic_eoi                 ; write 0 to LAPIC EOI (MMIO 0xFEE000B0)
    add rsp, 8                    ; restore SysV entry alignment
    ret
```

**Why call, not inline.** Three concurrent reasons:

1. **Single source of truth.** `apic_eoi` is the LAPIC EOI
   contract. `handle_timer` calls it. Every IPI trampoline calls
   it. If Intel ever revises §10.8.5 (unlikely but non-zero) or
   we discover a hardware quirk requiring a memory barrier before
   the write, we change one function, not N.
2. **Cost is one indirect `call/ret` per interrupt** — ~5–10
   cycles, vs a per-byte cost that runs 14× more often. Free.
3. **Effect / capability set composes automatically.** `apic_eoi`
   is declared `!{sysreg, mem} @{boot}`. Calling it means
   `uart_rx_isr` inherits both. Inlining would still require the
   `{sysreg, mem}` effect on the MMIO store and would need
   `@{boot}` on the callsite justification anyway.

### 3.5 Alternatives considered — drain loop shape

| Variant                                       | Rejected because                                                                                             |
|-----------------------------------------------|--------------------------------------------------------------------------------------------------------------|
| **Two-pointer drain (chosen)**                | —                                                                                                            |
| Fixed count (loop 16 times, assume trigger)   | 16550 FIFO trigger is 14 bytes (FCR=0xC7 sets trigger = 14). Loop of 16 would read past trigger threshold and could read stale bytes if fewer than 16 arrived. LSR.DR check *is* the correct terminator per NS PC16550D §3.1.4.                          |
| Batch drain (read N bytes into local buffer, then bulk-enqueue) | Would need `.bss` or stack scratch, and enqueue is already a 20-instruction leaf. Batching buys nothing.        |
| Poll LSR *before* AND *after* RBR read        | The 16550's DR bit clears when the FIFO empties on read — a subsequent poll would give the same answer as the top-of-loop poll. Redundant read is dead code. |
| Drain only if LSR.DR was set at ISR entry (no loop) | Loses bytes: FCR=0xC7 sets the FIFO trigger at 14 bytes but the interrupt fires once for a *batch*, not per byte. A single-byte-per-IRQ handler would fall behind at any sustained rate ≥ (IRQ latency)⁻¹. Wrong. |

### 3.6 Alternatives considered — EOI placement

| Variant                                       | Rejected because                                                                                             |
|-----------------------------------------------|--------------------------------------------------------------------------------------------------------------|
| **Call `apic_eoi` from body (chosen)**        | Matches `handle_timer` (exceptions.pdx:162) — the only prior ISR-body precedent that includes EOI in the body. |
| Inline `mov rax, 0xFEE000B0; xor rcx, rcx; mov [rax], ecx` in body | Duplicates the LAPIC EOI contract in a 2nd site (apic_eoi is the 1st). Zero performance win.               |
| Emit EOI from the trampoline (#598) instead of body | The IPI trampolines do this (ipi/vectors.pdx:27,49). Would work, but splits the RX driver's concern across the trampoline PR and this PR — bisect-hostile.                        |
| No EOI, rely on iretq                         | **Broken.** Per Intel SDM §10.8.5, iretq does *not* signal EOI to the LAPIC. Without an EOI the LAPIC's in-service bit for vector 0x24 stays set, blocking future IRQ 4 delivery. |

### 3.7 Overrun policy — read-then-drop

When `uart_rx_enqueue` returns 1 (ring full), the RBR byte has
*already been read* (that read is what makes `LSR.DR` clear).
Dropping the byte from the software ring is the only remaining
option — putting it back into the hardware FIFO is impossible.

Two policies were considered:

- **Chosen: silent drop.** Ignore `rax` after `call
  uart_rx_enqueue`. Simplest; matches how `handle_timer` ignores
  the sched_tick return in the tick-count path. The consumer
  (sys_read via #600) will observe a bounded delay (up to
  ring-capacity worth of subsequent bytes buffered before the
  next drop) but no functional error.
- **Rejected: bump a `_uart_rx_dropped_count : u64`.** Deferred
  to #600 or a later hardening issue per §6.4. Costs a new .bss
  symbol and an atomic-inc semantics question the tactical plan
  hasn't answered yet.
- **Rejected: BREAK on drop.** Would panic on any legitimate
  fast-typist input burst — hostile.

### 3.8 File contents

```pdx
// src/kernel/core/uart/rx_isr.pdx — R16-M4-003 (#597)
// uart_rx_isr: drain COM1 16550 RBR into the software RX ring; EOI.
//
// One leaf-shaped body (non-leaf: calls uart_rx_enqueue per byte
// and apic_eoi once at the end). Invoked from the vector-0x24
// trampoline installed by #598 (deferred); IRQ 4 delivery to that
// trampoline is enabled by the IOAPIC routing landed at #599 (also
// deferred). At R16.M4-003, the sole caller is the manual
// invocation from the kernel_main witness, which runs with
// LSR.DR = 0 (no bytes at COM1), so the drain loop terminates on
// the first iteration and the ISR reduces to `apic_eoi; ret`.
//
// Contract:
//   Input:  (none)
//   Output: (none)
//   Effects: {sysreg, mem}    Capabilities: {boot}
//     - sysreg: two 8-bit port reads (LSR 0x3FD, RBR 0x3F8) per
//       drained byte, plus the MMIO write inside apic_eoi
//       (0xFEE000B0 = 0).
//     - mem:    each drained byte writes one slot in _uart_rx_ring
//       and bumps _uart_rx_head (transitive via uart_rx_enqueue).
//     - boot:   inherited from apic_eoi's capability declaration.
//
// Overrun policy: on uart_rx_enqueue returning FULL (1), the byte
// has already been consumed from the hardware FIFO and is dropped
// from the software ring. No counter is bumped at R16.M4-003 (see
// design §6.4).
//
// See design/kernel/r16-m4-003-uart-rx-isr.md for full contract.

module RxIsr = structure {
  // ==========================================================================
  // uart_rx_isr — drain 16550 RBR into ring; signal EOI
  //
  // Input:  (none)
  // Output: (none)
  //
  // Side effects:
  //   For each byte with LSR.DR set: reads RBR (clearing DR for
  //     that FIFO slot); calls uart_rx_enqueue; on ring-full,
  //     drops the byte silently. Then calls apic_eoi to write 0
  //     to LAPIC EOI MMIO 0xFEE000B0.
  //
  // Clobbers (SysV caller-save):
  //   rax, rcx, rdx, rdi, r8, r9, r10 (own use + transitive via
  //   uart_rx_enqueue and apic_eoi).
  // ==========================================================================
  pub let uart_rx_isr : () -> () !{sysreg, mem} @{boot} = fn () -> unsafe {
    effects: { sysreg, mem },
    capabilities: { boot },
    justification: "R16-M4-003 (#597): 16550 RX-side ISR body. Called from the vector-0x24 trampoline installed by #598 (deferred) once the IOAPIC RTE for IRQ 4 lands at #599 (also deferred). At this issue's landing, IRQ 4 delivery is impossible (IDT slot 0x24 is default, IOAPIC not routed, 8259 masked by pic_mask_all); the sole caller is the kernel_main witness that manually invokes the ISR with LSR.DR = 0 to prove the empty-drain path is faultless. Drain loop: `mov dx, 0x3FD; in_al al; and rax, 0x01; cmp rax, 0; je done` — LSR (COM1 base + 5) bit 0 = Data Ready per NS PC16550D §3.1.4; loop terminates when the 16550 FIFO empties. On DR set, `mov dx, 0x3F8; in_al al; and rax, 0xFF; mov rdi, rax; call uart_rx_enqueue` — RBR read is the sole write that clears LSR.DR for one FIFO slot per NS PC16550D §3.1.1; ignoring uart_rx_enqueue's rax (drop-on-full policy — see design §3.7). Alignment: `sub rsp, 8` at entry restores rsp%16==0 so nested SysV calls (uart_rx_enqueue and apic_eoi) enter with rsp%16==8 as ABI requires; `add rsp, 8` at exit restores caller's expected rsp%16==8 view after the trampoline's `call uart_rx_isr` pushes the return address. Matches the vops.pdx dispatcher alignment idiom frozen at R16-M1-003 (#572 verify-pass correction). EOI: single `call apic_eoi` — reuses core/apic/eoi.pdx.apic_eoi (R9-m2-003 #358) rather than inlining the 3-instruction MMIO write to 0xFEE000B0, so the LAPIC EOI contract stays single-sourced across handle_timer, every IPI trampoline, and this driver. Runs with IF=0 by construction: IDT gate type = interrupt gate (per idt.pdx) clears IF on entry; trampoline preserves that state until iretq. No cli/sti here. Encoder: zero paideia-as gaps; every mnemonic proven — see design §2.3. Audit: r16-m4-003-uart-rx-isr.",
    block: {
      // Align stack for nested SysV calls (uart_rx_enqueue, apic_eoi).
      sub rsp, 8;

    urxi_drain_loop:
      // --- LSR poll (COM1 base + 5 = 0x3FD), test DR (bit 0) ---
      mov dx, 0x3FD;
      in_al al;
      and rax, 0x01;
      cmp rax, 0;
      je  urxi_drain_done;

      // --- RBR read (COM1 base = 0x3F8) — consumes one FIFO slot ---
      mov dx, 0x3F8;
      in_al al;
      and rax, 0xFF;                // defensive zero-extend (see design §3.3)
      mov rdi, rax;                 // SysV arg 0 = byte
      call uart_rx_enqueue;         // rax = 0 (OK) or 1 (FULL); dropped

      jmp urxi_drain_loop;

    urxi_drain_done:
      // --- EOI: write 0 to LAPIC EOI (MMIO 0xFEE000B0) ---
      call apic_eoi;

      // Restore SysV entry alignment for the caller (trampoline / witness).
      add rsp, 8;
      ret
    }
  }
}
```

**Instruction count**: `sub rsp, 8` + loop head (5) + loop body
(5) + `jmp` + `call apic_eoi` + `add rsp, 8` + `ret` = **15
instructions**.

## 4. Witness placement

### 4.1 Position in kernel_main.pdx

Inserted after the last-landed R16.M4 witness `_done` label
(`uart_rx_ring_witness_done:` at `kernel_main.pdx:3826`). The
insertion point is therefore:

```
      uart_rx_ring_witness_done:
          pop  r12;

      <-- INSERT R16.M4-003 WITNESS HERE

      // R14b-m5-002 (#507): IA32_GS_BASE = &_cpu_locals[0] on CPU0.
      lea rax, [rip + _cpu_locals];
      ...
```

The insertion is structurally independent — no data flow into or
out of any preceding witness. The wrmsr / process_init block
that follows is likewise unaffected: `uart_rx_isr` writes nothing
to `_current_tcb`, `_preempt_needed`, `_cpu_locals`, or any
scheduler-visible state.

### 4.2 LAPIC state at witness time — safety

At witness time, `apic_svr_enable` has *not* yet run (it is
called at `kernel_main.pdx:3839`, after our insertion point). The
LAPIC is therefore **not software-enabled**. Writing 0 to MMIO
0xFEE000B0 in this state is safe:

- The LAPIC MMIO region is identity-mapped from boot (kind_dev
  probes 0xFEE00000, lapic_timer writes to 0xFEE000F0/320/380/3E0).
- Per Intel SDM Vol 3A §10.4.7.1, LAPIC MMIO writes with the LAPIC
  software-disabled complete without fault; the write is dropped
  or absorbed silently.
- No interrupt is in-service (the witness is running in kernel
  code, not from an IRQ), so an EOI write has no active in-service
  bit to clear — a no-op on both real hardware and QEMU.

QEMU-specific: QEMU's `-cpu max` emulates the xAPIC/x2APIC MMIO
region correctly regardless of software-enable state. Verified
transitively — if the write faulted, the witness would page-fault
into `_typed_handler_14` and never reach the OK marker.

**Alternative considered: move the witness *after* the
apic_enable/apic_svr_enable calls at kernel_main:3838-3839.**
Rejected — that block also calls `pic_mask_all` (already done
functionally at earlier boot per idt.pdx) and then goes directly
into `runq_init` and the idle-task witness. Inserting between
apic_svr_enable and pic_mask_all is structurally noisy; the
current position (immediately after the R16.M4-002 witness) keeps
all four R16.M4 witnesses contiguous, which mirrors how the R16.M3
FD witnesses cluster.

### 4.3 No witness slab needed

Unlike R16.M3 syscall witnesses (`_sys_read_witness_task`, etc.),
`uart_rx_isr` needs no per-witness state. The `_uart_rx_head`
symbol landed at R16.M4-002 is the sole observable this witness
inspects.

## 5. Test canary — kernel_main witness block

### 5.1 Sub-test structure

**One sub-test.** The function's contract for the empty-drain path
is a single postcondition: "after `uart_rx_isr()` returns, if LSR
was 0 at entry, `_uart_rx_head` is unchanged."

That single check exercises:

- **Structural**: the function exists at a valid entry point and
  returns without faulting.
- **LSR read**: the top-of-loop LSR poll executes (any encoding
  bug in `mov dx, 0x3FD; in_al al; and rax, 0x01; cmp; je` would
  cause the witness to hang, take a #GP, or misread and enter the
  RBR-drain branch spuriously).
- **Loop-exit**: the `je urxi_drain_done` branch is taken when
  DR=0; equivalently, the enqueue path is *not* taken.
- **EOI write**: the `call apic_eoi` completes without faulting.
  If MMIO 0xFEE000B0 were unmapped or the alignment `sub rsp, 8`
  were miscoded, apic_eoi would fault or misbehave and the OK
  marker would never emit.
- **Alignment**: the `sub rsp, 8` / `add rsp, 8` pair balances —
  a mismatch would corrupt the caller's stack and either
  scramble `_uart_rx_head` read-back (unlikely — head is via
  `[rip + sym]`, not stack) or crash the subsequent uart_puts
  call.

Multi-part sub-tests would add no coverage: there is no fixture
byte to inject at QEMU stdin from within the witness, and the
positive-drain path is the AC end-to-end proof deferred to #601.

### 5.2 Witness assembly (complete block)

```asm
; ============================================================
; R16-M4-003 (#597): uart_rx_isr witness — 1 sub-test
; ============================================================
uart_rx_isr_witness:
    push r12                                 ; callee-save head snapshot

    ; Sub-test A: with no bytes at COM1 (LSR.DR=0), calling
    ; uart_rx_isr must not enqueue any bytes into the ring.
    ; Snapshot _uart_rx_head; call ISR; verify head unchanged.
    mov  rax, [rip + _uart_rx_head]
    mov  r12, rax                            ; head_before survives the call

    call uart_rx_isr                         ; drains what's available (nothing) + EOI

    mov  rax, [rip + _uart_rx_head]
    cmp  rax, r12                            ; head_after must equal head_before
    jne  uart_rx_isr_witness_fail

    ; --- All green ---
    lea  rdi, [rip + uart_rx_isr_ok_msg]
    call uart_puts
    jmp  uart_rx_isr_witness_done

uart_rx_isr_witness_fail:
    lea  rdi, [rip + uart_rx_isr_fail_msg]
    call uart_puts

uart_rx_isr_witness_done:
    pop  r12
```

Total: ~22 lines including labels and blank lines.

**Label uniqueness.** All labels prefixed `uart_rx_isr_witness_*`
to avoid clashes with the earlier R16.M4-001/002 witnesses in the
same file. Same discipline as `urrw_*` (uart_rx_ring witness).

**r12 discipline.** r12 is SysV callee-save. `push r12` at witness
entry preserves the outer kernel_main flow's r12; `pop r12` at
witness done restores it. The value stored in r12 is
`head_before`, snapshotted from `[rip + _uart_rx_head]`. `call
uart_rx_isr` does not touch r12 (r12 is callee-save; uart_rx_isr
declares caller-save-only clobbers), so r12 is safe to compare
after the call.

### 5.3 Marker

On sub-test A green:

```
R16 UART RX ISR OK
```

Emitted via `uart_puts` on `uart_rx_isr_ok_msg`. Fingerprint added
to all three R14B/R15 expected-output files, inserted immediately
after the `R16 UART RX RING OK` line.

### 5.4 String data — `tools/boot_stub.S`

Append after the last-landed R16.M4-002 witness strings (at
approximately line 712, i.e. right after `uart_rx_ring_fail_msg`):

```asm
# R16-M4-003 (#597): uart_rx_isr witness success message
.global uart_rx_isr_ok_msg
.align 8
uart_rx_isr_ok_msg: .ascii "R16 UART RX ISR OK\n\0"

# R16-M4-003 (#597): uart_rx_isr witness failure message
.global uart_rx_isr_fail_msg
.align 8
uart_rx_isr_fail_msg: .ascii "R16 UART RX ISR FAIL\n\0"
```

No other rodata changes. Single-line failure message matches
R16.M4-001 and R16.M4-002 discipline — the witness has one
sub-test, so per-sub-test failure differentiation is not
warranted.

### 5.5 Fingerprint files — marker insertion

Insert `R16 UART RX ISR OK` in three files:

| File                                        | Insert after            | Insert before          |
|---------------------------------------------|-------------------------|------------------------|
| `tests/r14b/expected-boot-r14b-loader.txt`  | `R16 UART RX RING OK`   | `LOADER OK`            |
| `tests/r15/expected-boot-r15-ring3.txt`     | `R16 UART RX RING OK`   | `R15 IDLE TASK OK`     |
| `tests/r15/expected-boot-r15-process.txt`   | `R16 UART RX RING OK`   | `R15 IDLE TASK OK`     |

Contains-in-order matching makes the addition strictly additive
— no earlier line reorders. All 5-mode smoke stages that do not
observe R16 markers (`boot_r8_only`, `boot_r10`, `boot_r11`,
`boot_r12`, `boot_r12_denial`) stay byte-identically green.

## 6. Alternatives considered / follow-ups

### 6.1 Combine with #598 (IDT vector 0x24 wire) in one PR

**Rejected.** #598 introduces a new trampoline template
(15-push, `call uart_rx_isr`, 15-pop, iretq) that itself needs
witness. Landing them together would (a) leave the ISR body
untested until IRQ 4 delivery works, or (b) balloon the witness
with a synthetic self-IPI trigger. Splitting keeps each issue's
regression surface minimal: this issue verifies the ISR body's
structural shape; #598 verifies the trampoline; #599 verifies
routing; #601 verifies end-to-end AC.

### 6.2 Combine with #601 (RX smoke) instead of a synthetic witness here

**Rejected.** #601 needs the trampoline (#598), the IOAPIC route
(#599), *and* a QEMU-side stdin injection harness. Waiting for
all three would delay landing this ~55-LOC module by three
issues. The synthetic empty-drain witness here bisects a body
regression at this issue's SHA without waiting on the
delivery-path work.

### 6.3 Move `uart_rx_isr` to `core/int/` alongside `handle_timer`

**Rejected.** The subsystem-14 pattern places all UART-RX code
under `core/uart/`. `handle_timer` sits in `core/int/exceptions.pdx`
because it predates the per-driver-subsystem discipline the R14b
plan introduced. Consistency with #595/#596/#600 wins.

### 6.4 Add `_uart_rx_dropped_count : u64` overrun counter here

**Deferred to #600 or a later hardening issue.** Reasons:

- The AC does not require it.
- Adding a counter introduces a new .bss symbol whose SMP
  concurrency contract (single-writer here in the ISR, no reader
  yet) has to be re-answered when the R17 SMP tier lands
  (multiple CPUs, IPI-driven RX steering).
- A counter without a reader is dead observability. #600 wires
  the ring to a KIND_NOTIFICATION cap; that PR is the natural
  home for a `stats` cap or a `dmesg`-style dump path that
  reads the counter.
- The current drop-on-full policy is already documented in
  enqueue's justification (`rx_ring.pdx:46`: "caller MUST NOT
  retry"). The absence of a counter is explicit, not
  accidental.

### 6.5 Handle LSR error bits (Overrun, Parity, Framing, Break)

**Deferred to a future R17 hardening issue.** The current design
reads RBR unconditionally when LSR.DR is set; LSR error bits
(1..4) are ignored. This is safe:

- **Overrun (LSR bit 1)**: the byte is lost inside the 16550
  FIFO before the CPU sees it; the ISR has no recourse. Would
  need FCR trigger tuning (out of scope) or a hardware-overrun
  counter.
- **Parity error (bit 2)**: 8N1 configuration has no parity
  bit — this bit is never set in the current UART config.
- **Framing error (bit 3)**: signals a stop-bit violation. On
  QEMU with `-serial mon:stdio` this cannot occur (no physical
  line). On real hardware this would corrupt a byte; the current
  policy passes it through, which is defensible until an actual
  serial-line policy is designed.
- **Break interrupt (bit 4)**: signals a serial BREAK. Currently
  ignored; a BREAK detector would be a distinct driver feature.

Documented for the R17 issue but not this one.

### 6.6 Read LSR only once at entry (single-shot, no loop)

**Rejected.** FCR=0xC7 sets the RX FIFO trigger at 14 bytes. The
16550 raises IRQ 4 once per trigger crossing (or once per
character-timeout), not once per byte. A single-shot handler
would consume 1 byte per interrupt and fall behind at any
sustained rate above (IRQ latency)⁻¹. See §3.5.

### 6.7 Use x2APIC MSR (0x80B) instead of xAPIC MMIO for EOI

**Not applicable at this layer.** The existing `apic_eoi`
primitive chose xAPIC MMIO (0xFEE000B0). Whether R17 SMP migrates
to x2APIC MSR is an APIC-layer decision — this ISR just calls
`apic_eoi` and inherits whatever choice that primitive makes.
Future switch is invisible to `uart_rx_isr`.

### 6.8 Emit `R16 UART RX ISR OK` from within `uart_rx_isr`

**Rejected.** Same discipline as every prior R16 subsystem: the
primitive is silent, the witness emits. Printing from the ISR
would flood the console at any real IRQ rate and destroy the
console UX. Keeps `uart_rx_isr` reusable by non-witness callers
(the actual trampoline at #598 will call it dozens of times per
second under keyboard input).

### 6.9 Inline `apic_eoi` for micro-optimization

**Rejected.** Rationale in §3.6. One `call/ret` cost (~5 cycles)
is negligible against the ~200 cycles the drain loop already
spends in port I/O per byte. Single source of truth wins.

## 7. Invariants

### 7.1 `_uart_rx_head` unchanged if LSR.DR was 0 at entry

- **Base case**: at witness time, LSR.DR = 0 (no bytes at COM1).
- **Loop**: first iteration reads LSR, masks to 0x01, compares
  against 0, takes the `je` branch to `urxi_drain_done`. No RBR
  read; no `call uart_rx_enqueue`.
- **Postcondition**: `_uart_rx_head` value stored in
  `rx_ring.pdx:25` is unchanged.

Verified by sub-test A's post-call read-back.

### 7.2 LAPIC EOI is written exactly once per `uart_rx_isr` call

- **Structure**: `call apic_eoi` sits at `urxi_drain_done` after
  the loop's sole exit. No path bypasses it (no `ret` inside the
  loop; no exception handler between loop and EOI).
- **Consequence**: every real IRQ 4 delivery through this ISR
  clears the in-service bit for vector 0x24, unblocking the next
  IRQ 4.

Not exercised at R16.M4-003 (no real IRQ path); property is
by-construction.

### 7.3 Stack pointer restored to entry state

- **Entry**: `rsp%16 == 8` (SysV post-call).
- **After `sub rsp, 8`**: `rsp%16 == 0`.
- **Nested calls preserve alignment**: each nested `call`
  pushes 8 bytes, so callee entry sees `rsp%16 == 8` (SysV
  correct); the nested callee's own `ret` pops 8 bytes,
  restoring `rsp%16 == 0` at our resume point.
- **After `add rsp, 8`**: `rsp%16 == 8` — matches entry.
- **`ret` pops return address**: caller sees `rsp%16 == 0`
  (back to pre-`call uart_rx_isr` state).

No stack corruption possible. Symmetric with the vops.pdx
dispatchers.

### 7.4 The drain loop terminates in bounded time

- **Bound 1 — 16550 FIFO**: at most 16 bytes wait in the RX
  FIFO. Each iteration consumes exactly one byte. After ≤ 16
  iterations LSR.DR reads 0 and the loop exits (assuming no
  producer refill during the drain).
- **Bound 2 — CPU vs baud**: at 115200 baud, a byte takes
  ~87 μs to arrive. A drain iteration is ~200 cycles ≈ 60 ns on
  any modern CPU. Producer/consumer ratio is > 10^3 in the
  consumer's favor — the loop cannot livelock.
- **Bound 3 — ring capacity**: even under an adversarial
  producer, after 256 bytes the enqueue returns FULL and the
  byte is dropped, but the RBR read still clears LSR.DR. Loop
  continues to make forward progress on the *hardware side* even
  when the *software side* is saturated.

### 7.5 No re-entrancy on `_uart_rx_head` from concurrent IRQs

At R16.M4 (UP), IF=0 across the entire body (IDT interrupt gate
clears IF on entry; the trampoline preserves it until iretq).
Only one CPU exists. So `_uart_rx_head` has exactly one writer
active at any instant — the ISR itself. SPSC discipline
(rx_ring.pdx §3.9) is preserved.

At R17 SMP, the RX driver is UP-affine: IRQ 4 routes to CPU 0
only (deferred SMP routing design). So even under SMP, this ISR
runs on exactly one CPU at a time. No lock needed.

## 8. Cross-cutting risks

- **Someone types on QEMU stdin between smoke start and the
  witness.** The drain loop would consume real bytes, advancing
  `_uart_rx_head` and failing the "head unchanged" check. This
  requires a human at the keyboard during `tools/run-smoke.sh`.
  Mitigation: none needed — the smoke harness redirects stdin to
  `/dev/null` and runs headless. If someone runs smoke
  interactively and types before the witness fires, the failure
  message is `R16 UART RX ISR FAIL` — a self-describing
  diagnostic. Documented so future maintainers recognize the
  mode.
- **A future R16.M4 issue enables IRQ 4 delivery before this
  witness runs.** The current ordering places
  uart_rx_init/ring/isr witnesses *before* apic_svr_enable and
  well before any IOAPIC RTE programming. If a future issue moves
  ISR-body execution to a post-IOAPIC-routed slot, real bytes
  could arrive during the witness. Mitigation: this witness must
  run before any IOAPIC RTE for IRQ 4 is programmed. Documented
  as a placement constraint in §4.1.
- **The `apic_eoi` MMIO write is a no-op on a
  software-disabled LAPIC**. If a future refactor moves
  apic_svr_enable *earlier* than this witness, the LAPIC is
  enabled and the EOI write clears... nothing (no in-service
  interrupt), still a no-op. Mitigation: no action needed;
  behavior is identical in both LAPIC states for the empty-drain
  witness.
- **`in_al al` upper-bit staleness across iterations.** The `and
  rax, 0x01` after the LSR read guarantees bits 8..63 are 0 by
  the time the `cmp; je` fires. The subsequent `in_al al` for
  RBR writes AL but leaves bits 8..63 at 0 (their previous value
  after the mask). The `and rax, 0xFF` before `mov rdi, rax` is
  therefore redundant — but see §3.3 for why it stays as a
  defensive redundancy.

## 9. LOC estimate

| File                                                        | LOC        |
|-------------------------------------------------------------|------------|
| `src/kernel/core/uart/rx_isr.pdx` (new)                     | ~55        |
|   - module boilerplate + justification                      |   ~35      |
|   - `uart_rx_isr` body (15 instructions)                    |   ~18      |
|   - inline comments                                         |    ~2      |
| `src/kernel/boot/kernel_main.pdx` (witness block)           | ~25        |
|   - 1 sub-test + labels                                     |   ~18      |
|   - preceding/trailing comment banner                       |    ~5      |
|   - blank / structural spacing                              |    ~2      |
| `tools/boot_stub.S` (2 messages)                            | ~8         |
| 3 expected-output fingerprint files (1 marker each)         | ~3         |
| `design/kernel/r16-m4-003-uart-rx-isr.md` (this doc)        | (this)     |
| **Total executable / testing / test-data**                  | **~91**    |

Executable code path: ~55 LOC. Witness + fingerprint: ~36 LOC.
Comparable to R16.M4-001 (~86 LOC) — slightly larger because the
ISR body is 15 instructions vs 4, and the witness needs r12
save/restore around the head snapshot.

## 10. Tractability

**HIGH — comparable to R16.M4-001.**

- **Zero paideia-as encoder gap.** Every mnemonic proven at
  `boot/uart.pdx` (port I/O), `core/uart/rx_ring.pdx` (call to
  enqueue), `core/apic/eoi.pdx` (call to apic_eoi), and
  `core/fs/vops.pdx` (alignment idiom). See §2.3 table.
- **Non-leaf, but uses the recent-frozen alignment discipline.**
  `sub rsp, 8 / add rsp, 8` bracket around the drain loop
  matches vops.pdx verbatim.
- **Reuses `apic_eoi`** rather than re-encoding MMIO writes here.
- **Witness is a single sub-test.** Head-unchanged check; no
  fixture slab, no fd table, no vnode wiring, no cross-subsystem
  interaction beyond the (already-landed) ring.
- **Marker line is contains-in-order** — strictly additive to
  fingerprints; no reordering risk.
- **No cross-repo escalation risk.**
- **LAPIC MMIO safety at witness time verified**: apic_eoi writes
  to a mapped identity region regardless of SVR state; write is
  a no-op with no in-service interrupt.
- **Sizing (~91 LOC total)** is comparable to R16.M4-001 (~86
  LOC), well within a single workerbee session.

Estimated implementation time: **~40 minutes of a workerbee
session** — slightly longer than R16.M4-001 because the drain
loop has 5 more instructions and the witness needs a callee-save
push/pop pair, but no new mnemonics to introduce.

Estimated risk of regressing an existing smoke mode:
**near-zero** — purely additive (one new module, one new witness
block, one new emit line, two new rodata strings).

**Known follow-ups (do NOT block #597's landing)**:

- **#598 (idt vector 0x24 wire)** — installs a trampoline at
  IDT slot 0x24 that saves 15 GPRs, calls this issue's
  `uart_rx_isr`, restores, iretqs. This issue's function is the
  target.
- **#599 (ioapic route IRQ 4)** — programs the IOAPIC RTE so
  IRQ 4 → vector 0x24 on CPU 0. First moment `uart_rx_isr` fires
  from a real interrupt.
- **#600 (uart_rx_notification_cap)** — wires the ring to a
  KIND_NOTIFICATION cap so sys_read unblocks on ring-non-empty.
  Also the natural home for `_uart_rx_dropped_count` per §6.4.
- **#601 (RX smoke)** — end-to-end AC verification via QEMU
  stdin injection.

## 11. References

- Issue: paideia-os#597
- Milestone: paideia-os R16.M4 (UART input driver — 16550 RX
  interrupt-driven)
- Prereq issues: #595 (uart_rx_init), #596 (uart_rx_ring),
  #358 (apic_eoi), #572 (vops alignment idiom), P1-006/007
  (uart_init + in_al al idiom)
- Blocks: #598, #599, #600, #601
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 14, item 3
- Master plan: `design/milestones/r14b-master-plan.md` §M20
  (UART input)
- Prior-art body pattern: `src/kernel/core/int/exceptions.pdx:138`
  (`handle_timer`) — closest ISR-body precedent that calls nested
  routines then `call apic_eoi; ret`
- Prior-art alignment pattern: `src/kernel/core/fs/vops.pdx:78..242`
  (R16-M1-003 #572 verify-pass) — `sub rsp, 8` / nested call /
  `add rsp, 8` around a post-outer-call function body
- Prior-art port-poll pattern: `src/kernel/boot/uart.pdx:63-64`
  (uart_putc's LSR THRE poll) — this issue mirrors verbatim with
  DR (0x01) in place of THRE (0x20)
- Prior-art EOI callsites: `src/kernel/core/int/exceptions.pdx:162`
  (handle_timer), `src/kernel/core/ipi/vectors.pdx:27,49` (IPI
  trampolines)
- Existing primitive: `src/kernel/core/apic/eoi.pdx:30` (apic_eoi,
  MMIO 0xFEE000B0 write)
- NS PC16550D §3.1.1 (RBR), §3.1.4 (LSR) — 16550 register spec
- Intel SDM Vol 3A §10.4.7.1 (SVR / software-enable), §10.8.5
  (EOI register semantics)
