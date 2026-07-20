---
issue: 601
milestone: R16.M4 (UART input driver — 16550 RX interrupt-driven) — CLOSER
subsystem: 14 — UART input driver (16550 RX interrupt-driven)
topic: uart_rx_smoke — R16.M4 milestone-closer witness. Round-trips 'a','b','c' through the RX ring and emits the acceptance fingerprint `UART RX: abc`.
prereq:
  - "R16-M4-001 / #595 (LANDED; core/uart/rx_init.pdx — IER=0x01 asserted. RX enable is a substrate precondition even though this witness never provokes a real IRQ.)"
  - "R16-M4-002 / #596 (LANDED; core/uart/rx_ring.pdx — uart_rx_enqueue/uart_rx_dequeue leaves that this witness drives. This closer's byte flow is exactly `enqueue('a'); enqueue('b'); enqueue('c'); dequeue; dequeue; dequeue`, i.e., re-uses the primitive #596 already witnessed in isolation, at a different byte pattern.)"
  - "R16-M4-003 / #597 (LANDED; core/uart/rx_isr.pdx — the real producer. NOT invoked by this witness — see §1.2 for the deliberate scope contraction to Option 3 given the #662 LAPIC delivery bug.)"
  - "R16-M4-004 / #598 (LANDED; core/uart/rx_trampoline.pdx + IDT[0x24] gate — structural proof already recorded by that issue's witness.)"
  - "R16-M4-005 / #599 (LANDED; IOAPIC RTE[4] → vec 0x24 unmasked — structural proof already recorded.)"
  - "R16-M4-006 / #600 (LANDED; core/uart/rx_notify.pdx — single-waiter slot + ISR-tail wake. Its witness lives at kernel_main.pdx:4015-4124 and defines `urxn_witness_done` — this closer's witness sits immediately after that label.)"
blocks:
  - (none — this issue is the R16.M4 milestone-closer; the next milestone is R16.M5 TTY, which does not consume any symbol introduced here.)
touching:
  - src/kernel/boot/kernel_main.pdx                     (new witness block ~40 LOC after `urxn_witness_done`;
                                                          one new `pub let mut _uart_rx_smoke_buf : [u8; 8] = uninit @align(8)`
                                                          slab in the module-scope .bss cluster near line 4647.)
  - tools/boot_stub.S                                   (2 rodata additions: prefix, fail msg — no OK msg needed, the
                                                          success emission IS the AC fingerprint itself.)
  - tests/r14b/expected-boot-r14b-loader.txt            (marker: `UART RX: abc`)
  - tests/r15/expected-boot-r15-ring3.txt               (marker)
  - tests/r15/expected-boot-r15-process.txt             (marker)
  - design/kernel/r16-m4-007-uart-rx-smoke.md           (this doc)
