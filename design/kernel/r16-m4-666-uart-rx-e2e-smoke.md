# R16-M4-666: real-IRQ-driven end-to-end UART RX smoke

**Issue**: [paideia-os#666](https://github.com/snunezcr/paideia-os/issues/666)
**Milestone**: `r16-m4` (follow-up to #601)
**Blockers cleared**: #662 (LAPIC delivery), R16.M5 (TTY subsystem)
**Depends on**: #595 uart_rx_init, #596 uart_rx_ring, #597 uart_rx_isr,
#598 IDT vec 0x24, #599 IOAPIC IRQ 4 route, #600 uart_rx_notify,
#601 uart_rx_smoke (structural companion)

## 1. Goal

Prove the full 16550 RX interrupt chain end-to-end on the wire:

```
    QEMU host                  QEMU 16550          IOAPIC     LAPIC    CPU 0
    -------------              ----------          ------     -----    -----
    write 'a','b','c'   -->    RBR + LSR.DR       -->  RTE #4  -->  vec 0x24
    on chardev pipe            (ERBFI set)             -> vec       IDT gate
                                                       -> 0x24      -> _uart_rx_trampoline
                                                                    -> uart_rx_isr
                                                                       -> uart_rx_enqueue x3
                                                                    -> uart_rx_notify_wake
                                                                    -> apic_eoi
    Kernel witness             _uart_rx_ring (SPSC)
    dequeue x3          <--    3 bytes now buffered
    emit "UART RX: abc\n"     via uart_puts to serial output
    (host reads on            <-- captured to LOG file
     chardev pipe .out)
```

No layer is faked. The 3 bytes traverse the real interrupt path from
host-side pipe injection to kernel emission on the same serial wire.

## 2. Design choice

Three shapes were considered. Chosen: **A. new kernel-side polling witness
gated by real byte arrival**.

### Option A — kernel polling witness (chosen)

Insert one `~40-line` witness in `kernel_main.pdx` immediately before
`call lapic_timer_init` (§4). Under `sti` with a bounded poll budget,
drain up to 3 bytes from `_uart_rx_ring` via `uart_rx_dequeue`, then
emit `UART RX: abc\n` via the reused `uart_rx_smoke_prefix_msg` +
`_uart_rx_smoke_buf` from #601. If the poll budget expires with fewer
than 3 bytes captured, cli and bail silently — no fingerprint emission.

* Zero user-space code needed.
* Zero syscall dispatch needed.
* Zero TTY-line-buffer bridge needed (the ring **is** the endpoint).
* Reuses #601's rodata + `.bss` slab exactly as the spec requires.
* Non-driven boot modes (every existing mode) time out silently and
  emit nothing — AC of `boot_r17_init` is preserved byte-identically.

Rejected alternatives:

### Option B — userland init reader

Extend `init.pdx` to `sys_read(0, buf, 3)` post-child_hello, then
`sys_write` back. Rejected because:
* Requires a `tty_process_input` bridge from `_uart_rx_ring` to
  `_tty_line_buf` (currently missing — see `uart_rx_isr` at
  `core/uart/rx_isr.pdx:52` which only enqueues into ring + wakes).
  Bridge would need to run in ISR context or in a driver thread and
  is out of scope for #666.
* Blocking `sys_read` on init would deadlock non-driven boot modes,
  breaking every other smoke mode.
* Adds a fingerprint dependency on `sys_write` output shape.

### Option C — kernel-side self-injection witness

Duplicate #601 but call `uart_rx_isr` manually with QEMU-injected
bytes present in the FIFO. Rejected because it does not prove IOAPIC
→ LAPIC → IDT gate delivery — the ISR is called by C, not by the CPU
IRQ mechanism. #601 is already this shape; #666 must supersede it
with real IRQ delivery, not duplicate it.

## 3. Placement in `kernel_main.pdx`

Between `bin_child_hello_seed_done:` (existing L7408) and
`call lapic_timer_init;` (existing L7410).

**Rationale for this exact slot**:

| Prior boot state at this point                        | Why it matters                             |
| ----------------------------------------------------- | ------------------------------------------ |
| `apic_enable` + `apic_svr_enable` done (L6547-6548)   | LAPIC globally enabled, can receive IRQs   |
| `pic_mask_all` done (L6549)                           | 8259 masked, no legacy IRQ interference    |
| `ioapic_irq4_init` done (L5359)                       | IRQ 4 → vec 0x24 → CPU 0 routed            |
| IDT vec 0x24 wired (`idt_install` at boot)            | Real IRQ can reach `_uart_rx_trampoline`   |
| `uart_rx_init` done (L5100)                           | 16550 ERBFI set, QEMU will raise IRQ 4     |
| **`lapic_timer_init` NOT yet called** (L7410)         | LAPIC timer LVT still masked at power-on   |
|                                                       | default → no vec 32 IRQ during our `sti`   |
|                                                       | window                                     |
| **`_current_tcb` NOT yet published**                  | If timer somehow fired, `handle_timer` →   |
|                                                       | `sched_switch` would fault on null TCB.    |
|                                                       | Bounded by the point above.                |

The `sti` window is short (bounded poll budget, `cli` on exit or
timeout) and only IRQ 4 can be delivered. Vec 0xFF spurious is
theoretically possible via LAPIC SVR but has not been observed on
QEMU TCG in this configuration; if it fires the default IDT slot is
inert (no-op stub from `idt_install`'s 256-vector fill loop).

## 4. Wire fingerprint

`UART RX: abc\n` — same emission shape as #601 per the spec's
"reuse `_uart_rx_smoke_buf` and `uart_rx_smoke_prefix_msg`"
constraint. Distinguishability from #601's emission is provided at
the fingerprint-matcher level: the new smoke mode's fingerprint file
lists `UART RX: abc` **twice** (once at the #601 position, once at
the #666 position later in the log). The matcher (`tools/run-smoke.sh`
§#673 in-order search) advances `search_offset` past each match, so
the second occurrence is only found if #666 actually emits — i.e.,
only if real IRQ delivery worked.

Non-driven boot modes (every existing `boot_*` mode) still show
exactly one occurrence (from #601 alone) and their fingerprints stay
byte-identical.

## 5. Injection mechanism

QEMU chardev pipe. Two named FIFOs bracket QEMU's serial port:

```
    driver script  --write-->  ${FIFO}.in   --read-->  QEMU 16550 RX
    driver script  <--read--   ${FIFO}.out  <--write-- QEMU 16550 TX
```

`tools/run-smoke.sh` in `boot_r16_uart_rx` mode:

1. `mkfifo ${FIFO}.in ${FIFO}.out` (both must exist before QEMU opens
   them; QEMU blocks otherwise).
2. Start a background `cat ${FIFO}.out > ${LOG}` reader to drain
   QEMU's serial output into the same LOG file the fingerprint
   matcher reads.
3. Start a background writer subshell: `(sleep 1.0; printf 'abc';
   sleep 10) > ${FIFO}.in`. The trailing sleep keeps the pipe open
   for QEMU's read side (a closed writer would EOF the RX and
   confuse the 16550 emulation).
4. Launch QEMU with `-chardev pipe,id=char0,path=${FIFO} -serial
   chardev:char0` (replacing the default `-serial file:${LOG}`).
5. Wait for QEMU to exit (timeout 10s — kernel boot + witness + init
   flow all fit in ~3s).
6. Clean up FIFOs, kill background procs, fingerprint-check.

### Why the 1-second injection delay

QEMU serial emulation raises IRQ 4 when `LSR.DR` becomes set **while
`IER.ERBFI` is asserted**. Two orderings are possible:

* Kernel enables ERBFI before host writes bytes: bytes arrive at
  16550, LSR.DR := 1, IRQ 4 fires immediately.
* Host writes bytes before kernel enables ERBFI: bytes queue in
  16550 RBR, LSR.DR := 1, but IRQ suppressed until ERBFI flips 0→1.
  When kernel sets ERBFI, `serial_update_irq` re-checks and raises
  the pending IRQ.

Both orderings work end-to-end. The 1-second delay picks the
"host-after-kernel" order (kernel definitely at witness by then on
TCG), so bytes arrive live during the poll loop and IRQ fires
cleanly through the IOAPIC → LAPIC → IDT chain. Either ordering
would satisfy the AC.

## 6. Kernel witness pseudocode

```
uart_rx_wire_witness:
    sti                                              ; arm IRQ delivery

    lea  r12, [rip + _uart_rx_smoke_buf]            ; reuse #601 buf
    xor  r13, r13                                    ; captured count
    mov  r14, POLL_BUDGET                            ; ~2s on TCG

  urxw_poll_loop:
    call uart_rx_dequeue                             ; rax = byte or 0xFFFF
    mov  rcx, 0xFF
    cmp  rax, rcx
    ja   urxw_no_byte                                ; empty
    mov  r8, r12
    add  r8, r13
    mov_b [r8 + 0], rax
    add  r13, 1
    cmp  r13, 3
    je   urxw_have_three

  urxw_no_byte:
    sub  r14, 1
    jnz  urxw_poll_loop
    cli
    jmp  urxw_done                                   ; timeout — silent

  urxw_have_three:
    cli
    mov  rax, 0x0A
    mov  r8, r12
    add  r8, 3
    mov_b [r8 + 0], rax                              ; buf[3] = '\n'
    xor  rax, rax
    mov  r8, r12
    add  r8, 4
    mov_b [r8 + 0], rax                              ; buf[4] = '\0'

    lea  rdi, [rip + uart_rx_smoke_prefix_msg]      ; reuse #601 prefix
    call uart_puts                                   ; emits "UART RX: "
    mov  rdi, r12
    call uart_puts                                   ; emits "abc\n"

  urxw_done:
```

Register discipline:
* `r12`, `r13`, `r14` are SysV callee-save — survive the `call
  uart_rx_dequeue` (leaf; clobbers rax/rcx/rdx/r9/r10 only per
  `core/uart/rx_ring.pdx:97`) and the `call uart_puts` (clobbers
  rax/rcx/rdx/rdi/rsi only per `boot/uart.pdx:81`).
* `r8` is caller-save but is fully reloaded from `r12`+`r13` at each
  use site — no cross-call dependency.
* No prologue/epilogue push/pop — this is a top-level witness site
  running with the ambient boot stack; `r12-r14` are consumed only
  by this witness.

Poll budget: `2 * 10^8` iterations. Empirically ~1-2s on TCG for
this many simple compare-and-branch iterations. Well inside the 10s
smoke timeout, well past the driver's 1s injection sleep.

## 7. Ring accounting after #601

At #666 witness entry, `#601` has already:
* Enqueued 3 bytes → `_uart_rx_head = 3`.
* Dequeued 3 bytes → `_uart_rx_tail = 3`.
* Emitted `UART RX: abc\n` — the buffer holds `"abc\n\0..."`.

Ring is empty (head == tail == 3). When real IRQ delivers a byte:
* `uart_rx_enqueue` stores at `ring[3 & 0xFF] = ring[3]`, head=4.
* Our `uart_rx_dequeue` loads from `ring[3 & 0xFF] = ring[3]`, tail=4.

Correct by construction — the 256-slot circular index math works
identically at any head/tail base.

## 8. AC preservation matrix

| Mode                  | Behavior                                          |
| --------------------- | ------------------------------------------------- |
| `boot_r8_only`        | `-serial file:LOG` — no input, poll times out.    |
|                       | Fingerprint unchanged (predates R16.M4).          |
| `boot_r10`            | Same as above.                                    |
| `boot_r11`            | Same as above.                                    |
| `boot_r12`            | Same as above.                                    |
| `boot_r12_denial`     | Same as above.                                    |
| `boot_r14b_*` (all 5) | Same as above.                                    |
| `boot_r15_ring3`      | Same as above.                                    |
| `boot_r15_process`    | Same as above.                                    |
| `boot_r17_init`       | Same as above. Fingerprint unchanged (only one    |
|                       | `UART RX: abc` line, from #601).                  |
| `boot_r16_uart_rx`    | **NEW.** `-chardev pipe` + driver injects `abc`.  |
|                       | Fingerprint requires TWO `UART RX: abc` lines.    |
| `boot_panic`          | `boot_r17_init` variant — same preservation.      |
| `boot_panic_halt`     | Builds panic kernel — untouched.                  |
| `boot_exc3`           | Builds exc3 kernel — untouched.                   |

Byte-identical output across every existing mode. New mode adds one
line (`UART RX: abc\n`) between `R17 BIN CHILD HELLO SEED OK` and
`INIT BOOT OK`.

## 9. Backtracking discipline

If real IRQ delivery is observably broken (poll times out
consistently under injection), do NOT weaken the fingerprint or
add a fallback path. File a diagnostic follow-up issue for the
suspect layer:

* `_uart_rx_trampoline` not reached → IOAPIC RTE misprogrammed or
  IDT gate corrupted.
* Trampoline reached but ring empty post-`uart_rx_isr` → `uart_rx_enqueue`
  ring-full false-positive.
* Ring populated but our poll always sees empty → head/tail counter
  read ordering issue with the ISR.

Each of these has a distinct diagnostic strategy (QEMU `-d int`,
`info lapic`, `info ioapic`) documented against the corresponding
subsystem issue (#597, #598, #599, #600).
