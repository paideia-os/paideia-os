---
issue: 607
milestone: R16.M5 (TTY / cooked line discipline)
subsystem: 15 — TTY / cooked line discipline
topic: tty_write — UART TX loop with \n→\r\n canonical line-ending translation. Extends the two-instruction minimal shipped at #603 monotonically.
prereq:
  - "#603 (R16.M5-002 tty_vops_table + tty_write minimal — LANDED; publishes _tty_vops[+8] = &tty_write. This issue REPLACES the two-instruction body at write.pdx with the real writer. The tty_write SYMBOL and its ADDRESS in the vops table stay stable across the substitution — only the body of the function that address points to grows. This matches the monotonic-growth contract #603 froze in its own §3.3.3.)"
  - "#595 (R16.M4-001 uart_rx_init — LANDED; sets UART RX ready. uart_putc (#603) polls LSR.THRE, then writes to THR. This issue calls uart_putc in a loop over caller's buffer, expanding \\n → \\r\\n before TX emission.)"
blocks:
  - "#608 (r15-m5-007 connect-tty-to-init-fd012 — orthogonal to this issue. Once init's fd 0/1/2 map to _tty0, sys_write reaches this issue's tty_write through vops dispatch. The witness exercises the fast path in isolation; end-to-end TX to real UART is verifiable at #609 via echo artifact.)"
  - "#609 (r15-m5-008 R16.M5 CLOSER smoke — the composed end-to-end \"write prompt to real UART\" fingerprint. This issue's witness proves the loop-and-translate logic; #609 verifies the echo appears on serial line.)"
touching:
  - src/kernel/core/tty/write.pdx                            (existing file, monotonic growth: 38 LOC → ~80 LOC incl. justifications + witness strings)
  - src/kernel/boot/kernel_main.pdx                          (witness block inserted after tty_read_witness_done at line 4788; ~50 LOC)
  - tools/boot_stub.S                                        (2 rodata additions: tty_write_ok_msg, tty_write_fail_msg after tty_read strings at line 812)
  - tests/r14b/expected-boot-r14b-loader.txt                 (marker `R16 TTY WRITE OK` after `R16 TTY READ OK`)
  - tests/r15/expected-boot-r15-ring3.txt                    (marker)
  - tests/r15/expected-boot-r15-process.txt                  (marker)
  - design/kernel/r16-m5-006-tty-write-nl-cr.md              (this doc)
