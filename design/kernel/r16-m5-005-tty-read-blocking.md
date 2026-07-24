---
issue: 606
milestone: R16.M5 (TTY / cooked line discipline)
subsystem: 15 — TTY / cooked line discipline
topic: tty_read — cooked-mode reader; fast path copies a complete line from _tty_line_buf to user buf + resets the line, slow path installs waiter + sched_block, retries on wake. Extends the two-instruction minimal shipped at #603 monotonically.
prereq:
  - "#605 (R16.M5-004 tty_process_input — LANDED; per-byte cooked router. Guarantees that whatever ends up in `_tty_line_buf` respects the cooked-mode invariants this issue's reader depends on: (a) every byte in `[0.._tty_line_head)` is a printable/control byte the terminal actually sent (or a CR→LF-translated 0x0A); (b) `_tty_line_complete == 1` iff the last-appended byte was 0x0A; (c) backspace never shrinks head past 0; (d) overflow drops the offending byte and never leaves head > 256. This issue is the mirror-image consumer of the pipeline #605 is the producer for.)"
  - "#604 (R16.M5-003 tty_line_buffer — LANDED; provides `tty_line_reset` and the triple `{_tty_line_buf, _tty_line_head, _tty_line_complete}`. This issue's fast path reads all three and calls `tty_line_reset` after copy-out. The `pub let mut` visibility on each cell is what makes the direct qword-load-of-head-and-complete path legal from this file, matching the sanction pattern #604 §3.3/§6.3 granted to #605 for `_tty_line_head` decrement.)"
  - "#603 (R16.M5-002 tty_vops_table + tty_read minimal — LANDED; publishes `_tty_vops[+0] = &tty_read`. This issue REPLACES the two-instruction body at read.pdx:33-36 with the real reader. The `tty_read` SYMBOL and its ADDRESS in the vops table stay stable across the substitution — only the body of the function that address points to grows. This matches the monotonic-growth contract #603 froze in its own §3.3.3.)"
  - "#600 (R16.M4-006 uart_rx_notify — LANDED; provides `uart_rx_notify_set_waiter(tcb)` and `_uart_rx_notify_waiter` slot. This issue's blocking wrapper calls the setter with `_current_tcb` to park the reader before `sched_block`. The slot's single-waiter design bounds R16.M5 to one blocked reader — see §6.5 for the R17+ multi-reader migration path.)"
  - "#567 (R15-M7-006 sched_block / sched_wake — LANDED; provides `sched_block` self-suspend. This issue's blocking wrapper calls `sched_block` after installing the waiter; the ISR-tail wake path at #600 will call `sched_wake` on the same TCB when a byte arrives, resuming this reader in the retry loop. The wrapper spills user buf (rsi) into rbx and user len (rdx) into r12 across the `sched_block` call because rsi/rdx are caller-save and the context switch inside sched_switch_r15 does not preserve them per #564 §5.")"
  - "#562 (R15-M7-001 idle-task; `sched_pick_next_r15` — LANDED; the empty-runqueue fallback that sched_block routes to. Not called directly, but its landing is what makes calling sched_block from a task-context caller (once we have one) safe.)"
blocks:
  - "#607 (r15-m5-006 tty_write — REPLACES the minimal tty_write body at write.pdx alongside this issue's replacement of tty_read. Composes with this issue's reader at the shell-loop level: shell writes prompt → reads command → writes result. Not a compile-time dependency of #606 but the natural sibling.)"
  - "#608 (r15-m5-007 connect-tty-to-init-fd012 — orthogonal to this issue. Once init's fd 0/1/2 map to `_tty0`, `sys_read` reaches this issue's `tty_read` through vops dispatch. The blocking wrapper's runtime exercise begins here.)"
  - "#609 (r15-m5-008 R16.M5 CLOSER smoke — the composed end-to-end \"typing hello\\n from real RX-driven bytes yields 6 bytes from sys_read\" fingerprint. This issue's witness proves the fast-path copy-out in isolation; #609 exercises the full producer-drainer-consumer-wake-syscall loop.)"
touching:
  - src/kernel/core/tty/read.pdx                             (existing file, monotonic growth: 38 LOC → ~140 LOC incl. justifications + witness fixture slab)
  - src/kernel/boot/kernel_main.pdx                          (witness block inserted after tty_input_witness_done at line 4573; ~100 LOC)
  - tools/boot_stub.S                                        (2 rodata additions: tty_read_ok_msg, tty_read_fail_msg after the tty_input strings at line 802)
  - tests/r14b/expected-boot-r14b-loader.txt                 (marker `R16 TTY READ OK` after `R16 TTY INPUT OK`)
  - tests/r15/expected-boot-r15-ring3.txt                    (marker)
  - tests/r15/expected-boot-r15-process.txt                  (marker)
  - design/kernel/r16-m5-005-tty-read-blocking.md            (this doc)