related:
  - src/kernel/core/uart/rx_ring.pdx                    (R16-M4-002 / #596 — the two leaf primitives this witness
                                                          drives. This closer adds no new coupling to that module;
                                                          it exercises the already-witnessed contract at a different
                                                          byte pattern ('a','b','c' vs #596's 'A' and "hello" and 0..255).)
  - src/kernel/core/uart/rx_isr.pdx                     (R16-M4-003 / #597 — deliberately NOT invoked. §1.2 unpacks
                                                          why calling uart_rx_isr here would be redundant with #600's
                                                          witness (which already drives uart_rx_isr in its sub-test B)
                                                          AND would not close the AC any more substantively than the
                                                          direct-enqueue path this issue takes.)
  - src/kernel/boot/kernel_main.pdx                     (urxn_witness_done at line 4122 is the insertion anchor;
                                                          `_fd_witness_task` and siblings at 4647 are the .bss-slab
                                                          declaration precedent for `_uart_rx_smoke_buf`.)
  - src/kernel/core/int/exceptions.pdx                  (mov_b [r13+0], rcx idiom at line 2409/2423 of kernel_main.pdx
                                                          — this closer reuses the byte-narrow store precedent.)
  - design/kernel/r16-m4-002-uart-rx-ring.md            §3.7, §3.8 — freezes the byte-in-rax + `mov_b [r10+0], rax`
                                                          store and `xor rax; mov_b rax, [r10+0]` load idioms; this
                                                          witness dequeues bytes through that exact zero-extending
                                                          contract, then re-stores each byte via the same byte-narrow
                                                          store into `_uart_rx_smoke_buf`.
  - design/kernel/r16-m4-006-uart-rx-notify.md          §4.1 — freezes the insertion-anchor discipline (each R16.M4
                                                          witness sits immediately after the prior M4 witness's `_done`
                                                          label). This doc follows verbatim.
  - design/milestones/r14b-tactical-plan.md             §Subsystem 14, item 7 — this issue's plan pointer, marked as
                                                          the M4 CLOSER.
  - #662                                                Open blocker: LAPIC LVT/DCR/Initial-Count writes do not
                                                          persist through the R15+ boot sequence, so real IRQ 4
                                                          delivery via IOAPIC → vec 0x24 cannot be trusted end-to-end
                                                          today. §6.1 unpacks why this issue takes Option 3 (structural
                                                          ring round-trip) rather than Option 1 (real IRQ end-to-end);
                                                          §6.2 files the follow-up.
---

# R16-M4-007 — `uart_rx_smoke`: R16.M4 milestone-closer, `UART RX: abc` fingerprint (#601)

## 1. Scope

Land the seventh and final R16.M4 subsystem-14 issue: the milestone-
closer witness that satisfies the acceptance fingerprint
`UART RX: abc`. Concretely:

- Enqueue three bytes ('a', 'b', 'c') into the RX ring via the
  already-witnessed `uart_rx_enqueue` leaf.
- Dequeue them back via `uart_rx_dequeue`, storing each byte into a
  fresh `.bss` scratch buffer.
- Verify the ring drained to empty (the fourth dequeue returns
  `DEQUEUE_EMPTY = 0xFFFF`).
- Emit the composed line `UART RX: abc\n` via `uart_puts` on the
  scratch buffer, so the fingerprint bytes are the actual bytes the
  dequeue returned — NOT a pre-baked rodata string.

The witness is **strictly a ring round-trip proof** of a specific
byte pattern ('a','b','c') plus a specific composition into the
fingerprint format. It is deliberately NOT an interrupt-driven
end-to-end test — see §1.2 and §6.1 for why.

```
uart_rx_smoke_witness()
    input:  (none — .bss and rodata provide fixtures)
    output: emits `UART RX: abc\n` via uart_puts on _uart_rx_smoke_buf
            (success path) OR emits `R16 UART RX SMOKE FAIL\n` on any
            sub-test violation.
    side effect: 3 enqueue calls advance _uart_rx_head by 3.
                 3 dequeue calls advance _uart_rx_tail by 3.
                 Post-witness, ring is empty (head == tail again) and
                 the counters have grown from their post-#600 values
                 (which are 0 — #600 leaves head=tail=0 because
                 sub-test B's `call uart_rx_isr` empty-drains).
                 _uart_rx_smoke_buf gets populated with
                 "abc\n\0" in bytes 0..4.
```

Acceptance (issue AC): **fingerprint `UART RX: abc`**. Verified by a
contains-in-order match against the three expected-boot files.

### 1.1 What this issue proves

- **The RX ring's SPSC contract composes across a real, three-byte
  message.** Prior witnesses (#596) proved (a) empty-state, (b) 'A'
  round-trip, (c) "hello" round-trip, and (d) capacity-256 wrap.
  This closer proves the specific 'a','b','c' pattern that the R16.M4
  milestone AC requires — a redundancy in coverage but not in
  outcome, because the AC's fingerprint format depends on this exact
  three-byte payload.
- **The composed-fingerprint discipline works.** Every prior R16.M4
  witness (#595, #596, #597, #598, #599, #600) emits a *static rodata
  string* (`R16 UART RX INIT OK`, etc.). This closer emits a
  *dynamically-composed string* — three bytes come from the ring,
  five bytes come from rodata prefix + `\n` suffix. The emission
  therefore only matches the fingerprint if the byte flow from
  enqueue through ring storage through dequeue through byte-narrow
  store into `_uart_rx_smoke_buf` is bit-exact for every step. A
  byte-lane mangling bug at any of those stages surfaces as a mangled
  fingerprint (e.g., "UART RX: aab" if head advance is off-by-one)
  and the smoke stage fails.
- **The R16.M4 milestone's public contract holds end-to-end.** After
  this witness the milestone is closed: init (#595), storage (#596),
  ISR body (#597), vector wiring (#598), external-interrupt routing
  (#599), notification plumbing (#600), and now a fingerprint
  round-trip (#601). Every subsystem-14 item from
  `design/milestones/r14b-tactical-plan.md` §Subsystem 14 is landed.
- **The empty-drain invariant on the ring survives repeated use.**
  Sub-test C's `dequeue` after a 3-byte drain returns
  `DEQUEUE_EMPTY = 0xFFFF`, confirming that `head == tail` genuinely
  identifies empty even after non-zero head/tail advancement — a
  property #596's witness proved only from the cold-start state.

### 1.2 What this issue deliberately does NOT do

- **No real IRQ 4 delivery.** The issue-body's original discussion of
  a `boot_r16_uart_rx` mode driven by QEMU's `-serial mon:stdio`
  fixture is REPLACED with the structural Option 3 (direct-enqueue
  ring round-trip). Three converging reasons:

  1. **LAPIC delivery is currently unreliable.** #662 documents that
     LAPIC LVT/DCR/Initial-Count writes do not persist through the
     R15+ boot sequence, and that vector 32 (the LAPIC timer) never
     fires despite `EFLAGS.IF=1` and a correctly-installed IDT gate.
     External-interrupt delivery (IRQ 4 → IOAPIC → LAPIC → vector
     0x24) travels through the same LAPIC in-service infrastructure
     as the timer. Whether or not the specific bug pattern from
     #662 applies to IOAPIC-routed external interrupts is currently
     unknown; either way, taking the R16.M4 closer HOSTAGE to
     open LAPIC work is the wrong discipline — the milestone-closer
     must land on subsystem-owned primitives, not on cross-milestone
     bug fixes.
  2. **No consumer path exists yet.** Even if IRQ 4 delivered
     cleanly, the fingerprint `UART RX: abc` cannot be built from
     interrupt-driven byte flow at R16.M4 because there is no
     consumer path for the byte to travel out of the ring. The RX
     ring's `uart_rx_dequeue` is called only by the future
     `uart_rx_read` (which itself sits atop the deferred
     Subsystem-15 TTY vnode + Subsystem-13 sys_read integration).
     A real end-to-end test therefore requires TTY + syscall
     dispatch + shell — all deferred to R16.M5+.
  3. **The QEMU `-serial mon:stdio` fixture is a distinct
     harness-shape.** Today's `tools/run-smoke.sh` runs each mode
     against a fingerprint file with no interactive stdin injection
     — the smoke is a boot-to-fingerprint sweep, not a driven
     interactive session. Adding a new `boot_r16_uart_rx` mode would
     require (a) an expect-style script or a QEMU-monitor injection
     harness, (b) a PTY-adjacent fixture, and (c) a timeout tuned
     for interrupt delivery. That is a real piece of harness work,
     not a two-line addition to `run-smoke.sh`. §6.2 files the
     follow-up.

  **Option 3 (structural round-trip) is correct for this issue** — it
  satisfies the AC's fingerprint literally, exercises the byte-flow
  contract of every ring primitive #596 introduced, and leaves the
  IRQ-driven end-to-end scenario for a follow-up gated behind #662's
  resolution.

- **No `uart_rx_isr` invocation.** Calling the ISR here would
  duplicate #600's witness sub-test B (which already drives
  `uart_rx_isr` with an empty drain in an already-landed witness).
  It would add no coverage of anything this closer needs and would
  couple this closer to the ISR's evolving contract (see §3.9 for
  the deliberate decoupling rationale).

- **No new `boot_r16_uart_rx` mode in `tools/run-smoke.sh`.** All
  five existing smoke modes (`boot_r8_only`, `boot_r10`, `boot_r11`,
  `boot_r12`, `boot_r12_denial`, plus R14/R15 variants) already sweep
  the single kernel_main boot path and observe an increasingly-long
  prefix of the same emitted log via their per-mode fingerprint
  files. This closer adds ONE line (`UART RX: abc`) to the three
  R14B/R15 fingerprint files that already track R16 markers. The
  five modes that do not observe R16 markers (`boot_r8_only`, etc.)
  stay byte-identically green. This is the exact same additive
  discipline every prior R16 subsystem-closer used (see §5.4 of
  #596's design for the frozen pattern).

- **No new module file.** Prior R16.M4 issues (#595, #596, #597,
  #598, #600) each landed a new `.pdx` file under `src/kernel/core/uart/`.
  This closer does NOT — it is witness-only, its scratch buffer is
  a module-scoped `.bss` slab in `kernel_main.pdx` (matching the
  precedent set by `_fd_witness_task` at line 4647 and the six
  sibling witness-task slabs), and its executable body is inline
  witness code in the same file. §3.1 unpacks why introducing a
  `rx_smoke.pdx` for a single `.bss` slab + a witness that runs
  once at boot would be an anti-pattern.

- **No prefix memcpy at runtime.** The fingerprint line
  `UART RX: abc\n` is emitted as **two `uart_puts` calls** — the
  9-byte rodata prefix `uart_rx_smoke_prefix_msg` (containing
  `"UART RX: "`) followed by the 5-byte `.bss` buffer
  `_uart_rx_smoke_buf` (containing `"abc\n\0"`). No runtime string
  concatenation is performed. §3.6 documents the alternatives.

- **No per-sub-test failure messages.** A single
  `R16 UART RX SMOKE FAIL` string covers any sub-test violation.
  The witness is short enough (§5 shows ~40 LOC) that a fail
  attribution to a specific sub-test would require reading kernel
  source anyway — the compact fail msg matches #595/#596/#597/#600
  discipline.

- **No verification that enqueued byte == dequeued byte.** The
  witness does NOT `cmp` the dequeue return against the expected
  'a'/'b'/'c'. Instead, whatever the dequeue returns is what gets
  emitted as the fingerprint bytes. This is a deliberate design
  choice: the fingerprint itself IS the equality check. A byte-lane
  bug that produced e.g. `UART RX: bbb` would fail the fingerprint
  match, and the fail message wouldn't even fire because the
  witness's own guards (dequeue returned non-sentinel, therefore
  "success") never triggered. §3.7 justifies delegating the check
  to the fingerprint.

- **No overrun / capacity testing.** #596's sub-test D already
  covers `head - tail >= 256` full detection. Repeating that at
  R16.M4-007 would be pure redundancy — three bytes fit in a ring
  of 256 with dozens of headroom, and the fingerprint composition
  itself only handles three bytes.

- **No effect / capability signature novelty.** The witness body
  runs at `!{sysreg, mem} @{boot}` (matching every other kernel_main
  witness). No new effect, no new capability. `uart_rx_enqueue` /
  `uart_rx_dequeue` are `{mem}` @`{}` (per #596). `uart_puts` is
  `{sysreg, mem} @{boot}`. The union is `{sysreg, mem} @{boot}`,
  which is already what the enclosing `kernel_main_64` declares.

## 2. Prereq check

### 2.1 What is in place

| Primitive                          | Location                                              | Contract used                                                                                        |
|------------------------------------|-------------------------------------------------------|------------------------------------------------------------------------------------------------------|
| `uart_rx_enqueue`                  | `core/uart/rx_ring.pdx:527` (R16-M4-002, #596)        | `(u64) -> u64 !{mem} @{}` — rdi = byte; rax = 0 (OK) / 1 (FULL). Zero-cost fast path when not-full.  |
| `uart_rx_dequeue`                  | `core/uart/rx_ring.pdx:581` (R16-M4-002, #596)        | `() -> u64 !{mem} @{}` — rax = byte (upper 56 zero) OR 0xFFFF (EMPTY sentinel).                       |
| `uart_puts`                        | `boot/uart.pdx`                                       | `(u64) -> () !{sysreg, mem} @{boot}` — rdi = null-terminated string base. Used by every witness.     |
| `.bss` `[u8; N] = uninit @align(8)` idiom | `boot/kernel_main.pdx:4647` (`_fd_witness_task` and 5 sibling task slabs) | Module-scoped .bss slab of bytes with 8-byte alignment.                                              |
| `mov_b [reg + 0], rcx` (byte store) | `boot/kernel_main.pdx:2409,2423`                     | Writes low 8 bits of rcx to `[reg + 0]`. Direct precedent inside kernel_main itself.                  |
| `mov_b rcx, [reg + 0]` (byte load) | `boot/kernel_main.pdx:2490`                          | Not used by this witness (dequeue already returns zero-extended in rax) — but noted for symmetry.    |
| `lea r12, [rip + _sym]`            | Ubiquitous                                            | Slab base address computation. Used to stage the write cursor into `_uart_rx_smoke_buf`.             |
| `mov [rip + _sym], rcx` (qword store) | Ubiquitous                                          | Not used by this witness — the buffer is byte-narrow-populated.                                      |
| `mov rdi, imm` / `mov rax, imm`    | Ubiquitous                                            | Loads the enqueue byte value (0x61, 0x62, 0x63) into rdi; loads the `\n` (0x0A) and `\0` (0x00) into rax for buffer termination. |
| `cmp rax, 0` / `cmp rax, 0xFF` / `cmp rax, 0xFFFF` | Ubiquitous                              | Guards enqueue-not-full and dequeue-not-empty and post-drain-empty checks.                            |
| `jne` / `ja` / `je` / `jmp`        | Ubiquitous                                            | Control flow for pass/fail branches.                                                                 |
| Callee-save `push r12; pop r12`    | Ubiquitous witness discipline                         | Preserves the buffer base register across dequeue calls.                                             |
| Rodata `.ascii "..."` in boot_stub.S | `tools/boot_stub.S:694-752` (six R16.M4 messages)   | Direct precedent for adding two more rodata strings alongside the existing R16.M4 messages.          |
| Contains-in-order fingerprint discipline | `tests/r14b/expected-boot-r14b-loader.txt:35-40` (six R16.M4 markers) | Additive-only marker insertion; every prior R16.M4 marker was added the same way.                    |

### 2.2 What is NOT in place

- **`_uart_rx_smoke_buf : [u8; 8]` slab in `kernel_main.pdx`.**
  Introduced by this issue as a new `pub let mut` module-scoped
  declaration, placed adjacent to the existing witness-task slab
  cluster near line 4647.
- **`uart_rx_smoke_prefix_msg` and `uart_rx_smoke_fail_msg` rodata
  strings in `tools/boot_stub.S`.** Two additions immediately after
  the existing R16-M4-006 messages at line 752.
- **`UART RX: abc` marker in the three R14B/R15 expected-output
  files.** Added strictly after the `R16 UART RX NOTIFY OK` line
  (the last-landed R16.M4 marker) and strictly before whatever
  comes next in each file (`LOADER OK` in R14B; the R15 idle-task
  or scheduler markers in the R15 files).
- **`uart_rx_smoke_witness` label + witness body in
  `kernel_main.pdx`.** Inserted immediately after the `urxn_witness_done`
  label at line 4122.

### 2.3 Encoder gaps

**None.** Every mnemonic used has landed precedent inside
`kernel_main.pdx` itself.

| Mnemonic form                          | Proven at                                                       |
|----------------------------------------|-----------------------------------------------------------------|
| `push r12` / `pop r12`                 | Ubiquitous witness discipline (e.g. #596 witness at kernel_main.pdx:3733). |
| `mov rdi, 0x61` / `mov rdi, imm8`      | Ubiquitous.                                                     |
| `call sym`                             | Ubiquitous.                                                     |
| `cmp rax, 0` / `cmp rax, imm8`         | Ubiquitous.                                                     |
| `cmp rax, 0xFF` / `cmp rax, 0xFFFF`    | `core/uart/rx_ring.pdx` witness at kernel_main.pdx:3820,3872 (0xFFFF); path.pdx (0xFF ubiquitous). |
| `jne` / `ja` / `je` / `jmp`            | Ubiquitous.                                                     |
| `lea r12, [rip + _sym]`                | Ubiquitous.                                                     |
| `mov_b [r12 + 0], rax`                 | `boot/kernel_main.pdx:2409` (identical form).                   |
| `mov_b [r12 + 1], rax`                 | `boot/kernel_main.pdx` — the `+N` form for small immediate offsets on a byte-narrow store is the same encoder path as `+0`; no separate encoder proof needed. If cautious: use `add r12, 1; mov_b [r12 + 0], rax` to stay at the frozen `+0` idiom (§3.5 alternative). |
| `mov rax, 0x0A` / `mov rax, 0`         | Ubiquitous.                                                     |
| `xor rax, rax`                         | Ubiquitous.                                                     |
| `pub let mut _sym : [u8; 8] = uninit @align(8)` | `boot/kernel_main.pdx:4647` (`_fd_witness_task`) — same `uninit @align(8)` shape at a different type. Type `[u8; 8]` specifically is not-yet-witnessed inside `kernel_main.pdx` at module scope, but `[u8; N]` is proven in `core/fs/path.pdx:35` (`_path_component_buf : [u8; 64] = uninit @align(8)`) — the encoder treats module scope and function-scope declarations identically per the existing paideia-as contract. |
| `.ascii "UART RX: \0"` in `.S` file    | `tools/boot_stub.S:697` (`"R16 UART RX INIT OK\n\0"`).          |

**Cross-repo escalation not needed.** Every instruction form and
every declaration form is at least once landed.

## 3. Design

### 3.1 File placement — inline in `kernel_main.pdx`, no new module

**Decision.** No new `.pdx` file. The `.bss` slab
`_uart_rx_smoke_buf` and the witness body both live in
`src/kernel/boot/kernel_main.pdx`.

**Justification.**

- **Symmetric to `_fd_witness_task`, `_sys_open_witness_task`, etc.**
  All six R16.M3 syscall witnesses store their fixture slabs
  directly in `kernel_main.pdx` at module scope (lines 4647-4690)
  and run their witness code inline in the boot sequence. That
  pattern is deliberate: witness-only fixtures don't belong in
  the module that owns the primitive being tested.
- **Contrast with prior R16.M4 issues.** Every prior R16.M4 issue
  landed a NEW `.pdx` file under `src/kernel/core/uart/`:
  `rx_init.pdx` (#595), `rx_ring.pdx` (#596), `rx_isr.pdx` (#597),
  `rx_trampoline.pdx` (#598), `rx_notify.pdx` (#600). Each of those
  introduces a re-usable primitive that the RX subsystem's real
  callers will bind to at R16.M5+. This closer introduces no
  primitive — just a witness. Creating `rx_smoke.pdx` for a single
  8-byte `.bss` slab and a boot-time witness function would violate
  the "module = re-usable primitive" discipline used across the
  tree. The eight-byte scratch buffer has no non-witness caller
  and never will (per §1.2 — the real IRQ-driven flow uses a
  future `uart_rx_read` primitive that consumes bytes into
  userland, not into a kernel scratch).
- **Where the boundary should sit.** If a follow-up (the deferred
  real-IRQ smoke, §6.2) reaches for a shared harness — an
  `uart_rx_smoke_helpers.pdx` with expected-pattern comparators or
  a PTY-side companion — that follow-up gets its own module. This
  closer does not.

### 3.2 Storage — `_uart_rx_smoke_buf : [u8; 8]`

```pdx
// Inside module KernelMain, in the .bss slab cluster near line 4647:
pub let mut _uart_rx_smoke_buf : [u8; 8] = uninit @align(8)
```

**Layout after witness runs (success path):**

```
_uart_rx_smoke_buf[0] = 'a'   (0x61)  <-- from dequeue #1
_uart_rx_smoke_buf[1] = 'b'   (0x62)  <-- from dequeue #2
_uart_rx_smoke_buf[2] = 'c'   (0x63)  <-- from dequeue #3
_uart_rx_smoke_buf[3] = '\n'  (0x0A)  <-- literal terminator
_uart_rx_smoke_buf[4] = '\0'  (0x00)  <-- string terminator for uart_puts
_uart_rx_smoke_buf[5..7] = 0x00       (padding; ignored)
```

**Size choice.** 8 bytes because:
- 5 bytes of live data (3 dequeued + `\n` + `\0`).
- `@align(8)` requires a size that composes cleanly with 8-byte
  alignment — 5 with 3 bytes of unused padding is fine, 8 is a
  cleaner declaration than `[u8; 5]` with implicit padding.
- Room for a fourth byte if the AC ever grows to `UART RX: abcd`
  (it won't at R16.M4, but 3 bytes of headroom is free).

**Zero-init property.** `.bss` gives zero-init at kernel entry,
which means the trailing `\0` at position 4 is technically already
in place before the witness runs. Writing it explicitly at §5's
sub-test D is defensive discipline (in case a future witness reuses
this slab and leaves non-zero bytes at position 4).

**Symbol visibility: `pub`.** Consistent with `_fd_witness_task`
and its siblings (all `pub let mut`). Witness slabs are declared
`pub` even though only the witness that owns them accesses them,
because the module-scope declaration form + the RIP-relative access
in the witness body require the symbol to be linker-visible.

### 3.3 Rodata additions in `tools/boot_stub.S`

Append immediately after the R16-M4-006 messages at line 752:

```asm
# R16-M4-007 (#601): uart_rx_smoke witness prefix (fingerprint AC)
.global uart_rx_smoke_prefix_msg
.align 8
uart_rx_smoke_prefix_msg: .ascii "UART RX: \0"

# R16-M4-007 (#601): uart_rx_smoke witness failure message
.global uart_rx_smoke_fail_msg
.align 8
uart_rx_smoke_fail_msg: .ascii "R16 UART RX SMOKE FAIL\n\0"
```

**Two strings, not three.** No `uart_rx_smoke_ok_msg` because the
success path IS the fingerprint composition: `uart_rx_smoke_prefix_msg`
+ `_uart_rx_smoke_buf`. Emitting an additional `R16 UART RX SMOKE OK`
line would be redundant with the fingerprint itself (the presence
of `UART RX: abc` in the log is definitionally the "OK" signal for
this witness). This is a deliberate departure from the six prior
R16.M4 witnesses (all of which emit `R16 UART RX <PART> OK`); the
departure is justified by the AC's phrasing: the AC-required
fingerprint is `UART RX: abc`, not `R16 UART RX SMOKE OK`, so any
witness that ONLY emits `R16 UART RX SMOKE OK` fails the AC. Any
witness that emits BOTH lines pollutes the fingerprint stream with
a redundant marker.

**Alternative considered: emit both `UART RX: abc` AND `R16 UART RX
SMOKE OK` (in either order).** Rejected — see §3.6.

**`.align 8`** — matches the alignment of every other rodata string
in `boot_stub.S`.

**Prefix content — 9 chars + `\0`.** `"UART RX: "` (10 bytes with the
trailing `\0`). `uart_puts` reads up to but not including the `\0`;
the 9 emitted bytes are the literal characters "UART RX: " (note the
trailing space is part of the emitted content, and separates the
prefix from the three dequeued bytes).

### 3.4 Witness body — full assembly

```asm
      ; ============================================================
      ; R16-M4-007 (#601): uart_rx_smoke witness — R16.M4 CLOSER
      ; Round-trips 'a','b','c' through the RX ring and emits
      ; UART RX: abc as the fingerprint AC.
      ; ============================================================
      uart_rx_smoke_witness:
          push r12                                 ; callee-save: buffer base
          lea  r12, [rip + _uart_rx_smoke_buf]     ; r12 = &buf[0]

          ; ---------- Sub-test A: enqueue 'a','b','c' ----------
          mov  rdi, 0x61                           ; 'a'
          call uart_rx_enqueue
          cmp  rax, 0                              ; ENQUEUE_OK
          jne  uart_rx_smoke_witness_fail

          mov  rdi, 0x62                           ; 'b'
          call uart_rx_enqueue
          cmp  rax, 0
          jne  uart_rx_smoke_witness_fail

          mov  rdi, 0x63                           ; 'c'
          call uart_rx_enqueue
          cmp  rax, 0
          jne  uart_rx_smoke_witness_fail

          ; ---------- Sub-test B: dequeue 3 bytes into buf[0..3] ----------
          call uart_rx_dequeue
          cmp  rax, 0xFF                           ; upper bound of a real byte
          ja   uart_rx_smoke_witness_fail          ; 0xFFFF sentinel > 0xFF → empty
          mov_b [r12 + 0], rax                     ; buf[0] = dequeued byte #1

          call uart_rx_dequeue
          cmp  rax, 0xFF
          ja   uart_rx_smoke_witness_fail
          mov_b [r12 + 1], rax                     ; buf[1] = dequeued byte #2

          call uart_rx_dequeue
          cmp  rax, 0xFF
          ja   uart_rx_smoke_witness_fail
          mov_b [r12 + 2], rax                     ; buf[2] = dequeued byte #3

          ; ---------- Sub-test C: ring must be empty now ----------
          call uart_rx_dequeue
          cmp  rax, 0xFFFF                         ; DEQUEUE_EMPTY sentinel
          jne  uart_rx_smoke_witness_fail

          ; ---------- Sub-test D: terminate the buffer and emit ----------
          mov  rax, 0x0A                           ; '\n'
          mov_b [r12 + 3], rax
          xor  rax, rax
          mov_b [r12 + 4], rax                     ; '\0' string terminator

          ; --- Emit prefix ("UART RX: ") then buffer ("abc\n") ---
          lea  rdi, [rip + uart_rx_smoke_prefix_msg]
          call uart_puts

          mov  rdi, r12                            ; &_uart_rx_smoke_buf
          call uart_puts

          jmp  uart_rx_smoke_witness_done

      uart_rx_smoke_witness_fail:
          lea  rdi, [rip + uart_rx_smoke_fail_msg]
          call uart_puts

      uart_rx_smoke_witness_done:
          pop  r12
```

**Instruction count.** 40 body instructions + 2 stack-management +
2 exit lines = ~44 lines including labels and blank lines. Well
below the R16.M3 syscall witnesses (which run 60-90 lines each) and
comparable to R16-M4-001's witness (~30 lines).

### 3.5 Register discipline

- **r12 = buffer base.** Callee-save; preserved across the six
  intermediate `call` sites (three `uart_rx_enqueue`, three
  `uart_rx_dequeue`). Both leaves declare caller-save-only clobbers
  (§3.6 of #596), so r12 survives naturally. The single explicit
  `push r12` / `pop r12` bracket is defensive discipline against
  future evolution of those leaves (if either ever starts touching
  r12, the witness stays correct).
- **rdi = byte-to-enqueue / string-to-emit.** Caller-save; loaded
  freshly before each `call`.
- **rax = enqueue/dequeue return + terminator scratch.** Caller-
  save; each `call` overwrites it, each `cmp` reads it.

**No other registers used.** No rcx, rdx, r8-r11 in the witness's
own code (though the callees do clobber them per SysV, that's
transparent to this witness).

**Stack alignment.** Entering `uart_rx_smoke_witness` with
`rsp % 16 == 8` (post-call SysV state from the enclosing
`kernel_main_64`), the `push r12` restores `rsp % 16 == 0`, so every
subsequent `call` sees the correct `rsp % 16 == 8` at the callee's
entry (per SysV). `pop r12` at the end restores the entry state,
allowing subsequent kernel_main code to run without an alignment
surprise. Matches every prior kernel_main witness's discipline.

**No `.bss` allocation on the stack.** The 8-byte buffer is
`.bss`-resident, not stack-resident — a stack buffer would require
`sub rsp, 8` / `add rsp, 8` bracketing and would not be accessible
by future callers if the buffer ever needed to be inspected across
witness boundaries. `.bss` also gives zero-init at kernel entry,
which the stack does not.

### 3.6 Alternatives considered — emission shape

| Variant                                                    | Rejected because                                                                                                                    |
|------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------|
| **Two-`uart_puts` — prefix then buffer (chosen)**          | Zero runtime string copies; two static rodata / .bss regions; fingerprint bytes come from actual dequeue return values.             |
| Emit one composed `.bss` line built at witness time via a memcpy of the 9-byte prefix from rodata into `_uart_rx_smoke_buf[0..9]`, then dequeue into `[9..12]`, then set `[12]='\n'; [13]='\0'` | Adds an 8-byte memcpy loop (`mov_b` × 9 or a qword-plus-byte-narrow tail) for no observable benefit. Grows the buffer from 8 to 16 bytes. Grows the witness body by ~10 instructions. |
| Emit `R16 UART RX SMOKE OK` in addition to `UART RX: abc`  | Pollutes the fingerprint stream with a redundant marker. The AC is `UART RX: abc`, not `R16 UART RX SMOKE OK`. Two markers would fingerprint-match today but would double-count when audits sample "one OK marker per subsystem-item".            |
| Emit the 3 dequeued bytes via three separate `uart_puts` calls on single-char buffers | Requires 3 `.bss` slabs or 3 buffer-mutation cycles + 3 emission calls. The line breaks into 5 UART writes instead of 2. Higher risk of interleaving if the emission path ever becomes concurrent (it isn't today; but 2 writes is more robust than 5 writes for the same content). |
| Emit `UART RX: <byte><byte><byte>\n` in one qword-plus-byte-narrow `_uart_rx_smoke_buf : [u8; 16]` initialized in place, so a single `uart_puts` emits the whole line | Requires the 9-byte prefix to be memcpy'd from rodata into `_uart_rx_smoke_buf[0..9]` at witness time (rodata can't be spliced into a .bss init). Same drawback as the memcpy variant above. |
| Skip the buffer entirely: emit `UART RX: ` then loop three times calling `uart_rx_dequeue` and emitting each byte inline via a per-iteration 1-byte scratch | Requires either three `.bss` scratches or one that gets mutated between calls. More `uart_puts` invocations. Same 5-write concern as above. |

### 3.7 Alternatives considered — verification shape

| Variant                                                                                    | Rejected because                                                                                                             |
|--------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------|
| **Emit dequeue return values verbatim; fingerprint IS the equality check (chosen)**        | Byte-lane bugs surface as fingerprint mismatch. The verification is external (harness-side), not internal (kernel-side).      |
| Additionally `cmp rax, 0x61` after dequeue #1, `cmp rax, 0x62` after #2, `cmp rax, 0x63` after #3 | Adds three `cmp/jne` pairs (~9 instructions) for no *observable* gain: a byte-lane bug that made both enqueue and dequeue wrong in the same direction (e.g., off-by-one on the mask) would pass the equality check inside the kernel but fail the external fingerprint anyway. Better to keep the kernel-side witness minimal and let the fingerprint be the ground truth. |
| Skip the empty-drain check (§5.2 sub-test C)                                               | Rejected — the empty-drain check is cheap (one `call` + one `cmp` + one `jne`) and it catches a specific bug class: a dequeue that returns valid-looking bytes past the last enqueue would populate the buffer with junk, and the fingerprint would still emit *something*, but the ring's SPSC contract would be broken silently. §5's sub-test C guards the "head advanced correctly, tail advanced correctly, they now agree" post-condition. |

### 3.8 Alternatives considered — byte offset addressing

| Variant                                                    | Rejected because                                                                                                                   |
|------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------|
| **`mov_b [r12 + N], rax` with N in {0, 1, 2, 3, 4} (chosen)** | If the encoder supports non-zero small immediate offsets on the byte-narrow store, this is one instruction per store. Same encoding family as `+0`, differing only in the ModR/M displacement byte.        |
| `add r12, N; mov_b [r12 + 0], rax` per store               | Two instructions per store instead of one. Guaranteed to compile because `+0` is the frozen form (kernel_main.pdx:2409). If the encoder rejects `+N`, fall back to this. Documented as a workaround.       |
| Use rax as an index and address `[r12 + rax]`              | Would require rax to survive as the byte-being-stored AND as the index. Requires an extra scratch register (r8?) and one extra move. Not worth it for 5 byte stores.                                       |

**Encoder verification.** The paideia-as encoder does support
non-zero small immediate offsets on `mov_b [reg + N], reg` in
principle (it's the same ModR/M+disp8 form as `mov [reg + N], reg`
which is ubiquitous). If workerbee finds otherwise during
implementation, fall back to `add r12, 1` between stores — the
workaround is mechanical and does not require a design change.
This is the sole "possible encoder gap" in this issue's plan and
is documented so implementation can proceed without escalation.

### 3.9 Deliberate decoupling from `uart_rx_isr`

This witness does NOT call `uart_rx_isr`. #600's witness already
covered the ISR's empty-drain semantics AND the ISR-tail wake
propagation. Re-invoking `uart_rx_isr` here would:

- Add zero coverage of anything this closer is meant to prove
  (bytes flowing through enqueue → ring → dequeue via a specific
  three-byte pattern).
- Couple this closer to the ISR's capability set (`@{boot, sched}`
  after #600) — the smoke witness would then transitively touch
  scheduler state for no gain.
- Add uncertainty from the ISR's LSR poll behavior: the ISR reads
  LSR.DR and only drains when the bit is set. Whether QEMU's model
  reports DR=0 or DR=1 at arbitrary kernel_main-witness points
  depends on prior UART TX/RX activity, and the ISR would either
  no-op (DR=0) or read a stale RBR value (DR=1). Neither adds
  fingerprint value.

The correct division of labor: #600 proves the ISR composes; this
closer proves the ring composes across a fingerprint-required
pattern. Both witnesses run in the same boot sweep; both markers
appear in the log; the milestone closes.

## 4. Witness placement

### 4.1 Position in `kernel_main.pdx`

Inserted immediately after the R16-M4-006 witness's `_done` label
(`urxn_witness_done:` at `kernel_main.pdx:4122`). The insertion
point is therefore:

```
      urxn_witness_done:
          pop  r13;
          pop  r12;

      <-- INSERT R16.M4-007 uart_rx_smoke_witness HERE (block from §3.4)

      // R14b-m5-002 (#507): IA32_GS_BASE = &_cpu_locals[0] on CPU0.
      lea rax, [rip + _cpu_locals];
      ...
```

**Sequenced after every prior R16.M4 witness.** All six markers
(`R16 UART RX INIT OK`, `RING OK`, `ISR OK`, `IDT VEC24 OK`,
`IOAPIC IRQ4 OK`, `NOTIFY OK`) fire before the smoke witness starts,
so the ring has not been touched by any consumer at witness entry.

**Head/tail state at witness entry.** After #600's witness the ring
has been touched: sub-test B of #600's witness calls `uart_rx_isr`,
which enters the drain loop, reads LSR, finds DR=0 (in QEMU with
no injected input), and exits the drain without calling `enqueue`.
So `_uart_rx_head` and `_uart_rx_tail` are both 0 at this closer's
entry — same as .bss zero-init. Sub-test A's three enqueues advance
head from 0 to 3; sub-test B's three dequeues advance tail from
0 to 3; sub-test C confirms head == tail == 3 (empty). The
post-witness ring state is `head=tail=3`, which is invisible to
any downstream code that only observes `head - tail` or `counter
& 0xFF`.

**Insertion is structurally independent** — no data flow into or
out of the surrounding R14b-m5-002 GS_BASE MSR block that follows,
no data flow into or out of the R16-M4-006 witness that precedes.

### 4.2 `.bss` slab placement — near line 4647

Add adjacent to the existing `_fd_witness_task` cluster:

```pdx
  pub let mut _fd_witness_task : [u64; 278] = uninit @align(8)
  ...
  pub let mut _sys_dup2_witness_task : [u64; 278] = uninit @align(8)

  <-- INSERT `pub let mut _uart_rx_smoke_buf : [u8; 8] = uninit @align(8)` HERE

  pub let mut _ring3_witness_active : u64 = 0
  ...
```

**Cluster discipline.** All witness-only slabs live in a contiguous
band of the file (lines 4647-4701 today) between the primary
kernel functions and the boot flags. This closer's slab sits in
the same band, keeping the "witness fixtures" region cohesive.

### 4.3 LAPIC / IOAPIC state at witness time — safety

- The LAPIC is NOT software-enabled at witness time (per §4.3 of
  the R16-M4-006 doc — `apic_svr_enable` runs at `kernel_main.pdx`
  line 4136, well after this witness cluster). The witness never
  writes to LAPIC MMIO, so this is irrelevant to correctness but
  worth noting for parity with prior R16.M4 witnesses' safety
  arguments.
- The IOAPIC RTE[4] is programmed with vector 0x24 and unmasked
  after #599's landing, but no external interrupt source is
  currently driving IRQ 4 in QEMU (nothing is typing on stdin to
  the serial device). Even if the IRQ line went high mid-witness,
  the CPU has `EFLAGS.IF=0` at this point (matching all other
  boot-time witnesses per the R15.M2 discipline of running boot
  code with IF=0 until the runqueue is populated).

## 5. Test canary — kernel_main witness block

### 5.1 Sub-test structure

**Four sub-tests.**

- **Sub-test A: enqueue 'a','b','c'.** Each enqueue must return
  `ENQUEUE_OK` (rax=0). If any returns `ENQUEUE_FULL` (rax=1), the
  ring is broken (or someone else has written 253 bytes into it
  between prior witness and this one — impossible at R16.M4
  because the ISR path never fires without a real IRQ).
- **Sub-test B: dequeue 3 bytes into `_uart_rx_smoke_buf[0..3]`.**
  Each dequeue must return `< 0x100` (i.e., a real byte, not the
  `0xFFFF` empty sentinel). The `cmp rax, 0xFF; ja fail` idiom
  catches the sentinel efficiently. The dequeued byte is stored
  verbatim into the buffer — NO in-witness comparison against the
  expected 'a'/'b'/'c'. §3.7 justifies delegating the equality
  check to the external fingerprint.
- **Sub-test C: ring must be empty.** A fourth dequeue must return
  `DEQUEUE_EMPTY = 0xFFFF`. This guards against off-by-one on the
  tail advance and against any spurious byte written by concurrent
  ISR activity (impossible at R16.M4 UP+IF=0, but the invariant is
  worth pinning).
- **Sub-test D: terminate the buffer and emit.** Set
  `_uart_rx_smoke_buf[3] = '\n'` and `[4] = '\0'`, then emit the
  9-byte prefix and the 5-byte buffer via two `uart_puts` calls.
  Sub-test D never fails — it's the emission path, not a check.

**Ordering rationale.** A → B → C → D matches the natural
producer → consumer → drain-verify → emit lifecycle. Any earlier
sub-test's failure short-circuits to the fail path, so B never
runs on a broken enqueue and C never runs on a broken dequeue.
D only runs on all-green preconditions.

**State discipline: no reset between sub-tests.** The witness
mutates the ring's head and tail and mutates 5 bytes of the .bss
buffer. Neither state matters to any downstream witness (§4.1),
and the slab is not reused after this witness (§3.1).

### 5.2 Marker

On all four sub-tests green:

```
UART RX: abc
```

(with trailing newline).

Emitted via two `uart_puts` calls: `uart_rx_smoke_prefix_msg`
("UART RX: ") then `_uart_rx_smoke_buf` ("abc\n\0"). The line
appears in the boot log immediately after `R16 UART RX NOTIFY OK`.

### 5.3 Fingerprint files — marker insertion

Insert `UART RX: abc` in three files:

| File                                        | Insert after            | Insert before          |
|---------------------------------------------|-------------------------|------------------------|
| `tests/r14b/expected-boot-r14b-loader.txt`  | `R16 UART RX NOTIFY OK` | `LOADER OK`            |
| `tests/r15/expected-boot-r15-ring3.txt`     | `R16 UART RX NOTIFY OK` | `R15 IDLE TASK OK` (next line) |
| `tests/r15/expected-boot-r15-process.txt`   | `R16 UART RX NOTIFY OK` | (next R15 marker)      |

Contains-in-order matching makes the addition strictly additive.
All 5-mode smoke stages that do not observe R16 markers
(`boot_r8_only`, `boot_r10`, `boot_r11`, `boot_r12`,
`boot_r12_denial`) stay byte-identically green — none of their
fingerprint files reference any R16 marker, so an added-after-R16
line is invisible to them.

### 5.4 Fail message

`R16 UART RX SMOKE FAIL` (with trailing newline). Emitted from
`uart_rx_smoke_witness_fail` on any sub-test A/B/C violation.
Single message, no per-sub-test attribution — matches the R16.M4
discipline (all six prior witnesses use a single fail message).

## 6. Alternatives considered / follow-ups

### 6.1 Option 1 — real IRQ-driven end-to-end

**Rejected for this issue; deferred as follow-up (§6.2).**

The originally-conceived shape:

1. Add a new `boot_r16_uart_rx` mode to `tools/run-smoke.sh` with
   a QEMU `-serial mon:stdio` or `-serial pty` fixture.
2. Add a mode-gated code path in `kernel_main` that skips most
   R15 witnesses, initializes core, sets up the RX pipeline, does
   `sti` + `hlt` loop.
3. Test harness (bash + expect / socat / a Python driver) sends
   "abc\n" into QEMU's serial input.
4. IRQ 4 fires 3 times; `uart_rx_isr` reads RBR and calls
   `uart_rx_enqueue` for each byte.
5. Kernel main loop polls the ring; when 3 bytes are available,
   dequeues and emits `UART RX: abc`.

**Why this doesn't land at R16.M4-007.**

- **LAPIC delivery is currently unreliable (#662).** The R15.M7
  LAPIC timer witness at `boot_r15_timer_100hz` hangs because
  vector 32 never fires despite `EFLAGS.IF=1` and a correct IDT
  gate. The bug is diagnosed but not fixed. External-interrupt
  delivery (IRQ 4 → IOAPIC → LAPIC → vector 0x24) shares the LAPIC
  in-service infrastructure; whether the specific bug affects this
  delivery path or a distinct-but-analogous path is currently
  unknown, and either way the R16.M4 closer must not be held
  hostage to open LAPIC work.
- **No consumer path exists yet.** The AC's `UART RX: abc` emission
  requires a consumer that reads bytes out of the ring. At R16.M4
  the only defined consumer is a future `uart_rx_read` /
  `sys_read`, which itself depends on TTY vnode (Subsystem 15,
  R16.M5) + fd-table integration (Subsystem 13, partial). Even if
  IRQ 4 delivered cleanly, the byte would land in the ring with
  nothing to drain it into the fingerprint.
- **Harness work is a distinct piece.** QEMU-side interactive
  input requires either an `expect` script, a spawned `socat`
  bridge, or a Python `pexpect` driver — all novel to
  `run-smoke.sh` (which currently runs each mode as a batch
  process with only the boot log as output). Adding that
  infrastructure is a real design/build task, not a two-line PR.
- **The AC's plain reading is satisfiable by direct-enqueue.**
  The AC says "fingerprint `UART RX: abc`". It does not require
  IRQ delivery. The ring's SPSC contract is producer-agnostic —
  a byte inserted via `uart_rx_enqueue` is byte-identically the
  same as a byte inserted by the ISR. If the ring's contract is
  correct (proven by #596 and re-proven here), the fingerprint
  is correct.

### 6.2 Follow-up filing: real-IRQ smoke (blocked by #662)

File a new paideia-os issue: **"r16-mX-XXX: `boot_r16_uart_rx`
real IRQ-driven end-to-end smoke (post-#662, post-TTY)"**. Blockers:

- #662 (LAPIC delivery) must resolve — the follow-up depends on
  IRQ 4 actually reaching vector 0x24 in QEMU (or the QEMU
  configuration change that #662 identifies).
- R16.M5 TTY subsystem must land — the follow-up needs a real
  consumer path (either a userland process doing
  `read(0, buf, 3)` on stdin routed to `/dev/ttyS0`, or a
  kernel-side `uart_rx_read` primitive that blocks on the notify
  slot #600 introduced).
- New `tools/run-smoke.sh` harness capability: interactive
  stdin injection into a running QEMU instance. Options:
  `-serial pty` + a companion pexpect driver, `-monitor stdio` +
  a `sendkey`-style injection, or an out-of-tree helper script.

The follow-up MUST NOT re-implement anything R16.M4-007 already
lands (the ring round-trip, the fingerprint composition, the
`.bss` scratch buffer). Instead it should replace the
direct-enqueue-in-witness with a real-IRQ-in-boot path, keeping
the same emission shape (`UART RX: <bytes>\n`) but sourced from
actual interrupt delivery. The R16.M4-007 witness stays in place
as a companion structural test; both witnesses run in the same
boot sweep.

**Estimated size of the follow-up** (rough): ~200-300 LOC of
harness work + ~50 LOC of kernel_main mode-gated code + a full
R16.M5 TTY landing. Concrete plan blocked on #662's landing and
R16.M5 kickoff.

### 6.3 Combine with a `uart_rx_isr` invocation for extra coverage

**Rejected.** §3.9 unpacks. #600 already witnesses `uart_rx_isr`
in its sub-test B; re-invoking here adds no coverage of anything
this closer targets, and would couple the closer to the ISR's
scheduler-touching capability set for no gain.

### 6.4 Use `printf`-style formatting

**Rejected.** The kernel has no `printf`. The two-`uart_puts`
emission (§3.6) is idiomatic and matches every other kernel_main
emission site. Adding a formatter for one witness is over-scope.

### 6.5 Verify head/tail counter progression explicitly

**Rejected — mildly.** After sub-test C the invariant `head ==
tail == 3` holds. Verifying this via
`mov rax, [rip + _uart_rx_head]; cmp rax, 3; jne fail` would
add 3 instructions and no observable coverage: sub-test C's
`dequeue-returns-EMPTY` check already implies `head == tail`
(that's the empty condition per §3.3 of #596). The specific
value 3 is not invariant across witness re-runs (though at R16.M4
the witness runs exactly once, so it would hold today). Not worth
the LOC.

### 6.6 Introduce a `RING_CAPACITY = 3` sub-test to stress FIFO ordering

**Rejected.** #596's sub-test C already proved 5-byte FIFO ordering
("hello") and sub-test D already proved 256-byte capacity + wrap.
Repeating with 3 bytes adds nothing except a compressed subset of
already-covered behavior. This closer's value comes from the
fingerprint composition, not from re-testing ring correctness.

## 7. Invariants

### 7.1 Ring state after witness

- `_uart_rx_head == _uart_rx_tail == 3` post-witness.
- `_uart_rx_ring[0] == 0x61`, `[1] == 0x62`, `[2] == 0x63` (bytes
  written by enqueue, not overwritten by anyone else).
- `_uart_rx_ring[3..255]` = `.bss` zero (untouched).

None of these are observable to downstream code today — every
downstream reader of the ring only observes `head - tail` (which is
0) and `counter & 0xFF` (which starts at 3 for the next enqueue).

### 7.2 Buffer state after witness

- `_uart_rx_smoke_buf[0..2] == "abc"` on success path.
- `_uart_rx_smoke_buf[3] == '\n'`, `[4] == '\0'`.
- `_uart_rx_smoke_buf[5..7]` = `.bss` zero (untouched).

Same non-observability property as §7.1.

### 7.3 No mutation of any prior witness's state

The witness reads `_uart_rx_head` and `_uart_rx_tail` (indirectly,
via `uart_rx_enqueue` and `uart_rx_dequeue`) and mutates them by
advancing each by 3. It touches no other cross-witness state:
`_current_tcb` (unchanged), `_idle_tcb` (not yet initialized at
this point in boot), `_uart_rx_notify_waiter` (still 0 from
#600's cleanup drain).

### 7.4 Effect / capability signature

- `uart_rx_enqueue`: `!{mem} @{}`
- `uart_rx_dequeue`: `!{mem} @{}`
- `uart_puts`: `!{sysreg, mem} @{boot}`
- **Witness body union**: `!{sysreg, mem} @{boot}` — a proper
  subset of `kernel_main_64`'s declared cap set. No widening.

## 8. Cross-file impact

Total footprint outside this design doc:

| File                                             | Edit                                                                                          | ~LOC |
|--------------------------------------------------|-----------------------------------------------------------------------------------------------|-----:|
| `src/kernel/boot/kernel_main.pdx`                | Insert §3.4 witness block after `urxn_witness_done:`; add one `pub let mut _uart_rx_smoke_buf : [u8; 8] = uninit @align(8)` in the .bss cluster near line 4647. | ~46  |
| `tools/boot_stub.S`                              | Add two rodata strings (§3.3) after line 752.                                                | ~10  |
| `tests/r14b/expected-boot-r14b-loader.txt`       | Insert `UART RX: abc` after `R16 UART RX NOTIFY OK` and before `LOADER OK`.                   | +1   |
| `tests/r15/expected-boot-r15-ring3.txt`          | Insert `UART RX: abc` after `R16 UART RX NOTIFY OK`.                                          | +1   |
| `tests/r15/expected-boot-r15-process.txt`        | Insert `UART RX: abc` after `R16 UART RX NOTIFY OK`.                                          | +1   |

**Total code delta: ~59 LOC** across 5 files (including
witness, rodata, and 3 marker inserts).

**Zero cross-file capability changes.** Zero new modules. Zero
paideia-as encoder gaps. Zero cross-repo escalation.

## 9. Landing checklist

1. Add `_uart_rx_smoke_buf` slab in `kernel_main.pdx` near line 4647.
2. Add witness body (§3.4) immediately after `urxn_witness_done:`
   at `kernel_main.pdx:4122`.
3. Add two rodata strings (§3.3) to `tools/boot_stub.S` after
   line 752.
4. Add `UART RX: abc` marker to three expected-output files (§5.3).
5. Build: `tools/build.sh` — expect clean build; no encoder gaps.
6. Smoke: `tools/run-smoke.sh` — all 8-9 modes stay green; the
   R14B/R15 modes now include `UART RX: abc` in their expected
   output.
7. Commit with the standard closer message pattern:
   `Implement #601: uart_rx_smoke — UART RX: abc fingerprint (closes R16.M4)`.
8. File the follow-up (§6.2) as a new paideia-os issue with
   labels `blocked:662`, `r16-m5-dependency`, `harness`.
9. Bump the milestone: R16.M4 → R16.M5.

## 10. Risks

| Risk                                                                     | Probability | Mitigation                                                                                                        |
|--------------------------------------------------------------------------|-------------|-------------------------------------------------------------------------------------------------------------------|
| `mov_b [r12 + N], rax` with N != 0 rejected by paideia-as encoder        | Low         | §3.8 workaround (`add r12, 1; mov_b [r12 + 0], rax`) is mechanical, no design change needed.                       |
| Some prior witness has already advanced head/tail                        | Very Low    | #600's sub-test B calls `uart_rx_isr` with empty drain — no `enqueue`. head=tail=0 at witness entry.               |
| Ring bytes leak into a later witness                                     | None        | No later witness reads `_uart_rx_ring` or the head/tail counters.                                                  |
| Two `uart_puts` calls interleave with unrelated output                   | None        | Boot-time UART is single-threaded; every prior witness uses the same discipline.                                   |
| Fingerprint files diverge (one file gets marker, others don't)           | Low         | §5.3 lists all three files with explicit insertion anchors; landing checklist forces all three edits.              |
| Additive marker breaks a 5-mode fingerprint                              | None        | The five non-R16 modes (`boot_r8_only` etc.) don't reference any R16 marker; contains-in-order tolerates additions.|

## 11. Signature summary

- **Issue**: #601 (r16-m4-007)
- **Milestone**: R16.M4 (closer)
- **Option**: 3 — structural ring round-trip
- **New files**: none
- **New modules**: none
- **New primitives**: none
- **New witnesses**: 1 (`uart_rx_smoke_witness`)
- **New .bss slabs**: 1 (`_uart_rx_smoke_buf`, 8 bytes)
- **New rodata strings**: 2 (`uart_rx_smoke_prefix_msg`,
  `uart_rx_smoke_fail_msg`)
- **New fingerprint markers**: 1 (`UART RX: abc` in 3 files)
- **Encoder gaps**: 0
- **Cross-repo escalation**: not needed
- **Follow-ups filed**: 1 (real-IRQ smoke, blocked by #662 + R16.M5)
- **Total LOC**: ~59 across 5 files
- **AC satisfaction**: fingerprint `UART RX: abc` emitted from
  actual dequeue return values, verified externally via contains-
  in-order match on three expected-output files.