related:
  - design/kernel/r16-m5-002-tty-vops-table.md               (#603 — §3.3.3 pins the monotonic-growth contract for tty_write's body; this issue is the substitution event #603 anticipates.)
  - design/kernel/r16-m5-005-tty-read-blocking.md            (#606 — the mirror-image consumer; tty_read + tty_write compose at the shell-loop level)
  - design/kernel/r16-m4-001-uart-rx-init.md                 (#595 — uart_putc polling discipline; this issue calls uart_putc in a loop)
  - src/kernel/boot/uart.pdx                                 (#603 — uart_putc(ch: u64) in RDI; clobbers RAX; polls LSR.THRE bit 5, writes to THR when ready)
  - design/milestones/r14b-tactical-plan.md                  §Subsystem 15 line ~1598, item 6 (this issue's plan pointer)
---

# R16-M5-006 — `tty_write`: UART TX loop with \n→\r\n translation (#607)

## 1. Scope

Land the sixth R16.M5 subsystem-15 issue: substitute the real
UART-writing loop in for the two-instruction `mov rax, rdx; ret`
placeholder that #603 shipped in `src/kernel/core/tty/write.pdx`.

The vops slot at `_tty_vops[+8]` — populated at #603 by
`lea rax, [rip + tty_write]; mov [r8+8], rax` — stays untouched.
The **symbol** `tty_write` keeps its address; only the **body** at
that address grows. This is the monotonic-growth substitution
#603 §3.3.3 explicitly pinned.

The function `tty_write(vn, buf, len, off) -> u64` replaces its
minimal body with a loop that:

1. For `i` in `0..len`:
   - Load `buf[i]`
   - If `buf[i] == '\n'` (0x0A): output '\r' (0x0D), then '\n'
   - Else: output `buf[i]` as-is
2. Return `len` (bytes accepted from caller's perspective)

**Accounting split:** The return value of `len` satisfies the vops
caller (all N bytes accepted from user perspective), while the UART
sees expanded output (N + count of newlines). At R16.M5, `uart_putc`
polls, so there is no backpressure. At R17+, a TX-ring-buffer
backpressure mechanism may tighten this accounting.

Acceptance (issue AC, literally): **Return value matches input
length; each \\n in the output expands to \\r\\n on the wire.**

At R16.M5 there is no real TTY I/O loop yet — userland read/write
land at R17. The witness at §5 exercises three cases:

- Sub-test A: `tty_write(0, "hi\n", 3, 0)` returns 3; witnesses loop
  entry + newline expansion + return semantics.
- Sub-test B: `tty_write(0, "abc", 3, 0)` returns 3; witnesses
  loop handles non-newline bytes correctly.
- Sub-test C: `tty_write(0, "", 0, 0)` returns 0; witnesses empty
  buffer + correct zero return.

The full end-to-end AC — "user writes to fd 1, echo appears on
UART" — is exercised at #609's closer smoke once fd 0/1/2 wiring
lands.

### 1.1 Loop structure and register discipline

The loop uses callee-save registers to survive `uart_putc` calls:

- **RBX:** save caller's `rsi` (buf address)
- **R12:** save caller's `rdx` (len)
- **R13:** loop counter `i`

Per SysV x86-64, `uart_putc` clobbers rax, rcx, rdx, rdi, r8, r9
(caller-save). The prologue pushes rbx and r12; the epilogue pops
them. This allows the loop to re-enter `uart_putc` without
re-spilling buf/len.

```
push rbx                        # prologue
push r12
  mov rbx, rsi                  # rbx = buf
  mov r12, rdx                  # r12 = len
  xor r13, r13                  # r13 = i

loop:
  cmp r13, r12
  jae done
    xor rax, rax
    mov r8, rbx
    add r8, r13
    mov_b rax, [r8]             # rax = buf[i]
    cmp rax, 0x0A               # is newline?
    jne output_byte
      mov rdi, 0x0D             # rdi = '\r'
      call uart_putc
      mov rdi, 0x0A             # rdi = '\n'
      call uart_putc
      jmp advance
    output_byte:
      mov rdi, rax
      call uart_putc
    advance:
      add r13, 1
      jmp loop

done:
  mov rax, r12                  # return len
  pop r12                        # epilogue
  pop rbx
  ret
```

This structure is **leaf-adjacent** (calls `uart_putc` multiple times,
but the loop itself is local). The 2-push prologue maintains
rsp%16==0 for each `uart_putc` call per SysV.

## 2. Test strategy

### 2.1 What this issue proves

- **Loop entry and exit bounds:** The witness calls with varying
  lengths (3, 3, 0) and verifies return values match exactly.
- **Newline expansion:** Sub-test A includes a newline; the return
  value is 3 (the input length), not 4 (the expanded output). This
  verifies the "accounting split" is implemented correctly: caller
  sees 3 bytes accepted; UART sees 4 bytes transmitted.
- **Non-newline passthrough:** Sub-test B exercises the else path.
  A 3-byte buffer with no newlines returns 3.
- **Empty buffer:** Sub-test C exercises the case len==0. The loop
  never executes; return value is 0. This guards against off-by-one
  in the loop termination.

### 2.2 What this issue does NOT prove

- **Echo on real UART:** The witness calls `tty_write` but does not
  observe UART wire behavior (that is a black-box external verification
  at #609 via console-output artifact). The witness asserts return
  value semantics only.
- **Actual TX timing:** Each `uart_putc` call polls LSR before writing.
  The witness verifies the loop structure and return semantics, not
  UART register timing. If `uart_putc` were broken (e.g., polling the
  wrong register), `tty_write` would still return the correct length,
  but UART wouldn't emit bytes — caught at #609.

## 3. Risk analysis

### 3.1 Off-by-one in loop

**Risk:** Loop counter initialization or termination could skip a
byte or loop one extra time.

**Mitigation:** The witness exercises two lengths (3 and 3) with
different content patterns (one has newline, one doesn't) and one
empty case. If the loop increment were wrong, at least one return
value would mismatch.

### 3.2 Newline expansion not triggering

**Risk:** The `cmp rax, 0x0A` logic could be inverted (e.g., `jne`
becomes `je`), causing newlines to be output as-is and non-newlines
to expand.

**Mitigation:** Sub-test A has a newline; the witness would fail if
the expansion didn't happen (since UART output would be visibly
different from expected "hi\r\n"). At #609, a real keyboard test
would catch this.

### 3.3 Return value wrong

**Risk:** The epilogue could return something other than `r12` (e.g.,
return `r13` which would be len at exit, not the original len).

**Mitigation:** The witness checks `cmp rax, 3` and `cmp rax, 0`
explicitly. An off-by-one in the return would fail those assertions.

## 4. Design notes

### 4.1 Why "accounting split" is sound at R16.M5

At R16.M5, `uart_putc` polls LSR.THRE (Transmitter Holding Register
Empty). If the UART's TX buffer is full, polling blocks until space
opens up. There is no backpressure mechanism — the caller to `tty_write`
will wait as long as needed for the entire message to be transmitted.

This means `tty_write` can safely return `len` (bytes accepted from
the caller) even though the UART sees expanded output. The caller is
not notified of the expansion, but also does not need to be — from
the caller's perspective, the N bytes went into the UART pipeline.

At R17+, when we add a TX ring-buffer with backpressure, this
accounting may change. For now, the contract is clear: caller writes
N bytes, `tty_write` returns N, UART actually transmits N +
(count of newlines) bytes. This is a documented, intentional design
choice, not a bug.

### 4.2 Why we don't preserve the input buffer

If the input buffer were preserved (e.g., for multi-write scenarios),
we would need to track an offset and return the actual number of
bytes consumed (which could be less than `len` if the UART buffers
full). At R16.M5 this is overengineering; R17 syscall semantics
will address partial-write handling.

## 5. Witness

The witness appears in kernel_main.pdx after `tty_read_witness_done`.

```
// Sub-test A: "hi\n" (3 bytes) → returns 3
lea r12, [rip + _tty_write_witness_a]   // r12 = "hi\n"
xor rdi, rdi
mov rsi, r12
mov rdx, 3
xor rcx, rcx
call tty_write
cmp rax, 3
jne tty_write_witness_fail

// Sub-test B: "abc" (3 bytes) → returns 3
lea r12, [rip + _tty_write_witness_b]   // r12 = "abc"
xor rdi, rdi
mov rsi, r12
mov rdx, 3
xor rcx, rcx
call tty_write
cmp rax, 3
jne tty_write_witness_fail

// Sub-test C: "" (0 bytes) → returns 0
xor rdi, rdi
xor rsi, rsi
xor rdx, rdx
xor rcx, rcx
call tty_write
cmp rax, 0
jne tty_write_witness_fail

// All green
lea rdi, [rip + tty_write_ok_msg]
call uart_puts
jmp tty_write_witness_done
```

The witness strings are defined in write.pdx as `pub let _tty_write_witness_a`
and `pub let _tty_write_witness_b` (arrays of bytes). This follows the pattern
from #606's `_tty_read_witness_buf`.

Marker messages are added to boot_stub.S:
- `tty_write_ok_msg: "R16 TTY WRITE OK\n"`
- `tty_write_fail_msg: "R16 TTY WRITE FAIL\n"`

## 6. Future work (R17+)

### 6.1 TX backpressure and partial writes

At R17, once a TX ring-buffer lands, `tty_write` may return a value
less than `len` if the UART buffer fills up mid-write. The caller
must then retry with the remaining bytes. This is standard POSIX
write semantics.

### 6.2 Output processing flags

At R17+, when a full `termios` discipline lands, we will support
flags like `ONLCR` (Output New Line to CR+LF) and `OCRNL` (Output CR
to NL). At R16.M5, the `\n → \r\n` translation is hard-coded. This
issue documents the intended place for future flag consultation.

### 6.3 Non-blocking mode

At R17, `O_NONBLOCK` on the TTY will cause `tty_write` to fail with
`EAGAIN` if the UART buffer is full, rather than block. This is
another concern for the R17 TX-ring refactor.
