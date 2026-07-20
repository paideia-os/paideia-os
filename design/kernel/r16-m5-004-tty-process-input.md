---
issue: 605
milestone: R16.M5 (TTY / cooked line discipline)
subsystem: 15 — TTY / cooked line discipline
topic: tty_process_input — per-byte cooked-mode router; echoes to TX, appends to _tty_line_buf, translates \r→\n, handles backspace (BS/DEL), rings bell on line-buffer overflow
prereq:
  - "#604 (R16.M5-003 tty_line_buffer — LANDED; provides tty_line_append(byte), tty_line_reset(), tty_line_available(), and the .bss triple {_tty_line_buf, _tty_line_head, _tty_line_complete}. This issue is the sole non-witness caller of tty_line_append. Backspace path directly decrements _tty_line_head via the `pub let mut` handle exposed at line_buffer.pdx:25 — an alternative documented at #604 §3.3/§6.3 which explicitly names this issue as the possible in-line consumer.)"
  - "#603 (R16.M5-002 tty_vops_table — LANDED; publishes _tty0 and the vops table. Not called by this issue's code, but establishes the discipline that tty_process_input is a leaf-adjacent primitive not yet wired into a vnode ops slot. The drainer that will invoke tty_process_input for each RX-ring byte is a future issue — see §1.2 note on non-integration at #605.)"
  - "#602 (R16.M5-001 tty_init — LANDED; establishes core/tty/ directory + module naming convention. This issue adds process_input.pdx as a sibling file per the family layout catalogued at line_buffer.pdx:245-252.)"
  - "#600 (R16.M4-006 uart_rx_notify — LANDED; the ISR-tail wake primitive that will (post-drainer-wiring) trigger the future drainer to call tty_process_input. Not a compile-time dependency of this issue; called out to fix the eventual composition: ISR enqueues to _uart_rx_ring → wake_if_waiter → sched_wake → drainer resumes → dequeue byte → this issue → tty_line_append.)"
  - "boot/uart.pdx (uart_putc — Phase-1 landed primitive at boot/uart.pdx:55. Signature `(u64) -> () !{sysreg} @{}`. Clobbers rax, rdx only (poll loop uses dx=0x3FD then dx=0x3F8; and rax masks THRE bit). Does NOT touch rdi, rcx, r8, r9, r10, r11, or any callee-save. This issue's echo path invokes it 1..3 times per input byte.)"
blocks:
  - "#606 (r15-m5-005 tty_read_blocking — REPLACES the minimal tty_read body shipped at #603. Not a direct compile-time dependency, but this issue's chosen \\r→\\n on-INPUT policy ensures the reader at #606 always sees the POSIX-canonical line terminator (0x0A) in _tty_line_buf regardless of terminal keyboard convention. #606's copy-out to user buf will emit the buffer's \\n bytes verbatim; no back-translation needed.)"
  - "#608 (r15-m5-007 connect-tty-to-init-fd012 — orthogonal to this issue but composes at R16.M5 closer: once init's fd 0/1/2 map to _tty0, the drainer that invokes tty_process_input completes the RX→TTY→sys_read cycle.)"
  - "#609 (r15-m5-008 R16.M5 CLOSER smoke — the composed end-to-end \"typing hello\\n from injected RX yields 6 bytes from sys_read\" fingerprint. This issue's witness proves the byte-router's semantics in isolation; #609 proves them under real ISR-fed byte flow.)"
touching:
  - src/kernel/core/tty/process_input.pdx                  (new file — ~110 LOC incl. justifications)
  - src/kernel/boot/kernel_main.pdx                        (witness block after tty_line_witness_done at line 4414; ~90 LOC)
  - tools/boot_stub.S                                      (2 rodata additions: tty_input_ok_msg, tty_input_fail_msg)
  - tests/r14b/expected-boot-r14b-loader.txt               (marker: `R16 TTY INPUT OK`)
  - tests/r15/expected-boot-r15-ring3.txt                  (marker)
  - tests/r15/expected-boot-r15-process.txt                (marker)
  - design/kernel/r16-m5-004-tty-process-input.md          (this doc)
