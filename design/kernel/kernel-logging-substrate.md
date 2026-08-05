---
doc: kernel-logging-substrate
scope: Cross-cutting kernel diagnostics + structured logging
status: Design v0.1 (proposal — pre-implementation)
issues: (this design is the referent; downstream issues filed as `logging-mN-NNN-...`)
subsystem: kernel diagnostics / observability
prereq:
  - "paideia-as ≥ 0.20 (rdtsc, cr* reads, cmp-sized, unsafe-block emit stability — all landed)"
  - "src/kernel/boot/uart.pdx (uart_putc/uart_puts polling primitives — landed)"
  - "src/kernel/core/mm/panic_trace.pdx (module scaffold with PANIC_TRACE_SIZE=4096 — stub, unused)"
blocks:
  - "any future dmesg-visible-capability work"
  - "any userspace log-stream syscall"
  - "meaningful triage of hangs like #679 (shell reaches iretq, no output)"
related:
  - design/audit/log-structure.md              (audit log — persistent, PQ-signed; disjoint from kernel dmesg)
  - design/kernel/r14b-m5-008-cr0-wp-substrate.md (exemplar of doc depth + phasing)
  - src/kernel/boot/uart.pdx                   (polling UART primitives)
  - src/kernel/core/int/exceptions.pdx         (current exc_handle — the single "EXC HALT" call site)
  - src/kernel/core/mm/panic_trace.pdx         (ring buffer stub to be reused)
  - tools/boot_stub.S                          (80+ ad-hoc `_msg` rodata strings — the migration target)
  - tools/run-smoke.sh                         (contains-in-order fingerprint semantics — the compatibility contract)
---

# Kernel logging + diagnostics substrate

## 0. Motivation

### 0.1 The black hole

Issue #679 recorded a symptom: after the shell reaches its ring-3 `iretq`
boundary, the serial log falls silent — no `$` prompt, no fault, no
marker. The kernel is either spinning, hung on an unmapped page, faulting
into another fault, or executing correctly with no output side-effect —
and the log **cannot distinguish** those four cases. The root cause
(`_kernel_pml4_pa` symbol collision between `kpti.pdx` and
`trampoline_data.pdx`) was only findable because a manual probe was
inserted, `exc_handle` was patched to emit `EXC HALT` before its `hlt`,
and a bisection was run by hand.

Every kernel that has ever shipped has a `printk`. paideia-os does not.
Every emit today is a hand-rolled `lea rdi, [rip + xxx_msg]; call
uart_puts` with **no severity, no timestamp, no CPU id, no task
context, no exception vector, no CR2, no register file**. The exception
path (`exc_handle`) prints two words (`EXC HALT`) and halts. The panic
path *does not exist*: `cpu_halt` is a bare `hlt`. The 80+ rodata
strings in `tools/boot_stub.S` are each one static message with no
structure, no filter, no post-mortem visibility.

This document specifies the substrate that fixes it, in a phased
rollout that keeps the current serial-fingerprint contract working
throughout.

### 0.2 What "proper logging" buys, concretely

- Any future black-hole (unmapped page, IRQ-in-IRQ, silent triple-fault,
  wrong CR3) surfaces in the log with vector + RIP + CR2 + PID + TSC —
  triage minutes, not hours.
- `panic()` becomes a real word: freeze, dump, halt. Any `assert`ion
  failure carries its file/line/expected/actual.
- Boot progress becomes filterable: `DEBUG` witnesses off in prod
  fingerprints, `INFO` boot markers stable across releases, `ERROR`
  lines never lost in the scroll.
- Post-mortem via ring buffer: even when the UART TX FIFO is full or the
  IRQ path is deadlocked, the last N structured lines survive in .bss
  for the next boot's crash-dump reader or an in-kernel `dmesg` reader.
- A single format the userspace log-daemon can parse without heuristics.

## 1. Non-goals

Deliberately out of scope for this substrate. Each has a reason and (where
applicable) a downstream owner.

1. **Persistent / on-disk log.** `design/audit/log-structure.md` owns
   the durable, PQ-signed audit log at `/system/audit/log.pdaudit`.
   This substrate is **volatile diagnostic (dmesg)**, not audit; the two
   pipelines are disjoint by design. Kernel `dmesg` can *emit into*
   the audit log later via an IPC-visible capability, but that is
   R-post-M9 work.

2. **printf-style formatting.** paideia-as has no varargs, no format
   parser, no int→string library. Rather than build one, this design
   uses a fixed set of **per-arity emit helpers** (`klog_s1`,
   `klog_s1_x1`, `klog_s2_x2`, etc. — see §5). This is a language
   constraint made into a design principle: no format-string injection
   surface, no allocator, no macro expander.

3. **Cross-CPU log ordering.** At R14b we are single-CPU; even at R18+
   with SMP, per-CPU ring buffers + monotonic TSC + drain thread will
   suffice. Global total ordering across cores is not attempted; it
   would require a shared spinlock on the hot log path, which is
   antithetical to the multicore-first principle.

4. **Log rotation / bounded persistence.** The kernel ring is fixed
   size (default 64 KiB / ~1000 lines). Overwrites drop oldest. No
   compression, no rotation, no eviction policy beyond FIFO. Rotation
   is a userspace log-daemon concern.

5. **Kernel tracing / eBPF-equivalent.** Not this. If we ever want
   dynamic probes, they get their own subsystem.

