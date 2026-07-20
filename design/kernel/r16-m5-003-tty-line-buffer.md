---
issue: 604
milestone: R16.M5 (TTY / cooked line discipline)
subsystem: 15 — TTY / cooked line discipline
topic: tty_line_buffer — 256-byte single-line accumulator (head + complete flag) + tty_line_append / tty_line_reset / tty_line_available leaf functions
prereq:
  - "#602 (R16.M5-001 tty_init — LANDED; publishes _tty0. Not a functional dependency for this issue's storage or primitives — the line buffer is subsystem-scoped, not per-vnode — but confirms the src/kernel/core/tty/ directory exists and establishes naming conventions this issue follows.)"
  - "#603 (R16.M5-002 tty_vops-table — LANDED; §3.6 documents the R18+ migration path from a subsystem-scoped singleton line buffer to an array indexed by tty_idx. This issue's naming (_tty_line_buf, not _tty0_line_buf) preserves that migration path — see §3.1.1 for the deviation-from-task-brief argument.)"
  - "#596 (R16.M4-002 uart_rx_ring — LANDED; structural precedent for a .bss byte slab + monotonic-counter cursor + leaf enqueue primitive. Every mnemonic used here has proven precedent in rx_ring.pdx.)"
blocks:
  - "#605 (r15-m5-004 tty_process_input — the sole real producer into this line buffer; per-byte drains from _uart_rx_ring, calls tty_line_append (this issue), adds echo + backspace + \\r→\\n handling on top. Also owns the 'bell on overflow' policy — see §3.5.)"
  - "#606 (r15-m5-005 tty_read_blocking — REPLACES the minimal tty_read body shipped at #603. The extended body will (a) call tty_line_available (this issue); (b) if 1, memcpy from _tty_line_buf[0..head] into user buf; (c) call tty_line_reset (this issue). Vops slot pointer at _tty_vops[+0] stays stable across #603 → #606; only tty_read's body grows.)"
  - "#608 (r15-m5-007 connect-tty-to-init-fd012 — assigns _tty0 idx into init's fd_table[0/1/2]; every sys_read from init eventually reaches _tty_line_buf via the #606-extended tty_read.)"
  - "#609 (r15-m5-008 R16.M5 CLOSER smoke — end-to-end line-discipline exercise where the ISR (#597) feeds bytes into _uart_rx_ring, process_input (#605) drains them into this line buffer, and sys_read (#606) copies out. This issue's witness proves the buffer's own semantics in isolation before the composed flow is exercised.)"
touching:
  - src/kernel/core/tty/line_buffer.pdx                     (new file — ~85 LOC incl. justifications)
  - src/kernel/boot/kernel_main.pdx                         (witness block after tty_vops_witness_done at line 4309; ~70 LOC)
  - tools/boot_stub.S                                       (2 rodata additions: tty_line_ok_msg, tty_line_fail_msg)
  - tests/r14b/expected-boot-r14b-loader.txt                (marker: `R16 TTY LINE OK`)
  - tests/r15/expected-boot-r15-ring3.txt                   (marker)
  - tests/r15/expected-boot-r15-process.txt                 (marker)
  - design/kernel/r16-m5-003-tty-line-buffer.md             (this doc)