related:
  - design/kernel/r16-m5-003-tty-line-buffer.md            (#604 — §3.4/3.5 pin drop-on-overflow policy at the primitive layer AND explicitly hand bell-on-overflow to THIS issue; §3.3 and §6.3 flag in-line _tty_line_head decrement as the sanctioned backspace mechanism for #605.)
  - design/kernel/r16-m5-002-tty-vops-table.md             (#603 — §3.6 pinning the R18+ multi-tty migration path preserved by this issue's subsystem-scoped naming.)
  - src/kernel/core/tty/line_buffer.pdx                    (#604 — landed; this issue's sole non-witness caller of tty_line_append and only decrementer of _tty_line_head outside tty_line_reset.)
  - src/kernel/boot/uart.pdx                               (uart_putc/uart_puts landed at Phase-1; the TX side of the echo path.)
  - design/milestones/r14b-tactical-plan.md                §Subsystem 15 line 1598, item 4 (this issue's plan pointer; item 4 language matches issue AC verbatim).
---

# R16-M5-004 — `tty_process_input`: per-byte cooked-mode router (#605)

## 1. Scope

Land the fourth R16.M5 subsystem-15 issue: a single leaf-adjacent
routine that consumes one input byte from the RX pipeline and
applies the cooked-mode line discipline:

- **Printable byte** → echo it verbatim; append to `_tty_line_buf`.
- **CR (0x0D)** → translate to LF (0x0A) for the buffer; echo
  `"\r\n"` for the terminal; append LF.
- **LF (0x0A)** as a raw user byte (rare, but legal) → echo
  `"\r\n"`; append LF. Same effective path as CR — both route to
  the newline handler.
- **BS (0x08) OR DEL (0x7F)** → if `_tty_line_head > 0`, decrement
  head and emit `"\b \b"` (backspace, space, backspace) to
  visually erase; else no-op (nothing to erase, no echo).
- **Buffer full** (tty_line_append returns 1) → emit BEL (0x07)
  to acknowledge the drop.

```
tty_process_input(byte : u64) -> ()
    input:  rdi = byte value in low 8 bits (upper 56 bits ignored)
    output: (none — rax undefined on return)
    side effect (any path):     0..3 calls to uart_putc via COM1 THR
    side effect (append path):  _tty_line_buf[head] = byte;
                                _tty_line_head += 1;
                                if byte == '\n':  _tty_line_complete = 1
    side effect (BS/DEL path):  _tty_line_head -= 1 (if head > 0)
    side effect (overflow):     BEL (0x07) echoed; buffer state unchanged
```

Acceptance (issue AC, literally): **typing "hello\n" leaves buffer
"hello\n" and echoes correctly.**

The witness at §5 exercises this AC verbatim (sub-test A: feed
'h','e','l','l','o','\r' — the byte a real terminal sends on Enter
— and observe `_tty_line_buf` contains "hello\n" with
`_tty_line_complete == 1`), plus four additional sub-tests
covering the code-branch axes the AC does not enumerate.

### 1.1 What this issue proves

- **Per-byte cooked routing composes without leaking.** Each of
  the five input classes (printable, CR, LF, BS/DEL, overflow)
  reaches its intended combination of {echo bytes, buffer
  mutation, bell} without cross-branch state corruption. Witness
  sub-tests A–E each isolate one class.
- **Byte survival across nested `uart_putc` calls is trivial.**
  `uart_putc` clobbers only `{rax, rdx}` per boot/uart.pdx:60-70
  — it does not touch `rdi`, `rcx`, `r8..r15`, or any callee-save
  register. The routing byte in `rdi` at entry survives every
  echo call. This issue nonetheless spills the byte into
  callee-save `rbx` at entry to (a) shrink the register-pressure
  surface as tty_line_append also lands in the caller-save window,
  (b) let the routing decoder use `rdi` as scratch for computed
  branch dispatch, and (c) preserve a stable value across the
  handful of `mov rdi, imm8` calls in the CR/BS paths.
- **The \r→\n input translation lands here, once, at the earliest
  cooked-mode-aware layer.** All downstream consumers of
  `_tty_line_buf` observe canonical LF (0x0A) as the line
  terminator regardless of what the terminal keyboard emits (Mac
  Terminal.app: CR; Linux xterm: CR; Windows PuTTY: CR by default,
  configurable). Neither #606's reader nor userland `read()` needs
  a back-translation table. This matches POSIX termios `ICRNL`.
- **The `_tty_line_head` cell is legally decremented from outside
  `tty_line_reset`.** #604 §3.3 and §6.3 explicitly bless the
  in-line decrement path from this issue as an alternative to
  minting a `tty_line_backspace` leaf. The witness sub-test D
  proves the decrement's isolated correctness.
- **Overflow triggers a BEL echo without state corruption.**
  #604's `tty_line_append` returns 1 on overflow with head
  unchanged; this issue's BEL emission decouples the "user gets
  told" from the "buffer stays clean" — the two paths compose
  cleanly. Witness sub-test E proves both halves.

### 1.2 What this issue deliberately does NOT do

- **No ISR / drainer wiring.** `tty_process_input` is not yet
  called from the RX drain path. The drainer that walks
  `_uart_rx_ring` byte-by-byte and invokes this routine is a
  future issue (a "TTY drainer thread" between #605 and #608 —
  see §6.7). At R16.M5-004 the routine is exercised only from
  the witness. This matches the pattern already used at #604
  (line buffer is a primitive; the drainer is separate).
- **No Ctrl-D EOF handling.** Tactical plan §Subsystem 15 A:
  "Ctrl-D (0x04) at start of empty line → EOF (read returns 0)."
  This requires (a) an EOF flag alongside `_tty_line_complete`
  and (b) reader-side special handling — both #606's concern.
  If the byte 0x04 arrives at this issue, it takes the "normal
  byte" branch: echoed as an unprintable control char (visible
  as `^D` only if the terminal has ECHOCTL, else typically as
  nothing), appended to the buffer. #606 will handle EOF
  detection after copy-out. §6.4 unpacks the deferral.
- **No Ctrl-C SIGINT.** Tactical plan §Subsystem 15 A defers
  SIGINT to R17+; log-only in R14B. Not this issue's concern.
- **No terminal-echoctl gating (ECHO / ECHONL / ECHOCTL).**
  Cooked-mode termios has ~15 flags; #605 hardcodes the
  equivalent of `ECHO | ECHONL | ECHOE | ICRNL | ONLCR` (echo
  everything typed, echo NL after echoing CR translation, echo
  BS with erase, translate CR to NL, output NL as CR+NL). This
  matches Linux default termios `cfmakeraw` inverted. A per-tty
  termios struct + syscall (`tcsetattr`) is a Subsystem-15
  R18+ concern.
- **No SIGWINCH / window-size events.** Terminal resize is a
  R17+ pty concern.
- **No line-editing (kill-line 0x15, word-erase 0x17, reprint
  0x12).** Cooked-mode "read-line" editors add these; #605 ships
  the minimum viable set. §6.5 catalogues the follow-ups.
- **No UTF-8 / multibyte awareness.** This issue processes one
  byte at a time; multibyte sequences (e.g., UTF-8 codepoints,
  ANSI escape sequences) pass through byte-by-byte. A UTF-8-aware
  cooked mode is a R19+ concern.
- **No raw-mode toggle.** All bytes route through the cooked
  path; raw mode (`~ICANON`) would bypass this routine entirely
  and read directly from `_uart_rx_ring`. Not this issue's shape.
- **No backspace-across-multiple-classes coalescing.** BS/DEL
  decrements head by exactly 1 per call; a UTF-8-aware
  implementation would need to walk back to the previous
  codepoint start. Deferred with the UTF-8 point above.
- **No re-entrancy guard.** Single-CPU boot; callers must not
  re-enter this routine on the same input stream. R17 SMP tier
  will add per-tty locking if needed.

## 2. Prereq check

### 2.1 What is in place

| Primitive / symbol         | Location                                               | Contract used                                                                                                          |
|----------------------------|--------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------|
| `core/tty/` directory      | `src/kernel/core/tty/` (#602)                          | Established; this issue adds `process_input.pdx` as a sibling of `line_buffer.pdx`.                                    |
| `tty_line_append`          | `core/tty/line_buffer.pdx:43` (#604)                   | `(u64) -> u64 !{mem} @{}`. Returns 0 on accept, 1 on overflow. Reads rdi (byte). Clobbers `{rax, rcx, rdx, r8}`.        |
| `_tty_line_head` slot      | `core/tty/line_buffer.pdx:25` (#604)                   | `pub let mut _tty_line_head : u64`. Directly readable/writable via RIP-relative loads/stores.                          |
| `uart_putc`                | `boot/uart.pdx:55`                                     | `(u64) -> () !{sysreg} @{}`. Reads rdi (char). Clobbers `{rax, rdx}` only. Does NOT touch rdi or callee-save.          |
| RIP-relative qword load    | `core/uart/rx_ring.pdx:533`                            | `mov rax, [rip + _sym]` — used for `_tty_line_head` read in BS path.                                                    |
| RIP-relative qword store   | `core/uart/rx_ring.pdx:554`                            | `mov [rip + _sym], rax` — used for `_tty_line_head` write in BS path.                                                   |
| `and rax, 0xFF`            | `core/tty/line_buffer.pdx:62`                          | Byte-mask the routing scratch reg.                                                                                     |
| `cmp reg, imm8`            | Ubiquitous.                                            | Router branch discriminators (0x08, 0x0A, 0x0D, 0x20, 0x7F).                                                            |
| `push rbx` / `pop rbx`     | `core/uart/rx_isr.pdx` prologue/epilogue idiom         | Callee-save prologue for the routing register.                                                                         |
| `mov reg, reg`             | Ubiquitous.                                            | Save/restore byte across calls.                                                                                        |
| `sub qword [rip+sym], 1`   | NOT USED (see §3.5 — chose split load/sub/store for encoder safety).                                                                                                                              |
| `je` / `jne` / `jmp`       | Ubiquitous.                                            | Router branches.                                                                                                       |
| Direct `call sym` / `ret`  | Ubiquitous.                                            | Nested-call form for `uart_putc` and `tty_line_append`.                                                                |

### 2.2 What is NOT in place

- **`tty_process_input` symbol.** Introduced by this module.
- **`tty_input_ok_msg` / `tty_input_fail_msg` rodata in
  `boot_stub.S`.** Added alongside the R16.M5-003 witness strings
  at approximately lines 785-792.
- **`R16 TTY INPUT OK` marker in three fingerprint files.**
  Additive — inserted after `R16 TTY LINE OK`.

### 2.3 Encoder gaps

**None.** Every mnemonic used has landed precedent:

| Mnemonic form                          | Proven at                                                        |
|----------------------------------------|------------------------------------------------------------------|
| `mov rax, [rip + _sym]`                | `core/uart/rx_ring.pdx:533`; `core/tty/line_buffer.pdx:48`.       |
| `mov [rip + _sym], rax`                | `core/uart/rx_ring.pdx:554`; `core/tty/line_buffer.pdx:59`.       |
| `mov reg, reg` (e.g., `mov rbx, rdi`)  | Ubiquitous.                                                       |
| `mov rdi, imm8` (e.g., `mov rdi, 0x08`)| Ubiquitous (`core/cap/kind_notification.pdx` and elsewhere).      |
| `and rax, 0xFF`                        | `core/uart/rx_ring.pdx:544`; `core/tty/line_buffer.pdx:62`.       |
| `cmp rax, imm8` (0x08, 0x0A, 0x0D, 0x7F) | Ubiquitous.                                                     |
| `sub rax, 1` (reg,imm8)                | Ubiquitous (path.pdx pointer bumps, rx_ring cursor decrement equivalents). |
| `add rax, 1` (reg,imm8)                | Ubiquitous.                                                       |
| `xor rax, rax`                         | Ubiquitous.                                                       |
| `push rbx` / `pop rbx`                 | Callee-save spill pattern; `core/uart/rx_isr.pdx` and many.       |
| `je` / `jne` / `jmp`                   | Ubiquitous.                                                       |
| `call sym` (direct)                    | Ubiquitous.                                                       |
| `ret`                                  | Ubiquitous.                                                       |

No SIB. No REX.B beyond r8..r10. No SSE/AVX. No port I/O
directly (delegated to `uart_putc`). **Cross-repo escalation not
needed.**

## 3. Design

### 3.1 File and module structure

New file: `src/kernel/core/tty/process_input.pdx`. Sits alongside
the four R16.M5 modules already landed:

```
src/kernel/core/tty/
    init.pdx           (#602, LANDED)
    vops.pdx           (#603, LANDED)
    read.pdx           (#603, LANDED — minimal; extended at #606)
    write.pdx          (#603, LANDED — minimal; extended at #607)
    line_buffer.pdx    (#604, LANDED)
    process_input.pdx  <-- THIS ISSUE (#605) — per-byte cooked router
```

Module name: `ProcessInput`. Public export: `tty_process_input`.
No new storage cells — this module is stateless and composes
against `_tty_line_head` / `_tty_line_complete` owned by `#604`.

### 3.2 Byte classification

Five input classes routed by a linear chain of `cmp + je`
discriminators against `rax` (the byte, low 8 bits, in a scratch
register — see §3.3 for why we spill `rdi` into `rbx` first).
Ordering is chosen for the expected frequency (printable is the
common case, so its branch is fall-through with zero taken
branches on the router):

| Byte class                          | Byte values           | Router branch label   | Instructions from entry to handler |
|-------------------------------------|-----------------------|-----------------------|-------------------------------------|
| Backspace (BS)                      | 0x08                  | `tpi_backspace`       | 4 (push, mov, and, cmp, je)         |
| Delete (DEL)                        | 0x7F                  | `tpi_backspace`       | 6 (…, cmp, je)                      |
| Carriage return (CR)                | 0x0D                  | `tpi_newline`         | 8                                   |
| Line feed (LF) as raw input         | 0x0A                  | `tpi_newline`         | 10                                  |
| Anything else (incl. control chars, printable ASCII, high-bit) | 0x00..0x07, 0x0B, 0x0C, 0x0E..0x0C, 0x09 (TAB), 0x20..0x7E, 0x80..0xFF | `tpi_normal` (fall-through) | 11 |

**Ordering justification.**

1. **BS/DEL first.** Cheapest to detect; if a typing session is
   error-heavy, backspace can approach printable-frequency. Both
   values merge into `tpi_backspace`.
2. **CR/LF next.** CR is exactly-once-per-line-terminator; LF is
   near-zero on real keyboards (Enter emits CR). Both merge into
   `tpi_newline`. Placing CR before LF matches the empirical
   ordering (CR wins for QEMU + xterm + Terminal.app).
3. **Normal case is fall-through.** Zero router branch cost on
   the hot path. Adds ~3 cycles per character for interactive
   typing — dominated by `uart_putc`'s polling loop anyway.

**Alternative rejected: jump table (`_router[byte]` → address).**
Would eliminate the 4-branch discriminator chain but adds 256×8
bytes of `.rodata`, a `lea + jmp [reg]` indirect branch (no
landed precedent for indirect jumps in this tree — see §3.7),
and complicates the audit of "which byte routes where". YAGNI
for a 5-class router.

### 3.3 Register discipline

`tty_process_input` is a **non-leaf** function that makes up to
3 nested `uart_putc` calls (BS path emits `"\b \b"`) plus
optionally 1 `tty_line_append` call plus optionally 1 BEL
`uart_putc` call. Register discipline:

- **`rbx` — callee-save, holds the routing byte across all
  nested calls.** Pushed at entry, popped at exit. `uart_putc`
  does not touch `rbx` (only `rax, rdx`); neither does
  `tty_line_append` (only `rax, rcx, rdx, r8`). So spilling to
  `rbx` is enough — no other callee-save needed.
- **`rdi` — SysV arg-0 slot for each nested call.** Loaded from
  `rbx` (or immediate) at each `mov rdi, …` site.
- **`rax` — scratch; return value of `tty_line_append` for the
  overflow check.**
- **`rcx, rdx, r8 — clobbered by callees, never read across a
  call.**

Stack alignment: `rsp % 16 == 8` at entry (post-`call`). `push
rbx` makes it `0`, which is the SysV-required alignment for the
nested calls. Symmetric `pop rbx` restores `rsp % 16 == 8` for
the outer `ret`. Same idiom as `core/uart/rx_isr.pdx` prologue.

**Why not spill `rdi` directly and reuse it?** Because we need
`rdi` as a scratch to stage each nested call's argument — the
`mov rdi, imm8` sequences overwrite the byte if it's still in
`rdi`. Spilling to `rbx` (or any callee-save reg) is the
cleanest way.

**Why `rbx` and not `r12`?** Both are legal callee-save.
`rbx` is chosen because it's the first-preference SysV
callee-save (per AMD64 ABI Fig 3.4), matching the idiom in
`core/int/exceptions.pdx` where `rbx` is the first spill slot.

### 3.4 Control flow — pseudocode

```
tty_process_input(byte : u64):
    push rbx
    rbx := byte & 0xFF                    ; stable copy in callee-save

    if rbx == 0x08:  goto backspace       ; BS
    if rbx == 0x7F:  goto backspace       ; DEL
    if rbx == 0x0D:  goto newline         ; CR
    if rbx == 0x0A:  goto newline         ; LF (raw)
    ; fall-through: normal byte

normal:
    uart_putc(rbx)                        ; echo raw
    rax := tty_line_append(rbx)           ; append
    if rax == 1:  goto overflow_bell      ; buffer full
    goto done

newline:
    uart_putc(0x0D)                       ; echo CR
    uart_putc(0x0A)                       ; echo LF
    rax := tty_line_append(0x0A)          ; append LF (translated)
    if rax == 1:  goto overflow_bell
    goto done

backspace:
    rax := _tty_line_head
    if rax == 0:  goto done               ; nothing to erase, no echo
    rax := rax - 1
    _tty_line_head := rax                 ; head--
    uart_putc(0x08)                       ; BS
    uart_putc(0x20)                       ; space
    uart_putc(0x08)                       ; BS
    goto done

overflow_bell:
    uart_putc(0x07)                       ; BEL
    ; fall-through

done:
    pop rbx
    ret
```

Total sequence: **~30 body instructions + 5 labels + 1
prologue push + 1 epilogue pop = ~40 lines in the .pdx block.**

### 3.5 Backspace path — in-line `_tty_line_head` decrement

Load `_tty_line_head`, compare to 0, decrement if non-zero,
store back. Three-instruction burst:

```asm
    mov rax, [rip + _tty_line_head]
    cmp rax, 0
    je  tpi_done                        ; empty — no visual erase, no state change
    sub rax, 1
    mov [rip + _tty_line_head], rax
    ; ... echo "\b \b" ...
```

**Why not a memory-operand `sub qword [rip + _tty_line_head], 1`?**
Two reasons:

1. **Encoder audit.** `sub` with a RIP-relative memory operand is
   a form paideia-as HAS encoded, but audit of `find-paideia-as`
   would require re-verifying the RIP-relative sub form for
   qword. The split load/sub/store form uses three already-audited
   idioms (RIP-relative qword load, register sub imm8,
   RIP-relative qword store — all landed at #596/#604) and adds
   zero encoder novelty.
2. **The empty-buffer check needs the value in a register anyway.**
   The `cmp rax, 0; je tpi_done` short-circuit is trivial with
   the value in `rax`; a memory-operand sub would require an
   additional load-and-compare before the sub, or an unguarded
   sub that could underflow head to `0xFFFFFFFFFFFFFFFF`. The
   split form is the natural shape.

**Why not add a `tty_line_backspace` leaf to `line_buffer.pdx`?**
#604 §3.3 and §6.3 explicitly bless the in-line decrement path:
*"#605's process_input will handle the ASCII 0x08 (BS) / 0x7F
(DEL) byte by directly reading/writing `_tty_line_head` (all
three storage cells are `pub`), OR by adding a
`tty_line_backspace` leaf here in a follow-on issue. YAGNI at
#604."* We take the "directly reading/writing" branch because
the primitive would be trivial (2 non-return instructions) and
have exactly one caller — this issue. Adding a wrapper would
cost 1 call + 1 ret per backspace with zero code-reuse benefit.

If R17+ ever needs backspace-from-userland (say, a `tcflush`
syscall), a wrapper can be added post-hoc and this issue's
in-line decrement rewritten to a `call tty_line_backspace`.

### 3.6 Overflow handling — BEL on `tty_line_append == 1`

Per #604 §3.5 (chosen policy), `tty_line_append` returns 1 when
head == 256 (buffer full), drops the byte, and leaves state
unchanged. #604 §3.5 explicitly hands the bell-emission half of
the tactical-plan-mandated "drop char + bell" policy to this
issue:

> "The tactical-plan-mandated 'bell on overflow' is enforced at
> #605 (`tty_process_input`), which owns TX and can emit BEL
> (0x07) on receiving a `1` return from this primitive."

Implementation: after `call tty_line_append`, `cmp rax, 1; jne
tpi_done`, else `mov rdi, 0x07; call uart_putc`. Two extra
instructions on the accept path (branch not taken), four on the
overflow path (branch + arg + call). Overflow is expected to be
rare on interactive typing (a 256-byte line without ever
pressing Enter is atypical), so the branch-not-taken path is the
hot one.

**Note on the BEL byte itself.** BEL (0x07) is a control code
that most terminals honor by ringing an audible bell (or a
visual bell if the user has set `visualbell`). It does NOT
advance the cursor or affect the display, so it's safe to emit
mid-line without corrupting the echoed line's visual state. This
is exactly the property the tactical plan relies on.

**Alternative rejected: emit BEL only on transitions from
non-full to full.** Would require reading `_tty_line_head` before
the append (to detect the transition), doubling the ram access
per byte. Also — the user only hears one bell either way (the
first overflowed byte triggers it; subsequent overflowed bytes
would each emit BEL but at 115200 baud interactive typing, the
per-byte spacing is so wide that the bells sound like a single
tone). YAGNI.

### 3.7 Alternatives considered — router shape

| Router shape                                             | Rejected because                                                                          |
|----------------------------------------------------------|-------------------------------------------------------------------------------------------|
| **Linear `cmp + je` chain (chosen)**                     | Zero new encoder forms; 4 branches per input worst-case; matches routing conventions used at core/cap/dispatch.pdx and elsewhere. |
| 256-entry jump table `.rodata + jmp [table + rax*8]`     | Requires indirect-jump encoding not yet audited in this tree; adds 2 KiB `.rodata`; wins ~3 cycles per byte at ~2 KiB cost — bad tradeoff. |
| Bitmap classifier (`_router_class[byte>>3] & (1<<(byte&7))`) | Compact but requires bit-shift + AND encoding forms, and still needs a class-dispatcher on top. More novelty than a `cmp` chain for the same eventual effect. |
| Nested `switch`-like structure via computed goto         | Not expressible in paideia-as .pdx syntax at Phase 6; would require a language extension. |

### 3.8 Alternatives considered — echo policy for '\r'

| Policy                                        | Echo emitted for '\r' | Buffer stores | Rejected because                                                                          |
|-----------------------------------------------|-----------------------|---------------|-------------------------------------------------------------------------------------------|
| **Translate CR→LF; echo "\r\n" (chosen)**    | 0x0D, 0x0A            | 0x0A          | Matches POSIX cooked-mode (ICRNL + ECHO + ONLCR). Buffer sees canonical LF; terminal sees canonical newline. |
| Translate CR→LF; echo LF alone                | 0x0A                  | 0x0A          | Cursor moves down but stays in the current column on most terminals — visually broken.    |
| Translate CR→LF; echo CR alone                | 0x0D                  | 0x0A          | Cursor moves to column 0 but stays on current line — visually broken.                     |
| No translation; echo CR verbatim              | 0x0D                  | 0x0D          | Buffer contains CR; reader/consumer must back-translate; violates POSIX line convention.  |
| No translation; echo CR + wait for LF         | 0x0D                  | 0x0D          | Adds state (waiting-for-LF flag); complicates the byte-router; solves a problem nobody has (real terminals send CR alone on Enter). |

**Chosen: translate on input, echo `"\r\n"` on newline.** The
buffer's contract with `#606` (reader) is "\n-terminated lines".
The terminal's visual contract is "\r\n moves cursor to start of
next line". Both are satisfied by the chosen policy.

### 3.9 Alternatives considered — echo-before-append vs. append-before-echo

| Order                                       | Rejected because                                                                          |
|---------------------------------------------|-------------------------------------------------------------------------------------------|
| **Echo first, append second (chosen)**      | Preserves the invariant "the terminal shows what the buffer will show". If append fails (overflow), the user sees the byte they typed AND hears BEL — accurate feedback. |
| Append first, echo second                   | If append fails (overflow), we'd echo the byte the buffer rejected — confusing. Would need to suppress echo on overflow, adding a branch. |
| Echo only after successful append           | Adds a branch on the hot path; visually delays echo by the tty_line_append call time (~10 instructions). Interactive typing feel degrades. |

**Chosen: echo first.** The user always sees the byte they typed;
the bell (if any) confirms the drop. This matches Linux termios
default behavior exactly.

### 3.10 Alternatives considered — 0x7F (DEL) as backspace

| Interpretation of 0x7F                             | Rejected because                                                                          |
|----------------------------------------------------|-------------------------------------------------------------------------------------------|
| **Merge with 0x08 into backspace path (chosen)**   | Empirically necessary: most modern terminals (xterm, macOS Terminal, iTerm2) send 0x7F when the user hits the "Backspace" key on macOS/Linux; only Windows/Putty typically sends 0x08. Cooked mode conventionally accepts both. |
| Treat 0x7F as printable "delete char" glyph        | No real terminal expects to see DEL as a printable character; would leave users unable to erase.  |
| Route to a separate `tpi_delete` handler that clears from cursor to end-of-line | Requires cursor-position tracking (not yet a thing); overengineered.                     |

**Chosen: merge with 0x08.** Two `cmp rbx, 0x08; je tpi_backspace;
cmp rbx, 0x7F; je tpi_backspace` discriminators; both target the
same handler. Matches Linux termios `VERASE` default (which is
0x7F on most systems, 0x08 on some — the kernel accepts both).

### 3.11 File contents (target)

```pdx
// src/kernel/core/tty/process_input.pdx — R16-M5-004 (#605)
// tty_process_input: per-byte cooked-mode router.
//
// For each input byte:
//   - BS (0x08) or DEL (0x7F): decrement _tty_line_head if > 0; emit "\b \b".
//   - CR (0x0D) or LF (0x0A):  translate to LF in buffer; emit "\r\n"; append '\n'.
//   - Anything else:           echo raw; append raw; emit BEL on overflow.
//
// Uses uart_putc (boot/uart.pdx) for TX and tty_line_append (#604) for buffer.
// Directly decrements _tty_line_head on backspace (per #604 §3.3 sanction).
//
// See design/kernel/r16-m5-004-tty-process-input.md for full contract.

module ProcessInput = structure {
  // ==========================================================================
  // tty_process_input(byte) -> ()
  // ==========================================================================
  // Input:  rdi = byte value (low 8 bits used; upper 56 ignored)
  // Output: (none — rax undefined on return)
  //
  // Side effects (per branch):
  //   normal:    uart_putc(byte); tty_line_append(byte); if overflow, uart_putc(0x07)
  //   newline:   uart_putc('\r'); uart_putc('\n'); tty_line_append('\n');
  //              if overflow, uart_putc(0x07)
  //   backspace: if _tty_line_head > 0: _tty_line_head--;
  //                                     uart_putc('\b'); uart_putc(' '); uart_putc('\b')
  //              else: no effect.
  //
  // Clobbers (SysV caller-save): rax, rcx, rdx, r8. Preserves rbx (via push/pop).
  pub let tty_process_input : (u64) -> () !{sysreg, mem} @{} = fn (byte: u64) -> unsafe {
    effects: { sysreg, mem },
    capabilities: { },
    justification: "R16-M5-004 (#605): per-byte cooked-mode router. Routes low-8-bits(rdi) to one of three handlers via linear cmp+je chain: BS (0x08) / DEL (0x7F) -> backspace; CR (0x0D) / LF (0x0A) -> newline; else -> normal. Spills routing byte into callee-save rbx at entry (push rbx makes rsp%16==0 for nested SysV calls; uart_putc clobbers only rax/rdx per boot/uart.pdx:60-70; tty_line_append clobbers rax/rcx/rdx/r8 per line_buffer.pdx:43; rbx survives both). Normal path: uart_putc(rbx) then tty_line_append(rbx); if append returned 1 (overflow, per #604 §3.4 drop-on-overflow policy), emit BEL (0x07) via uart_putc — bell-on-overflow is the #605-owned half per #604 §3.5. Newline path: uart_putc(0x0D) then uart_putc(0x0A) — canonical POSIX cooked-mode ONLCR-style echo — then tty_line_append(0x0A) translating CR/LF to canonical LF (ICRNL); overflow branch identical. Backspace path: mov rax, [rip+_tty_line_head]; cmp rax, 0; je done (empty buffer, nothing to erase, no echo — matches Linux termios ECHOE); else sub rax, 1; mov [rip+_tty_line_head], rax (in-line decrement per #604 §3.3/§6.3 explicit sanction — 3 already-audited encoder idioms, no need for a tty_line_backspace wrapper); then uart_putc(0x08), uart_putc(0x20), uart_putc(0x08) to erase visually. Non-leaf; single push rbx / pop rbx callee-save prologue/epilogue keeps rsp%16==0 across nested calls per SysV. Byte-lane: `and rbx, 0xFF` after the initial `mov rbx, rdi` isolates low 8 bits to guard against upper-bit noise in rdi. No new encoder forms — every mnemonic (RIP-relative qword load/store, cmp reg,imm8, mov reg,reg, mov rdi,imm8, sub reg,1, push/pop rbx, call/ret, je/jne/jmp) has landed precedent (see design §2.3). Called by (a) this issue's witness at R16.M5 to prove routing semantics; (b) the future RX drainer (post-#608 wiring) which will consume bytes from _uart_rx_ring one at a time. Deliberately does NOT: handle Ctrl-D EOF (deferred to #606 — see §1.2); handle Ctrl-C SIGINT (R17+); gate on ECHO/ICRNL/ONLCR termios flags (hardcoded to ~cfmakeraw-inverse); recognize UTF-8 or ANSI escapes (byte-at-a-time); support raw mode (bypasses this routine entirely). Audit: r16-m5-004-tty-process-input.",
    block: {
      push rbx;

      mov rbx, rdi;
      and rbx, 0xFF;

      // ---- Router ----
      cmp rbx, 0x08;
      je  tpi_backspace;
      cmp rbx, 0x7F;
      je  tpi_backspace;
      cmp rbx, 0x0D;
      je  tpi_newline;
      cmp rbx, 0x0A;
      je  tpi_newline;

      // ---- Normal byte: echo, append, bell-if-full ----
      mov rdi, rbx;
      call uart_putc;
      mov rdi, rbx;
      call tty_line_append;
      cmp rax, 1;
      je  tpi_bell;
      jmp tpi_done;

      // ---- Newline: echo "\r\n"; append '\n' ----
    tpi_newline:
      mov rdi, 0x0D;
      call uart_putc;
      mov rdi, 0x0A;
      call uart_putc;
      mov rdi, 0x0A;
      call tty_line_append;
      cmp rax, 1;
      je  tpi_bell;
      jmp tpi_done;

      // ---- Backspace: erase if head > 0 ----
    tpi_backspace:
      mov rax, [rip + _tty_line_head];
      cmp rax, 0;
      je  tpi_done;
      sub rax, 1;
      mov [rip + _tty_line_head], rax;
      mov rdi, 0x08;
      call uart_putc;
      mov rdi, 0x20;
      call uart_putc;
      mov rdi, 0x08;
      call uart_putc;
      jmp tpi_done;

      // ---- Bell on overflow ----
    tpi_bell:
      mov rdi, 0x07;
      call uart_putc;

    tpi_done:
      pop rbx;
      ret
    }
  }
}
```

## 4. Witness placement

### 4.1 Position in `kernel_main.pdx`

Inserted immediately after the R16.M5-003 witness's `_done`
label (`tty_line_witness_done:` at `kernel_main.pdx:4413`) and
before the R14b-m5-002 GS_BASE `wrmsr` block (starts at
`kernel_main.pdx:4417` with `lea rax, [rip + _cpu_locals];`).
This keeps all R16.M5 witnesses contiguous, mirroring the R16.M4
and R16.M3 clusters.

```
      tty_line_witness_done:
          pop r12

      <-- INSERT R16.M5-004 WITNESS HERE (§5 body) -->

      // R14b-m5-002 (#507): IA32_GS_BASE = &_cpu_locals[0] on CPU0.
      lea rax, [rip + _cpu_locals];
      ...
```

No prior witness holds state that #605 reads. The line buffer
is left in the "post-E overflow" state by `tty_line_witness`
(`head=256`, `complete=0`, filled with 'X'). The FIRST action
of the tty_input witness is `call tty_line_reset` — the buffer
is thereby re-armed to `head=0, complete=0` before any routing
sub-test runs. This is deliberate: we exercise the reset primitive
as a de-facto sixth sub-test at zero cost.

### 4.2 No fixture slab needed

Same as #604: the line buffer itself is the fixture. No `.bss`
allocation of our own — we drive routing through the primitive,
observe head/complete/buf via the `pub` storage handles from
`#604`, and use `uart_puts` for OK/FAIL emission.

## 5. Test canary — kernel_main witness block

### 5.1 Sub-test structure — 5 sub-tests

Five sub-tests, each verifying one routing branch. The task-brief
steer enumerated four (A–D); this design adds sub-test E to
cover the overflow-with-bell path that #604 §3.5 hands to this
issue:

- **Sub-test A** (the literal issue AC) — Type "hello\r" (6
  bytes: 'h', 'e', 'l', 'l', 'o', '\r'). After the six calls:
  `_tty_line_head == 6`, `_tty_line_complete == 1`,
  `_tty_line_buf[0..6] == "hello\n"` (byte at [5] MUST be 0x0A
  — the CR→LF translation verified byte-by-byte).
- **Sub-test B** (LF-as-raw-input path) — reset. Feed '\n'
  (0x0A). After the call: `_tty_line_head == 1`,
  `_tty_line_complete == 1`, `_tty_line_buf[0] == 0x0A`.
  Proves the LF branch reaches the same handler as CR (§3.2).
- **Sub-test C** (printable-only path) — reset. Feed 'a', 'b',
  'c'. After 3 calls: `_tty_line_head == 3`,
  `_tty_line_complete == 0`, buffer contains "abc". Proves the
  fall-through normal-byte path does NOT touch the complete flag.
- **Sub-test D** (backspace path) — after sub-test C leaves
  head at 3, feed '\b' (0x08). After the call: `_tty_line_head
  == 2`, complete unchanged. Then feed DEL (0x7F). After:
  `_tty_line_head == 1`. Then feed '\b' again: head==0. Then
  feed '\b' one more time to prove the empty-buffer no-op:
  head still 0.
- **Sub-test E** (overflow-bell path) — reset. Fill 256 bytes
  of 'X' via 256 successive calls (each MUST leave head at
  1..256 with complete=0). Then feed one more 'X'
  (the 257th byte): `_tty_line_head` still 256, complete still
  0. The BEL emission is a UART side-effect not directly
  observable from the witness — see §5.4 for the observation
  strategy — but the state-preservation half is fully
  witnessable.

**Ordering rationale.** A first (proves the primary AC in
isolation from all other paths). B second (proves the sibling
LF path, minimal state). C third (proves the fall-through
normal path). D fourth (composes with C's residual state, then
crosses the empty-buffer boundary). E last (destructively fills
the buffer, so any subsequent witness would fail — this is the
last thing we do).

State discipline: **A resets to prove itself; B resets;
C resets; D composes with C; E resets.** Every sub-test that
needs a clean buffer explicitly calls `tty_line_reset` at its
start; the buffer state at the END of the witness (head=256,
complete=0, filled with 'X') is documented but not reset —
subsequent boot code does not read `_tty_line_buf` at all (per
#604 §1.3 and §3.8, the buffer is TTY-subsystem private).

| After sub-test | `_tty_line_head` | `_tty_line_complete` | Buffer contents            |
|----------------|------------------|----------------------|----------------------------|
| A              | 6                | 1                    | ['h','e','l','l','o','\n', … ] |
| B              | 1                | 1                    | ['\n', … ]                 |
| C              | 3                | 0                    | ['a','b','c', … ]          |
| D              | 0                | 0                    | ['a','b','c', … ] (unchanged; residual per #604 §3.8) |
| E              | 256              | 0                    | ['X' × 256]                |

### 5.2 Witness assembly (complete block)

```asm
; ============================================================
; R16-M5-004 (#605): tty_process_input witness — 5 sub-tests
; ============================================================
tty_input_witness:
    push r12                                 ; callee-save loop counter (sub-test E)

    ; ---------- Sub-test A: type "hello\r" -> buffer "hello\n" ----------
    call tty_line_reset

    mov  rdi, 0x68                          ; 'h'
    call tty_process_input
    mov  rdi, 0x65                          ; 'e'
    call tty_process_input
    mov  rdi, 0x6C                          ; 'l'
    call tty_process_input
    mov  rdi, 0x6C                          ; 'l'
    call tty_process_input
    mov  rdi, 0x6F                          ; 'o'
    call tty_process_input
    mov  rdi, 0x0D                          ; '\r' (Enter)
    call tty_process_input

    ; State assertions
    mov  rax, [rip + _tty_line_head]
    cmp  rax, 6
    jne  tty_input_witness_fail
    call tty_line_available
    cmp  rax, 1
    jne  tty_input_witness_fail

    ; Byte-by-byte buffer verification: "hello\n"
    lea  r12, [rip + _tty_line_buf]
    xor  rax, rax
    mov_b rax, [r12 + 0];  cmp rax, 0x68;  jne tty_input_witness_fail  ; 'h'
    xor  rax, rax
    mov_b rax, [r12 + 1];  cmp rax, 0x65;  jne tty_input_witness_fail  ; 'e'
    xor  rax, rax
    mov_b rax, [r12 + 2];  cmp rax, 0x6C;  jne tty_input_witness_fail  ; 'l'
    xor  rax, rax
    mov_b rax, [r12 + 3];  cmp rax, 0x6C;  jne tty_input_witness_fail  ; 'l'
    xor  rax, rax
    mov_b rax, [r12 + 4];  cmp rax, 0x6F;  jne tty_input_witness_fail  ; 'o'
    xor  rax, rax
    mov_b rax, [r12 + 5];  cmp rax, 0x0A;  jne tty_input_witness_fail  ; '\n' (translated from '\r')

    ; ---------- Sub-test B: LF-as-raw-input ----------
    call tty_line_reset

    mov  rdi, 0x0A                          ; '\n' raw
    call tty_process_input

    mov  rax, [rip + _tty_line_head]
    cmp  rax, 1
    jne  tty_input_witness_fail
    call tty_line_available
    cmp  rax, 1
    jne  tty_input_witness_fail

    xor  rax, rax
    mov_b rax, [r12 + 0]                    ; r12 still holds &_tty_line_buf
    cmp  rax, 0x0A
    jne  tty_input_witness_fail

    ; ---------- Sub-test C: printable-only, no newline ----------
    call tty_line_reset

    mov  rdi, 0x61                          ; 'a'
    call tty_process_input
    mov  rdi, 0x62                          ; 'b'
    call tty_process_input
    mov  rdi, 0x63                          ; 'c'
    call tty_process_input

    mov  rax, [rip + _tty_line_head]
    cmp  rax, 3
    jne  tty_input_witness_fail
    call tty_line_available
    cmp  rax, 0                             ; complete MUST NOT be set
    jne  tty_input_witness_fail

    ; ---------- Sub-test D: backspace (composed with C's head=3) ----------
    mov  rdi, 0x08                          ; BS
    call tty_process_input
    mov  rax, [rip + _tty_line_head]
    cmp  rax, 2
    jne  tty_input_witness_fail

    mov  rdi, 0x7F                          ; DEL (same handler)
    call tty_process_input
    mov  rax, [rip + _tty_line_head]
    cmp  rax, 1
    jne  tty_input_witness_fail

    mov  rdi, 0x08                          ; BS -> head to 0
    call tty_process_input
    mov  rax, [rip + _tty_line_head]
    cmp  rax, 0
    jne  tty_input_witness_fail

    mov  rdi, 0x08                          ; BS on empty -> no-op
    call tty_process_input
    mov  rax, [rip + _tty_line_head]
    cmp  rax, 0
    jne  tty_input_witness_fail

    ; ---------- Sub-test E: overflow-bell path ----------
    call tty_line_reset

    xor  r12, r12                           ; i = 0
  tiw_fill_loop:
    mov  rdi, 0x58                          ; 'X'
    call tty_process_input
    add  r12, 1
    cmp  r12, 256
    jb   tiw_fill_loop

    ; State assertion after fill: head=256, complete=0
    mov  rax, [rip + _tty_line_head]
    cmp  rax, 256
    jne  tty_input_witness_fail
    call tty_line_available
    cmp  rax, 0
    jne  tty_input_witness_fail

    ; 257th byte: tty_line_append returns 1; process_input emits BEL and
    ; leaves state unchanged.
    mov  rdi, 0x59                          ; 'Y' — overflowed byte
    call tty_process_input

    mov  rax, [rip + _tty_line_head]
    cmp  rax, 256
    jne  tty_input_witness_fail
    call tty_line_available
    cmp  rax, 0
    jne  tty_input_witness_fail

    ; ---------- All green ----------
    lea  rdi, [rip + tty_input_ok_msg]
    call uart_puts
    jmp  tty_input_witness_done

tty_input_witness_fail:
    lea  rdi, [rip + tty_input_fail_msg]
    call uart_puts

tty_input_witness_done:
    pop  r12
```

Total: ~130 lines including labels, push/pop, and blank lines.

**Label uniqueness.** All labels prefixed `tiw_` (tty_input
witness) to avoid clashes with `tlw_` (tty_line_witness) and
other witnesses in the same file. Same prefixing discipline as
`urrw_` at #596 §5.6 and `tlw_` at #604 §5.2.

**Callee-save discipline.** `r12` is SysV callee-save; used
here for two purposes at different points in the witness:
- After sub-test A's state assertions, `r12` is loaded with
  `&_tty_line_buf` and reused across sub-tests A, B, and C for
  byte-by-byte inspection.
- In sub-test E, `r12` is re-purposed as the fill-loop counter
  (0..256).

Since `tty_process_input` DOES preserve `rbx` (its only
callee-save use) but does NOT touch `r12`, and neither does
`tty_line_reset` / `tty_line_available` / `uart_puts` (all leaf
or leaf-like), `r12` survives across every call. Single
`push r12` at entry, `pop r12` at exit.

### 5.3 Marker

On all five sub-tests green:

```
R16 TTY INPUT OK
```

Emitted via `uart_puts` on `tty_input_ok_msg`. Fingerprint added
to all three R14B/R15 expected-output files, inserted immediately
after the `R16 TTY LINE OK` line.

### 5.4 What the witness does NOT verify

- **BEL byte on TX.** The witness cannot observe individual TX
  bytes from within the running kernel — `uart_putc` writes to
  the COM1 THR port, and the receiving side (the test harness's
  serial log) is not readable back from inside the kernel at
  witness time. The overflow-preservation half of sub-test E is
  fully witnessable (head/complete unchanged); the BEL emission
  itself is verified indirectly by (a) the code being
  present-in-assembly (auditable) and (b) the fingerprint files'
  `R16 TTY INPUT OK` marker, which only prints when sub-test E's
  state-preservation assertions pass AFTER the BEL-emitting
  call — i.e., the code path that emits BEL is provably reached.
  A future R18+ smoke mode with a TX-loopback fixture could
  observe the raw BEL byte on the wire; deferred as §6.6.
- **Terminal cursor position after "\b \b".** Same reason: no
  readback of TX. The three-byte erase sequence is provably
  emitted (auditable in the disassembly + the fingerprint
  proves the code path was reached).
- **Echo of the entire "hello\r" sequence on the wire.** Same
  reason. The `boot_r16_tty` end-to-end mode at #609 will
  observe echoed bytes on the harness's serial log.

### 5.5 String data — `tools/boot_stub.S`

Append after the R16.M5-003 witness strings (currently at lines
784-792):

```asm
# R16-M5-004 (#605): tty_process_input witness success message
.global tty_input_ok_msg
.align 8
tty_input_ok_msg: .ascii "R16 TTY INPUT OK\n\0"

# R16-M5-004 (#605): tty_process_input witness failure message
.global tty_input_fail_msg
.align 8
tty_input_fail_msg: .ascii "R16 TTY INPUT FAIL\n\0"
```

Zero other rodata changes. No per-sub-test failure messages —
same discipline as R16.M5-003 (§5.4 of #604) and R16.M4-002
(§5.8 of #596).

### 5.6 Fingerprint files — marker insertion

Insert `R16 TTY INPUT OK` in three files:

| File                                        | Insert after            | Insert before          |
|---------------------------------------------|-------------------------|------------------------|
| `tests/r14b/expected-boot-r14b-loader.txt`  | `R16 TTY LINE OK`       | `LOADER OK`            |
| `tests/r15/expected-boot-r15-ring3.txt`     | `R16 TTY LINE OK`       | `R15 IDLE TASK OK`     |
| `tests/r15/expected-boot-r15-process.txt`   | `R16 TTY LINE OK`       | `R15 IDLE TASK OK`     |

Contains-in-order matching (per `tools/run-smoke.sh`) makes the
addition strictly additive — no earlier line reorders. All 5-mode
smoke stages that do not observe R16 markers (`boot_r8_only`,
`boot_r10`, `boot_r11`, `boot_r12`, `boot_r12_denial`) stay
byte-identically green.

## 6. Alternatives considered / follow-ups

### 6.1 Combine with #606 (`tty_read_blocking`) in one PR

**Rejected.** #606 exercises the reader side — copy `_tty_line_buf`
into user buf, call `tty_line_reset`, and wire the KIND_NOTIFICATION
block-wake path. Landing them together would double the witness
scope (would need to prove BOTH the byte-router AND the reader
end-to-end), require an EOF flag design that's not yet needed,
and blur bisect surface. Splitting matches every prior R16
subsystem's issue cadence.

### 6.2 Emit BEL only on transitions from non-full to full

Rejected in §3.6. Would double per-byte ram access; user only
hears one bell either way at interactive typing rates.

### 6.3 Add a `tty_line_backspace()` leaf to `#604`'s file

Deferred in §3.5 per #604's own §3.3/§6.3 blessing of in-line
decrement. If R17+ needs backspace-from-userland (e.g., a
`tcflush` syscall), add the wrapper then and rewrite this issue's
in-line decrement to a `call tty_line_backspace`.

### 6.4 Ctrl-D (0x04) EOF handling

Deferred to #606. Requires an EOF flag alongside
`_tty_line_complete` and reader-side special handling ("if
head==0 AND eof, return 0 from read"). Filed as a follow-up
issue after R16.M5 closes; the eventual patch touches this file
(add a `cmp rbx, 0x04; je tpi_eof` discriminator + tpi_eof
handler that sets an EOF flag).

### 6.5 Line-editing keys (kill-line 0x15, word-erase 0x17,
reprint 0x12)

Deferred as separate follow-up issues, one per feature. Each
adds a router discriminator + handler. Kill-line requires
resetting head to 0 without touching complete; word-erase
requires walking back over non-whitespace then whitespace;
reprint requires re-emitting `_tty_line_buf[0..head]` to TX.
None are R16.M5 AC.

### 6.6 TX loopback witness for BEL / echo bytes

Requires a hardware/QEMU-loopback fixture that reads back TX
bytes from a second serial port or shared memory. Deferred to
R18+ when the shell subsystem adds a serial harness.

### 6.7 The RX drainer (call site for `tty_process_input`)

Not yet a landed issue. The drainer will:
1. Be a kernel thread (or a bottom-half of the ISR wake path).
2. Call `uart_rx_notify_set_waiter(self)`.
3. Call `sched_block` (releases cli, sleeps).
4. On wake: loop `uart_rx_dequeue` until DEQUEUE_EMPTY.
5. For each byte: `tty_process_input(byte)`.
6. Go back to step 2.

This composes #600's wake path with this issue's router. Filed
as a §Subsystem 15 follow-up (likely between #608 and #609).

### 6.8 `pub` visibility of `tty_process_input`

Marked `pub` to admit the (future) drainer as a caller. At R16.M5-004
the only caller is the witness, but marking it `pub` today avoids
a `pub` re-toggle when the drainer lands. Same discipline as
`uart_rx_enqueue` / `uart_rx_dequeue` at #596.

### 6.9 Per-tty routing at R18+ multi-tty

At R18+ the router becomes `tty_process_input(tty_idx, byte)` —
the byte's line buffer is `_tty_line_bufs[tty_idx]` per #603 §3.6.
The routing logic itself does not change. Migration path is
mechanical: append a `tty_idx` argument, index the storage
accesses. This issue's shape preserves the R18+ path.

## 7. Discipline check

- **5-mode smoke.** `boot_r8_only`, `boot_r10`, `boot_r11`,
  `boot_r12`, `boot_r12_denial` all stay byte-identical — none
  of them observe R16 markers, and the additive fingerprint
  changes are contains-in-order matched.
- **No stub / placeholder.** Every branch is fully implemented
  and witnessed. BEL emission is real (`uart_putc(0x07)`), not
  a stub. Backspace is real (in-line decrement + three
  `uart_putc` calls). CR→LF translation is real (writes 0x0A
  to buffer via `tty_line_append(0x0A)`).
- **Cross-repo escalation.** Not needed — §2.3 confirms zero
  encoder gap.
- **Autonomous loop.** Continue to #606 (`tty_read_blocking`)
  after landing.

## 8. Landing checklist

- [ ] `src/kernel/core/tty/process_input.pdx` — new file with
      the module contents at §3.11.
- [ ] `tools/boot_stub.S` — append the two `tty_input_*_msg`
      rodata entries per §5.5.
- [ ] `src/kernel/boot/kernel_main.pdx` — insert the witness
      block at §5.2 immediately after `tty_line_witness_done:`
      at line 4413.
- [ ] `tests/r14b/expected-boot-r14b-loader.txt` — insert
      `R16 TTY INPUT OK` after `R16 TTY LINE OK`.
- [ ] `tests/r15/expected-boot-r15-ring3.txt` — same.
- [ ] `tests/r15/expected-boot-r15-process.txt` — same.
- [ ] `tools/run-smoke.sh` — run 5-mode smoke; expect all
      green with the new marker present in three fingerprints.
- [ ] Commit message: `Implement #605: tty_process_input — cooked-mode byte router (echo + append + \r→\n + backspace + BEL)`.