related:
  - design/kernel/r16-m5-002-tty-vops-table.md               (#603 — §3.3.3 pins the monotonic-growth contract for tty_read's body; this issue is the substitution event #603 anticipates.)
  - design/kernel/r16-m5-003-tty-line-buffer.md              (#604 — §3.3/§6.3 sanction direct read of the `pub let mut` state cells; this issue is a second beneficiary of that sanction after #605.)
  - design/kernel/r16-m5-004-tty-process-input.md            (#605 — §1.2 defers Ctrl-D EOF handling explicitly to THIS issue; §6.4 unpacks the deferral. This issue's §6.4 discusses why EOF ships at #609 not here.)
  - design/kernel/r16-m4-006-uart-rx-notify.md               (#600 — §3.5 lists the caller obligations for `uart_rx_notify_set_waiter`; this issue's blocking wrapper satisfies each.)
  - src/kernel/core/sched/wake_block.pdx                     (#567 — the `sched_block` this issue's wrapper calls; §7.2 of #567 doc flags the preemption-safety cli window as a Phase-9 concern which this issue inherits.)
  - src/kernel/core/uart/rx_notify.pdx                       (#600 — landed; the waiter-slot + wake primitives this issue composes with.)
  - design/milestones/r14b-tactical-plan.md                  §Subsystem 15 line ~1598, item 5 (this issue's plan pointer; item 5 language: "tty_read: if complete-line ready, copy to user buf; else block via KIND_NOTIFICATION").
---

# R16-M5-005 — `tty_read`: blocking cooked-mode reader (#606)

## 1. Scope

Land the fifth R16.M5 subsystem-15 issue: substitute the real
cooked-mode reader in for the two-instruction `xor eax, eax; ret`
placeholder that #603 shipped in `src/kernel/core/tty/read.pdx`.

The vops slot at `_tty_vops[+0]` — populated at #603 by
`lea rax, [rip + tty_read]; mov [r8+0], rax` — stays untouched.
The **symbol** `tty_read` keeps its address; only the **body** at
that address grows. This is the monotonic-growth substitution
#603 §3.3.3 explicitly pinned:

> "At #606, this file is extended (monotonically grown) to
> block-until-line-ready, copy-out from buffer, and advance
> head/tail. The vops slot pointer (_tty_vops[+0]) stays stable —
> only the body of tty_read changes, not its address or signature."

Two functions land in the file:

- **`tty_read_try(vn, buf, len, off) -> u64`** — leaf, non-blocking.
  Returns bytes copied (0 if no complete line ready). Fully
  witnessable at kernel_main boot time.
- **`tty_read(vn, buf, len, off) -> u64`** — non-leaf wrapper.
  Loops: try; if 0, install `_current_tcb` as RX waiter, call
  `sched_block`, retry. This is what the vops slot resolves to.

Acceptance (issue AC, literally): **sys_read blocks; typing
"hello\n" completes and returns 6 bytes.**

At R16.M5 there is no `sys_read` yet — the syscall dispatch tier
lives at R17. The witness at §5 exercises the fast path of
`tty_read_try` (pre-fill line buffer via manual `tty_line_append`,
call the reader, verify byte-count + copy correctness + line
reset). The full end-to-end AC — "type on the keyboard, get 6
bytes from sys_read" — is exercised at #609's closer smoke once
the drainer + fd 0 wiring lands.

### 1.1 What this issue proves

- **The fast path copies exactly `min(len, head)` bytes into the
  user buffer without off-by-one, and resets the line buffer
  atomically after copy-out.** Witness sub-test A exercises the
  literal AC scenario (line contains "hello\n", user asks for 64
  bytes, gets exactly 6 with buffer contents verified byte-by-byte).
- **Cooked-mode "no-line-yet" semantics are enforced at the
  reader.** If `_tty_line_complete == 0`, `tty_read_try` returns
  0 regardless of `_tty_line_head`. A user that has typed "abc"
  but not hit Enter gets zero bytes from a poll — matching POSIX
  cooked-mode. Witness sub-test C proves this.
- **Line reset after copy-out is unconditional in the fast path.**
  Once bytes have been handed to the user, the line buffer is
  cleared (head=0, complete=0). Subsequent calls to `tty_read_try`
  return 0 until the drainer + `tty_process_input` produce a new
  complete line. Witness sub-test D proves state after copy-out.
- **The reader survives short user buffers.** If `len < head`,
  the reader copies exactly `len` bytes and resets. The remainder
  of the line is dropped. Witness sub-test E exercises this; §3.6
  discusses the R17+ upgrade path to preserve tail bytes via a
  read cursor.
- **The blocking wrapper is structurally sound.** `tty_read`
  installs `_current_tcb` as the RX waiter, calls `sched_block`,
  and retries via `tty_read_try` on wake. The wrapper spills
  `rsi` (user buf) into `rbx` and `rdx` (user len) into `r12`
  before the `sched_block` call — necessary because the context
  switch inside `sched_switch_r15` does not preserve caller-save
  registers per #564 §5. §5.4 audits why the wrapper is not
  exercised at witness time (would deadlock the boot thread on
  `sched_block` with nothing to wake it).

### 1.2 What this issue deliberately does NOT do

- **No sys_read syscall dispatch.** The R17 syscall tier
  (`sys_read(fd, buf, len)` reaching this issue via
  `fd_table[fd].vnode.ops_ptr[VOPS_READ_OFFSET]`) is out-of-scope
  for R16.M5. The vops slot is populated at #603; the syscall
  dispatcher is R17's concern.
- **No runtime exercise of the blocking wrapper.** `tty_read`
  (the wrapper) is code-committed and its symbol is resolved;
  its runtime behavior is not tested at R16.M5 because
  `sched_block` would suspend the boot thread and there is no
  RX ISR that would run `sched_wake` on it during kernel_main
  (the ISR wire-up at #598/#599 has landed, but no keyboard
  bytes are being fed at boot-witness time). The wrapper's
  runtime correctness lands at #609 with the closer smoke, and
  at R17 with the first real sys_read.
- **No Ctrl-D EOF handling.** #605 §1.2 deferred EOF explicitly
  to this issue. It moves again — to #609 — because EOF requires
  (a) an `_tty_line_eof` flag alongside `_tty_line_complete`
  that #604's primitives do not yet own; (b) a shared decision
  at the router (`tty_process_input`) to set the EOF flag on
  0x04 at start-of-line; and (c) the reader logic here to return
  0 with EOF as a distinct condition from would-block. Doing all
  three at #606 doubles this issue's surface and blurs the
  fast-path AC. Filed as a follow-up on the R16.M5 closer path;
  see §6.4.
- **No read cursor for partial reads.** If `len < head`, the
  bytes after `buf[len]` are dropped. §3.6 explains the shortest
  patch (a `_tty_line_read_cursor` cell + memmove or index-based
  read) and defers it to R17+ when userland actually asks small
  reads. R16.M5 shell code always allocates ≥256 byte buffers.
- **No Ctrl-C SIGINT interruption of a blocking read.**
  `sched_block` at R15.M7 has no interruption mechanism. R17+
  signal delivery adds an `EINTR`-return path.
- **No non-blocking-mode toggle (O_NONBLOCK).** The wrapper always
  blocks on empty; there is no per-fd flag consulted. The R17+
  fd-flags plumbing adds this.
- **No timeout on the block.** `sched_block` blocks indefinitely
  at R15.M7. `poll`/`select` semantics land at R17+ with a
  bounded-wait primitive.
- **No multi-reader serialization.** `_uart_rx_notify_waiter` is
  a single slot; a second reader installing itself would
  overwrite the first. R16.M5 has one reader (the shell);
  §6.5 discusses R17+ per-tty wait-queue upgrade.
- **No offset semantics.** `off` (rcx) is ignored — TTY is a
  streaming character device. `tty_read` still takes it as arg-3
  because the vops signature is uniform across all backends.
- **No memory-safety validation on the user `buf`.** At R17+ the
  syscall entry stub validates `buf` is user-writable and
  bounded by `len`. At R16.M5 the caller is the witness (which
  passes an in-kernel .bss scratch); no user pointer arrives here.

## 2. Prereq check

### 2.1 What is in place

| Primitive / symbol            | Location                                                | Contract used                                                                                                          |
|-------------------------------|---------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------|
| `tty_read` slot in vops       | `core/tty/vops.pdx:94`  (`lea rax, [rip + tty_read]`)   | Populated at #603 via `mov [r8+0], rax`. Address is baked at link time; substitution is body-only.                     |
| `_tty_line_buf` [u8;256]      | `core/tty/line_buffer.pdx:24` (#604)                    | `pub let mut`. Direct RIP-relative byte load via `lea + add + mov_b`. Same idiom as line_buffer.pdx:52-56.             |
| `_tty_line_head` : u64        | `core/tty/line_buffer.pdx:25` (#604)                    | `pub let mut`. Read via `mov rax, [rip + _tty_line_head]`. Sanctioned direct-read by #604 §3.3/§6.3.                   |
| `_tty_line_complete` : u64    | `core/tty/line_buffer.pdx:26` (#604)                    | `pub let mut`. Same sanction. Read via `mov rax, [rip + _tty_line_complete]`.                                          |
| `tty_line_reset`              | `core/tty/line_buffer.pdx:91` (#604)                    | `() -> u64 !{mem} @{}`. Clobbers rax only. Called on the fast path after copy-out.                                     |
| `uart_rx_notify_set_waiter`   | `core/uart/rx_notify.pdx:40` (#600)                     | `(u64) -> () !{mem} @{sched}`. Caller passes tcb in rdi. Clobbers rax. Preconditions caller-checked (§3.5 of #600).    |
| `sched_block`                 | `core/sched/wake_block.pdx:34` (#567)                   | `() -> () !{mem, sysreg} @{sched}`. Self-suspend. Returns after some other task calls `sched_wake` on this task.       |
| `_current_tcb` : u64          | `core/sched/runqueue.pdx:85`                            | `pub let mut`. Read via `mov rdi, [rip + _current_tcb]` to stage the waiter-install arg.                               |
| `mov_b [reg + 0], rax`        | `core/tty/line_buffer.pdx:56`                           | Byte-narrow store idiom. Used for user-buf writes.                                                                     |
| `mov_b rax, [reg + 0]`        | Byte-narrow load — used at witness site.                | Also needed for source-side byte reads in copy loop.                                                                   |
| `lea r?, [rip + _sym]`        | Ubiquitous.                                             | Compute base addresses for `_tty_line_buf` and (in witness) `_tty_read_witness_buf`.                                   |
| `add reg, reg`                | `core/tty/line_buffer.pdx:53` (add r8, rcx)             | Compose base+index into a single reg (avoid SIB).                                                                      |
| `cmp reg, reg` (jae, jbe)     | Ubiquitous.                                             | `min(len, head)` and copy-loop termination.                                                                            |
| `push rbx`, `pop rbx`         | `core/tty/process_input.pdx:35,92`                      | Callee-save spill for cross-call state preservation.                                                                   |
| `push r12`, `pop r12`         | `boot/kernel_main.pdx:4420,4573`                        | Same pattern — spill for cross-call preservation.                                                                      |
| `call sym` / `ret`            | Ubiquitous.                                             | Nested-call form for `tty_line_reset` and (in wrapper) `uart_rx_notify_set_waiter` + `sched_block`.                    |
| `sub rsp, 8` / `add rsp, 8`   | `core/uart/rx_notify.pdx:83,85`                         | SysV alignment prelude around nested calls in a post-outer-call body.                                                  |
| `jmp label` (loop)            | `boot/kernel_main.pdx:4542` (tiw_fill_loop)             | Retry loop in the wrapper.                                                                                             |
| `xor rax, rax` / `xor rcx,rcx`| Ubiquitous.                                             | Zero counters and pre-load-byte-mask registers.                                                                        |
| `add reg, 1`                  | Ubiquitous.                                             | Copy-loop cursor advance.                                                                                              |

### 2.2 What is NOT in place

- **The `tty_read_try` symbol.** Introduced by this module.
- **The `_tty_read_witness_buf` [u8;64] .bss slab.** Introduced by
  this module, right alongside the `tty_read_try` and `tty_read`
  definitions. Witness-only — see §5.3 for the rationale for
  co-locating the fixture with the primitive.
- **The `tty_read_ok_msg` / `tty_read_fail_msg` rodata in
  `boot_stub.S`.** Added after the R16.M5-004 witness strings
  at lines 795-802 (per the pattern established by #604 and #605).
- **The `R16 TTY READ OK` marker in three fingerprint files.**
  Additive, contains-in-order-matched — inserted after
  `R16 TTY INPUT OK`.

### 2.3 Encoder gaps

**None.** Every mnemonic form used has landed precedent — see
the §2.1 table. In particular:

| Mnemonic form                          | Proven at                                                        |
|----------------------------------------|------------------------------------------------------------------|
| `mov rax, [rip + _sym]`                | `core/uart/rx_ring.pdx:533`; `core/tty/line_buffer.pdx:48`.       |
| `mov [rip + _sym], rax`                | Not used by this issue's fast path — reset is done via `call tty_line_reset` rather than in-line clear. |
| `mov_b rax, [reg + 0]` (byte load)     | Witness site — `boot/kernel_main.pdx:4449` etc.                   |
| `mov_b [reg + 0], rax` (byte store)    | `core/tty/line_buffer.pdx:56`.                                    |
| `lea reg, [rip + _sym]`                | Ubiquitous.                                                       |
| `add reg, reg` (r8, rcx)               | `core/tty/line_buffer.pdx:53`.                                    |
| `cmp reg, reg` / `cmp reg, imm8`       | Ubiquitous.                                                       |
| `jae` / `jbe` / `je` / `jne` / `jmp`   | Ubiquitous.                                                       |
| `push rbx` / `pop rbx`                 | `core/tty/process_input.pdx:35,92`.                               |
| `push r12` / `pop r12`                 | `boot/kernel_main.pdx:4420,4573`.                                 |
| `mov reg, reg` (mov rbx, rsi)          | Ubiquitous.                                                       |
| `sub rsp, 8` / `add rsp, 8`            | `core/uart/rx_notify.pdx:83,85`.                                  |
| `call sym` / `ret`                     | Ubiquitous.                                                       |
| `xor eax, eax` (zero return)           | Ubiquitous.                                                       |
| `add reg, 1`                           | Ubiquitous.                                                       |

No SIB. No indexed addressing (`[base + idx]` is always composed
via a preceding `add`). No REX.B beyond `r8..r12`. No SSE/AVX.
No port I/O. **Cross-repo escalation not needed.**

## 3. Design

### 3.1 File and module structure

`src/kernel/core/tty/read.pdx` grows from 38 LOC (the #603
minimal) to ~140 LOC. The module retains its name `Read`;
`tty_read` retains its address. Two new items land in the same
module:

- `tty_read_try` — leaf, non-blocking, `pub` (admits the future
  syscall-dispatch layer as a caller if it ever wants to peek).
- `_tty_read_witness_buf : [u8; 64]` — witness-only .bss fixture,
  `pub let mut`, aligned 8. Not touched by any production path.

```
src/kernel/core/tty/
    init.pdx           (#602, LANDED)
    vops.pdx           (#603, LANDED — points +0 at tty_read)
    read.pdx           (#603 minimal → THIS ISSUE #606, monotonically grown)
    write.pdx          (#603, LANDED — minimal; extended at #607)
    line_buffer.pdx    (#604, LANDED)
    process_input.pdx  (#605, LANDED)
```

### 3.2 Contract for `tty_read_try`

```
tty_read_try(vn : u64,      // rdi — vops arg-0, ignored (single-tty at R16.M5)
             buf : u64,     // rsi — destination user buffer base
             len : u64,     // rdx — maximum bytes to copy
             off : u64)     // rcx — offset, ignored (streaming device)
    -> u64                  // rax — bytes actually copied (0 if no line ready)

    fast path (_tty_line_complete == 1):
        n := min(len, _tty_line_head)
        for i in 0..n:  buf[i] := _tty_line_buf[i]
        tty_line_reset()                    ; head := 0, complete := 0
        return n

    empty path (_tty_line_complete == 0):
        return 0                            ; unchanged state; caller retries or blocks
```

Register discipline (see §3.3 for prose):
- rdi (vn), rcx (off) — ignored, not read.
- rsi (buf) — dest base, used in copy-loop store.
- rdx (len) — limit for min(len, head).
- rbx — callee-save; holds `n` across `call tty_line_reset`.
  Push at entry, pop at exit.
- r8, r9 — scratch (src base, source-byte staging).
- rax — scratch + return.

Effect: `!{mem}`. Capability: `@{}` — `tty_line_reset` is
`@{}` too.

### 3.3 Contract for `tty_read`

```
tty_read(vn, buf, len, off) -> u64      ; vops slot pointer resolves here

    push rbx                            ; spill user buf (rsi) across sched_block
    push r12                            ; spill user len (rdx)
    mov  rbx, rsi                       ; rbx := buf
    mov  r12, rdx                       ; r12 := len

  retry:
    ; Restore args for tty_read_try (rdi unchanged; rsi/rdx from spills).
    mov  rsi, rbx
    mov  rdx, r12
    call tty_read_try                   ; leaf; returns bytes in rax
    cmp  rax, 0
    jne  read_done                      ; got bytes — return them

    ; Empty: install current_tcb as RX waiter, then sched_block.
    mov  rdi, [rip + _current_tcb]
    call uart_rx_notify_set_waiter
    call sched_block                    ; blocks; returns after RX-ISR sched_wake
    jmp  retry

  read_done:
    pop  r12
    pop  rbx
    ret
```

Effect: `!{mem, sysreg}`. Capability: `@{sched}` — inherited
from `sched_block` and `uart_rx_notify_set_waiter`.

**Why rbx and r12 for spills?** Both are SysV callee-save. The
nested calls (`tty_read_try`, `uart_rx_notify_set_waiter`,
`sched_block`) all preserve callee-save regs by contract. The
context switch inside `sched_switch_r15` explicitly saves and
restores rbx and r12-r15 to/from the TCB slab (per #564 §5), so
values in these regs survive across the block-and-resume window.

**Why not spill rdi (vn)?** vn is ignored by `tty_read_try` and
the wrapper does not re-issue it. If a future extension needs
vn preserved across the block, add a third spill (r13).

**Alignment.** Entry `rsp % 16 == 8` (post-call). Two pushes
make it `-8` → `-16` → `-24` — wait, that's wrong. Let me
recompute: entry rsp%16==8; push rbx (rsp-=8) → rsp%16==0;
push r12 (rsp-=8) → rsp%16==8. Nested calls need rsp%16==0 at
callee entry, i.e. rsp%16==8 at the `call` site. So the two
pushes leave us at rsp%16==8 — nested `call tty_read_try`
enters at rsp%16==0. **Good.**

For the tail (call uart_rx_notify_set_waiter; call sched_block),
we're still at rsp%16==8 at the call sites — same alignment
holds. No `sub rsp, 8` needed. This matches the alignment idiom
at core/uart/rx_notify.pdx:83 (which needed `sub rsp, 8`
because it had zero pushes and was called from a rsp%16==8
context — different starting condition).

### 3.4 Byte-copy loop shape

The copy loop reads `_tty_line_buf[0..n]` and writes `buf[0..n]`
one byte at a time via `mov_b` load and `mov_b` store. Register
allocation:

```
    ; Compute n = min(len, head), stash in rbx.
    mov  rax, [rip + _tty_line_head]    ; rax = head
    cmp  rax, rdx                        ; head vs len
    jbe  ttr_n_is_head                   ; head <= len → n = head
    mov  rax, rdx                        ; else n = len
  ttr_n_is_head:
    mov  rbx, rax                        ; rbx = n (callee-save)

    ; Source base: r8 = &_tty_line_buf.
    lea  r8, [rip + _tty_line_buf]

    ; Copy loop.  Cursor i = rcx.
    xor  rcx, rcx                        ; i = 0
  ttr_copy_loop:
    cmp  rcx, rbx
    jae  ttr_copy_done                   ; i >= n → stop

    ; src byte: xor + mov_b for zero-extended byte load.
    xor  rax, rax
    mov  r9, r8
    add  r9, rcx                         ; r9 = &_tty_line_buf[i]
    mov_b rax, [r9 + 0]

    ; dst byte: buf[i] = rax (low 8 bits).
    mov  r9, rsi
    add  r9, rcx                         ; r9 = &buf[i]
    mov_b [r9 + 0], rax

    add  rcx, 1
    jmp  ttr_copy_loop

  ttr_copy_done:
    call tty_line_reset                  ; clobbers rax; head/complete zeroed
    mov  rax, rbx                        ; return n
    pop  rbx
    ret
```

**Why not SIB `[r8 + rcx]` addressing?** paideia-as has landed
this form at `core/uart/rx_ring.pdx:70` for the ring cursor, but
the audited-idiom that #604 (line_buffer) chose is `lea + add`
composition into a scratch base register. This issue follows the
same idiom for uniformity with its sole caller of the byte
primitives; adds zero new encoder novelty. Cost: one extra `mov`
and `add` per iteration = ~4 cycles overhead per byte at
interactive typing scales (negligible).

**Why re-compute `r9 = base + i` inside the loop?** Because we
need it TWICE per iteration (src and dst). We could hoist by
maintaining two moving pointers (`r8` and `r9` advancing by 1
each iteration), saving 2 instructions per iteration. Rejected:
the moving-pointer form has landed precedent at
`core/uart/rx_ring.pdx` for a single stream but not for a
paired src/dst copy loop, and clarity beats 2 cycles on a
witness-critical path. If interactive typing performance ever
matters here (unlikely — we're bottlenecked on
`sched_block`/`sched_wake` and `uart_putc` polling), refactor.

### 3.5 Empty-path shape

If `_tty_line_complete == 0`, the fast path returns 0
immediately — no side effects, no buffer touch:

```
  ; At entry to tty_read_try, after push rbx:
    mov  rax, [rip + _tty_line_complete]
    cmp  rax, 0
    je   ttr_try_empty

    ; ... fast path (§3.4) ...

  ttr_try_empty:
    xor  rax, rax                        ; return 0
    pop  rbx
    ret
```

The caller (`tty_read` wrapper OR the R17+ syscall dispatcher OR
the witness) interprets 0 as "would block, retry after wake".
Cooked-mode is line-at-a-time: even if head==3 ("abc\0"), we
return 0 because `_tty_line_complete == 0`. This is the
canonical POSIX behavior (`ICANON` in termios) and matches the
producer's contract at #605 (complete flag lags head until a
newline arrives).

### 3.6 Truncation policy — `len < head`

When the user asks for fewer bytes than are available:

```
    n := min(len, _tty_line_head)
    copy n bytes
    tty_line_reset()               ; RESET UNCONDITIONALLY
    return n
```

**Chosen: unconditional reset; trailing bytes dropped.** This
is the simplest correct-enough policy for R16.M5:

- Real userland `read()` on cooked-mode input always allocates
  page-sized buffers (4096 bytes) or line-sized (256 bytes ==
  `LINE_BUF_BYTES`). Small buffers are a testing corner case.
- The `_tty_line_buf` at #604 is exactly 256 bytes, so any
  `len >= 256` never truncates. R16.M5 shell allocates a 512-byte
  read buffer — see design/kernel/r16-m5-shell.md pending.
- Preserving the tail requires a new state cell
  (`_tty_line_read_cursor : u64`), a `memmove` on the buffer OR
  cursor-based re-reads, AND a decision about when to allow the
  next `tty_process_input` to touch the buffer (waiting for the
  cursor to drain). All three concerns are R17+ territory once
  the shell surfaces the corner case.

Documented alternative (§6.6): add
`_tty_line_read_cursor` and change the semantics to "read from
cursor to head, advance cursor; only reset when cursor == head".
Filed as follow-up.

Witness sub-test E proves the truncation-and-drop behavior
explicitly, so the policy is not an accident of oversight.

### 3.7 Alternatives considered — reader shape

| Shape                                                    | Rejected because                                                                          |
|----------------------------------------------------------|-------------------------------------------------------------------------------------------|
| **Two-function split: try + wrapper (chosen)**           | Cleanly separates the witnessable leaf from the block-committing wrapper. Fast path can be exercised at boot; blocking path lands in the same file and is code-audited but not runtime-tested at R16.M5. Minimizes witness surface. Same discipline #605 used to split router from drainer. |
| Single monolithic tty_read with in-line block            | Not exercisable at kernel_main witness time — `sched_block` would suspend the boot thread with nothing to wake it (no RX bytes fed at boot). Would force us to either skip the AC witness entirely or design an elaborate wake-before-block harness. |
| Three-function split: try + block-loop + syscall entry   | The third function belongs to R17's syscall dispatcher. YAGNI at R16.M5.                  |
| Callback-passing reader (`tty_read(vn, buf, len, cb)`)   | Would require capability-passing infrastructure not landed until R18+.                     |
| Direct memcpy without loop (via a landed `memcpy` prim)  | No `memcpy` primitive has landed in the kernel yet — every copy site currently uses byte-at-a-time loops. Adding one at #606 is a scope expansion. |

### 3.8 Alternatives considered — waiter / block ordering

The wrapper's inner sequence (install-then-block) matters:

| Order                                                    | Rejected because                                                                          |
|----------------------------------------------------------|-------------------------------------------------------------------------------------------|
| **Install waiter → sched_block (chosen)**                | Install-before-block matches the "arm-then-sleep" idiom #600 §3.5 documents. The ISR-tail wake path at #600 reads the waiter slot; if it's set, it wakes; if not (because we haven't installed yet), a byte arriving between our try-check and our install would win the race — we'd sleep forever. Install-before-block closes this window IF we also re-check state after install. See §3.9 for the race analysis. |
| sched_block first, waiter install inside                 | Impossible — sched_block never returns until woken. There would be no "inside".            |
| Install waiter → re-check line_complete → sched_block    | This IS what the retry loop achieves at the OUTER level: the retry `jmp retry` after `sched_block` re-issues `tty_read_try` which re-checks `_tty_line_complete`. On the FIRST iteration, the race is: (a) try returns 0 (no line); (b) we install waiter; (c) byte arrives → ISR wakes waiter → sched_wake sets us RUNNABLE + enqueues. Since our current state is still RUNNING (haven't blocked yet), sched_wake's re-enqueue is a no-op (already-on-runq check in runq_enqueue — CHECK: is that guarded?). If unguarded, we double-enqueue. If we then call sched_block, we're in a corrupted runq state. |

**Race analysis — is there a window between install and block?**
Yes, and it needs handling. Sequence:

```
                    Reader (this)                          RX ISR
    T0:    tty_read_try → 0
    T1:    install self as waiter
    T2:                                        RX byte arrives → tpi → line_complete=1
    T3:                                        uart_rx_notify_wake_if_waiter
                                                → reads slot (us!)
                                                → clears slot
                                                → sched_wake(us)
                                                → sets state=RUNNABLE
                                                → runq_enqueue(us)  ← BUT WE'RE ALREADY ON RUNQ
    T4:    sched_block:
              state := WAITING
              runq_dequeue(us)                                 ← removes us from runq
              sched_pick_next → next task (idle or empty)
              switch away                                       ← we sleep forever!
```

The T3-T4 order flip corrupts state: sched_wake sets RUNNABLE
but then sched_block overwrites with WAITING. The wake's
runq_enqueue put us on; sched_block's runq_dequeue takes us off.
We now sleep forever with no waiter installed.

**Mitigation at R16.M5 — cli-guard within sched_block.**
`sched_block` at R15.M7 has no cli window (see #567 §7.2 —
deferred to #565's preemption-safety fix). Until that lands, the
race is real for real interrupt-driven paths.

**Concrete R16.M5 escape hatch.** At R16.M5, the reader can only
be invoked from:
(a) the witness at kernel_main (no real RX bytes at boot); or
(b) once shell/init lands (future issue), from a task-context
call — but no timer preemption exists yet (per #567's own §), so
the ONLY interruption source between our T1 and T4 is the RX
ISR itself. If we set IF=0 across install-and-block (a manual
`cli` at T0.5 and rely on `sched_switch_r15` to `popfq` the
pre-call rflags at task-resume time), the RX ISR cannot fire
between T1 and T4.

**Escape hatch for THIS issue: add a `cli` before
`uart_rx_notify_set_waiter` in the wrapper, and let
`sched_switch_r15`'s own popfq restore IF on wake.** This mirrors
what #567 §7.2 flagged as the deferred preemption-safety fix.

Adjusted wrapper:

```
    ; Empty: cli (guard install+block), install waiter, sched_block.
    cli
    mov  rdi, [rip + _current_tcb]
    call uart_rx_notify_set_waiter
    call sched_block                    ; sched_switch_r15's popfq will re-enable IF on wake
    jmp  retry
```

`cli` is a leaf instruction, one byte (0xFA); no encoder gap.
This narrows the race window to zero on UP + no-timer. R17 SMP
will need per-CPU locking on the waiter slot itself — deferred.

**Alternative rejected: check line_complete AFTER install,
BEFORE block.** Would require a second `tty_read_try`-style
peek inside the wrapper. The `cli` guard is simpler and matches
the pattern the preempt-safety issue (#565's fix, whenever it
lands) will formalize kernel-wide.

### 3.9 Alternatives considered — return sentinel for empty

| Empty-path return value                    | Rejected because                                                                          |
|--------------------------------------------|-------------------------------------------------------------------------------------------|
| **0 bytes (chosen)**                       | Matches POSIX `read()` return convention (0 = EOF, >0 = bytes; there is no distinct "would block" in blocking mode). At R16.M5 EOF is not distinguished from would-block (§1.2); at R17+ non-blocking mode adds `-EAGAIN` (=-11 in Linux; = a sentinel constant) as a distinct return. |
| `-EAGAIN` (0xFFFFFFFFFFFFFFF5 as u64)      | Ambiguous at R16.M5 — no fd-flags plumbing yet. Adding it now bakes a syscall-error-code discipline before syscalls exist. |
| `0xFFFFFFFFFFFFFFFF` (u64 max as sentinel) | Two-value polymorphism in the same return register is confusing at the primitive layer. |

The wrapper `tty_read` distinguishes: `tty_read_try` returning
0 means "empty, block and retry"; the wrapper never returns 0
in the blocking-mode contract (it either returns >0 bytes or
blocks forever). At R17+ non-blocking mode, the syscall
dispatcher will check the fd's O_NONBLOCK flag and translate
`tty_read_try == 0` into `-EAGAIN` before returning to user.

### 3.10 File contents (target)

```pdx
// src/kernel/core/tty/read.pdx — R16-M5-005 (#606)
// tty_read + tty_read_try — cooked-mode reader for TTY vnode.
//
// Per design/kernel/r16-m5-005-tty-read-blocking.md:
//
//   tty_read_try(vn, buf, len, off) -> u64
//     Non-blocking peek. If _tty_line_complete == 1, copies
//     min(len, _tty_line_head) bytes from _tty_line_buf to buf,
//     calls tty_line_reset, and returns the byte count.
//     Otherwise returns 0.
//
//   tty_read(vn, buf, len, off) -> u64
//     Blocking wrapper. Loops: tty_read_try; if 0, install
//     _current_tcb as RX waiter (under cli guard, see design
//     §3.8 race analysis) and call sched_block; retry on wake.
//     This is the function the vops slot at _tty_vops[+0] points
//     to; its address stays stable across the #603 → #606
//     substitution (monotonic body growth per #603 §3.3.3).
//
// Witness fixture: _tty_read_witness_buf : [u8; 64] — .bss slab
//   used ONLY by the kernel_main witness at #606. Not touched
//   by any production caller. See design §5.3.

module Read = structure {
  // === Witness fixture (kernel_main-only) ===
  pub let mut _tty_read_witness_buf : [u8; 64] = uninit @align(8)

  // ==========================================================================
  // tty_read_try(vn, buf, len, off) -> u64 — leaf, non-blocking
  // ==========================================================================
  // Input:  rdi = vn (ignored — single-tty at R16.M5)
  //         rsi = buf (destination base)
  //         rdx = len (max bytes)
  //         rcx = off (ignored — streaming device)
  // Output: rax = bytes copied (0 if _tty_line_complete == 0)
  //
  // Side effects (fast path):
  //   buf[0..n] := _tty_line_buf[0..n]  where n = min(len, _tty_line_head)
  //   _tty_line_head := 0
  //   _tty_line_complete := 0
  //
  // Side effects (empty path): none.
  //
  // Clobbers (SysV caller-save): rax, rcx, rdx, r8, r9.
  // Preserves rbx (via push/pop) — used to carry n across tty_line_reset.
  pub let tty_read_try : (u64, u64, u64, u64) -> u64 !{mem} @{} =
    fn (vn: u64) (buf: u64) (len: u64) (off: u64) -> unsafe {
      effects: { mem },
      capabilities: { },
      justification: "R16-M5-005 (#606): non-blocking cooked-mode reader. Reads _tty_line_complete via `mov rax, [rip + _tty_line_complete]` (RIP-relative qword load — landed at core/tty/line_buffer.pdx:118). If 0, returns 0 with no side effect (empty path — see design §3.5). If 1 (fast path — see design §3.4), computes n = min(len, _tty_line_head) via `mov rax, [rip + _tty_line_head]; cmp rax, rdx; jbe use_head; mov rax, rdx; use_head:` then spills n to callee-save rbx across the subsequent `call tty_line_reset` (which clobbers rax). Byte-copy loop: `lea r8, [rip + _tty_line_buf]` for src base, `xor rcx, rcx` for cursor, then per iteration `mov r9, r8; add r9, rcx; mov_b rax, [r9+0]; mov r9, rsi; add r9, rcx; mov_b [r9+0], rax; add rcx, 1; cmp rcx, rbx; jb loop`. Uses lea+add composition instead of SIB [base+idx] to stay within the audited idiom set — same discipline as core/tty/line_buffer.pdx:52-53 for its own single-index case. Post-copy: `call tty_line_reset` (zeroes head + complete; clobbers rax only — line_buffer.pdx:96-100), `mov rax, rbx` restores n, `pop rbx; ret`. Leaf-adjacent (single nested call to tty_line_reset which is itself leaf). Push rbx at entry makes rsp%16==0 for the nested call per SysV; symmetric pop restores caller's rsp%16==8. Return convention: rax = n. 0 return distinguishes empty from EOF only externally (§3.9); at R16.M5 both map to 0 and the wrapper retries either way. Called by (a) this issue's witness (all 5 sub-tests); (b) the sibling tty_read blocking wrapper; (c) (future) R17+ syscall dispatcher when the fd carries O_NONBLOCK. No user-pointer validation — R17+ syscall entry stub will bounds-check buf/len before calling. Truncation on len < head is unconditional-reset-with-drop (§3.6 documents the R17+ read-cursor upgrade path). Audit: r16-m5-005-tty-read-blocking.",
      block: {
        push rbx;

        // Empty-path guard: return 0 if no complete line.
        mov  rax, [rip + _tty_line_complete];
        cmp  rax, 0;
        je   ttr_try_empty;

        // n = min(len, _tty_line_head), stashed in callee-save rbx.
        mov  rax, [rip + _tty_line_head];
        cmp  rax, rdx;
        jbe  ttr_n_is_head;
        mov  rax, rdx;
      ttr_n_is_head:
        mov  rbx, rax;

        // Copy loop: for i in 0..n: buf[i] := _tty_line_buf[i].
        lea  r8, [rip + _tty_line_buf];
        xor  rcx, rcx;
      ttr_copy_loop:
        cmp  rcx, rbx;
        jae  ttr_copy_done;

        // src byte
        xor  rax, rax;
        mov  r9, r8;
        add  r9, rcx;
        mov_b rax, [r9 + 0];

        // dst byte
        mov  r9, rsi;
        add  r9, rcx;
        mov_b [r9 + 0], rax;

        add  rcx, 1;
        jmp  ttr_copy_loop;

      ttr_copy_done:
        call tty_line_reset;               // zeroes head + complete
        mov  rax, rbx;                     // return n
        pop  rbx;
        ret;

      ttr_try_empty:
        xor  rax, rax;                     // return 0
        pop  rbx;
        ret
      }
    }

  // ==========================================================================
  // tty_read(vn, buf, len, off) -> u64 — blocking wrapper (vops slot)
  // ==========================================================================
  // Input:  rdi = vn, rsi = buf, rdx = len, rcx = off
  // Output: rax = bytes copied (always > 0 in blocking-mode contract)
  //
  // Loops: tty_read_try; if 0, install _current_tcb as RX waiter (under cli
  // guard — see design §3.8), call sched_block, retry on wake.
  //
  // Spills rsi (buf) → rbx and rdx (len) → r12 across the sched_block call,
  // because caller-save rsi/rdx do not survive the context switch inside
  // sched_switch_r15 (per #564 §5).
  //
  // At R16.M5 this function is code-committed but not runtime-exercised by
  // the witness (would suspend the boot thread with no RX ISR to wake it).
  // Runtime exercise lands at #609 closer smoke + R17 syscall dispatch.
  //
  // Clobbers (SysV caller-save): rax, rcx, rdx, rdi, rsi, r8, r9.
  // Preserves rbx, r12 (via push/pop).
  pub let tty_read : (u64, u64, u64, u64) -> u64 !{mem, sysreg} @{sched} =
    fn (vn: u64) (buf: u64) (len: u64) (off: u64) -> unsafe {
      effects: { mem, sysreg },
      capabilities: { sched },
      justification: "R16-M5-005 (#606): blocking wrapper around tty_read_try. This is the function the vops slot at _tty_vops[+0] (populated at #603) points to; its ADDRESS is stable across the #603 minimal → #606 real substitution, only the body grows (monotonic per #603 §3.3.3). Spills user buf (rsi) to callee-save rbx and user len (rdx) to callee-save r12 at entry — necessary because the context switch inside sched_switch_r15 saves/restores only callee-save regs (per #564 §5); caller-save rsi/rdx would return with arbitrary values after sched_block resumes. Loop: restore rsi/rdx from rbx/r12, call tty_read_try (leaf; returns rax = bytes); if rax != 0, pop and return. If rax == 0 (empty), cli (see design §3.8 race analysis — closes the install-slot to sched_block window against a racing RX ISR wake; single-byte 0xFA instruction, no encoder gap; sched_switch_r15's popfq inside its cli/popfq window restores IF on wake per #564 §5.4), load _current_tcb via `mov rdi, [rip + _current_tcb]` (RIP-relative qword load — landed idiom), call uart_rx_notify_set_waiter (clobbers rax only per #600 §), call sched_block (clobbers all caller-save + spills callee-save through the TCB slab; returns after another task calls sched_wake on this task, which the RX ISR does via uart_rx_notify_wake_if_waiter at #600). On wake, jump back to retry. Register discipline: rbx (buf spill) + r12 (len spill) are the only callee-save regs used; both pushed at entry, popped at exit; symmetric push/pop keeps rsp%16 stable (entry rsp%16==8, after two pushes rsp%16==8, nested `call` enters at rsp%16==0 as SysV requires). No sub/add rsp,8 pad needed for the calls because the two pushes already provide the alignment. Effect {mem, sysreg}: mem for the storage-cell loads, sysreg for the cli within the blocking path. Capability {sched}: inherited from sched_block and uart_rx_notify_set_waiter. At R16.M5 the wrapper's runtime path is NOT exercised by the witness (would deadlock the boot thread — no RX ISR feeds bytes during kernel_main witness time); the leaf tty_read_try is exercised by all 5 sub-tests. Runtime exercise lands at #609 (closer smoke with a real drainer thread + real RX bytes) and R17 (first real sys_read syscall). Called by (a) vops dispatch (once R17 sys_read plumbs through _tty_vops[+0]); (b) the audit-visible entry point in the file for symbol-existence proofs at the closer smoke. Preconditions (caller's obligation): _current_tcb != 0 (i.e., a task context — not kernel-main-preinit); some upstream producer (drainer + tty_process_input) is running that can eventually cause _tty_line_complete := 1. Neither precondition holds at R16.M5 kernel_main witness time — that's why the wrapper is not exercised there. Audit: r16-m5-005-tty-read-blocking.",
      block: {
        push rbx;
        push r12;
        mov  rbx, rsi;                     // spill buf
        mov  r12, rdx;                     // spill len

      ttr_retry:
        mov  rsi, rbx;                     // restore args
        mov  rdx, r12;
        call tty_read_try;
        cmp  rax, 0;
        jne  ttr_read_done;                // got bytes → return

        // Empty: cli-guarded waiter-install + sched_block.
        cli;
        mov  rdi, [rip + _current_tcb];
        call uart_rx_notify_set_waiter;
        call sched_block;                  // returns after ISR sched_wake
        jmp  ttr_retry;

      ttr_read_done:
        pop  r12;
        pop  rbx;
        ret
      }
    }
}
```

**Line count.** New file body is ~140 physical lines (including
comments and justifications), up from the 38-line #603 minimal.
The vops slot pointer address stays identical after re-link
(same symbol, longer body).

## 4. Witness placement

### 4.1 Position in `kernel_main.pdx`

Inserted immediately after the R16.M5-004 witness's `_done`
label (`tty_input_witness_done:` at
`src/kernel/boot/kernel_main.pdx:4572`) and before the R14b-m5-002
GS_BASE `wrmsr` block (starts at `kernel_main.pdx:4575` with
`lea rax, [rip + _cpu_locals];`). This keeps all R16.M5
witnesses contiguous.

```
      tty_input_witness_done:
          pop  r12;

      <-- INSERT R16.M5-005 WITNESS HERE (§5 body) -->

      // R14b-m5-002 (#507): IA32_GS_BASE = &_cpu_locals[0] on CPU0.
      lea rax, [rip + _cpu_locals];
      ...
```

**Prior state at insertion point.** The tty_input witness ends
with `_tty_line_buf` full of 'X' bytes, `_tty_line_head == 256`,
`_tty_line_complete == 0`. The tty_read witness's FIRST action
in every sub-test is `call tty_line_reset`, so this residual
state does not leak — same discipline as #605 §4.1.

### 4.2 No fixture slab needed beyond `_tty_read_witness_buf`

`_tty_read_witness_buf : [u8; 64]` is co-located with the
primitive in `read.pdx` (§3.1). Rationale for putting it
alongside the primitive rather than in a separate witness file:

- It's a 64-byte .bss allocation with a single purpose: give
  the tty_read witness a destination for the copy-out. Its
  scope is tightly bound to the primitive it exists to exercise.
- Same locality pattern used by `_block_witness_task_x` at
  `core/sched/runqueue.pdx:72` (a witness-only fake TCB
  co-located with the runqueue primitive it exercises).
- Marked `pub let mut` so the witness at kernel_main can `lea`
  its address; the `pub` visibility does not admit new callers
  since the name has "witness" in it and the doc explicitly
  scopes it.

Everything else the witness needs (`_tty_line_head`,
`_tty_line_complete`, `_tty_line_buf`, `tty_line_reset`,
`tty_line_append`) is already exported by #604.

## 5. Test canary — kernel_main witness block

### 5.1 Sub-test structure — 5 sub-tests, marker `R16 TTY READ OK`

Five sub-tests, each isolating one behavioral axis. Sub-tests A
through D exercise `tty_read_try` directly; sub-test E exercises
truncation. The blocking wrapper (`tty_read` proper) is NOT
runtime-exercised at R16.M5 — see §5.4.

- **Sub-test A** (the literal issue AC) — Pre-fill the line buffer
  with "hello\n" via 6 successive `tty_line_append` calls (5
  printable + 1 newline; the router path is out of scope here,
  we drive the primitive directly). Confirm `_tty_line_head == 6`,
  `_tty_line_complete == 1`. Call
  `tty_read_try(vn=0, buf=&_tty_read_witness_buf, len=64, off=0)`.
  Expect: `rax == 6`; `_tty_read_witness_buf[0..6] == "hello\n"`;
  post-call `_tty_line_head == 0`, `_tty_line_complete == 0`.

- **Sub-test B** (empty path — no complete line) — Reset. Confirm
  `_tty_line_head == 0`, `_tty_line_complete == 0`. Call
  `tty_read_try(0, buf, 64, 0)`. Expect: `rax == 0`; buffer state
  unchanged; `_tty_read_witness_buf` untouched (verify byte [0]
  is still whatever it was after sub-test A — 'h' — for a
  positive no-copy proof).

- **Sub-test C** (partial line — head > 0 but complete == 0) —
  Reset. Append "abc" (3 bytes, no newline) via
  `tty_line_append('a'/b/c)`. Confirm `_tty_line_head == 3`,
  `_tty_line_complete == 0`. Call `tty_read_try`. Expect:
  `rax == 0` (no complete line, even though head > 0 — cooked
  mode); post-call `_tty_line_head == 3` (unchanged),
  `_tty_line_complete == 0`. Proves the empty-path guard fires
  on complete, not on head.

- **Sub-test D** (post-read state — subsequent read of same
  buffer returns 0) — Reset. Append "hi\n" (3 bytes). Call
  `tty_read_try` (rax == 3 expected, buf[0..3] == "hi\n").
  IMMEDIATELY call `tty_read_try` a second time with the same
  args. Expect: `rax == 0` (buffer was reset by first call);
  post-second-call state unchanged from post-first-call.
  Proves the fast path's reset is real and immediate.

- **Sub-test E** (truncation — len < head) — Reset. Append
  "hello\n" (6 bytes) via 6× append. Call
  `tty_read_try(vn=0, buf=&_tty_read_witness_buf, len=3, off=0)`.
  Expect: `rax == 3`; `_tty_read_witness_buf[0..3] == "hel"`;
  post-call `_tty_line_head == 0`, `_tty_line_complete == 0` (reset
  is unconditional per §3.6). The trailing "lo\n" bytes are
  dropped — the R17+ read-cursor upgrade is the way to preserve
  them; this sub-test pins the current drop-tail contract in a
  witness-visible way.

| After sub-test | `_tty_line_head` | `_tty_line_complete` | `_tty_read_witness_buf[0..6]`            | `tty_read_try` returned |
|----------------|------------------|----------------------|------------------------------------------|-------------------------|
| A              | 0                | 0                    | 'h','e','l','l','o','\n'                 | 6                       |
| B              | 0                | 0                    | ['h','e','l','l','o','\n'] (unchanged)   | 0                       |
| C              | 3                | 0                    | (unchanged from B)                       | 0                       |
| D  (2nd call)  | 0                | 0                    | 'h','i','\n',… (partially rewritten)     | 0 (2nd call)            |
| E              | 0                | 0                    | 'h','e','l',… (first 3 replaced)         | 3                       |

**Ordering rationale.** A first (proves the primary AC). B second
(empty path — proves guard fires on complete==0). C third (proves
guard fires on complete regardless of head — cooked-mode line
discipline). D fourth (proves reset actually happens by observing
the second read returns 0). E last (destructive to the buffer's
"nice known state", so any subsequent read-witness would need to
reset first).

**State discipline.** Every sub-test that needs a clean buffer
explicitly calls `tty_line_reset` at its start. The buffer state
at end of witness (`head=0, complete=0`, `_tty_read_witness_buf`
partially overwritten with sub-test remnants) is documented and
not reset — subsequent boot code does not read either buffer.

### 5.2 Witness assembly (complete block)

```asm
; ============================================================
; R16-M5-005 (#606): tty_read witness — 5 sub-tests
; ============================================================
tty_read_witness:
    push r12                                 ; callee-save fixture-base cache

    lea  r12, [rip + _tty_read_witness_buf]  ; r12 = &witness buf (survives all calls)

    ; ---------- Sub-test A: complete line "hello\n" → 6 bytes ----------
    call tty_line_reset

    mov  rdi, 0x68;  call tty_line_append    ; 'h'
    mov  rdi, 0x65;  call tty_line_append    ; 'e'
    mov  rdi, 0x6C;  call tty_line_append    ; 'l'
    mov  rdi, 0x6C;  call tty_line_append    ; 'l'
    mov  rdi, 0x6F;  call tty_line_append    ; 'o'
    mov  rdi, 0x0A;  call tty_line_append    ; '\n' → sets complete

    ; Sanity: line buffer state ready for read.
    mov  rax, [rip + _tty_line_head]
    cmp  rax, 6
    jne  tty_read_witness_fail
    call tty_line_available
    cmp  rax, 1
    jne  tty_read_witness_fail

    ; Read.
    xor  rdi, rdi                             ; vn = 0
    mov  rsi, r12                             ; buf
    mov  rdx, 64                              ; len
    xor  rcx, rcx                             ; off = 0
    call tty_read_try

    ; Assert return value.
    cmp  rax, 6
    jne  tty_read_witness_fail

    ; Assert post-read state: head=0, complete=0.
    mov  rax, [rip + _tty_line_head]
    cmp  rax, 0
    jne  tty_read_witness_fail
    call tty_line_available
    cmp  rax, 0
    jne  tty_read_witness_fail

    ; Assert buf contents byte-by-byte: "hello\n".
    xor  rax, rax
    mov_b rax, [r12 + 0];  cmp rax, 0x68;  jne tty_read_witness_fail   ; 'h'
    xor  rax, rax
    mov_b rax, [r12 + 1];  cmp rax, 0x65;  jne tty_read_witness_fail   ; 'e'
    xor  rax, rax
    mov_b rax, [r12 + 2];  cmp rax, 0x6C;  jne tty_read_witness_fail   ; 'l'
    xor  rax, rax
    mov_b rax, [r12 + 3];  cmp rax, 0x6C;  jne tty_read_witness_fail   ; 'l'
    xor  rax, rax
    mov_b rax, [r12 + 4];  cmp rax, 0x6F;  jne tty_read_witness_fail   ; 'o'
    xor  rax, rax
    mov_b rax, [r12 + 5];  cmp rax, 0x0A;  jne tty_read_witness_fail   ; '\n'

    ; ---------- Sub-test B: empty (no complete line) → 0 ----------
    ; State from A: head=0, complete=0 already (fast path reset).
    ; Extra sanity: reset explicitly.
    call tty_line_reset

    xor  rdi, rdi
    mov  rsi, r12
    mov  rdx, 64
    xor  rcx, rcx
    call tty_read_try

    cmp  rax, 0
    jne  tty_read_witness_fail

    ; Assert buf unchanged (byte [0] still 'h' from A).
    xor  rax, rax
    mov_b rax, [r12 + 0];  cmp rax, 0x68;  jne tty_read_witness_fail

    ; ---------- Sub-test C: partial line (head>0, complete==0) → 0 ----------
    call tty_line_reset
    mov  rdi, 0x61;  call tty_line_append    ; 'a'
    mov  rdi, 0x62;  call tty_line_append    ; 'b'
    mov  rdi, 0x63;  call tty_line_append    ; 'c'

    ; Confirm setup: head=3, complete=0.
    mov  rax, [rip + _tty_line_head]
    cmp  rax, 3
    jne  tty_read_witness_fail
    call tty_line_available
    cmp  rax, 0
    jne  tty_read_witness_fail

    xor  rdi, rdi
    mov  rsi, r12
    mov  rdx, 64
    xor  rcx, rcx
    call tty_read_try

    cmp  rax, 0
    jne  tty_read_witness_fail

    ; Assert state unchanged.
    mov  rax, [rip + _tty_line_head]
    cmp  rax, 3
    jne  tty_read_witness_fail
    call tty_line_available
    cmp  rax, 0
    jne  tty_read_witness_fail

    ; ---------- Sub-test D: double read; second returns 0 ----------
    call tty_line_reset
    mov  rdi, 0x68;  call tty_line_append    ; 'h'
    mov  rdi, 0x69;  call tty_line_append    ; 'i'
    mov  rdi, 0x0A;  call tty_line_append    ; '\n'

    ; First read.
    xor  rdi, rdi
    mov  rsi, r12
    mov  rdx, 64
    xor  rcx, rcx
    call tty_read_try
    cmp  rax, 3
    jne  tty_read_witness_fail

    ; Second read on now-empty buffer.
    xor  rdi, rdi
    mov  rsi, r12
    mov  rdx, 64
    xor  rcx, rcx
    call tty_read_try
    cmp  rax, 0
    jne  tty_read_witness_fail

    ; ---------- Sub-test E: truncation (len < head) ----------
    call tty_line_reset
    mov  rdi, 0x68;  call tty_line_append    ; 'h'
    mov  rdi, 0x65;  call tty_line_append    ; 'e'
    mov  rdi, 0x6C;  call tty_line_append    ; 'l'
    mov  rdi, 0x6C;  call tty_line_append    ; 'l'
    mov  rdi, 0x6F;  call tty_line_append    ; 'o'
    mov  rdi, 0x0A;  call tty_line_append    ; '\n'

    xor  rdi, rdi
    mov  rsi, r12
    mov  rdx, 3                               ; len = 3 (< head=6)
    xor  rcx, rcx
    call tty_read_try

    cmp  rax, 3
    jne  tty_read_witness_fail

    ; Assert buf[0..3] == "hel".
    xor  rax, rax
    mov_b rax, [r12 + 0];  cmp rax, 0x68;  jne tty_read_witness_fail
    xor  rax, rax
    mov_b rax, [r12 + 1];  cmp rax, 0x65;  jne tty_read_witness_fail
    xor  rax, rax
    mov_b rax, [r12 + 2];  cmp rax, 0x6C;  jne tty_read_witness_fail

    ; Assert unconditional reset: head=0, complete=0 (§3.6).
    mov  rax, [rip + _tty_line_head]
    cmp  rax, 0
    jne  tty_read_witness_fail
    call tty_line_available
    cmp  rax, 0
    jne  tty_read_witness_fail

    ; ---------- All green ----------
    lea  rdi, [rip + tty_read_ok_msg]
    call uart_puts
    jmp  tty_read_witness_done

tty_read_witness_fail:
    lea  rdi, [rip + tty_read_fail_msg]
    call uart_puts

tty_read_witness_done:
    pop  r12
```

Total: ~150 lines including labels, blank separators, and
byte-by-byte assertions. Same label-prefix discipline as #605
(`trw_` conflicts avoided — this file uses no bare labels; local
labels use `tty_read_witness_*` explicit names).

### 5.3 Marker

On all five sub-tests green:

```
R16 TTY READ OK
```

Emitted via `uart_puts` on `tty_read_ok_msg`. Added to all three
R14B/R15 expected-output files, inserted immediately after the
`R16 TTY INPUT OK` line.

### 5.4 What the witness does NOT verify

- **The `tty_read` blocking wrapper's runtime path.** Calling
  `tty_read` from the witness would execute the retry-block-retry
  loop; the first iteration returns 0 (buffer empty after our
  final reset), then `cli; install waiter; sched_block` would
  fire. At witness time `_current_tcb` may be 0 (pre-`process_init`
  — check: `process_init` runs at kernel_main:4582 which is AFTER
  the tty_read witness insertion point at 4575). Even if
  `_current_tcb` were non-zero, no RX ISR is running to feed
  bytes into `_tty_line_buf`, so no `sched_wake` would fire —
  the boot thread would deadlock inside `sched_block`. **Correct
  behavior — that's why the wrapper is not exercised here.**

  The wrapper's correctness is verified by:
  (a) **Code audit.** The wrapper's disassembly is inspectable
     via `objdump -d` on the kernel binary; the sequence
     (spill → try → jne-return / cli → install → sched_block →
     jmp retry) is human-readable and matches design §3.3.
  (b) **Symbol resolution.** The vops populator at #603 does
     `lea rax, [rip + tty_read]; mov [r8+0], rax` — linker
     resolves `tty_read` to the new (extended) body. If the
     symbol failed to resolve, link fails; the boot binary
     wouldn't exist.
  (c) **Runtime exercise at #609.** The closer smoke installs a
     drainer thread that calls `tty_process_input` for each RX
     byte, and an init-context thread that calls `tty_read` via
     sys_read. Real RX bytes fed via QEMU's serial input drive
     the full loop.
  (d) **Runtime exercise at R17.** First real user `read(0, buf,
     n)` on the shell's fd 0 lands here through the syscall
     dispatcher.

- **The waiter slot being cleared by the ISR path.** The
  `uart_rx_notify_wake_if_waiter` clear-then-wake behavior is
  witnessed at #600 (block_wake witness). We don't re-witness
  it here.

- **The BEL side-effect of `tty_process_input` on overflow.**
  This is a #605 concern; #606 doesn't emit BEL.

### 5.5 String data — `tools/boot_stub.S`

Append after the R16.M5-004 witness strings (currently at lines
795-802):

```asm
# R16-M5-005 (#606): tty_read witness success message
.global tty_read_ok_msg
.align 8
tty_read_ok_msg: .ascii "R16 TTY READ OK\n\0"

# R16-M5-005 (#606): tty_read witness failure message
.global tty_read_fail_msg
.align 8
tty_read_fail_msg: .ascii "R16 TTY READ FAIL\n\0"
```

Zero other rodata changes.

### 5.6 Fingerprint files — marker insertion

Insert `R16 TTY READ OK` in three files:

| File                                        | Insert after            | Insert before          |
|---------------------------------------------|-------------------------|------------------------|
| `tests/r14b/expected-boot-r14b-loader.txt`  | `R16 TTY INPUT OK`      | `LOADER OK`            |
| `tests/r15/expected-boot-r15-ring3.txt`     | `R16 TTY INPUT OK`      | `R15 IDLE TASK OK`     |
| `tests/r15/expected-boot-r15-process.txt`   | `R16 TTY INPUT OK`      | (same as ring3 file, verify per-file positioning) |

Contains-in-order matching (per `tools/run-smoke.sh`) makes the
addition strictly additive — no earlier line reorders. All 5-mode
smoke stages that do not observe R16 markers (`boot_r8_only`,
`boot_r10`, `boot_r11`, `boot_r12`, `boot_r12_denial`) stay
byte-identically green.

## 6. Alternatives considered / follow-ups

### 6.1 Land the blocking wrapper's runtime witness now

**Rejected.** Would require:
(a) A task-context caller for `tty_read` (kernel-mode boot has
    `_current_tcb == 0` at witness time; `process_init` runs
    later at kernel_main:4582).
(b) An RX-ISR-driven byte feed OR a scheduler tick that injects
    a synthetic wake.
(c) Two-thread choreography: reader blocks, feeder wakes.

All three are #609's territory. Splitting #606 to leaf-only
matches the #605 discipline (router primitive alone, drainer
deferred).

### 6.2 Add a `tty_line_read` leaf to `line_buffer.pdx`

**Considered and rejected.** The fast-path copy loop lives
naturally in the reader, not the line-buffer primitive. #604's
line_buffer is a producer-side primitive; making it a bidirectional
API would blur the layering. Also: the reader's byte-copy shape
uses two moving pointers (src + dst) not shared with any other
line_buffer caller — no reuse motivation.

### 6.3 Use a landed `memcpy` primitive

**No such primitive exists yet.** Adding one at #606 is a scope
expansion. The 256-byte-max byte-at-a-time loop is negligible
performance-wise (bottlenecked on `uart_putc` polling in the
producer, not on the reader). If a real memcpy lands in R17+ as
part of a userlib, refactor.

### 6.4 Ctrl-D EOF handling — moved to #609

#605 §1.2 handed Ctrl-D to this issue. Moving again:

- Requires a new state cell `_tty_line_eof : u64` alongside
  `_tty_line_complete`, owned by #604. Adding it is a #604
  extension (or a new small file).
- Requires `tty_process_input` (#605) to detect 0x04 at
  head==0 and set the EOF flag instead of appending.
- Requires this reader to distinguish `tty_read_try` returns:
  - `>0` bytes → return normally
  - `0` + EOF flag set → return 0 as EOF signal (POSIX)
  - `0` + EOF flag clear → would-block, retry
- All three land coherently at #609 (or an interstitial
  issue between #605 and #609), NOT at #606.

Deferring here avoids doubling the reader's return-value
polymorphism during the initial land, keeps the fast path
purely mechanical (copy-and-return), and lets the #609
composed-loop smoke test EOF end-to-end.

### 6.5 Multi-reader wait-queue at R17+ SMP

The single-slot `_uart_rx_notify_waiter` at #600 admits one
waiter at a time. R17+ multi-tty and/or multi-task-per-tty will
need a proper wait-queue (linked list of TCBs) per tty. Migration
path: replace `uart_rx_notify_set_waiter(tcb)` with
`tty_wait_queue_enqueue(tty_idx, tcb)`; replace
`uart_rx_notify_wake_if_waiter()` with
`tty_wait_queue_wake_one(tty_idx)` (or `wake_all` for readers
that all want the same line). This issue's reader shape
(install-then-block loop) is unchanged — only the install
primitive is swapped.

### 6.6 Read cursor for partial reads (`len < head`)

Add `_tty_line_read_cursor : u64` cell to `line_buffer.pdx`;
change reader semantics to:

```
n := min(len, _tty_line_head - _tty_line_read_cursor)
for i in 0..n:  buf[i] := _tty_line_buf[_tty_line_read_cursor + i]
_tty_line_read_cursor += n
if _tty_line_read_cursor == _tty_line_head:
    tty_line_reset()
return n
```

Also requires `tty_process_input` (#605) to defer touching the
buffer while `_tty_line_read_cursor > 0` (or to reset both cursor
and complete flag together on a new line — R17+ line-editor
concern). Filed as follow-up. Not R16.M5.

### 6.7 O_NONBLOCK / EAGAIN in the syscall dispatcher

R17+ syscall dispatcher checks the fd's O_NONBLOCK flag; if
set, translates `tty_read_try == 0` into `-EAGAIN` and returns
without invoking the blocking wrapper. This issue's primitives
already support this — the dispatcher just chooses which one to
call.

### 6.8 Preemption-safety inside `sched_block`

The `cli` guard in this issue's wrapper (§3.8) closes the race
window in the caller. The dual problem — timer preemption
between `state := WAITING` and `runq_dequeue` inside sched_block
itself — is #567 §7.2's deferred concern, blocked on #565's
preemption fix. When #565 lands, the wrapper's `cli` may become
redundant (sched_block will have its own cli window); the cli
here is defense-in-depth and doesn't hurt to leave.

### 6.9 `pub` visibility of `tty_read_try`

Marked `pub` to admit:
(a) The R17+ syscall dispatcher when the fd carries O_NONBLOCK.
(b) The #609 closer smoke's structural probes.
(c) The witness at this issue (which could also use a private
    function, but there is no `pub` cost).

## 7. Discipline check

- **5-mode smoke.** `boot_r8_only`, `boot_r10`, `boot_r11`,
  `boot_r12`, `boot_r12_denial` all stay byte-identical — none
  of them observe R16 markers, and the additive fingerprint
  changes are contains-in-order matched.
- **No stub / placeholder.** The fast path is real (copy loop,
  reset call, byte-accurate return). The blocking wrapper is
  real (install waiter, cli guard, sched_block call, retry loop
  — code-committed even if not runtime-witnessed at R16.M5, per
  §5.4). The empty-path return-0 is real and correct semantics
  for cooked-mode.
- **Cross-repo escalation.** Not needed — §2.3 confirms zero
  encoder gap.
- **Autonomous loop.** Continue to #607 (`tty_write`) after
  landing.

## 8. Landing checklist

- [ ] `src/kernel/core/tty/read.pdx` — replace 38-LOC minimal
      with ~140-LOC extended file per §3.10. Symbol `tty_read`
      keeps its identity; add `tty_read_try` and
      `_tty_read_witness_buf`.
- [ ] `tools/boot_stub.S` — append the two `tty_read_*_msg`
      rodata entries per §5.5.
- [ ] `src/kernel/boot/kernel_main.pdx` — insert the witness
      block at §5.2 immediately after `tty_input_witness_done:`
      at line 4572.
- [ ] `tests/r14b/expected-boot-r14b-loader.txt` — insert
      `R16 TTY READ OK` after `R16 TTY INPUT OK`.
- [ ] `tests/r15/expected-boot-r15-ring3.txt` — same.
- [ ] `tests/r15/expected-boot-r15-process.txt` — same.
- [ ] `tools/run-smoke.sh` — run 5-mode smoke; expect all
      green with the new marker present in three fingerprints.
- [ ] Commit message: `Implement #606: tty_read — cooked-mode reader (fast-path copy + reset; blocking wrapper via install-waiter + sched_block)`.

## 9. R16.M5 amendment (#667): real body

The wrapper body at §3.3 / §3.10 lands verbatim into
`src/kernel/core/tty/read.pdx`, replacing the two-instruction stub
described in the R16.M5 landing note.

Prerequisite deltas since R16.M5:
- #567 (sched_block/sched_wake) — LANDED.
- #663 (sched_block/sched_wake state-machine guards) — LANDED;
  sched_block soft-panics on `_current_tcb.state != RUNNABLE`.
  In wrapper callers post-process_init this is satisfied by
  construction; in the pre-process_init tty_vops witness path
  (kernel_main.pdx Sub-test C) it is NOT satisfied, so that
  sub-test was edited in the same commit to pre-fill the line
  buffer with "hi\n" — wrapper's first `tty_read_try` returns 3,
  `jne ttr_read_done` fires, sched_block never reached.

Verification stance: STRUCTURAL-ONLY at #667.
`tools/verify-tty-read-wrapper.sh` greps compiled `tty_read`
disassembly for the eight load-bearing mnemonics (push rbx,
push r12, call tty_read_try, cli, call uart_rx_notify_set_waiter,
call sched_block, symmetric pops). Runtime exercise is deferred
to sys_read from ring-3 shell/init once that path is interactively
driven.