related:
  - design/kernel/r16-m5-001-tty-vnode-alloc.md             (#602 — establishes core/tty/ directory + module-per-file convention)
  - design/kernel/r16-m5-002-tty-vops-table.md              (#603 — §3.6 documents the R18+ multi-tty migration; this issue's naming preserves it. Also §1.3 catalogs the #604 deferral: "No line buffer allocation. _tty_line_buf is #604's concern.")
  - design/kernel/r16-m4-002-uart-rx-ring.md                (#596 — structural template: .bss slab + counter + leaf primitives + monotonic-counter empty/full semantics. This doc reuses the encoder-precedent table and register-discipline pattern verbatim.)
  - src/kernel/core/uart/rx_ring.pdx                        (#596 — landed module whose byte-narrow store idiom (mov_b [r10+0], rax) and RIP-relative counter load (mov rax, [rip + _sym]) this issue reuses.)
  - src/kernel/core/tty/read.pdx                            (#603 — the minimal tty_read that #606 will extend to consume this line buffer)
  - design/milestones/r14b-tactical-plan.md                 §Subsystem 15 line 1593, item 3 (this issue's plan pointer)
---

# R16-M5-003 — `tty_line_buffer`: 256-byte single-line accumulator + append/reset/available (#604)

## 1. Scope

Land the third R16.M5 subsystem-15 issue: a bounded static 256-byte
byte buffer in `.bss` plus a monotonic write cursor (`_tty_line_head`)
and a boolean complete-line flag (`_tty_line_complete`), together with
three leaf functions that populate, reset, and query the accumulator.
This is a **data-structure** issue, not a driver issue — no UART port
touched, no ISR wired, no vops table modified. It hands #605 a
validated single-line accumulator to drain the RX ring into, and hands
#606 a signal (`tty_line_available`) to gate the blocking read.

```
tty_line_append(byte: u64) -> u64
    input:  rdi = byte value in low 8 bits (upper 56 bits ignored)
    output: rax = 0 on success (byte accepted)
    output: rax = 1 if buffer full (head >= 256) — byte dropped
    side effect (success): _tty_line_buf[head] = byte;
                           _tty_line_head += 1;
                           if byte == '\n' (0x0A): _tty_line_complete = 1
    side effect (full):   none (byte discarded)

tty_line_reset() -> u64
    input:  (none)
    output: rax = 0 (always)
    side effect: _tty_line_head = 0; _tty_line_complete = 0

tty_line_available() -> u64
    input:  (none)
    output: rax = 1 if complete line ready; rax = 0 otherwise
    side effect: none (pure read of _tty_line_complete)
```

Acceptance (issue AC, literally): "line buffer populated by ISR feed."
See §1.1 for the reconciliation — the ISR feed path is composed at
#605, not #604; the structural equivalent proved here is that the
buffer primitives round-trip byte-by-byte through the exact sequence
that #605's per-byte drain will invoke.

### 1.1 Reconciling with the formal acceptance criterion

The tactical plan's stated AC (`design/milestones/r14b-tactical-plan.md`
§Subsystem 15 item 3) is:

> **AC: line buffer populated by ISR feed.**

**This AC cannot be literally met at #604 without also landing
#605 (`tty_process_input`) and #597's ISR notification path.**
Specifically:

1. **The ISR (`uart_rx_isr`, #597, LANDED) writes bytes into
   `_uart_rx_ring`, not into `_tty_line_buf`.** The ISR knows about
   the ring; it does not know about the line buffer. That's by
   design: SPSC ring belongs to the UART subsystem; line buffer
   belongs to the TTY subsystem.
2. **`_uart_rx_ring` → `_tty_line_buf` per-byte drain is #605's
   concern (`tty_process_input`).** Per the tactical plan §Subsystem
   15 item 4, #605 owns the byte-by-byte drain that composes:
   `uart_rx_dequeue()` → `tty_line_append()` + echo TX + \r→\n
   translation + backspace handling + bell on overflow. Without
   #605, no code path drains the ring into the line buffer.
3. **The notification cap that wakes the drainer is #600
   (`uart_rx_notification_cap`, LANDED).** #605's drainer will run
   from a kernel thread that blocks on this cap and wakes per RX
   byte batch.

**The structural equivalent — accepted here — is the five-sub-test
witness at §5**, which proves the buffer's semantics end-to-end for
the exact sequence #605's ISR-feed drainer will invoke:

| Formal AC guarantee                                    | Structural sub-test that proves the same thing at R16.M5                                                      |
|--------------------------------------------------------|--------------------------------------------------------------------------------------------------------------|
| Bytes fed one at a time land in `_tty_line_buf`        | Sub-test B: append 'a','b','c' → head=3; the byte-by-byte call sequence is exactly what #605 will invoke     |
| `\n` transitions the buffer to complete-line state     | Sub-test C: append '\n' → complete=1; tty_line_available() returns 1                                          |
| The buffer can be re-armed for the next line           | Sub-test D: tty_line_reset → head=0, complete=0; subsequent appends behave like sub-test B                    |
| Overflow does not corrupt state                        | Sub-test E: 256-byte fill without \n leaves complete=0, head=256; 257th append returns 1 without state change |

The literal AC ("populated by ISR feed") is deferred to #605's
witness, which will inject bytes into `_uart_rx_ring` via
`uart_rx_enqueue` (already the mechanism used by #596's own witness)
and observe them appear in `_tty_line_buf` via `tty_line_available` +
direct buffer inspection. Per the R16.M5 subsystem discipline, all
downstream issues reach the buffer through direct kernel handles —
none go through the actual IRQ path at R16.M5 witness time — so the
deferred literal AC does NOT block subsystem closure.

### 1.2 What this issue proves

- **A single-line accumulator with byte-narrow writes composes with
  the current encoder surface.** Every mnemonic used has landed
  precedent in `core/uart/rx_ring.pdx` (#596) and `core/fs/path.pdx`
  (#573). Zero encoder gap — see §2.3.
- **`.bss` zero-init is the correct initial state.** `_tty_line_head`
  and `_tty_line_complete` both start at 0, so the buffer starts
  empty (head=0) with complete=0 (no line ready). No init function
  required; the buffer is live at kernel_main entry.
- **Monotonic-counter head + boolean complete-flag semantics are
  viable.** Head is a bounded u64 counter (0..256, saturating at
  256 on overflow). Complete is a u64 flag (0 or 1). Both counters
  are written by exactly one party (the drainer/appender) and read
  by exactly one other party (the reader / tty_line_available
  caller), preserving the SPSC discipline that #596 established for
  the RX ring.
- **Overflow policy is decouple-able from the appender.** This
  issue's `tty_line_append` reports overflow via `rax=1` and drops
  the byte with no state change. The tactical-plan-mandated "bell
  on overflow" is enforced at #605 (`tty_process_input`), which
  owns TX and can emit BEL (0x07) on receiving a `1` return from
  this primitive.

### 1.3 What this issue deliberately does NOT do

- **No UART / ISR interaction.** #597's ISR (LANDED) writes into
  `_uart_rx_ring`, not this buffer. This issue is pure `.bss`
  storage + three leaf primitives.
- **No process_input / echo / backspace / \r→\n translation.**
  #605's concern. This buffer accepts bytes verbatim; \n triggers
  the complete flag; every other byte is stored as-is. Backspace
  handling (which requires decrementing head) is a separate
  primitive that #605 may implement as either a direct
  `_tty_line_head`-decrementer or a new `tty_line_backspace` leaf
  in this same file (deferred).
- **No `!{sysreg}` or `!{io}` effects.** Both primitives operate
  purely on `.bss` memory. Effect set is `{mem}`, matching the
  precedent set by `_uart_rx_ring`'s enqueue/dequeue.
- **No cooked/raw mode toggle.** All appends assume cooked mode at
  R16.M5 (the only mode). A future raw-mode primitive would either
  bypass this buffer entirely (read directly from `_uart_rx_ring`)
  or add a `tty_line_raw_append` variant. Either way, no cross-cutting
  concern at #604.
- **No refcount / lock / barrier.** Same SPSC-under-cli discipline
  as `_uart_rx_ring`; R17 SMP tier will add barriers if needed.
- **No `_tty_line_tail` cursor.** The buffer is a single-line
  accumulator, not a ring. When the reader consumes a complete
  line, it copies the entire `[0..head)` range out and calls
  `tty_line_reset` — there is no partial-consume semantics. See §3.3
  for the design argument against a tail cursor.
- **No `tty_line_backspace()` primitive.** #605's process_input
  will handle the ASCII 0x08 (BS) / 0x7F (DEL) byte by directly
  reading/writing `_tty_line_head` (all three storage cells are
  `pub`), OR by adding a `tty_line_backspace` leaf here in a
  follow-on issue. YAGNI at #604; the append/reset/available trio
  is the minimum viable API for the "populate by ISR feed" AC.
- **No re-entrancy guard.** Single-CPU boot / IRQ-off consumer;
  same argument as `_uart_rx_ring`.

## 2. Prereq check

### 2.1 What is in place

| Primitive / symbol         | Location                                              | Contract used                                                                                                             |
|----------------------------|-------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------|
| `core/tty/` directory      | `src/kernel/core/tty/` (#602)                         | Established by #602; this issue adds `line_buffer.pdx` as a sibling.                                                       |
| `.bss` byte slab           | `core/uart/rx_ring.pdx:_uart_rx_ring` (#596)          | `pub let mut _uart_rx_ring : [u8; 256] = uninit @align(8)` — exact structural precedent.                                   |
| `.bss` scalar u64          | `core/uart/rx_ring.pdx:_uart_rx_head` (#596)          | `pub let mut _uart_rx_head : u64 = 0` — exact precedent.                                                                   |
| RIP-relative qword load    | `core/uart/rx_ring.pdx:533` (#596)                    | `mov rcx, [rip + _uart_rx_head]` — used verbatim.                                                                          |
| RIP-relative qword store   | `core/uart/rx_ring.pdx:554` (#596)                    | `mov [rip + _uart_rx_head], rcx` — used verbatim.                                                                          |
| Byte-narrow store          | `core/fs/path.pdx:141` / `core/uart/rx_ring.pdx:550`  | `mov_b [r10 + 0], rax` — writes low 8 bits of rax to a memory byte.                                                        |
| Byte-narrow load           | `core/fs/path.pdx:74` / `core/uart/rx_ring.pdx:602`   | `xor rax; mov_b rax, [r10 + 0]` — zero-extending byte load.                                                                |
| `and reg, 0xFF`            | `core/uart/rx_ring.pdx:544` (#596)                    | Byte-mask a register.                                                                                                      |
| `cmp reg, 256`             | `core/uart/rx_ring.pdx:539` (#596)                    | Compare against a value that exceeds imm8 range.                                                                           |
| `sub reg, reg` / `add reg, imm8` | Ubiquitous.                                     | Standard AMD64 arithmetic.                                                                                                 |
| Direct `call sym` / `ret`  | Ubiquitous.                                            | Leaf-function invocation without prologue.                                                                                 |
| `jae` / `jne` / `jmp`      | Ubiquitous.                                            | Conditional/unconditional branches.                                                                                        |

### 2.2 What is NOT in place

- **`_tty_line_buf`, `_tty_line_head`, `_tty_line_complete` symbols.**
  Introduced by this module. All three go into `.bss`; all three
  zero-init.
- **`tty_line_append`, `tty_line_reset`, `tty_line_available`
  symbols.** Introduced by this module.
- **`tty_line_ok_msg` / `tty_line_fail_msg` symbols in `boot_stub.S`.**
  Added alongside the R16.M5-002 witness strings at approximately
  lines 775-782 of `tools/boot_stub.S`.

### 2.3 Encoder gaps

**None.** Every mnemonic used has landed precedent, itself audited
at #596 §2.3:

| Mnemonic form                          | Proven at                                                       |
|----------------------------------------|-----------------------------------------------------------------|
| `mov rax, [rip + _sym]`                | `core/uart/rx_ring.pdx:533`; `core/sched/wake_block.pdx:41`.    |
| `mov [rip + _sym], rax`                | `core/uart/rx_ring.pdx:554`; `core/syscall/entry.pdx:29`.       |
| `lea rax, [rip + _sym]`                | Ubiquitous (`_current_tcb`, `_uart_rx_ring`, etc.).             |
| `add rax, rcx` (reg,reg)               | `core/uart/rx_ring.pdx:546` (base + offset).                    |
| `add rax, 1` (reg,imm8)                | Ubiquitous (path.pdx pointer bumps, rx_ring head advance).      |
| `sub rax, rcx` (reg,reg)               | `core/uart/rx_ring.pdx:539`.                                    |
| `and rax, 0xFF`                        | `core/uart/rx_ring.pdx:544`; `core/int/tss.pdx:121`.            |
| `cmp rax, 256`                         | `core/uart/rx_ring.pdx:539`.                                    |
| `cmp rax, 0x0A` / `cmp rax, imm8`      | Ubiquitous.                                                     |
| `je` / `jne` / `jae` / `jmp`           | Ubiquitous.                                                     |
| `xor rax, rax`                         | Ubiquitous.                                                     |
| `mov rax, imm8`                        | Ubiquitous (`mov rax, 1` for boolean-flag write).               |
| `mov_b [reg + 0], rax` (byte store)    | `core/uart/rx_ring.pdx:550`; `core/fs/path.pdx:141`.            |
| `mov_b rax, [reg + 0]` (byte load)     | `core/uart/rx_ring.pdx:602`; `core/fs/path.pdx:74`.             |
| `call sym` (direct)                    | Ubiquitous.                                                     |
| `ret`                                  | Ubiquitous.                                                     |

No REX.B on extended base regs beyond r8..r10 (all proven at
rx_ring.pdx). No SIB. No SSE/AVX. **Cross-repo escalation not
needed.**

## 3. Design

### 3.1 File and module structure

New file: `src/kernel/core/tty/line_buffer.pdx`. Sits alongside the
four modules landed at R16.M5-001/002:

```
src/kernel/core/tty/
    init.pdx        (#602, LANDED)
    vops.pdx        (#603, LANDED)
    read.pdx        (#603, LANDED — minimal; extended at #606)
    write.pdx       (#603, LANDED — minimal; extended at #607)
    line_buffer.pdx <-- THIS ISSUE (#604) — _tty_line_buf + 3 leaf primitives
    process_input.pdx (#605 — future; drains _uart_rx_ring into _tty_line_buf)
```

Module name: `LineBuffer`. Public exports:
- Storage: `_tty_line_buf`, `_tty_line_head`, `_tty_line_complete`
  (all three `pub` so #605 can poke them directly for backspace
  handling, so a future debug snapshot routine can inspect state,
  and so the witness in kernel_main.pdx can verify state
  post-append).
- Functions: `tty_line_append`, `tty_line_reset`,
  `tty_line_available`.
- Constants: `LINE_BUF_BYTES`, `LINE_APPEND_OK`, `LINE_APPEND_FULL`,
  `LINE_NEWLINE_BYTE`, `LINE_AVAILABLE_YES`, `LINE_AVAILABLE_NO`.

#### 3.1.1 Symbol-name deviation from the task-brief steer

**The task brief specifies `_tty0_line_buf`, `_tty0_line_head`,
`_tty0_line_complete`. This design uses `_tty_line_buf`,
`_tty_line_head`, `_tty_line_complete` (subsystem-scoped, not
instance-scoped).**

Justification for the deviation:

1. **Preserves the R18+ multi-tty migration path documented at
   `#603 §3.6`.** That doc commits to "Extend `_tty_line_buf` to
   an array indexed by tty_idx" when multi-tty lands. Naming the
   storage `_tty0_line_buf` at #604 would either (a) require a
   rename at R18+ (breaking every existing consumer's symbol
   reference), or (b) force the multi-tty extension to introduce a
   new symbol family (`_tty_line_bufs[]`) and leave `_tty0_line_buf`
   as a dead outlier.
2. **Matches the `_tty_vops` naming already landed at #603.**
   `_tty_vops` is subsystem-scoped even though at R16.M5 there is
   only one TTY. The line buffer follows the same discipline —
   subsystem-scoped storage that happens to be dimensioned for
   exactly one instance at R16.M5.
3. **The `_tty0` handle IS instance-scoped.** `_tty0` (a u64 slot
   holding the vnode idx) IS the one and only instance-scoped
   symbol in the TTY subsystem. Naming the line buffer with a
   `_tty0_` prefix would falsely suggest per-instance scope where
   the multi-tty migration will re-scope it.

Deviation is documented explicitly here so downstream reviewers
and #605's implementer do not restage the task-brief typo.

#### 3.1.2 Field-type deviation from the task-brief steer

**The task brief specifies `_tty0_line_complete : u8`. This design
uses `_tty_line_complete : u64`.**

Justification:

1. **Matches `_uart_rx_head` / `_uart_rx_tail` (both u64) and
   `_tty0` (u64) — the SPSC-family storage convention.** Every
   .bss scalar in the R16.M4/M5 storage layer is u64. The complete
   flag is one more scalar; u64 keeps the convention uniform.
2. **Encoder cost is neutral.** `mov [rip + _tty_line_complete],
   rax` is one instruction whether the destination is u8 or u64.
   `mov rax, [rip + _tty_line_complete]` (u64 load) requires one
   fewer instruction than the u8-load idiom
   (`xor rax; mov_b rax, [rip + _tty_line_complete]`) — the u64
   variant self-zero-extends by width.
3. **No storage-density argument at .bss scale.** Saving 7 bytes
   on a u8 (vs u64) is meaningless in a kernel where the RX ring
   alone is 272 bytes and the line buffer is 256 bytes.

`_tty_line_head` naturally follows the same u64 convention (it's
a bounded counter, not a boolean, but u64 is the family type).

### 3.2 Storage layout (.bss)

```
_tty_line_buf      : [u8; 256] = uninit @align(8)   // 256 B — the line accumulator
                                                     //   @align(8) enables future
                                                     //   qword-copy drains (memcpy
                                                     //   into user buf at #606)
_tty_line_head     : u64 = 0                         //   8 B — write cursor (0..256)
                                                     //   saturates at 256 on overflow
_tty_line_complete : u64 = 0                         //   8 B — 0 = pending, 1 = ready
```

Total: 272 B in `.bss`. Same total as `_uart_rx_ring` +
`_uart_rx_head` + `_uart_rx_tail` (256 + 8 + 8 = 272 B) — the
storage-footprint symmetry is coincidental but a useful landmark
during .bss layout inspection.

`.bss` zero-init guarantees `head = complete = 0` at kernel
entry, which is precisely the "empty, no line ready" state.
No `_tty_line_init` function is needed — the zero state is the
correct start state. Same discipline as `_uart_rx_ring` (§6.7
of #596's doc).

**Symbol visibility.** All three are `pub let mut`. The `mut`
attribute is essential — append writes to head + buf[head]; append
may write to complete; reset writes to head + complete.

### 3.3 Why no `_tty_line_tail` cursor (contrast with `_uart_rx_ring`)

`_uart_rx_ring` has head AND tail because bytes stream in
asynchronously (ISR) and out asynchronously (sys_read); the
consumer may drain some but not all bytes at each wake.

`_tty_line_buf` is different: it holds **at most one complete
line** at a time. When the reader (`tty_read` at #606) sees
`tty_line_available() == 1`, it copies ALL of `_tty_line_buf[0..
head)` into the user buffer and immediately calls
`tty_line_reset()` — no partial-line consumption. A tail cursor
would be dead storage.

**Corollary**: `_tty_line_head` is bounded 0..256, not
monotonic-unbounded. The RX ring's `head - tail >= 256` full check
works because head is unbounded and (head - tail) is the pending
byte count; here, `head` IS the pending byte count directly, and
the full check is `head >= 256`.

### 3.4 Overflow / complete-line state semantics

**Chosen strategy: drop excess bytes on overflow; do NOT
auto-terminate.**

- `head < 256, byte != '\n'`: byte accepted; head += 1; complete stays 0.
- `head < 256, byte == '\n'`: byte accepted; head += 1; complete = 1.
- `head >= 256, any byte`: byte dropped; head unchanged; complete unchanged; return 1.

**State machine**:

```
    (empty)              append (any byte b, b != '\n')              (accumulating, k bytes)
    head=0,complete=0  ────────────────────────────────────────────► head=k, complete=0
       ▲                                                                   │
       │                                                                   │
       │ reset                                            append (b == '\n', head < 256)
       │                                                                   │
       │                                                                   ▼
    (empty)                                                       (complete-line, k+1 bytes)
    head=0,complete=0  ◄────────────────────────────────────────  head=k+1, complete=1
                                    reset
```

Additional edge: `(accumulating, head=256)` (overflow-pending).
Reachable if 256 bytes appended without \n. Escape paths:
- `append(any b)` → returns 1, stays in same state (byte dropped).
- `reset()` → returns to empty.
- **Not reachable via `append('\n')` from head=256** — the \n
  is dropped like any other byte because full check runs BEFORE
  the \n-check. See §3.5 sub-choice discussion for the alternative
  we rejected.

### 3.5 Alternatives considered — overflow policy

| Strategy                                                | Buffer post-overflow           | Reader can consume? | Rejection rationale                                                                 |
|---------------------------------------------------------|--------------------------------|---------------------|-------------------------------------------------------------------------------------|
| **Drop excess (chosen)**                                | head=256, complete=0           | No — reader waits   | Matches tactical plan §A "drop char + bell"; simplest primitive semantics.          |
| Auto-terminate at 256 (force complete=1 at head==256)   | head=256, complete=1           | Yes, truncated line | Silently corrupts the last byte with an implicit \n the user didn't type; hostile.  |
| Reserve slot 255 for terminator (max 255 real bytes)    | head=255 or 256, complete=0/1  | Yes if \n arrives   | Complicates the append body (special-case when head==255 && byte=='\n'); YAGNI.     |
| Accept \n even when head==256 (special case)            | head=256, complete=1 (no store)| Yes, no \n in buffer| Reader would then see head=256 with complete=1 but buffer's byte at [255] is not \n.|

**Chosen: drop excess.** Rationale:

1. **Tactical plan §Subsystem 15 A Failure Modes**: "Line buffer
   overflow → drop char + bell." The `drop char` half is enforced
   here (return 1, no state mutation). The `bell` half is layered
   at #605 which owns TX and can emit BEL (0x07) on receiving `1`
   from this primitive.
2. **Cleanest semantic contract for the primitive.** `append`
   either accepts a byte verbatim or rejects it. No silent
   promotion of a non-\n byte to line-terminator. No implicit
   truncation.
3. **Composable with any future backspace primitive.** If the
   user types 300 bytes (dropping 44), then hits backspace, the
   backspace can decrement head from 256 to 255 — recovering
   room for new appends. If the buffer had auto-terminated, the
   backspace would need to also clear the complete flag, adding
   coupling between the two state cells.

### 3.6 Register discipline

All three functions are **leaf**. No nested calls. No callee-save
reg touched. No prologue, no epilogue. Only caller-save scratch:
`rax, rcx, rdx, r8, r9, r10`. `rdi` is read-only in
`tty_line_append` (passed-in byte).

Stack alignment is irrelevant to leaves that dispatch nothing —
`rsp % 16 == 8` at entry (post-call SysV state), the leaf runs
without touching `rsp`, and `ret` restores `rsp % 16 == 0` in the
caller. Same argument as #596 §3.6.

### 3.7 `tty_line_append` — body

```asm
; ================================================================
; tty_line_append(byte: u64) -> u64
;   rdi = byte value (low 8 bits used, upper 56 ignored)
;   rax = 0 (LINE_APPEND_OK) on success
;   rax = 1 (LINE_APPEND_FULL) if head >= 256
;
;   Effects: {mem}   Capabilities: {}
;   Leaf. No prologue. Callers must treat rcx, rdx, r8, r9, r10,
;   rax as clobbered (SysV caller-save discipline).
; ================================================================
tty_line_append:
    ; --- Load head ---
    mov rcx, [rip + _tty_line_head]     ; rcx = head

    ; --- Full check: head >= 256 ---
    cmp rcx, 256                        ; LINE_BUF_BYTES
    jae line_append_full

    ; --- Compute slot address: &buf[head] ---
    lea r8, [rip + _tty_line_buf]       ; r8 = buffer base
    add r8, rcx                         ; r8 = &buf[head]

    ; --- Store byte (low 8 bits of rdi) ---
    mov rax, rdi                        ; stage byte into rax so
                                        ;   mov_b [r8+0], rax idiom
                                        ;   applies verbatim
    mov_b [r8 + 0], rax                 ; buf[head] = byte

    ; --- Advance head ---
    add rcx, 1
    mov [rip + _tty_line_head], rcx

    ; --- Check if byte was '\n' (0x0A) -> set complete flag ---
    mov rdx, rdi
    and rdx, 0xFF                       ; isolate low 8 bits
    cmp rdx, 0x0A                       ; LINE_NEWLINE_BYTE
    jne line_append_ok

    mov rax, 1                          ; LINE_AVAILABLE_YES
    mov [rip + _tty_line_complete], rax ; complete = 1

line_append_ok:
    xor rax, rax                        ; return LINE_APPEND_OK (0)
    ret

line_append_full:
    mov rax, 1                          ; return LINE_APPEND_FULL (1)
    ret
```

**Instruction count**: ~17 body + `ret` × 2. Single branch besides
the full-check and the \n-check. No nested call.

**Byte-lane discipline**. Same as `uart_rx_enqueue`: `mov_b [r8+0],
rax` writes AL; upper 56 bits of `rdi` are ignored by the encoding
and by the contract.

**Complete-flag write is idempotent-on-repeat.** If the caller
appends multiple \n bytes (e.g., pressing Enter twice), the second
\n sees `complete` already 1 and re-writes it to 1 — no observable
change. This matches the "cooked-mode returns a single line at a
time" contract; if the reader is slow, subsequent \n bytes are
still counted into head and preserved in the buffer, allowing #606
to see everything the user typed once it wakes.

### 3.8 `tty_line_reset` — body

```asm
; ================================================================
; tty_line_reset() -> u64
;   (no input)
;   rax = 0 (always)
;
;   Side effect: _tty_line_head = 0; _tty_line_complete = 0.
;
;   Effects: {mem}   Capabilities: {}
;   Leaf. No prologue. Clobbers rax only.
; ================================================================
tty_line_reset:
    xor rax, rax
    mov [rip + _tty_line_head], rax
    mov [rip + _tty_line_complete], rax
    ret
```

**Instruction count**: 4. Buffer contents (`_tty_line_buf[0..256]`)
are **not** cleared — they remain as the previous line's bytes.
This is safe because `head` (now 0) bounds any future read to
`buf[0..0)` = empty; no consumer inspects bytes past `head`.
Not clearing saves 256 byte-writes on every line reset (a real
cost for interactive typing).

**Alternative considered**: clear the buffer via a 32-byte-aligned
qword-store loop. Rejected on the grounds that (a) no known
consumer requires zero-init between lines; (b) the byte-lane
security concern (residual data from prior lines leaking) does
not apply at R16.M5 because there is exactly one reader (init),
one writer (the drainer), and the buffer is kernel-only — no
cross-process leak vector.

### 3.9 `tty_line_available` — body

```asm
; ================================================================
; tty_line_available() -> u64
;   (no input)
;   rax = 1 (LINE_AVAILABLE_YES) if _tty_line_complete == 1
;   rax = 0 (LINE_AVAILABLE_NO)  otherwise
;
;   Side effect: none (pure read).
;
;   Effects: {mem}   Capabilities: {}
;   Leaf. No prologue. Clobbers rax only.
; ================================================================
tty_line_available:
    mov rax, [rip + _tty_line_complete]
    ret
```

**Instruction count**: 2. The primitive is essentially a getter
for `_tty_line_complete`. Wrapping in a function (rather than
inlining `mov rax, [rip + _tty_line_complete]` at each call site)
is chosen because:

1. **Future-proofs the semantics.** When #606 lands blocking
   read + notification, `tty_line_available` may extend to include
   a Ctrl-D EOF check (returns 1 also if EOF was seen). Callers
   that used the raw load would need to be rewritten; callers
   that use the function inherit the new semantics.
2. **Symbol export at the primitive layer.** The function's
   symbol is a natural extension point; the raw storage is
   `pub` for debug reasons but is not the intended consumer API.
3. **Multi-tty migration path.** At R18+, this becomes
   `tty_line_available(tty_idx)`; inlined call sites would have
   to be rewritten. Function form takes the argument change once,
   at the primitive definition.

Cost of the wrapper: one `call` instruction per query in the
caller, one `ret` in the callee. Negligible compared to the
downstream reader's copy-out.

### 3.10 File contents (target)

```pdx
// src/kernel/core/tty/line_buffer.pdx — R16-M5-003 (#604)
// tty_line_buffer: static 256-byte single-line accumulator + head + complete flag.
//
// Three leaf functions:
//   tty_line_append(byte):  appends byte if head < 256; sets complete on '\n'.
//   tty_line_reset():       zeroes head and complete; leaves buffer content.
//   tty_line_available():   returns 1 if a complete line is ready.
//
// Storage: _tty_line_buf [u8;256] (@align 8) + _tty_line_head u64 + _tty_line_complete u64.
// .bss zero-init: head=0, complete=0 — the correct empty state, so no init call.
//
// See design/kernel/r16-m5-003-tty-line-buffer.md for full contract.

module LineBuffer = structure {
  // === Constants ===
  pub let LINE_BUF_BYTES     : u64 = 256
  pub let LINE_APPEND_OK     : u64 = 0
  pub let LINE_APPEND_FULL   : u64 = 1
  pub let LINE_NEWLINE_BYTE  : u64 = 0x0A         // '\n'
  pub let LINE_AVAILABLE_YES : u64 = 1
  pub let LINE_AVAILABLE_NO  : u64 = 0

  // === Storage (.bss slab + two u64 scalars) ===
  pub let mut _tty_line_buf      : [u8; 256] = uninit @align(8)
  pub let mut _tty_line_head     : u64 = 0     // write cursor (0..256)
  pub let mut _tty_line_complete : u64 = 0     // 0 = pending, 1 = complete

  // ==========================================================================
  // tty_line_append(byte) -> u64
  // ==========================================================================
  // Input:  rdi = byte value (low 8 bits used; upper 56 ignored)
  // Output: rax = 0 (LINE_APPEND_OK)   on success (byte accepted)
  //         rax = 1 (LINE_APPEND_FULL) if head >= 256 (byte dropped)
  //
  // Side effects (success):
  //   _tty_line_buf[head] = byte
  //   _tty_line_head     += 1
  //   if byte == '\n':  _tty_line_complete = 1
  //
  // Side effects (full): none.
  //
  // Clobbers (SysV caller-save):  rax, rcx, rdx, r8.
  pub let tty_line_append : (u64) -> u64 !{mem} @{} = fn (byte: u64) -> unsafe {
    effects: {mem},
    capabilities: {},
    justification: "R16-M5-003 (#604): appends one byte to the 256-byte single-line accumulator. Reads _tty_line_head; if >= 256 (LINE_BUF_BYTES) returns 1 (LINE_APPEND_FULL) with no state change (drop-on-overflow policy per design doc §3.5; bell handling is layered at #605). Otherwise computes &_tty_line_buf[head] via `lea + add`, stores the low 8 bits of the passed byte via `mov_b [r8+0], rax` (byte-narrow store idiom frozen at core/uart/rx_ring.pdx:550), advances head, and checks if the stored byte was '\\n' (0x0A / LINE_NEWLINE_BYTE) — if so, writes 1 to _tty_line_complete. Returns 0 (LINE_APPEND_OK). Leaf function; no prologue; caller-save-only clobbers (rax, rcx, rdx, r8). Called only by (a) this issue's witness at R16.M5 to prove primitive semantics; (b) #605's tty_process_input drainer (post-#605-landing) which composes this call with echo/backspace/\\r→\\n/bell handling. .bss zero-init gives head=0, complete=0 at kernel entry, so the very first call sees an empty buffer — matches sub-test A which relies on this exact initial state. Complete-flag write is idempotent on repeated \\n (second \\n re-writes 1 to 1 — no observable change). Byte-lane: mov_b writes AL, upper 56 bits of rdi discarded per encoding, matching the low-8-bits-used contract. Audit: r16-m5-003-tty-line-buffer.",
    block: {
      mov rcx, [rip + _tty_line_head];
      cmp rcx, 256;
      jae line_append_full;

      lea r8, [rip + _tty_line_buf];
      add r8, rcx;

      mov rax, rdi;
      mov_b [r8 + 0], rax;

      add rcx, 1;
      mov [rip + _tty_line_head], rcx;

      mov rdx, rdi;
      and rdx, 0xFF;
      cmp rdx, 0x0A;
      jne line_append_ok;

      mov rax, 1;
      mov [rip + _tty_line_complete], rax;

    line_append_ok:
      xor rax, rax;
      ret;

    line_append_full:
      mov rax, 1;
      ret
    }
  }

  // ==========================================================================
  // tty_line_reset() -> u64
  // ==========================================================================
  // Input:  (none)
  // Output: rax = 0 (always)
  //
  // Side effect: _tty_line_head = 0; _tty_line_complete = 0.
  //              Buffer content (_tty_line_buf[0..256]) is NOT cleared —
  //              subsequent reads are bounded by head=0, so residual bytes
  //              are unreachable. See design doc §3.8.
  //
  // Clobbers: rax only.
  pub let tty_line_reset : () -> u64 !{mem} @{} = fn () -> unsafe {
    effects: {mem},
    capabilities: {},
    justification: "R16-M5-003 (#604): resets the line buffer's cursor and completion state. Zeros _tty_line_head and _tty_line_complete via a single `xor rax; mov [rip+_tty_line_head], rax; mov [rip+_tty_line_complete], rax` sequence. Does NOT clear _tty_line_buf[0..256] content — subsequent appends will overwrite as head advances from 0, and subsequent reads are bounded by head=0 (empty range), so residual bytes are unreachable. Saves 256 byte-writes per line reset for interactive typing. Leaf function; no prologue; 4 instructions total. Callers: (a) #606's tty_read_blocking after copy-out of a complete line into the user buffer; (b) this issue's witness sub-test D to prove the reset path. Audit: r16-m5-003-tty-line-buffer.",
    block: {
      xor rax, rax;
      mov [rip + _tty_line_head], rax;
      mov [rip + _tty_line_complete], rax;
      ret
    }
  }

  // ==========================================================================
  // tty_line_available() -> u64
  // ==========================================================================
  // Input:  (none)
  // Output: rax = 1 (LINE_AVAILABLE_YES) if _tty_line_complete == 1
  //         rax = 0 (LINE_AVAILABLE_NO)  otherwise
  //
  // Side effect: none (pure read).
  //
  // Clobbers: rax only.
  pub let tty_line_available : () -> u64 !{mem} @{} = fn () -> unsafe {
    effects: {mem},
    capabilities: {},
    justification: "R16-M5-003 (#604): returns 1 if a complete line is ready for consumption, 0 otherwise. Pure read of _tty_line_complete via `mov rax, [rip+_tty_line_complete]; ret` — 2 instructions. Wrapped in a function (rather than inlined at call sites) to future-proof semantics: at #606 this may extend to also include Ctrl-D EOF handling, and at R18+ this becomes tty_line_available(tty_idx). Leaf; no prologue; clobbers rax only. Callers: (a) #606's tty_read_blocking to gate the blocking wait; (b) this issue's witness (sub-tests A, C) to observe post-append state. Audit: r16-m5-003-tty-line-buffer.",
    block: {
      mov rax, [rip + _tty_line_complete];
      ret
    }
  }
}
```

## 4. Witness placement

### 4.1 Position in kernel_main.pdx

Inserted after the R16.M5-002 witness `_done` label
(`tty_vops_witness_done:` at `kernel_main.pdx:4309`), and before
the R14b-m5-002 GS_BASE `wrmsr` block (currently at line 4311).
The insertion is structurally independent — no data flow into or
out of any preceding witness, no data flow into the wrmsr /
process_init block that follows.

```
      tty_vops_witness_done:
          pop r12

      <-- INSERT R16.M5-003 WITNESS HERE (§5 body) -->

      // R14b-m5-002 (#507): IA32_GS_BASE = &_cpu_locals[0] on CPU0.
      lea rax, [rip + _cpu_locals];
      ...
```

If a follow-on R16.M5 amendment slips in between #603 and #604,
the insertion point moves to the actual last-landed R16.M5
witness's `_done:` label. No prior witness holds state that #604
reads.

### 4.2 No fixture slab needed

Unlike the vnode / vops witnesses that need scratch vnodes or
scratch vops tables, this witness needs no `.bss` allocation of
its own. The line buffer itself is the fixture. `.bss` zero-init
ensures `head=0, complete=0` at witness entry, which is precisely
the state sub-test A requires. Same pattern as the R16.M4-002
uart_rx_ring witness (§4.2 of #596).

## 5. Test canary — kernel_main witness block

### 5.1 Sub-test structure — 5 sub-tests

Five sub-tests, each verifying one axis of the primitive contract.
The task-brief steer enumerated exactly these five; the letter
mapping below matches:

- **Sub-test A** — Fresh state: `_tty_line_head == 0` AND
  `tty_line_available() == 0`. Proves .bss zero-init contract.
- **Sub-test B** — Append 'a','b','c' (no \n): after 3 calls,
  `_tty_line_head == 3` AND `tty_line_available() == 0`. Proves
  the byte-accumulating path without the complete-flag transition.
- **Sub-test C** — Append '\n': after the 4th call,
  `_tty_line_head == 4` AND `tty_line_available() == 1`. Proves
  the \n → complete=1 transition and that head continues to
  advance past the \n (i.e., \n is stored in the buffer, not
  swallowed).
- **Sub-test D** — `tty_line_reset()`: after the call,
  `_tty_line_head == 0` AND `tty_line_available() == 0`. Proves
  both cells zeroed in one atomic call.
- **Sub-test E** — Overflow: 256 successive appends (all 'X',
  0x58, no \n) leave `_tty_line_head == 256` AND
  `tty_line_available() == 0`; the 257th append returns 1 with
  no state change (head still 256, complete still 0). Proves
  drop-on-overflow policy AND that overflow does not spuriously
  set complete.

**Ordering rationale.** A first (probes trivial state, no
mutation). B second (proves the single-byte-accumulate lifecycle
without triggering complete). C third (proves complete transition
while composed with prior state — head at 3, not 0). D fourth
(proves reset from a non-trivial state). E last (proves overflow
from a re-armed state — after D, buffer is empty and reset; E
fills to capacity and probes both the boundary and beyond).

State discipline across sub-tests: **A/B/C compose serially with
no reset; D explicitly resets between C and E; E starts from a
reset state**. Documenting the composed head values:

| After sub-test | `_tty_line_head` | `_tty_line_complete` | Buffer contents            |
|----------------|------------------|----------------------|----------------------------|
| A (probe only) | 0                | 0                    | (all zero)                 |
| B              | 3                | 0                    | ['a','b','c',0,0,...]      |
| C              | 4                | 1                    | ['a','b','c','\n',0,0,...] |
| D              | 0                | 0                    | ['a','b','c','\n',0,0,...] (unchanged; residual — see §3.8) |
| E fill         | 256              | 0                    | ['X' × 256] (overwrites residual) |
| E overflow probe | 256            | 0                    | (unchanged from fill)      |

### 5.2 Witness assembly (complete block)

```asm
; ============================================================
; R16-M5-003 (#604): tty_line_buffer witness — 5 sub-tests
; ============================================================
tty_line_witness:
    push r12                                 ; callee-save loop counter (sub-test E)

    ; ---------- Sub-test A: fresh state ----------
    mov  rax, [rip + _tty_line_head]
    cmp  rax, 0
    jne  tty_line_witness_fail
    call tty_line_available
    cmp  rax, 0
    jne  tty_line_witness_fail

    ; ---------- Sub-test B: append 'a','b','c' -> head=3, complete=0 ----------
    mov  rdi, 0x61                          ; 'a'
    call tty_line_append
    cmp  rax, 0
    jne  tty_line_witness_fail
    mov  rdi, 0x62                          ; 'b'
    call tty_line_append
    cmp  rax, 0
    jne  tty_line_witness_fail
    mov  rdi, 0x63                          ; 'c'
    call tty_line_append
    cmp  rax, 0
    jne  tty_line_witness_fail

    mov  rax, [rip + _tty_line_head]
    cmp  rax, 3
    jne  tty_line_witness_fail
    call tty_line_available
    cmp  rax, 0
    jne  tty_line_witness_fail

    ; ---------- Sub-test C: append '\n' -> head=4, complete=1 ----------
    mov  rdi, 0x0A                          ; '\n'
    call tty_line_append
    cmp  rax, 0
    jne  tty_line_witness_fail

    mov  rax, [rip + _tty_line_head]
    cmp  rax, 4
    jne  tty_line_witness_fail
    call tty_line_available
    cmp  rax, 1
    jne  tty_line_witness_fail

    ; ---------- Sub-test D: reset -> head=0, complete=0 ----------
    call tty_line_reset
    cmp  rax, 0                             ; reset returns 0
    jne  tty_line_witness_fail

    mov  rax, [rip + _tty_line_head]
    cmp  rax, 0
    jne  tty_line_witness_fail
    call tty_line_available
    cmp  rax, 0
    jne  tty_line_witness_fail

    ; ---------- Sub-test E: overflow -> fill 256 'X', 257th returns 1 ----------
    xor r12, r12                             ; i = 0
  tlw_fill_loop:
    mov rdi, 0x58                            ; 'X'
    call tty_line_append
    cmp rax, 0                               ; each of the 256 must succeed
    jne tty_line_witness_fail
    add r12, 1
    cmp r12, 256
    jb  tlw_fill_loop

    ; State check: head == 256, complete == 0 (no \n was fed)
    mov  rax, [rip + _tty_line_head]
    cmp  rax, 256
    jne  tty_line_witness_fail
    call tty_line_available
    cmp  rax, 0
    jne  tty_line_witness_fail

    ; 257th append: must return 1 (LINE_APPEND_FULL) with no state change
    mov  rdi, 0x59                           ; 'Y' — a would-be overflow byte
    call tty_line_append
    cmp  rax, 1
    jne  tty_line_witness_fail

    ; Verify state is unchanged post-overflow
    mov  rax, [rip + _tty_line_head]
    cmp  rax, 256
    jne  tty_line_witness_fail
    call tty_line_available
    cmp  rax, 0
    jne  tty_line_witness_fail

    ; ---------- All green ----------
    lea  rdi, [rip + tty_line_ok_msg]
    call uart_puts
    jmp  tty_line_witness_done

tty_line_witness_fail:
    lea  rdi, [rip + tty_line_fail_msg]
    call uart_puts

tty_line_witness_done:
    pop  r12
```

Total: ~85 lines including labels, push/pop, and blank lines.

**Register discipline.** `r12` (callee-save) carries the loop
counter for sub-test E across the nested `tty_line_append` calls.
Since all three primitives declare caller-save-only clobbers (§3.6),
`r12` is preserved implicitly. `push r12` at witness entry and
`pop r12` at exit keep `rsp % 16 == 0` for all nested calls
(`tty_line_*`, `uart_puts`). Same pattern as the R16.M4-002 witness
at kernel_main.pdx:816-885.

**Label uniqueness.** All labels prefixed `tlw_` (tty_line
witness) to avoid clashes with other witnesses in the same file
that use generic names like `fill_loop`. Same prefixing discipline
as `urrw_` at #596 §5.6.

### 5.3 Marker

On all five sub-tests green:

```
R16 TTY LINE OK
```

Emitted via `uart_puts` on `tty_line_ok_msg`. Fingerprint added to
all three R14B/R15 expected-output files, inserted immediately
after the `R16 TTY VOPS OK` line and before the `LOADER OK` /
`R15 IDLE TASK OK` line.

### 5.4 String data — `tools/boot_stub.S`

Append after the R16.M5-002 witness strings (currently
`tty_vops_ok_msg` / `tty_vops_fail_msg` at approximately lines
775-782):

```asm
# R16-M5-003 (#604): tty_line_buffer witness success message
.global tty_line_ok_msg
.align 8
tty_line_ok_msg: .ascii "R16 TTY LINE OK\n\0"

# R16-M5-003 (#604): tty_line_buffer witness failure message
.global tty_line_fail_msg
.align 8
tty_line_fail_msg: .ascii "R16 TTY LINE FAIL\n\0"
```

No other rodata changes. No per-sub-test failure messages — same
discipline as R16.M4-002 (§5.8 of #596).

### 5.5 Fingerprint files — marker insertion

Insert `R16 TTY LINE OK` in three files:

| File                                        | Insert after            | Insert before          |
|---------------------------------------------|-------------------------|------------------------|
| `tests/r14b/expected-boot-r14b-loader.txt`  | `R16 TTY VOPS OK`       | `LOADER OK`            |
| `tests/r15/expected-boot-r15-ring3.txt`     | `R16 TTY VOPS OK`       | `R15 IDLE TASK OK`     |
| `tests/r15/expected-boot-r15-process.txt`   | `R16 TTY VOPS OK`       | `R15 IDLE TASK OK`     |

Contains-in-order matching (per `tools/run-smoke.sh`) makes the
addition strictly additive — no earlier line reorders. All 5-mode
smoke stages that do not observe R16 markers (`boot_r8_only`,
`boot_r10`, `boot_r11`, `boot_r12`, `boot_r12_denial`) stay
byte-identically green.

## 6. Alternatives considered / follow-ups

### 6.1 Combine with #605 (`tty_process_input`) in one PR

**Rejected.** #605 composes echo + backspace + \r→\n + bell +
this issue's append primitive; landing them together would balloon
the witness (which must exercise TX loopback for echo verification)
and blur the "primitive-alone-works" property this issue proves.
Splitting matches the R16.M4 pattern (#596 alone for the ring;
#597 separate for the ISR that fills it).

### 6.2 Buffer size 128 or 512 instead of 256

**Rejected.** The tactical plan §Subsystem 15 A explicitly pins
"Line buffer is 256 chars per TTY." 128 would truncate long
paste operations (a full 80-column terminal line + trailing
metadata easily exceeds 128); 512 doubles .bss for no
demonstrated benefit at R16.M5. 256 is also the maximum POSIX
`_POSIX_MAX_CANON` value (which most systems set at 255) — the
one-byte overshoot allows `_POSIX_MAX_CANON` bytes + \n to fit.

### 6.3 Add a `tty_line_backspace()` primitive here

**Deferred to #605.** Backspace handling requires:
- Detect ASCII 0x08 (BS) or 0x7F (DEL) at input time.
- Emit `\b \b` to TX to visually erase the character.
- Decrement `_tty_line_head` if head > 0.

All three concerns compose above the append primitive; the
decrement of `_tty_line_head` is a one-instruction operation
(`sub qword [rip + _tty_line_head], 1`) that #605 can do inline
without a wrapper. If a wrapper turns out to be desirable (e.g.,
for R18+ multi-tty), it can be added to this file post-hoc as a
new leaf, reusing the same file's storage.

### 6.4 Add a `tty_line_count()` primitive returning head

**Rejected.** `_tty_line_head` is `pub`, so any caller can read it
via `mov rax, [rip + _tty_line_head]` — a 1-instruction inline
that a wrapper would triple in cost. Also, at R16.M5, only #606
needs the count (to memcpy from `[0..head)`) and it already knows
the storage-symbol name.

### 6.5 Auto-terminate at head==256 (force complete=1 on overflow)

**Rejected.** See §3.5 table. Silently corrupts the last byte
with an implicit \n; hostile UX. Also, complete-flag semantics
would become ambiguous (complete=1 might mean "user pressed \n"
or "line auto-terminated" — the reader can't distinguish).

### 6.6 Clear `_tty_line_buf` in `tty_line_reset`

**Rejected.** See §3.8. 256 byte-writes per interactive line
reset is a real cost; no known consumer requires zero-init; no
security leak vector (kernel-only buffer). If R17+ ships a
security policy that requires kernel-buffer zeroing between
consumers, this decision would be revisited.

### 6.7 Emit `R16 TTY LINE OK` from within `tty_line_append`

**Rejected.** Same discipline as every other R16 primitive: leaf
functions are silent, witnesses emit. Keeps `tty_line_append`
reusable by non-witness callers (#605's drainer will call it
hundreds of times per second; printing on each call would flood
the console).

### 6.8 Use `u8` for `_tty_line_complete`

**Rejected.** See §3.1.2. u64 matches the RX-ring / _tty0 storage
convention; encoder cost is neutral; storage-density argument
does not apply at .bss scale.

### 6.9 Store `_tty_line_complete` as a bit in the same u64 as `_tty_line_head`

**Rejected.** Would save 8 bytes of .bss for a real cost in
primitive complexity: every write to head or complete would need
a read-modify-write with bit masking (violating the SPSC
single-writer-per-cell discipline). The two fields' writers are
disjoint in the composed system (drainer writes head; drainer
writes complete only on \n; reset writes both), and packing
them would force append's \n-branch to also touch head's bits.
Two separate cells keep the transitions clean.

## 7. Invariants

### 7.1 `_tty_line_head` is bounded 0..256

- **Base case**: .bss zero-init gives `_tty_line_head = 0`.
- **Append**: head += 1 only if `head < 256` (unsigned). So the
  post-increment value is at most 256.
- **Reset**: head := 0 unconditionally.
- **Implication**: `_tty_line_head` never exceeds 256, so
  `&_tty_line_buf[head]` for head ∈ [0, 255] is always in-bounds
  (writes never touch head==256 because the full-check rejects).

### 7.2 `_tty_line_complete ∈ {0, 1}`

- **Base case**: .bss zero-init gives 0.
- **Append (non-\n path)**: does not touch complete.
- **Append (\n path)**: writes 1.
- **Reset**: writes 0.
- **Implication**: complete is a strict boolean; no primitive
  writes any other value.

### 7.3 `_tty_line_complete == 1` implies `_tty_line_head >= 1`

- Complete transitions 0→1 only on the \n path of append, which
  runs AFTER `_tty_line_head += 1`. So at the moment complete
  becomes 1, head is already ≥ 1.
- Reset zeros both simultaneously, preserving the implication
  (0 → 0 is trivially true).
- **Not directly asserted by the witness** — sub-test C observes
  complete=1 and head=4 jointly, which is stronger than the
  implication requires (head ≥ 1).

### 7.4 The buffer contains exactly `_tty_line_head` valid bytes

- Append writes buf[head] before incrementing head, so after
  append the byte just written is at buf[new_head - 1].
- Reset zeros head, making the "valid range" empty regardless of
  buf's residual content (§3.8).
- **Implication**: any reader (`#606's tty_read`) can safely
  copy `_tty_line_buf[0..head)` into a user buffer of size ≥ head;
  bytes at [head..256) are unspecified.

### 7.5 SPSC (Single-Producer / Single-Consumer) discipline

- **Producer**: at #605 landing, `tty_process_input` (a kernel
  thread that wakes on RX notification) is the sole writer of
  head, complete, and buf[head]. At this issue's witness alone,
  the witness thread is the sole writer (no interrupt path is
  active for the line buffer at boot).
- **Consumer**: at #606 landing, `tty_read` (called from init's
  sys_read path) is the sole reader that consumes state and
  triggers reset. At this issue's witness alone, the witness
  thread is both writer and reader (sequentially).
- **Barrier discipline**: none at R16.M4 (UP; consumer runs with
  cli). R17 SMP tier will need `lfence` before the complete-load
  in `tty_line_available` and `sfence` before the complete-store
  in `tty_line_append`'s \n branch. Deferred per the R17 SMP
  master-plan gate; same argument as #596 §7.4.

### 7.6 `.bss` zero-init assumption

Same as every R14/R15/R16 witness: `.bss` is loader-zeroed at
kernel entry. Sub-test A of this issue is the earliest observer
in the boot fingerprint that reads `_tty_line_head` and
`_tty_line_complete` directly; a regression in `.bss` handling
would surface here (and at ~a dozen other witnesses first).

## 8. Cross-cutting risks

- **Sub-test C's post-\n head value must be 4, not 3.** The append
  increments head BEFORE checking for \n, so the \n byte is stored
  in the buffer AND head advances to 4. Any implementation that
  swaps the order (check \n first, then increment head only for
  non-\n) would produce head=3 after the \n and would fail sub-test
  C's `cmp rax, 4`. The reference body §3.7 places `add rcx, 1;
  mov [rip+_tty_line_head], rcx` BEFORE the \n-check for exactly
  this reason.
- **Sub-test E's post-fill head must be exactly 256.** The loop
  runs 256 iterations (r12 from 0 to 255 inclusive via `cmp r12,
  256; jb`), each of which advances head by 1. Off-by-one in the
  loop bound (`cmp r12, 255` instead of `256`) would fill only 255
  bytes and sub-test E would fail its state check. Also verified:
  the 257th call finds head==256 which triggers the full path via
  `cmp rcx, 256; jae line_append_full`.
- **The complete flag's u64 storage.** If a future amendment
  narrows `_tty_line_complete` to u8 (e.g., to match the task-brief
  literal), the load in `tty_line_available` must change from
  `mov rax, [rip + _tty_line_complete]` to
  `xor rax; mov_b rax, [rip + _tty_line_complete]` to preserve
  the zero-extension contract. Not planned; documented as a
  cross-cutting risk for future maintainers.
- **The `pub` visibility of storage cells.** #605 is expected to
  read/write `_tty_line_head` directly (for backspace handling)
  and possibly `_tty_line_buf[head-1]` (to observe the last
  byte for echo). If a future security review tightens visibility
  to module-private, the append/reset/available API surface must
  be extended with `tty_line_backspace()` and `tty_line_last_byte()`
  primitives. Deferred.
- **Marker line insertion vs. `R16 TTY VOPS OK`.** The prior
  fingerprint line is `R16 TTY VOPS OK\n`, the next is
  `LOADER OK\n` (r14b) or `R15 IDLE TASK OK\n` (r15). Inserting
  `R16 TTY LINE OK\n` between them is strictly additive under
  contains-in-order matching; no earlier or later line reorders.
- **5-mode smoke independence.** `boot_r8_only`, `boot_r10`,
  `boot_r11`, `boot_r12`, `boot_r12_denial` do not observe R16
  markers; their fingerprints stay byte-identically green.

## 9. LOC estimate

| File                                                        | LOC        |
|-------------------------------------------------------------|------------|
| `src/kernel/core/tty/line_buffer.pdx` (new)                 | ~85        |
|   - Module boilerplate + 6 constants                        |  ~15       |
|   - 3 storage decls with comments                           |   ~7       |
|   - `tty_line_append` (17 body instructions + justification)|  ~40       |
|   - `tty_line_reset` (4 instructions + justification)       |  ~12       |
|   - `tty_line_available` (2 instructions + justification)   |  ~11       |
| `src/kernel/boot/kernel_main.pdx` (witness block)           | ~85        |
|   - Comment banner                                          |   ~4       |
|   - Sub-test A (fresh state, 2 checks)                      |   ~8       |
|   - Sub-test B (3 appends + 2 state checks)                 |  ~18       |
|   - Sub-test C (1 append + 2 state checks)                  |   ~9       |
|   - Sub-test D (1 reset call + 2 state checks)              |   ~9       |
|   - Sub-test E (256-fill loop + full-probe + state checks)  |  ~24       |
|   - fail/success labels + marker emit + push/pop r12        |  ~13       |
| `tools/boot_stub.S` (2 messages)                            |  ~10       |
| 3 expected-output fingerprint files (1 marker each)         |   ~3       |
| `design/kernel/r16-m5-003-tty-line-buffer.md` (this doc)    | (this)     |
| **Total executable / testing / test-data**                  | **~183**   |

Executable code path: ~85 LOC. Witness + fingerprint: ~98 LOC.
Slightly larger than #602's ~116 LOC because there are three
primitives (vs one) and the witness has 5 sub-tests (vs 3), but
smaller than #603's ~248 LOC because there are no adapters, no
cross-file wire step, and no `[u64; 7]` populator.

## 10. Tractability

**HIGH — small R16 issue, one .bss-plus-leaf-primitives pattern,
five mechanically-structured sub-tests.**

- **Zero paideia-as encoder gap.** Every mnemonic proven at
  `core/uart/rx_ring.pdx` (#596) and `core/fs/path.pdx` (#573).
  Both patterns landed and stable.
- **Three leaf primitives**, all under 20 instructions, all
  caller-save-only. No nested calls. Register discipline is the
  simplest available (no push/pop needed inside the primitives).
- **Five sub-tests** with mechanical structure: A/D/E probe
  storage cells directly via `mov rax, [rip + _sym]; cmp`; B/C
  compose the append call with post-state probes. No fixture
  allocation, no scratch structure.
- **Marker line is contains-in-order** — strictly additive to
  fingerprints; no reordering risk.
- **No cross-repo escalation risk.**
- **Sizing (~183 LOC total)** is comparable to R16.M4-002
  (~272 LOC — that one had 4 sub-tests but included a 256-byte
  fill-loop with pointer-identity checks per slot, more
  book-keeping).
- **The literal AC ("populated by ISR feed") is deferred to #605
  per §1.1.** The structural equivalent (5-sub-test witness that
  proves the byte-by-byte call sequence #605 will invoke) is
  accepted here.

Estimated implementation time: **~50 minutes of a workerbee
session** (comparable to #602: three new symbols and five
sub-tests, no cross-repo work).

Estimated risk of regressing an existing smoke mode:
**near-zero** — purely additive (one new file, one new witness
block, one new emit line, two new rodata strings, one new marker
line in three fingerprint files, zero modifications to any
previously-landed source or witness).

**Known follow-ups (do NOT block #604's landing)**:

- **#605 (`tty_process_input`)** — the sole real producer into
  this line buffer. Composes: dequeue from `_uart_rx_ring`;
  \r→\n translation; backspace handling (direct write to
  `_tty_line_head` OR new `tty_line_backspace` leaf); echo to
  TX; bell (0x07) on `tty_line_append`'s `1` return; \n handling
  is already inside `tty_line_append` itself.
- **#606 (`tty_read_blocking`)** — replaces the minimal `tty_read`
  body shipped at #603. Extended body: `tty_line_available` gate;
  block on notification cap if 0; memcpy from `_tty_line_buf[0..
  _tty_line_head)` into user buf; `tty_line_reset`. Vops slot
  pointer at `_tty_vops[+0]` stays stable — only the body of
  `tty_read` in `read.pdx` grows.
- **#607 (`tty_write_nl_cr`)** — orthogonal to this issue;
  extends `tty_write` for output-side \n→\r\n translation. No
  interaction with the line buffer (which is input-side only).
- **#608 (`connect-tty-to-init-fd012`)** — assigns `_tty0` idx to
  `task[1].fd_table[0/1/2]`. This issue's buffer becomes reachable
  from init via that fd wire.
- **#609 (R16.M5 CLOSER smoke)** — end-to-end line discipline
  round-trip through the fully-wired stack: ISR → ring →
  process_input → line_buffer → sys_read → user buf.

## 11. References

- Issue: paideia-os#604
- Milestone: paideia-os R16.M5 (TTY / cooked line discipline)
- Prereq issues: #602 (tty_init — LANDED; establishes core/tty/
  directory), #603 (tty_vops-table — LANDED; commits to
  `_tty_line_buf` naming convention in §3.6), #596
  (uart_rx_ring — LANDED; structural template for .bss slab +
  counter + leaf primitives)
- Blocks: #605..#609 (subsystem 15 tail)
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 15 line 1593, item 3
- Prior-art body pattern: `src/kernel/core/uart/rx_ring.pdx`
  (`uart_rx_enqueue` — the byte-narrow store idiom + counter
  advance used here for `tty_line_append`)
- Prior-art witness pattern: `src/kernel/boot/kernel_main.pdx`
  §uart_rx_ring_witness (§5.6 of #596's doc — the loop counter
  in r12, per-sub-test state probes)
- Layout freeze sources: none (this issue introduces new storage,
  no layout freeze extension needed)