6. **Removal of legacy per-witness markers.** The 80+ `xxx_ok_msg`
   / `xxx_fail_msg` strings in `boot_stub.S` are **not** deleted. They
   are re-emitted through `klog_s1(SUBSYS_BOOT, LEVEL_INFO, tag)` where
   `tag` is the same ASCII text. `run-smoke.sh`'s contains-in-order
   fingerprint check keeps working: the tag is a substring of the
   structured line.

7. **Encryption / PQ-signing of kernel dmesg lines.** Audit-log
   territory. Kernel dmesg is diagnostic, not attestation.

## 2. Current state — one-page audit

| Concern                    | Today                                                                                   |
|----------------------------|-----------------------------------------------------------------------------------------|
| Emit primitive             | `call uart_puts` with `lea rdi, [rip + xxx_msg]`. Polls THRE; blocking; single-CPU-safe. |
| Emit sites                 | ~265 `uart_puts` call sites across `src/kernel/**/*.pdx` + `tools/boot_stub.S`.          |
| Message strings            | 80+ `.global xxx_msg; .ascii "..."` in `tools/boot_stub.S` (~one per witness).           |
| Severity                   | None. Every line has the same weight.                                                    |
| Filter                     | None. Every line always emits.                                                           |
| Timestamp                  | None. TSC is available (`rdtsc` encoded — used by `kind_timer.pdx`, `lapic_isr.pdx`).    |
| CPU id                     | Not printed. Available via APIC ID read + soon per-CPU GS_BASE (#657).                   |
| Task PID                   | Not printed. Available in `_current_tcb → offset 0`.                                     |
| Exception dump             | `exc_handle` emits `EXC HALT\n` then `hlt`. Vector is stored in `last_vector` (not emitted). CR2 read into `last_cr2_read` (not emitted). No RIP, no CS, no error-code, no register file. |
| Panic path                 | `cpu_halt` = bare `hlt`. No dump, no ring-buffer flush, no IPI-halt-APs.                 |
| Assertion primitive        | None. `unsafe { cmp; jne panic }` patterns are hand-rolled; #663 has one soft-panic pattern (cli; hlt loop, no marker). |
| Stack trace                | Never emitted.                                                                           |
| Ring buffer / dmesg        | `panic_trace.pdx` module exists (12 LOC stub, `PANIC_TRACE_SIZE = 4096`); unused.        |
| IRQ safety                 | `uart_puts` is blocking on THRE; a #PF-in-#PF while inside `uart_puts` would recurse into the same `handle_pf → uart_puts → poll` and either deadlock on THRE, corrupt the fault-in-fault trap frame, or triple-fault. |
| Multi-CPU                  | Not tested. `uart_puts` has no lock — first AP to log while BSP is logging will interleave bytes. |
| Fingerprint contract       | `tools/run-smoke.sh` reads `/tmp/paideia-os-smoke.log` and grep-in-orders for each line of `tests/rN/expected-*.txt`. Any line-substring appearing in order is a pass. |
| Int→string helpers         | **None.** No `u64_to_hex`, no `u64_to_dec`. Every emit today is a static string only.    |

## 3. Format specification

### 3.1 Design principles

- **One line per emit.** Terminated by `\n\0` (uart_puts stops on NUL).
  Multi-line dumps (register file, stack trace) are multiple emits.
- **Fixed-width fields where practical.** TSC as 16-hex-nibbles; CPU as
  1-hex-digit (SMP up to 15) or 2-hex-digits (SMP up to 255); level as
  1 letter; subsystem as fixed-4-letter tag. Fixed widths mean the
  userspace log-daemon parses via byte offset, not tokenizing.
- **ASCII-only, printable.** No terminal escape codes at the kernel
  level. Colorization is a userspace concern.
- **Grep-friendly.** Every line ends with a `tag` which is a short
  human-readable phrase (e.g. `KPTI OK`, `PF FAULT`, `SHELL SPAWN`).
  Fingerprint files continue grepping by tag substring.
- **No embedded delimiter collision.** `|` separates fields; tags and
  key-value strings **must not** contain `|`. Enforced at authorship
  (compile-time by convention).
- **Extensible key=value tail.** After the fixed prefix, zero or more
  `key=value` tokens separated by spaces. Values are hex (`0x...`) or
  decimal by convention. No quoting; keys and hex values contain no
  spaces.

### 3.2 EBNF

```
log-line       = prefix "|" tag [ " " kv-tail ] "\n"
prefix         = tsc "|" cpu "|" level "|" subsys
tsc            = 16*HEXDIG                   ; TSC ticks, hex, zero-padded
cpu            = 1*HEXDIG                    ; APIC ID or logical CPU id, hex
level           = "P" / "E" / "W" / "I" / "D" / "T"
                 ; PANIC / ERROR / WARN / INFO / DEBUG / TRACE
subsys         = 4*ALPHA                     ; fixed-4-char subsystem tag
                 ; BOOT MM_ INT_ TASK SCHD CAP_ IPC_ VFS_ TTY_ FS__ USER PANC
tag            = 1*(ALPHA / DIGIT / SP)      ; short human phrase, NO "|" NO "="
kv-tail        = kv *( SP kv )
kv             = key "=" value
key            = 1*(ALPHA / DIGIT / "_")
value          = hex-value / dec-value / short-word
hex-value      = "0x" 1*HEXDIG
dec-value      = 1*DIGIT
short-word     = 1*(ALPHA / DIGIT / "_" / ".")
```

### 3.3 Rendered examples

```
0000000012ab34cd|0|I|BOOT|CR0 WP OK
0000000012ab54e2|0|I|KPTI|OK
0000000012ac0912|0|D|SCHD|switch prev=1 next=2
0000000012ad4478|0|W|MM  |phys_alloc low frags=3
0000000012ae1023|0|E|INT |PF fault vec=14 err=0x3 cr2=0x400000 rip=0xffff8000c0002a44 pid=1
0000000012ae1024|0|P|PANC|assert failed file=exceptions.pdx line=304 exp=1 got=0 cpu=0 pid=1
```

The 4-char subsystem field is **padded with `_`** where the name is
shorter (e.g. `MM__`, `INT_`, `FS__`). This preserves fixed-width
byte-offset parsing.

### 3.4 Backwards compatibility with existing fingerprints

Every existing fingerprint file entry (e.g. `R14B CR0 WP OK`, `R15
RING3 HELLO OK`, `KPTI OK`) is exactly the `tag` field of a future
klog line. `tools/run-smoke.sh`'s contains-in-order semantics
(`[[ "${remaining}" == *"${line}"* ]]`) matches the substring
regardless of the surrounding TSC/CPU/level/subsys prefix. Therefore:

- **Zero fingerprint files change** during the migration.
- **Zero smoke modes break** as long as the tag text is preserved
  verbatim.
- The migration issue (M7) is a text-preserving refactor of the
  emit *primitive*; the emit *content* stays identical.

## 4. Severity levels

```
LEVEL_PANIC = 0    ; unrecoverable; ring buffer flushed, all CPUs halted
LEVEL_ERROR = 1    ; subsystem broken but kernel can continue
LEVEL_WARN  = 2    ; unusual state, not a fault
LEVEL_INFO  = 3    ; boot markers, witness OKs, state transitions
LEVEL_DEBUG = 4    ; per-syscall tracing, IRQ counts (default OFF in prod)
LEVEL_TRACE = 5    ; per-instruction / per-page-walk (default OFF; costly)
```

Two orthogonal filters:

- **Compile-time gate.** `KLOG_COMPILE_LEVEL` is a module-scope `let`
  constant in `src/kernel/core/klog/level.pdx`. Emit helpers whose
  static level is greater than `KLOG_COMPILE_LEVEL` compile to a
  single `ret`. Because paideia-as has no `#ifdef`, the gate is a
  runtime `cmp` + `jle` that the branch predictor eats; DEBUG/TRACE
  helpers *also* wrap their body in an early return so the field
  formatting is skipped entirely (see §5.3).
- **Runtime gate.** `_klog_runtime_level` is a `pub let mut u64` set
  by the boot sequence (default INFO) and mutable via a future
  `kctl` capability. Emit helpers check both gates in a single 5-op
  prologue.

Compile-time levels the workerbee should set per profile:

| Profile        | KLOG_COMPILE_LEVEL | Rationale                                         |
|----------------|--------------------|---------------------------------------------------|
| prod           | INFO (3)           | Boot + errors. No per-syscall spam.               |
| smoke          | INFO (3)           | Fingerprints depend on INFO markers.              |
| debug          | DEBUG (4)          | Local bring-up; DEBUG is `let mut` at boot.       |
| trace          | TRACE (5)          | Deep bisection; recompile with the constant flipped. |

Toggle discipline: bumping the constant is a two-line diff and a full
rebuild; runtime bumps require a boot-time boolean (`-debug` on the
QEMU command-line via a magic port write, TBD in M8).

## 5. Primitives

### 5.1 Register / effect discipline

Every klog primitive lives in `unsafe {}` (writes to UART port + `.bss`
ring buffer). Effect signature:

```
!{sysreg, mem} @{}
```

- `sysreg` — I/O port write to 0x3F8/0x3FD, and `rdtsc` (which is a
  ring-0 privileged read at PCE=0).
- `mem`    — writes to `_klog_ring` (`.bss`) and `_klog_ring_head`.
- No capability required at kernel scope (per exceptions.pdx pattern).

Register clobber contract (all klog helpers):

- Preserves: `rbx`, `rbp`, `r12`-`r15` (SysV callee-save).
- Clobbers:  `rax`, `rcx`, `rdx`, `rsi`, `rdi`, `r8`-`r11`.

Callers rely on this identically to how they rely on `uart_puts`
today (see e.g. `_typed_handler_6`'s `mov r12, rdi` save around the
`call uart_puts` — the same pattern applies unchanged).

### 5.2 Per-arity helpers (naming grammar)

Because paideia-as has no varargs, we define one helper per emit
shape. Shape is encoded in the suffix; **s** = string tag, **x** = hex
u64, **d** = decimal u64.

```
klog_s1  (level, subsys, tag)                              ; "SUBSYS|LEVEL|tag"
klog_s1_x1(level, subsys, tag, k, v)                       ; "... tag k=0x..v"
klog_s1_x2(level, subsys, tag, k1, v1, k2, v2)
klog_s1_x3(level, subsys, tag, k1, v1, k2, v2, k3, v3)
klog_s1_x4(level, subsys, tag, k1, v1, k2, v2, k3, v3, k4, v4)
klog_s1_d1(level, subsys, tag, k, v)                       ; "... k=NNN"
klog_s1_x1_d1(level, subsys, tag, kx, vx, kd, vd)
```

Coverage rule: any emit that needs more slots than the highest-arity
helper (`x4` at ~9 args) is decomposed into two adjacent lines; the
prefix carries the same TSC + tag so the two lines are joinable in
post.

`k` (key) arguments are passed as pointers to 8-char NUL-terminated
rodata strings, one per key symbol (`k_cr2`, `k_rip`, `k_pid`, …). This
avoids marshalling strings through registers.

### 5.3 The one central emit function

`klog_emit_core(level, subsys, tag_ptr, kvs_ptr, kv_count)` is the sole
site that touches the UART and the ring buffer. Every arity wrapper
composes its arguments and calls it. The core body:

```
1. filter check:  if level > _klog_runtime_level: ret
                  if level > KLOG_COMPILE_LEVEL: ret  ; folded by workerbee at rebuild
2. atomic prologue: cli; save RFLAGS (nested-IRQ safety, §7)
3. rdtsc → r14 (surviving)
4. read CPU id from GS_BASE offset _cpu_id, or 0 pre-SMP → r15
5. render prefix into a stack buffer:  "TSC|CPU|L|SUBSYS|" (fixed 24 bytes)
6. append tag_ptr (via uart_puts-style byte copy)
7. iterate kvs: append " KEY=VAL"
8. append "\n\0"
9. copy buffer into _klog_ring at _klog_ring_head, advance head mod ring_size (§6)
10. drain to UART: while THRE-poll available, write next byte from tail
11. atomic epilogue: restore RFLAGS
12. ret
```

The stack buffer is a fixed 256-byte area in the caller-supplied
frame (`sub rsp, 256` at prologue, `add rsp, 256` at epilogue).
Overruns are impossible at authorship-time given the arity bound (x4
+ tag ≤ ~200 bytes worst case).

### 5.4 Int→string helpers (M0 prerequisites)

Two leaf helpers, both callable from anywhere (no effects beyond
memory writes to caller-supplied buffer):

```
u64_to_hex(value, buf_ptr) -> buf_end_ptr   !{} @{}
    ; writes exactly 18 bytes: "0x" + 16 hex nibbles
    ; returns buf_ptr + 18

u64_to_dec(value, buf_ptr) -> buf_end_ptr   !{} @{}
    ; writes 1..20 bytes (decimal representation of u64)
    ; returns buf_ptr + written_len
```

Both are pure register-arithmetic (no allocation, no branches beyond
loop counter). u64_to_hex is single-pass right-to-left with a
static 16-entry lookup rodata (`"0123456789abcdef"`); u64_to_dec is
divide-by-10 in a buffer-reversed staging pattern. LOC ~40 each.

### 5.5 TSC + CPU-id read helpers

```
kread_tsc() -> u64          !{sysreg} @{}   ; rdtsc + combine EDX:EAX
kread_cpu_id() -> u64       !{sysreg, mem} @{}
    ; pre-SMP: return 0
    ; post-SMP: read [gs:_cpu_id] via kernel GS_BASE per #657
```

Both are ~10 LOC. `rdtsc` is already used in `core/timer/lapic_isr.pdx`
and `core/cap/kind_timer.pdx` — encoder support is proven.

## 6. Ring buffer

### 6.1 Layout

`src/kernel/core/klog/ring.pdx`:

```
KLOG_RING_SIZE : u64 = 65536      ; 64 KiB, fixed; ~1000 avg lines
_klog_ring     : [u8; KLOG_RING_SIZE]   ; in .bss, zeroed at boot
_klog_ring_head: u64 = 0          ; monotonic write cursor
_klog_ring_tail: u64 = 0          ; drain-to-UART cursor
```

Both head and tail are monotonic u64 counters (never wrap in practice
— 2^64 bytes at 1 line/µs is > 500 000 years). The actual byte index
is `head & (KLOG_RING_SIZE-1)`. Overwrite: when `head - tail >
KLOG_RING_SIZE`, the oldest bytes are considered lost (tail is
advanced along with head to preserve `head - tail ≤ RING_SIZE`).

### 6.2 Write path

`klog_ring_write(buf_ptr, len)`:
1. Compute `wrap_idx = head & (SIZE-1)`.
2. If `wrap_idx + len ≤ SIZE`: single `rep movsb`-shape copy.
3. Else: two copies split at the wrap.
4. `head += len`.
5. If `head - tail > SIZE`: advance `tail = head - SIZE` (drop oldest).

Register discipline: `rdi, rsi, rcx, rax` only. Callee-save preserved.
LOC ~40.

### 6.3 Drain path

The UART is the *only* sink at R18. `klog_ring_drain_to_uart()`:
- While `tail < head` and THRE=1:
  - Load byte at `[_klog_ring + (tail & SIZE-1)]`.
  - Write to `[0x3F8]`.
  - `tail += 1`.
- Return (does NOT spin on THRE — if UART is backed up, drain stops
  and the ring retains bytes; the next emit will drain more).

At R18 the drain is called at the tail of every `klog_emit_core`. At
R19+ the drain becomes a low-priority softirq or is attached to the
UART-TX-empty IRQ (currently only RX is IRQ-driven per
`core/uart/rx_isr.pdx`).

### 6.4 Panic dump

`klog_ring_dump_panic()` bypasses THRE polling — it busy-writes every
ring byte to `[0x3F8]` regardless of TX FIFO state (bytes past the
FIFO are dropped by QEMU; on real hardware they may drop until an
adapter buffers them, which is acceptable at panic-time). Prefixes
dump with `====== PANIC DUMP BEGIN ======\n`, suffixes with `======
PANIC DUMP END ======\n`, both structured klog lines.

## 7. IRQ / re-entrancy safety

### 7.1 The recursion hazard

Today: any exception fired *inside* `uart_puts` (e.g. #PF while THRE
polling — impossible in QEMU but possible on real hardware with
misconfigured LAPIC LVT MCE) recurses through `handle_pf →
exc_handle → uart_puts → poll → #PF`. There is no re-entrancy guard,
and the trap-frame push order does not carry a per-CPU
"already-in-log" flag.

### 7.2 The gate

`_klog_in_progress` is a per-CPU u64. `klog_emit_core`'s prologue:

```
mov rax, [gs:_klog_in_progress]     ; pre-SMP: [rip + _klog_in_progress_bsp]
cmp rax, 0
jne klog_emit_reentrant             ; skip UART; write to ring only
mov qword [gs:_klog_in_progress], 1
```

Epilogue clears it. When re-entrant, the ring gets the line (still
useful for post-mortem) but the UART drain is skipped so no
deadlock. The outer call resumes and drains at its own epilogue.

`klog_emit_reentrant`:
1. Render prefix into stack buffer.
2. Copy to ring buffer only (no UART touch).
3. Return.

### 7.3 CLI window

The `cli; ...; popfq` window around each emit is < 200 cycles
(prefix render + 1-2 stringlets + ring write) — well under any
timer-tick budget. `cli` inside an already-cli-holding context is
idempotent (RFLAGS.IF stays 0). No release before the tail drain.

## 8. Exception dump

### 8.1 dump_trap_frame helper

Callers pass the trap-frame pointer (already in `rdi` for every typed
handler per §3.3.3 of `r14b-m5-008-cr0-wp-substrate.md`). The helper
extracts and emits, in order:

```
klog_s1_x4(LEVEL_ERROR, "INT_", "TRAP FRAME",
           k_vec,   [rbp + 128],
           k_err,   [rbp + 128 + 8],
           k_rip,   [rbp + 128 + 16],
           k_cs,    [rbp + 128 + 24])
klog_s1_x4(LEVEL_ERROR, "INT_", "TRAP FRAME",
           k_rfl,   [rbp + 128 + 32],
           k_rsp,   [rbp + 128 + 40],
           k_ss,    [rbp + 128 + 48],
           k_pid,   [_current_tcb + 0])
```

For #PF, one additional line:

```
klog_s1_x1(LEVEL_ERROR, "INT_", "PF", k_cr2, cr2)
```

Register dump (RAX..R15) is a third block, emitted only when
`KLOG_COMPILE_LEVEL ≥ DEBUG`.

Offsets follow the trampoline push order in `core/int/idt.pdx:174-192`
(vector 14 template) — canonical `rax,rcx,rdx,rbx,rbp,rsi,rdi,r8-r15
(15 pushes), then errcode-or-placeholder, then vector` — with the
CPU-pushed frame `RIP,CS,RFLAGS,RSP,SS` starting at `[rbp+128+16]`.

### 8.2 Wiring

`exc_handle` (currently the single 6-line halt) becomes:

```
push r12
mov r12, rdi                          ; frame_ptr
mov rdi, r12
call dump_trap_frame
call klog_ring_dump_panic             ; flush ring before hlt
mov r12, rdi                          ; restore for downstream
pop r12
cli
hlt
```

Every typed handler (`_typed_handler_0/3/6/8/13/14`) receives an
additional entry line before its existing dispatch:

```
mov r12, rdi
klog_s1(LEVEL_DEBUG, "INT_", "vecN entry")   ; compiled out in prod
mov rdi, r12
```

Witness paths (vec 6/13's flag-check + resume) are unchanged in
semantics but their per-vector emit lines shift from raw uart_puts
to `klog_s1(INFO, "INT_", "R14 UD OK")` etc.

## 9. Panic path

### 9.1 panic() signature

```
panic(subsys, tag_ptr) -> ()   !{sysreg, mem} @{}   ; never returns
```

Bodies:

1. `cli` — inhibit further IRQs on this CPU.
2. `klog_s1(LEVEL_PANIC, subsys, tag_ptr)` — the panic line.
3. `dump_trap_frame(current_frame)` — if we have one (from exception
   entry). Panic from non-exception context skips.
4. IPI-halt-all-other-CPUs via `tlb_shootdown_broadcast`-shape IPI to
   a new `vec33_halt` handler that `cli; hlt`s (R18+ multicore only —
   R17 no-op).
5. `klog_ring_dump_panic()` — flush.
6. Write `0x11` to `isa-debug-exit` port `0xf4` — QEMU exits with
   code 35 (per run-smoke.sh convention: fail-exit code).
7. `cli; hlt; jmp $-1` — belt & braces.

### 9.2 Panic-from-panic

`_klog_in_progress` is checked at panic entry too. If already set,
skip step 3-4 (avoid nested faults) and go straight to step 5.

### 9.3 Existing cpu_halt call sites

Every current `cpu_halt` call migrates to `panic(SUBSYS, "HALT")`.
This is ~10 call sites (mostly witness-fail paths in `kernel_main.pdx`).
Migration is trivially per-site.

## 10. Stack trace

### 10.1 RBP-chain walker

paideia-as emits standard SysV frame prologues (`push rbp; mov rbp,
rsp`) for functions with locals. The RBP chain follows:

```
kwalk_rbp(start_rbp) -> ()   !{sysreg, mem} @{}
    mov rax, start_rbp
    mov rcx, 8                       ; frame counter
walk_top:
    cmp rax, 0
    je walk_done
    test rax, 7
    jnz walk_done                    ; misaligned → stop
    ; check rax is a canonical higher-half address
    mov rdx, 0xFFFF800000000000
    cmp rax, rdx
    jb walk_done
    ; load saved rbp + return addr
    mov r8, [rax]                    ; saved rbp
    mov r9, [rax + 8]                ; return addr
    ; emit
    klog_s1_x2(LEVEL_ERROR, "PANC", "FRAME", k_rip, r9, k_rbp, rax)
    mov rax, r8
    dec rcx
    jnz walk_top
walk_done:
    ret
```

Max 8 frames. Falls off on misaligned rbp, null, or below higher-half
canonical range. No symbol resolution at R18 (RIPs are raw hex);
symbolication is a userspace / build-time job (parse `nm -n` output).

### 10.2 Integration

`panic()` step 3.5 calls `kwalk_rbp(rbp)` between the trap dump and
the ring dump. Assertion failures (M6) pass the frame pointer of the
asserting site.

## 11. Assertions + BUG-check

### 11.1 kassert primitives

No macro system in paideia-as. We define an emit-and-panic helper and
canonical unsafe-block patterns.

```
kassert_fail(subsys, file_id, line, expected, actual) -> () !{sysreg,mem} @{}
    ; klog_s1_x2(PANIC, subsys, "ASSERT",   k_exp, expected, k_got, actual)
    ; klog_s1_x1_d1(PANIC, subsys, "AT",   k_file, file_id, k_line, line)
    ; panic(subsys, "assertion failed")   ; never returns
```

Callers wrap conditionals in an unsafe block:

```
unsafe {
    ...
    block: {
        mov rax, [rip + something]
        cmp rax, EXPECTED
        je  ok
        mov rdi, SUBSYS
        mov rsi, FILE_ID
        mov rdx, LINE
        mov rcx, EXPECTED
        mov r8,  rax
        call kassert_fail                    ; noreturn
    ok:
        ...
    }
}
```

`FILE_ID` is a compile-time-known u64 index into a per-file rodata
symbol table (`_klog_files[]`) generated at build-time by a
`tools/gen-file-ids.sh` pass that indexes every `.pdx` under
`src/kernel/`. Line numbers are passed as immediates by the author
(no `__LINE__` macro; discipline: hand-write the current line at
authorship).

An alternative — file-string ptr passed directly, symbol per file —
is documented in §14 as an option; the ID-table approach is chosen for
compactness (a 2-byte ID vs an 8-byte pointer per assertion).

### 11.2 BUG_ON pattern

`BUG_ON(cond)` = `kassert_fail(subsys, file_id, line, 0, 1)` when
`cond` holds. Same convention.

## 12. Migration plan

### 12.1 Phase M0 — primitives (independent, non-invasive)

Lands the leaf helpers with **zero** call-site changes. New files:
- `src/kernel/core/klog/hex.pdx`   — u64_to_hex, u64_to_dec  (~80 LOC)
- `src/kernel/core/klog/tsc.pdx`   — kread_tsc, kread_cpu_id (~30 LOC)

No fingerprint change; no existing behavior change.

### 12.2 Phase M1 — core substrate (additive, unused)

New files:
- `src/kernel/core/klog/level.pdx`  — level constants + runtime gate (~30 LOC)
- `src/kernel/core/klog/subsys.pdx` — subsystem tag constants (~40 LOC)
- `src/kernel/core/klog/emit.pdx`   — klog_emit_core + per-arity wrappers (~250 LOC)
- `src/kernel/core/klog/keys.pdx`   — canonical k_cr2, k_rip, etc. rodata (~30 LOC)

All new symbols. No existing call site touched. Fingerprints
unchanged.

### 12.3 Phase M2 — ring buffer (additive, unused)

New:
- `src/kernel/core/klog/ring.pdx`   — write path + drain + panic dump (~100 LOC)

Deletes stub `src/kernel/core/mm/panic_trace.pdx` (moved to
`klog/ring.pdx`; its `PANIC_TRACE_SIZE=4096` constant is superseded by
`KLOG_RING_SIZE=65536`).

`emit.pdx` gains a call to `klog_ring_write` post-render. Still no
external call-site change. Fingerprints unchanged.

### 12.4 Phase M3 — exception dump (invasive, additive)

Wires `dump_trap_frame` into `exc_handle` and adds the entry-line
klog to each `_typed_handler_N`. Existing `EXC HALT` emit stays, now
emitted through `klog_s1(ERROR, "INT_", "EXC HALT")` (tag preserved,
fingerprint unchanged). CR2 dump line is *new* — fingerprint files
for boot modes that fault (currently: none in the smoke set) get a
new line at exception time.

**Fingerprint impact**: `EXC HALT` line format changes from raw
`EXC HALT\n` to `TSC|CPU|E|INT_|EXC HALT\n`. Contains-in-order still
passes. **Verified compatible.**

### 12.5 Phase M4 — panic path (invasive, semantics change)

`cpu_halt` becomes `panic(SUBSYS_BOOT, "cpu_halt")`. All existing
`call cpu_halt` sites now dump before halting. QEMU exit code changes
from 33 (idle timeout) to 35 (isa-debug-exit failure byte). **This
is a smoke-mode change**: run-smoke.sh's exit-code interpretation
must be updated in the same commit. Not all halts are panics — the
`hlt` in idle-task and the `hlt` at the end of successful boot
witnesses stay as bare `hlt` (not `panic`).

### 12.6 Phase M5 — stack trace (additive)

`kwalk_rbp` addition + one call site in `panic()`. No existing
behavior change on successful boots (no panics fired). Panic
fingerprint gets 0-8 additional `FRAME` lines.

### 12.7 Phase M6 — assertions (invasive, targeted)

Land `kassert_fail` + `_klog_files[]` table. First integrations are
opportunistic: replace 5-10 existing hand-rolled `cmp; jne panic`
patterns in high-value spots (VFS reads, aspace_map postconditions,
frame_meta bounds). Zero mandatory conversions; keep momentum by
converting during subsequent bug fixes.

### 12.8 Phase M7 — call-site migration (bulk, mechanical)

Convert ~265 `call uart_puts` sites to `call klog_s1(INFO, SUBSYS,
tag)`. Batched by subsystem to keep each PR small:

- **M7-a**: `core/cap/kind_*.pdx`  (~15 sites)
- **M7-b**: `core/int/exceptions.pdx` + `core/int/*` (~20 sites)
- **M7-c**: `core/mm/*.pdx`         (~30 sites)
- **M7-d**: `core/sched/*.pdx` + `core/thread/*.pdx` (~15 sites)
- **M7-e**: `core/fs/*.pdx` + `core/tty/*.pdx` (~40 sites)
- **M7-f**: `core/uart/*.pdx` + `core/loader/*.pdx` (~15 sites)
- **M7-g**: `boot/kernel_main.pdx`  (~100+ sites; the largest, all boot witnesses)
- **M7-h**: `tools/boot_stub.S`     (rodata strings kept, but rewritten as `.global _tag_xxx: .ascii "xxx OK\0"` — no trailing `\n` since klog appends the `\n` after the tag)

Every M7 sub-issue asserts: **all fingerprint files pass unchanged**
before landing.

### 12.9 Phase M8 — testing

- `boot_panic_smoke` — new mode that force-panics (`ud2` in kernel-main,
  or a dedicated witness) and asserts the dump contains `PANIC DUMP
  BEGIN`, `TRAP FRAME`, `vec=6`, `PANIC DUMP END`.
- Fingerprint: `tests/logging/expected-panic-dump.txt`.

### 12.10 Phase M9 — future observability (post-R18)

- Kernel `dmesg` capability — IPC-visible endpoint returning ring
  contents.
- `sys_dmesg(buf, len)` syscall — kernel-to-userspace copy of ring
  tail. Reserved but not implemented at M9 scope.
- Audit-log bridge — a subset of PANIC + selected ERROR lines forwarded
  to the persistent audit log per `design/audit/log-structure.md`.

## 13. Testing / verification

Each phase M0..M6 has a self-contained witness in `kernel_main.pdx`
that fires under the existing smoke matrix — none add a new smoke
mode until M8. Witness format:

- M0: emit `LOGP HEX OK` after two `u64_to_hex(0xDEADBEEF, buf)` +
  compare against `"0x00000000deadbeef"`.
- M1: emit one `klog_s1(INFO, BOOT, "M1 EMIT OK")` and one
  `klog_s1_x1(INFO, BOOT, "M1 X1", k_cr2, 0xDEAD)`; grep for both in
  the log.
- M2: emit 2000 lines (overwrite the 64-KiB ring 2x), verify head
  advances past size + tail = head - size.
- M3: rearm a #UD witness with the new dump helper; assert log
  contains `vec=6 rip=0x...`.
- M4: force-panic in a gated smoke witness; assert exit code 35 + log
  contains `PANIC DUMP END`.
- M5: same panic, assert log contains ≥ 1 `FRAME` line.
- M6: force an `kassert_fail(SUBSYS_BOOT, 42, 100, 1, 0)`; assert log
  contains `ASSERT exp=0x...1 got=0x...0`.

Every witness has an OK marker and a FAIL marker. Fingerprints for
each new witness ship in the same issue.

## 14. Open questions

**Q1. File-ID vs file-string in kassert_fail.**
Option A (chosen in §11): 2-byte file ID + build-time table.
Option B: 8-byte pointer to a per-file rodata string.
A is more compact but requires build-time table generation; B is
simpler but bloats every assertion by 6 bytes. Decision: A. Revisit
if the table generator becomes a maintenance burden.

**Q2. Ring buffer size 64 KiB — enough?**
At ~64 avg bytes/line, 64 KiB = ~1000 lines. Boot alone emits ~150
markers today. A panic mid-boot needs to preserve all boot markers
plus the panic dump; 1000 fits comfortably. If tracing gets enabled
in production the ring will churn; that's a compile-time OFF for
TRACE anyway.

**Q3. Per-CPU rings vs one shared ring.**
R18 = 1 CPU: one shared ring is correct. R19+ multi-CPU: per-CPU
rings + a global "sort-merge on drain" pass is preferred over a
locked shared ring. Defer decision to R19 SMP bring-up; the current
`_klog_ring` symbol becomes `_klog_ring_bsp` and per-CPU copies are
added via GS_BASE offsetting.

**Q4. UART TX IRQ vs polling drain.**
Post-M9 candidate: attach the drain to the UART's TX-empty IRQ (LSR
bit 6). Removes the busy-poll from emit-hot-path. Currently only
UART RX is IRQ-driven (`core/uart/rx_isr.pdx`); TX IRQ needs a
matching setup. Deferred to a post-M8 issue.

**Q5. What color are the level letters?**
No color at the kernel level (§3.1). If a userspace log-daemon wants
to colorize, it maps `P/E/W/I/D/T` to ANSI codes. This design does
not open that door.

**Q6. Where does `boot_stub.S`'s 80+ `_msg` strings go post-M7?**
Two choices: (a) move to per-subsystem rodata under
`src/kernel/core/klog/tags/*.pdx`; (b) leave in `boot_stub.S` and
rename to `_tag_boot_xxx` for consistency. Choice (b) is smaller
diff, preferred; boot_stub.S becomes the "canonical boot tag
registry."

## 15. Backtrack strategy

Standard project discipline: each phase is landable and revertable
independently. Backtrack candidates:

**BT-A: klog_emit stack buffer overflow.**
If any per-arity helper's rendered line exceeds 256 bytes, the CLI
window's stack write corrupts the caller frame. Mitigation: static
authorship discipline (arity ≤ x4). Detection: M8 adds a witness
that emits max-length lines and asserts ring integrity.

**BT-B: rdtsc as ring-0-only.**
If CR4.PCE is 0 (default), rdtsc in kernel is fine; if userspace ever
touches CR4.PCE it's a userspace concern. No backtrack needed.

**BT-C: paideia-as `mov qword [gs:off], imm` gap.**
The `_klog_in_progress` gate needs a GS-relative store. If paideia-as
does not encode it, fall back to `mov rax, imm; mov [rip + _klog_in_progress_bsp], rax`
for R18 (pre-SMP) and file a paideia-as issue for the GS-relative
form. Detection: M1 build.

**BT-D: fingerprint drift on legacy markers.**
If any M7 sub-batch drifts a marker's ASCII content (typo, spacing),
the corresponding smoke mode fails. Mitigation: M7 sub-issues MUST
diff the pre/post log line-by-line before landing; smoke matrix runs
full before merge.

**BT-E: exception dump introduces additional trap-frame reads that
fault.**
If a PID read from `_current_tcb` hits a NULL/unmapped pointer
during pre-boot exception, `dump_trap_frame` re-faults. Mitigation:
guard `_current_tcb` load with a `test rax, rax; jz skip_pid`
sequence in `dump_trap_frame`. Add at authorship-time.

## 16. LOC estimate (aggregate)

| Phase | New code (kernel) | New code (tests) | Design    | Total |
|-------|-------------------|------------------|-----------|-------|
| M0    | 110               | 20               | (in this) | 130   |
| M1    | 350               | 20               |           | 370   |
| M2    | 100               | 20               |           | 120   |
| M3    | 180               | 20               |           | 200   |
| M4    | 120               | 30               |           | 150   |
| M5    | 60                | 10               |           | 70    |
| M6    | 100               | 20               |           | 120   |
| M7    | −650 (refactor)   | 0                |           | −650  |
| M8    | 40                | 100              |           | 140   |
| **Σ** | **~410 net**      | **240**          | **~800**  | **~1450** |

M7 is a net *reduction* in LOC (80 rodata + duplicate call patterns
collapse into 265 fewer bytes per site × 265 sites = ~4 KiB of
`.pdx` text saved).

## 17. Landing sequence (dependency graph)

```
              ┌── M0 hex/dec ──────────────────┐
              │                                │
              ├── M0 tsc/cpu-id ───────────────┤
              │                                ▼
              │                          ┌── M1 emit ─┐
              │                          │            │
              └──────────────────────────┼── M1 level │
                                         │            │
                                         └── M1 keys ─┤
                                                      │
                                                      ▼
                                                  M2 ring
                                                      │
                                                      ▼
                                                  M3 dump  ── M8 panic-smoke
                                                      │              ▲
                                                      ▼              │
                                                  M4 panic ──────────┘
                                                      │
                                                      ▼
                                                  M5 stack
                                                      │
                                                      ▼
                                                  M6 assert
                                                      │
                                                      ▼
                                                  M7-a…h  (parallel per subsystem)
```

M7-a..h are internally independent (different files) and can be
landed in any order; each is guarded by the "all fingerprints pass"
invariant.

M9 items are deferred to a future round and not scoped here.

## 18. Acceptance criteria (per-phase — see individual issues)

Each downstream issue restates its own AC. This design commits only
to the aggregate contract:

- **After M2**: every klog line survives in the ring for post-mortem
  reads even when UART is jammed.
- **After M3**: any exception in the kernel prints vector, RIP, CR2
  (for #PF), and current PID before halting.
- **After M4**: `panic()` is the only kernel halt idiom; all existing
  `cpu_halt` sites migrated.
- **After M6**: at least one assertion in each of `mm/`, `fs/`,
  `sched/` fires the panic path under a targeted witness.
- **After M7**: no direct `call uart_puts` remains in kernel `.pdx`;
  all remaining direct uart traffic is in the two low-level uart
  primitive files.
- **After M8**: `boot_panic_smoke` runs green in the smoke matrix
  and asserts the panic dump structure.
- **All phases**: every previously-green smoke mode remains green.

## 19. Cross-references

- design/audit/log-structure.md — the audit-log twin; **not** this
  substrate.
- design/kernel/r14b-m5-008-cr0-wp-substrate.md — the doc-depth exemplar.
- src/kernel/boot/uart.pdx — the polling primitive this substrate wraps.
- src/kernel/core/int/exceptions.pdx — the immediate M3 client.
- src/kernel/core/mm/panic_trace.pdx — retired at M2 in favor of
  `src/kernel/core/klog/ring.pdx`.
- tools/run-smoke.sh — the fingerprint contract this substrate
  preserves.
- MEMORY.md project-vision items: multicore-first, FP-disciplined,
  post-quantum-aware (this substrate is orthogonal to PQ; it forwards
  what's needed to the audit-log bridge that owns attestation).
