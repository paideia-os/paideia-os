---
issue: 596
milestone: R16.M4 (UART input driver — 16550 RX interrupt-driven)
subsystem: 14 — UART input driver (16550 RX interrupt-driven)
topic: uart_rx_ring — static 256-byte ring buffer + head/tail indices + enqueue/dequeue leaf functions
prereq:
  - "P1-006/007 (LANDED; boot/uart.pdx TX driver — no direct dep, only shares COM1 device; RX ring is device-agnostic storage)"
  - "R16-M4-001 / #595 (LANDED; establishes src/kernel/core/uart/ directory and the RxInit module sibling. This issue extends the same directory with rx_ring.pdx.)"
blocks:
  - "#597 (r16-m4-003 uart_rx_isr — the sole producer into this ring; reads RBR on IRQ 4, calls uart_rx_enqueue)"
  - "#600 (r16-m4-006 uart_rx_notification_cap — indirectly, via sys_read consumer path)"
touching:
  - src/kernel/core/uart/rx_ring.pdx                    (new module — ~90 LOC incl. justification)
  - src/kernel/boot/kernel_main.pdx                     (witness block — ~120 LOC after last-landed R16.M4 witness)
  - tools/boot_stub.S                                   (2 rodata additions: ok_msg, fail_msg)
  - tests/r14b/expected-boot-r14b-loader.txt            (marker: `R16 UART RX RING OK`)
  - tests/r15/expected-boot-r15-ring3.txt               (marker)
  - tests/r15/expected-boot-r15-process.txt             (marker)
  - design/kernel/r16-m4-002-uart-rx-ring.md            (this doc)
related:
  - src/kernel/core/uart/rx_init.pdx                    (R16-M4-001 — sibling in core/uart/; establishes
                                                          the module-per-file convention this issue extends.
                                                          Zero data-flow between the two — rx_init programs
                                                          IER on COM1, rx_ring is device-agnostic storage.)
  - src/kernel/core/ipc/port.pdx                        (R13-m6-004 — closest prior-art for a bounded static
                                                          circular structure: 64-slot port pool in .bss with
                                                          slot_full/payload byte layout. Ring buffer here follows
                                                          the same .bss + fixed-slot pattern but adds true
                                                          circular indexing rather than direct-mapped slotting.)
  - src/kernel/core/fs/path.pdx                         (R16-M1-004 — freezes the `lea reg, [rip + sym]; add reg,
                                                          offset; mov_b [reg + 0], src` idiom used verbatim by
                                                          the ring's byte load/store. Also freezes the
                                                          `xor rax; mov_b rax, [ptr]` zero-extending byte load.)
  - src/kernel/core/sched/wake_block.pdx                (R15-m7 — freezes the `mov rax, [rip + _scalar_u64]`
                                                          load idiom used for the head/tail counters.)
  - design/milestones/r14b-tactical-plan.md             §Subsystem 14, item 2 (this issue's plan pointer)
  - design/kernel/r16-m4-001-uart-rx-init.md            (structural template for this doc — R16.M4 witness pattern)
---

# R16-M4-002 — `uart_rx_ring`: 256-byte ring buffer + enqueue/dequeue (#596)

## 1. Scope

Land the second R16.M4 subsystem-14 issue: a bounded static 256-byte
byte ring in `.bss` plus two leaf functions that produce and consume
bytes across it. This is a **data-structure** issue, not a driver
issue — no I/O port touched, no IRQ hooked, no ISR wired. It hands
#597 a validated in-memory queue to drain the 16550 RBR into.

```
uart_rx_enqueue(byte: u64) -> u64
    input:  rdi = byte value in low 8 bits (upper 56 bits ignored)
    output: rax = 0 on success, 1 if ring is full
    side effect: writes 1 byte to _uart_rx_ring at (head & 0xFF);
                 increments _uart_rx_head

uart_rx_dequeue() -> u64
    input:  (none)
    output: rax = byte in low 8 bits (upper 56 zeroed) on success,
            rax = 0xFFFF if ring is empty (sentinel)
    side effect: reads 1 byte from _uart_rx_ring at (tail & 0xFF);
                 increments _uart_rx_tail
```

Acceptance (issue AC): **enqueue/dequeue round-trip preserves
bytes.** The witness verifies this by four sub-tests covering the
empty state, single-byte round-trip, multi-byte FIFO ordering, and
capacity + wrap.

### 1.1 What this issue proves

- **A bounded circular byte queue can be implemented in the current
  paideia-as encoder surface** using only proven mnemonics
  (`mov [rip + sym], reg`, `mov reg, [rip + sym]`, `lea`, `add`,
  `sub`, `and reg, imm`, `cmp reg, imm`, `mov_b [reg], rax`,
  `xor + mov_b rax, [reg]`, direct `call`, `ret`, conditional
  branches). Zero encoder gap — see §2.3.
- **`.bss` zero-init is the correct empty state.** `_uart_rx_head`
  and `_uart_rx_tail` both start at 0, so the first dequeue observes
  `head == tail` and returns the empty-sentinel `0xFFFF`. No init
  function required; the ring is live at kernel_main entry.
- **Monotonic-counter head/tail indices are viable in the current
  ABI.** Head and tail are u64 counters that grow monotonically and
  wrap only at u64 overflow (2^64 UART bytes ≈ 5.8 × 10^11 years at
  1 Gbaud). Ring offset is extracted per access via `and reg, 0xFF`.
  Empty is `head == tail`; full is `head - tail >= 256`. No third
  counter, no wasted slot, all 256 bytes usable — see §3.4 for the
  full comparison with the two rejected alternatives.
- **Byte-narrow load/store into a `[u8; 256]` `.bss` slab round-trips
  fidelity.** Sub-test C explicitly writes 5 distinct byte values in
  order and reads them back in FIFO order; sub-test D writes 256
  distinct byte values that fill the ring exactly and reads them all
  back in order, so any byte-lane sign-extension or upper-byte drift
  would fail the witness.

### 1.2 What this issue deliberately does NOT do

- **No IRQ 4 producer.** #597 (`uart_rx_isr`) is the sole real
  producer; the ISR reads RBR and calls `uart_rx_enqueue`. This
  issue's witness stands in as a synthetic producer to prove ring
  correctness in isolation, before wiring the interrupt path.
- **No sys_read consumer.** #600 wires the ISR to a notification cap
  that ultimately unblocks a sys_read in userland; that path
  eventually calls `uart_rx_dequeue`. Kept out of scope — the ring
  is a self-contained data structure.
- **No mutual exclusion / lock.** The ring is designed as a
  Single-Producer / Single-Consumer (SPSC) queue: only the ISR
  writes head; only sys_read writes tail. Under the SPSC discipline
  monotonic-counter head/tail is lock-free by construction (Lamport
  '77), assuming (a) atomic 8-byte loads/stores on x86_64, which
  the ABI guarantees for aligned qwords, and (b) that the ISR and
  the consumer never run concurrently on the same CPU when the
  consumer is in the enqueue/dequeue critical section — enforced by
  `cli` around the read side, planned for #600. **No barriers or
  `mfence` are added here** — the model is a single-CPU / IRQ-off
  window for the consumer at R16.M4; SMP RX will need `lfence`
  before the tail load in dequeue and `sfence` before the head
  store in enqueue, deferred to the R17 SMP tier per master plan.
  The absence of ordering primitives at R16.M4 is documented in the
  module justification and cross-referenced in §7.4.
- **No blocking / wait-queue integration.** Both leaf functions are
  non-blocking: enqueue returns immediately with `rax=1` on full,
  dequeue returns immediately with `rax=0xFFFF` on empty. Callers
  own the blocking policy (sys_read at #600 will block on a
  notification cap when dequeue reports empty).
- **No overwrite-on-full policy.** Enqueue-when-full reports the
  overrun via `rax=1` and drops the incoming byte. This matches
  16550 hardware behavior (`OE = Overrun Error` bit 1 of LSR); the
  ISR at #597 will read LSR after RBR to detect hardware overrun
  and can log a separate counter for kernel-side software overrun
  when this function returns 1. Any policy change (overwrite-oldest,
  panic-on-overrun) belongs at #597, not here.
- **No FIFO status queries** (`uart_rx_len`, `uart_rx_empty`, etc.).
  YAGNI at R16.M4. If a peek-length becomes necessary later (e.g.
  for a select/poll implementation), it composes trivially as
  `head - tail`. Adding a query surface here would ossify the API
  before we know the consumer's real needs.
- **No `!{sysreg}` effect on either function.** Both operate purely
  on `.bss` memory. Effect set is `{mem}`, matching every other
  pure-memory data-structure primitive in the tree (vnode_pool,
  fd_set, path_resolve — all `{mem}`-only). No I/O port access,
  no MSR access.

## 2. Prereq check

### 2.1 What is in place

| Primitive              | Location                              | Contract used                                                                       |
|------------------------|---------------------------------------|-------------------------------------------------------------------------------------|
| `core/uart/` directory | `src/kernel/core/uart/rx_init.pdx`    | R16-M4-001 established the directory. This issue adds `rx_ring.pdx` as a sibling.   |
| `.bss` byte slab       | `core/fs/path.pdx:35`                 | `pub let mut _path_component_buf : [u8; 64] = uninit @align(8)` — same shape.       |
| `.bss` scalar u64      | `core/sched/runqueue.pdx:85,89`       | `pub let mut _current_tcb : u64 = 0` — zero-init idiom.                             |
| RIP-relative qword load | `core/sched/wake_block.pdx:41`        | `mov rax, [rip + _current_tcb]` — proven idiom.                                     |
| RIP-relative qword store | `core/syscall/entry.pdx:29`          | `mov [rip + _saved_user_rsp], rsp` — proven idiom.                                  |
| Slab base address       | `core/fs/path.pdx:92`                 | `lea r15, [rip + _path_component_buf]` — proven idiom.                              |
| Byte-narrow store       | `core/fs/path.pdx:141,150`            | `mov_b [r14 + 0], rax` — writes low 8 bits of rax to a memory byte.                 |
| Byte-narrow load        | `core/fs/path.pdx:74,102,124`         | `xor rax; mov_b rax, [r12]` — zero-extending byte load.                             |
| `and reg, 0xFF`         | `core/int/tss.pdx:121`, `core/fs/mount.pdx:127` | Byte-mask a register.                                                     |
| `cmp reg, 256`          | `core/fs/fd_inherit.pdx:58`, `core/int/idt.pdx:345` | Compare against a value that exceeds imm8 range.                        |
| `sub reg, reg`          | (widely used — vops.pdx and many others) | Register-to-register subtraction.                                                |
| `add reg, reg`          | Ubiquitous.                           | Register-to-register addition (for `base + offset` address composition).            |
| Direct `call sym` / `ret` | Ubiquitous.                          | Leaf-function invocation without prologue.                                          |

### 2.2 What is NOT in place

- **`_uart_rx_ring`, `_uart_rx_head`, `_uart_rx_tail` symbols.**
  Introduced by this module. All three go into `.bss`, all three
  zero-init.
- **`uart_rx_ring_ok_msg` / `uart_rx_ring_fail_msg` symbols in
  `boot_stub.S`.** Added alongside the last-landed R16.M4 witness
  strings (see §5.4).

### 2.3 Encoder gaps

**None.** Every mnemonic used has landed precedent. Explicit
enumeration (a checklist for the workerbee session):

| Mnemonic form                          | Proven at                                                       |
|----------------------------------------|-----------------------------------------------------------------|
| `mov rax, [rip + _sym]`                | `core/sched/wake_block.pdx:41`.                                 |
| `mov [rip + _sym], rax`                | `core/syscall/entry.pdx:29,31`; `boot/kernel_main.pdx:70`.      |
| `lea rax, [rip + _sym]`                | Ubiquitous (`_current_tcb`, `_path_component_buf`, etc.).       |
| `add rax, rcx` (reg,reg)               | Ubiquitous.                                                     |
| `add rax, 1` (reg,imm8)                | Ubiquitous (path.pdx pointer bumps).                            |
| `sub rax, rcx` (reg,reg)               | (Standard AMD64; used across mm/aspace_map, sched/switch.)      |
| `and rax, 0xFF`                        | `core/int/tss.pdx:121`; `core/fs/mount.pdx:127`.                |
| `cmp rax, 256`                         | `core/fs/fd_inherit.pdx:58`; `core/int/idt.pdx:345`.            |
| `cmp rax, 1` / `cmp rax, imm8`         | Ubiquitous.                                                     |
| `je` / `jne` / `jae` / `jb` / `jmp`    | Ubiquitous.                                                     |
| `xor rax, rax`                         | Ubiquitous.                                                     |
| `mov rax, imm64` (for 0xFFFF sentinel) | Any imm ≤ 0xFFFFFFFF fits `mov rax, imm32`; `0xFFFF` is imm16.  |
| `mov_b [reg + 0], rax` (byte store)    | `core/fs/path.pdx:141,150`.                                     |
| `mov_b rax, [reg + 0]` (byte load)     | `core/fs/path.pdx:74,102,124`; `core/fs/tmpfs/lookup.pdx:75-76`.|
| `call sym` (direct)                    | Ubiquitous.                                                     |
| `ret`                                  | Ubiquitous.                                                     |

No REX.B on extended base regs beyond the r8..r10 already-proven
uses (path.pdx uses r14/r15 as bases with `mov_b [reg + 0]`; this
issue uses r10 as base which is smaller register-number and
therefore trivially encodable if r14/r15 are). No 32-bit port I/O.
No SIB. No SSE/AVX. **Cross-repo escalation not needed.**

## 3. Design

### 3.1 File and module structure

New file: `src/kernel/core/uart/rx_ring.pdx`. Sits alongside the
sibling landed at R16-M4-001:

```
src/kernel/core/uart/
    rx_init.pdx     (#595, LANDED)
    rx_ring.pdx     <-- THIS ISSUE (#596)
    rx_isr.pdx      (#597, planned; producer)
    rx_notify.pdx   (#600, planned; consumer plumbing)
```

Module name: `UartRxRing`. Public exports:
`uart_rx_enqueue`, `uart_rx_dequeue`, and the three storage symbols
`_uart_rx_ring`, `_uart_rx_head`, `_uart_rx_tail` (public so the
witness in `kernel_main.pdx` can inspect them if needed, and so a
future SMP snapshot / debug routine can peek without going through
the leaf functions).

Storage constants exported for reuse:

```
RING_BYTES   : u64 = 256
RING_MASK    : u64 = 0xFF         // (RING_BYTES - 1) — valid iff power-of-2
DEQUEUE_EMPTY: u64 = 0xFFFF       // sentinel — 65535 > 0xFF, so unambiguous
ENQUEUE_OK   : u64 = 0
ENQUEUE_FULL : u64 = 1
```

The `RING_MASK = RING_BYTES - 1` identity holds only for power-of-2
sizes. This is the sole reason `RING_BYTES` is 256 rather than 200
or 300 — see §3.5.

### 3.2 Storage layout (.bss)

```
_uart_rx_ring : [u8; 256] = uninit @align(8)   // 256 B — one cache
                                               //   line unaligned reads
                                               //   are fine since all
                                               //   accesses are 1-byte
_uart_rx_head : u64 = 0                        //   8 B — producer cursor
_uart_rx_tail : u64 = 0                        //   8 B — consumer cursor
```

Total: 272 B in `.bss`. The `@align(8)` on the ring is a mild
courtesy — byte accesses don't require it, but future memcpy-style
drains (a "drain N bytes into userland" fast path at #600's
consumer) will appreciate qword-aligned bases.

`.bss` zero-init guarantees `head == tail == 0` at kernel entry,
which is precisely the empty condition (see §3.3). No `_ring_init`
function is needed — the zero state is the correct start state.

**Symbol visibility.** All three are `pub let mut`. The `mut`
attribute is essential — enqueue writes to head + a ring slot;
dequeue writes to tail + reads a ring slot. Cache-line placement
(head and tail in separate cache lines to avoid false sharing) is
**deliberately not** engineered at R16.M4: on SMP with a separate
producer and consumer CPU this matters, but R16.M4 is UP with
ring-consumer-in-cli. Follow-up for R17 SMP.

### 3.3 Empty / full distinction — monotonic counters

**Chosen strategy: monotonic u64 head/tail.**

- Empty: `head == tail`
- Full:  `head - tail >= 256`   (unsigned subtraction)
- Slot index for enqueue: `head & 0xFF`
- Slot index for dequeue: `tail & 0xFF`

Both counters grow monotonically for the lifetime of the kernel;
wraparound at u64 overflow requires 2^64 bytes of UART traffic,
which at 1 Gbaud (a decade beyond any real 16550) is ~584 years.
Practically un-reachable.

Because head and tail are counters, not slot indices, the byte-
level slot addressing needs one extra `and reg, 0xFF` per access.
This is one extra instruction per enqueue and one extra per
dequeue — trivial cost. In exchange, all 256 bytes are usable
capacity (see §3.4 for comparison against the alternative that
wastes one slot).

**Signed-difference concern.** The `head - tail >= 256` check
depends on `head >= tail` for the subtraction to yield the intuitive
"count of pending bytes". Invariant §7.1 guarantees this: enqueue
only writes head, dequeue only writes tail, and head is only ever
incremented after a successful enqueue (which requires
`head - tail < 256`), so `head >= tail` always. The unsigned `sub`
+ `cmp result, 256` is therefore mathematically safe.

**Underflow concern.** Dequeue only decrements the "pending count"
(implicitly, by advancing tail), and only advances tail after
observing `head != tail`. So tail never overtakes head, and
`head - tail` never underflows into large unsigned space.

### 3.4 Alternatives considered — empty/full distinction

| Strategy                                | Bytes usable | .bss overhead | Extra insns per op | Rejection rationale                                                                 |
|-----------------------------------------|--------------|---------------|--------------------|-------------------------------------------------------------------------------------|
| **Monotonic counters (chosen)**         | 256          | 16 (head+tail)| +1 per op (`and`)   | —                                                                                   |
| One-slot-wasted (classic ring)          | 255          | 16 (head+tail)| 0                  | Sacrifices a byte of capacity for a "cleaner" full-check (`(head+1)&0xFF == tail`).  |
| Separate count field                    | 256          | 24 (head/tail/count) | +2 per op (`add`/`sub` on count) | Third field mutated from both enqueue and dequeue — hostile to future lock-free SPSC (violates Lamport's single-writer-per-field discipline). Also more code, more `.bss`. |
| Sequence-numbered slots (each slot carries seqno) | 256 | ring becomes `[u64;256] = 2048 B` | slot access is qword rather than byte | Elegant for lock-free MPMC but massive over-engineering for a byte queue where the entire fast path is 1 byte per iteration. YAGNI. |

**Chosen: monotonic counters.** Combines full 256-byte capacity, no
third field, natural SPSC discipline (each of head and tail is
written by exactly one party, unlocking future lock-free operation),
and identical LOC to the one-slot-wasted strategy modulo one
instruction per op.

### 3.5 Why 256 bytes and not 128 / 512

- **Power of two.** `RING_MASK = 0xFF` gives single-instruction
  wrap via `and reg, 0xFF`. Non-power-of-2 would require a compare
  + conditional subtract (or a full modulo) — the encoder does not
  have `div`, so modulo by 200 would be a hand-written sequence.
  Every power-of-2 size in [64, 4096] would work equally cheaply.
- **256-byte scale**. The 16550's own hardware FIFO is 16 bytes at
  the RX side (FCR bits 6-7 set the trigger; `uart_init` at
  `boot/uart.pdx:44` writes FCR=0xC7 which selects the 14-byte
  trigger and enables the FIFO). Kernel-side ring at 256 bytes
  gives 16× the hardware FIFO — comfortably absorbs bursts where
  the consumer stalls (e.g., a long sys_read setup) without
  overrunning. At 1 Mbaud a full 256-byte ring is ~2.5 ms of
  buffered input, adequate for any interactive latency budget.
- **`@align(8)` in .bss** costs at most 7 padding bytes and enables
  future qword-copy drains without a slow path.

### 3.6 Register discipline

Both functions are **leaf**. No nested calls. No callee-save reg
touched. No prologue, no epilogue. Only caller-save scratch used:
`rax, rcx, rdx, r8, r9, r10`. `rdi` is read-only in enqueue
(passed-in byte).

Stack alignment is irrelevant to leaves that dispatch nothing —
`rsp % 16 == 8` at entry (post-call SysV state), the leaf runs
without touching `rsp`, and `ret` restores `rsp % 16 == 0` in the
caller.

### 3.7 `uart_rx_enqueue` — body

```asm
; ================================================================
; uart_rx_enqueue(byte: u64) -> u64
;   rdi = byte value (low 8 bits used, upper 56 ignored)
;   rax = 0 (ENQUEUE_OK) on success
;   rax = 1 (ENQUEUE_FULL) if head - tail >= 256
;
;   Effects: {mem}   Capabilities: {}
;   Leaf. No prologue. Callers must treat rcx, rdx, r8, r9, r10,
;   rax as clobbered (SysV caller-save discipline).
; ================================================================
uart_rx_enqueue:
    ; --- Load counters ---
    mov rcx, [rip + _uart_rx_head]         ; rcx = head
    mov rdx, [rip + _uart_rx_tail]         ; rdx = tail

    ; --- Full check: (head - tail) >= 256 ---
    mov r8, rcx
    sub r8, rdx                            ; r8 = head - tail = used
    cmp r8, 256                            ; RING_BYTES
    jae enq_full

    ; --- Compute slot address: &ring[head & 0xFF] ---
    mov r9, rcx
    and r9, 0xFF                           ; r9 = head_slot
    lea r10, [rip + _uart_rx_ring]         ; r10 = ring base
    add r10, r9                            ; r10 = &ring[head_slot]

    ; --- Store byte (low 8 bits of rdi) ---
    mov rax, rdi                           ; stage byte into rax so
                                           ;   the byte-narrow store
                                           ;   idiom (mov_b [r10+0], rax)
                                           ;   applies verbatim
    mov_b [r10 + 0], rax                   ; ring[head_slot] = byte

    ; --- Advance head ---
    add rcx, 1
    mov [rip + _uart_rx_head], rcx

    ; --- Return ENQUEUE_OK ---
    xor rax, rax
    ret

enq_full:
    mov rax, 1                             ; ENQUEUE_FULL
    ret
```

**Instruction count**: 14 body + 2 exit (`xor + ret`) + 2 fail exit
(`mov + ret`) = 18 instructions. No branch besides the single full-
check.

**Byte lane discipline.** `mov_b [r10 + 0], rax` writes AL. The
upper 56 bits of the source register are ignored by the `mov_b`
encoding; whatever bit pattern `rdi` held in its upper bits is
silently discarded, which matches the contract ("low 8 bits used,
upper 56 ignored"). Documented in the justification.

### 3.8 `uart_rx_dequeue` — body

```asm
; ================================================================
; uart_rx_dequeue() -> u64
;   rax = byte in low 8 bits (upper 56 zero-extended) on success
;   rax = 0xFFFF (DEQUEUE_EMPTY sentinel) if head == tail
;
;   Effects: {mem}   Capabilities: {}
;   Leaf. No prologue. Callers must treat rcx, rdx, r9, r10, rax
;   as clobbered.
; ================================================================
uart_rx_dequeue:
    ; --- Load counters ---
    mov rcx, [rip + _uart_rx_head]         ; rcx = head
    mov rdx, [rip + _uart_rx_tail]         ; rdx = tail

    ; --- Empty check: head == tail ---
    cmp rcx, rdx
    je  deq_empty

    ; --- Compute slot address: &ring[tail & 0xFF] ---
    mov r9, rdx
    and r9, 0xFF                           ; r9 = tail_slot
    lea r10, [rip + _uart_rx_ring]         ; r10 = ring base
    add r10, r9                            ; r10 = &ring[tail_slot]

    ; --- Load byte (zero-extended into rax) ---
    xor rax, rax                           ; clear upper 56 bits
    mov_b rax, [r10 + 0]                   ; rax = ring[tail_slot]

    ; --- Advance tail ---
    add rdx, 1
    mov [rip + _uart_rx_tail], rdx

    ret                                    ; rax = byte

deq_empty:
    mov rax, 0xFFFF                        ; DEQUEUE_EMPTY sentinel
    ret
```

**Instruction count**: 12 body + 1 `ret` + 2 empty exit = 15.

**Sentinel choice: 0xFFFF.** Two properties matter:
1. `0xFFFF > 0xFF`, so the consumer can distinguish success (byte
   in range 0..0xFF) from empty (0xFFFF) with a single unsigned
   `cmp rax, 0xFF; ja` or `cmp rax, 0xFFFF; je`.
2. `0xFFFF` is a distinctive pattern (looks like a "no data"
   marker, matches -1 in u16 semantics). Not 0 because 0 is a
   legitimate byte value; not 0xFF because 0xFF is a legitimate
   byte value; 0xFFFF is the smallest value that unambiguously
   cannot be a data byte.

An alternative was `-1 = 0xFFFFFFFFFFFFFFFF`, which is even more
distinctive but costs a full imm64 encoding (`mov rax, imm64`
requires REX.W + 8-byte immediate). `0xFFFF` fits in imm16 /
imm32, saving 6 bytes of code per empty exit. In a leaf that runs
once per byte received under sustained UART traffic, this matters
mildly for icache.

### 3.9 Producer / consumer discipline (documented; enforced by #597/#600)

- **Only #597's `uart_rx_isr` may call `uart_rx_enqueue`.** ISR
  runs with interrupts disabled (implicit on x86 entering vector
  0x24 via IDT).
- **Only #600's sys_read path may call `uart_rx_dequeue`.** It must
  do so with interrupts locally disabled (`cli` / `sti` pair) on
  R16.M4 UP configuration; on R17 SMP it must also add `lfence`
  before the load of head to prevent the CPU from re-ordering the
  head-load ahead of the tail-store from a previous iteration.
- **The witness at R16.M4-002 (this issue) violates the discipline
  intentionally** — the same thread calls both enqueue and dequeue
  serially to prove ring correctness. That is a self-contained
  test scenario; no interrupt is armed, so no producer competes.

### 3.10 File contents

```pdx
// src/kernel/core/uart/rx_ring.pdx — R16-M4-002 (#596)
// uart_rx_ring: static 256-byte SPSC byte ring in .bss.
//
// Two leaf functions:
//   uart_rx_enqueue(byte): appends byte if not full; returns 0/1.
//   uart_rx_dequeue():     pops oldest byte or sentinel 0xFFFF.
//
// Head and tail are monotonically-increasing u64 counters; ring
// offset is (counter & 0xFF). Empty iff head==tail; full iff
// (head - tail) >= 256. .bss zero-init makes the initial state
// (head=tail=0) the empty state — no init call required.
//
// See design/kernel/r16-m4-002-uart-rx-ring.md for full contract.

module UartRxRing = structure {
  // === Constants (pinned by design §3.1) ===
  pub let RING_BYTES     : u64 = 256
  pub let RING_MASK      : u64 = 0xFF          // (RING_BYTES - 1)
  pub let ENQUEUE_OK     : u64 = 0
  pub let ENQUEUE_FULL   : u64 = 1
  pub let DEQUEUE_EMPTY  : u64 = 0xFFFF

  // === Storage (.bss slab + two counters — SPSC, no lock) ===
  pub let mut _uart_rx_ring : [u8; 256] = uninit @align(8)
  pub let mut _uart_rx_head : u64 = 0          // producer cursor (ISR-only)
  pub let mut _uart_rx_tail : u64 = 0          // consumer cursor (sys_read-only)

  // ==========================================================================
  // uart_rx_enqueue — append one byte to the ring
  //
  // Input:  rdi = byte value (low 8 bits used; upper 56 ignored)
  // Output: rax = ENQUEUE_OK (0) on success
  //         rax = ENQUEUE_FULL (1) if head - tail >= 256
  //
  // Side effects:
  //   On success: writes 1 byte to _uart_rx_ring[head & 0xFF];
  //               increments _uart_rx_head.
  //   On full:    no state change.
  //
  // Clobbers (SysV caller-save):
  //   rax, rcx, rdx, r8, r9, r10.
  // ==========================================================================
  pub let uart_rx_enqueue : (u64) -> u64 !{mem} @{} = fn (byte: u64) -> unsafe {
    effects: {mem},
    capabilities: {},
    justification: "R16-M4-002 (#596): appends one byte to the 256-slot SPSC ring. Reads _uart_rx_head and _uart_rx_tail as u64 monotonic counters; computes used = head - tail; full iff used >= 256 (RING_BYTES). On not-full, computes slot = head & 0xFF (RING_MASK), forms &_uart_rx_ring[slot] via `lea + add`, and stores the low 8 bits of the passed byte via `mov_b [r10+0], rax` (byte-narrow store idiom frozen at core/fs/path.pdx:141). Then increments head and stores back. Leaf function; no prologue; caller-save-only clobbers (rax, rcx, rdx, r8, r9, r10). Called only by uart_rx_isr (#597) at R16.M4; at that point IRQ 4 delivery via vector 0x24 (installed by #598) ensures the ISR runs with interrupts disabled implicitly, so no re-entrant enqueue is possible. This function does NOT emit an sfence — R16.M4 targets UP; the sole consumer (#600 sys_read path) will run with interrupts locally disabled, sequentially with the ISR, so store-order visibility is intra-CPU only. R17 SMP tier (deferred) will add the sfence after the head store. .bss zero-init gives head=tail=0 at kernel entry, so the very first call sees an empty ring — matches the AC (round-trip preserves bytes) when paired with the immediately-following dequeue. Full return semantics: rax=1 means the byte was dropped; caller (uart_rx_isr) can log a software-overrun counter but MUST NOT retry — the hardware RBR should already have been read by the ISR before this call, so the byte is lost regardless of what enqueue reports. Sentinel choice (0/1 vs 0xFFFF): 1 fits in a single-byte immediate, and success/failure being 0/1 matches the syscall/handler convention used across R13-R16. Audit: r16-m4-002-uart-rx-ring.",
    block: {
      // Load head and tail
      mov rcx, [rip + _uart_rx_head];
      mov rdx, [rip + _uart_rx_tail];

      // Full check: (head - tail) >= RING_BYTES
      mov r8, rcx;
      sub r8, rdx;
      cmp r8, 256;
      jae enq_full;

      // Compute &ring[head & 0xFF]
      mov r9, rcx;
      and r9, 0xFF;
      lea r10, [rip + _uart_rx_ring];
      add r10, r9;

      // Store byte
      mov rax, rdi;
      mov_b [r10 + 0], rax;

      // Advance head
      add rcx, 1;
      mov [rip + _uart_rx_head], rcx;

      // Return ENQUEUE_OK
      xor rax, rax;
      ret;

    enq_full:
      mov rax, 1;
      ret
    }
  }

  // ==========================================================================
  // uart_rx_dequeue — pop the oldest byte from the ring
  //
  // Input:  (none)
  // Output: rax = byte (low 8 bits, upper 56 zero-extended) on success
  //         rax = DEQUEUE_EMPTY (0xFFFF) if head == tail
  //
  // Side effects:
  //   On success: reads 1 byte from _uart_rx_ring[tail & 0xFF];
  //               increments _uart_rx_tail.
  //   On empty:   no state change.
  //
  // Clobbers (SysV caller-save):
  //   rax, rcx, rdx, r9, r10.
  // ==========================================================================
  pub let uart_rx_dequeue : () -> u64 !{mem} @{} = fn () -> unsafe {
    effects: {mem},
    capabilities: {},
    justification: "R16-M4-002 (#596): pops the oldest byte from the 256-slot SPSC ring. Reads _uart_rx_head and _uart_rx_tail; empty iff head == tail. On not-empty, computes slot = tail & 0xFF, forms &_uart_rx_ring[slot] via `lea + add`, and loads the byte via `xor rax; mov_b rax, [r10+0]` (zero-extending byte-load idiom frozen at core/fs/path.pdx:74). Then increments tail and stores back. Leaf function; no prologue; caller-save-only clobbers (rax, rcx, rdx, r9, r10). Empty-sentinel is 0xFFFF: chosen because it fits in imm16, is unambiguously out of the u8 range (any byte value is 0..0xFF), and matches -1-style semantics in u16 without requiring the imm64 encoding that 0xFFFFFFFFFFFFFFFF would need. Called only by the sys_read path (#600) at R16.M4; that path must gate this call with cli/sti on UP, and (deferred to R17 SMP) with lfence before the head-load. This function does NOT emit an lfence — R16.M4 targets UP. .bss zero-init gives head=tail=0 at kernel entry, so the very first call returns DEQUEUE_EMPTY — required by the witness sub-test A which relies on this exact behavior to prove the empty-state contract without any preceding setup. Audit: r16-m4-002-uart-rx-ring.",
    block: {
      // Load head and tail
      mov rcx, [rip + _uart_rx_head];
      mov rdx, [rip + _uart_rx_tail];

      // Empty check
      cmp rcx, rdx;
      je  deq_empty;

      // Compute &ring[tail & 0xFF]
      mov r9, rdx;
      and r9, 0xFF;
      lea r10, [rip + _uart_rx_ring];
      add r10, r9;

      // Load byte (zero-extended)
      xor rax, rax;
      mov_b rax, [r10 + 0];

      // Advance tail
      add rdx, 1;
      mov [rip + _uart_rx_tail], rdx;

      ret;

    deq_empty:
      mov rax, 0xFFFF;
      ret
    }
  }
}
```

## 4. Witness placement

### 4.1 Position in kernel_main.pdx

Inserted after the last-landed R16.M4-001 witness `_done` label
(`uart_rx_init_witness_done:` at `kernel_main.pdx:3728`). The
insertion point is therefore:

```
  uart_rx_init_witness_done:

  <-- INSERT R16.M4-002 WITNESS HERE

  // R14b-m5-002 (#507): IA32_GS_BASE = &_cpu_locals[0] on CPU0.
  lea rax, [rip + _cpu_locals];
  ...
```

The insertion is structurally independent — no data flow into or
out of any preceding witness, no data flow into the wrmsr /
process_init block that follows.

### 4.2 No fixture slab needed

Unlike R16.M3 syscall witnesses that need per-witness task_struct
blobs, this witness needs no `.bss` allocation of its own. The
ring itself is the fixture. .bss zero-init ensures head=tail=0
at witness entry, which is precisely the state sub-test A requires.

## 5. Test canary — kernel_main witness block

### 5.1 Sub-test structure

Four sub-tests, each verifying one axis of the round-trip contract:

- **Sub-test A** — Initial empty: dequeue on virgin ring returns 0xFFFF.
- **Sub-test B** — Single byte round-trip: enqueue 'A' (0x41), dequeue → 'A'.
- **Sub-test C** — Multi-byte FIFO ordering: enqueue "hello", dequeue 5 times → 'h','e','l','l','o'.
- **Sub-test D** — Capacity + wrap + full detection: enqueue 256 bytes (values 0..255), verify #257 returns ENQUEUE_FULL, dequeue 256 bytes in order, verify final dequeue returns DEQUEUE_EMPTY.

**Ordering rationale.** A first (probes the trivial state that
requires no setup). B second (proves the single-byte lifecycle end-
to-end). C third (proves FIFO ordering across multiple bytes but
without wrap). D last (exercises full detection, capacity=256, and
wrap correctness — the ring wraps at slot 0 when head reaches 256
because slot index is `head & 0xFF`).

State discipline: **no reset between sub-tests.** After each sub-
test the ring returns to an empty state (head == tail); the counter
values are non-zero (head=tail=1 after B, head=tail=6 after C,
head=tail=262 after D), but this is invisible to the leaf functions,
which only look at (head - tail) and (counter & 0xFF). The sub-
tests compose freely.

### 5.2 Sub-test A — initial dequeue returns 0xFFFF

```asm
uart_rx_ring_witness:
    ; ---------- Sub-test A: virgin ring is empty ----------
    call uart_rx_dequeue                    ; rax = 0xFFFF expected
    cmp  rax, 0xFFFF
    jne  uart_rx_ring_witness_fail
```

Rationale: relies on .bss zero-init. If the ring symbols landed in
`.data` with garbage init or if the linker mis-placed them, this
sub-test fires first and localizes the bug to a storage issue
before any operational test runs.

### 5.3 Sub-test B — enqueue 'A' then dequeue returns 'A'

```asm
    ; ---------- Sub-test B: single-byte round-trip ----------
    mov  rdi, 0x41                          ; 'A'
    call uart_rx_enqueue
    cmp  rax, 0                             ; ENQUEUE_OK
    jne  uart_rx_ring_witness_fail

    call uart_rx_dequeue
    cmp  rax, 0x41                          ; must equal 'A'
    jne  uart_rx_ring_witness_fail
```

Proves: (1) enqueue-when-empty succeeds, (2) enqueue actually
writes to the ring (not a no-op), (3) dequeue reads back the
exact byte, (4) upper 56 bits of rax on dequeue return are zero
(the `cmp rax, 0x41` is an exact-equality check on the full
qword — if `mov_b rax, [...]` left junk in the upper bits, the
compare fails).

### 5.4 Sub-test C — enqueue "hello" then dequeue 5 times

```asm
    ; ---------- Sub-test C: multi-byte FIFO ordering ----------
    ; Enqueue 'h' 'e' 'l' 'l' 'o'
    mov rdi, 0x68; call uart_rx_enqueue     ; 'h'
    cmp rax, 0; jne uart_rx_ring_witness_fail
    mov rdi, 0x65; call uart_rx_enqueue     ; 'e'
    cmp rax, 0; jne uart_rx_ring_witness_fail
    mov rdi, 0x6C; call uart_rx_enqueue     ; 'l'
    cmp rax, 0; jne uart_rx_ring_witness_fail
    mov rdi, 0x6C; call uart_rx_enqueue     ; 'l'
    cmp rax, 0; jne uart_rx_ring_witness_fail
    mov rdi, 0x6F; call uart_rx_enqueue     ; 'o'
    cmp rax, 0; jne uart_rx_ring_witness_fail

    ; Dequeue and check each in order
    call uart_rx_dequeue
    cmp rax, 0x68; jne uart_rx_ring_witness_fail    ; 'h'
    call uart_rx_dequeue
    cmp rax, 0x65; jne uart_rx_ring_witness_fail    ; 'e'
    call uart_rx_dequeue
    cmp rax, 0x6C; jne uart_rx_ring_witness_fail    ; 'l'
    call uart_rx_dequeue
    cmp rax, 0x6C; jne uart_rx_ring_witness_fail    ; 'l'
    call uart_rx_dequeue
    cmp rax, 0x6F; jne uart_rx_ring_witness_fail    ; 'o'
```

Proves FIFO ordering (not LIFO), and that byte values are not
mangled by the byte-narrow store/load pair. Explicit per-byte
enqueue is preferred over a loop with a "hello" string in rodata
because the direct form makes each byte value visible in the
witness source — a diagnostic reading the witness during a bisect
sees "expected 'h'" not "expected [rsi]".

### 5.5 Sub-test D — capacity, full detection, wrap, drain

```asm
    ; ---------- Sub-test D: fill to 256, verify full, drain, verify empty ----------
    ; Enqueue 256 bytes, values 0..255. r12 = i (loop counter).
    ; NOTE: r12 is callee-save; we're preserving it across the loop's
    ; nested call to uart_rx_enqueue (which does not clobber r12 per
    ; its SysV caller-save-only discipline).
    xor r12, r12                             ; i = 0
  fill_loop:
    mov rdi, r12                             ; byte = i (low 8 bits used)
    call uart_rx_enqueue
    cmp rax, 0                               ; must be ENQUEUE_OK
    jne uart_rx_ring_witness_fail
    add r12, 1
    cmp r12, 256
    jb  fill_loop

    ; Verify 257th enqueue returns FULL
    mov rdi, 0x99                            ; overflow byte
    call uart_rx_enqueue
    cmp rax, 1                               ; ENQUEUE_FULL
    jne uart_rx_ring_witness_fail

    ; Drain 256 bytes, verify each equals i (0..255)
    xor r12, r12                             ; i = 0
  drain_loop:
    call uart_rx_dequeue
    cmp rax, r12                             ; low 8 bits of r12 are the expected byte
    jne uart_rx_ring_witness_fail
    add r12, 1
    cmp r12, 256
    jb  drain_loop

    ; Verify ring is now empty (matches sub-test A's contract post-drain)
    call uart_rx_dequeue
    cmp rax, 0xFFFF
    jne uart_rx_ring_witness_fail
```

**Register discipline in the witness.** r12 is callee-save under
SysV, and both leaf functions declare caller-save-only clobbers.
The loop uses r12 as the counter so that nested calls preserve it
implicitly. Prologue for the whole witness needs one `push r12`
and one `pop r12` around the entire ring-witness block.

**Why fill-with-index (0..255) rather than fill-with-constant.**
Filling with a single constant byte would prove capacity and
full-detection but not that the wrap correctly maps
`head = 256` back to slot 0. Filling with sequential values
means the first byte dequeued (slot 0, written when head==0) is
0x00; the byte written when head==255 is 0xFF at slot 255; and
the byte at slot 0 after a wrap would only ever be a re-written
0x100&0xFF=0 — but at the fill stage no wrap occurs (256 bytes
exactly fills the ring). The drain then reads slots 0..255 in
order (tail starts at 0, drains to 256), so each dequeue must
return the value that was written at that slot index. Any wrap-
computation bug (e.g., off-by-one on the mask, mask=0x7F instead
of 0xFF, mask-both-sides ambiguity) surfaces as a specific byte
value mismatch.

**Why the post-drain empty check.** Symmetrically confirms sub-
test A's contract (empty → 0xFFFF) after arbitrary usage —
proves that DEQUEUE_EMPTY is not just a "cold-start" property
but a genuine invariant of `head == tail`.

### 5.6 Full witness assembly (integrated)

```asm
; ============================================================
; R16-M4-002 (#596): uart_rx_ring witness — 4 sub-tests
; ============================================================
uart_rx_ring_witness:
    push r12                                 ; callee-save loop counter

    ; ---------- Sub-test A: virgin ring is empty ----------
    call uart_rx_dequeue
    cmp  rax, 0xFFFF
    jne  uart_rx_ring_witness_fail

    ; ---------- Sub-test B: single-byte round-trip ----------
    mov  rdi, 0x41
    call uart_rx_enqueue
    cmp  rax, 0
    jne  uart_rx_ring_witness_fail
    call uart_rx_dequeue
    cmp  rax, 0x41
    jne  uart_rx_ring_witness_fail

    ; ---------- Sub-test C: multi-byte FIFO ("hello") ----------
    mov rdi, 0x68; call uart_rx_enqueue; cmp rax, 0; jne uart_rx_ring_witness_fail
    mov rdi, 0x65; call uart_rx_enqueue; cmp rax, 0; jne uart_rx_ring_witness_fail
    mov rdi, 0x6C; call uart_rx_enqueue; cmp rax, 0; jne uart_rx_ring_witness_fail
    mov rdi, 0x6C; call uart_rx_enqueue; cmp rax, 0; jne uart_rx_ring_witness_fail
    mov rdi, 0x6F; call uart_rx_enqueue; cmp rax, 0; jne uart_rx_ring_witness_fail

    call uart_rx_dequeue; cmp rax, 0x68; jne uart_rx_ring_witness_fail
    call uart_rx_dequeue; cmp rax, 0x65; jne uart_rx_ring_witness_fail
    call uart_rx_dequeue; cmp rax, 0x6C; jne uart_rx_ring_witness_fail
    call uart_rx_dequeue; cmp rax, 0x6C; jne uart_rx_ring_witness_fail
    call uart_rx_dequeue; cmp rax, 0x6F; jne uart_rx_ring_witness_fail

    ; ---------- Sub-test D: capacity + full + drain + empty ----------
    xor r12, r12
  urrw_fill_loop:
    mov rdi, r12
    call uart_rx_enqueue
    cmp rax, 0
    jne uart_rx_ring_witness_fail
    add r12, 1
    cmp r12, 256
    jb  urrw_fill_loop

    mov rdi, 0x99
    call uart_rx_enqueue
    cmp rax, 1
    jne uart_rx_ring_witness_fail

    xor r12, r12
  urrw_drain_loop:
    call uart_rx_dequeue
    cmp rax, r12
    jne uart_rx_ring_witness_fail
    add r12, 1
    cmp r12, 256
    jb  urrw_drain_loop

    call uart_rx_dequeue
    cmp rax, 0xFFFF
    jne uart_rx_ring_witness_fail

    ; --- All green ---
    lea  rdi, [rip + uart_rx_ring_ok_msg]
    call uart_puts
    jmp  uart_rx_ring_witness_done

uart_rx_ring_witness_fail:
    lea  rdi, [rip + uart_rx_ring_fail_msg]
    call uart_puts

uart_rx_ring_witness_done:
    pop  r12
```

Total: ~72 lines including labels and blank lines.

**Label uniqueness.** All labels prefixed `urrw_` (uart_rx_ring
witness) to avoid clashes with other witnesses in the same file
that use generic names like `fill_loop`, `drain_loop`. Same
prefixing discipline as `path_fail`, `regular_lookup`, etc.

### 5.7 Marker

On all four sub-tests green:

```
R16 UART RX RING OK
```

Emitted via `uart_puts` on `uart_rx_ring_ok_msg`. Fingerprint added
to all three R14B/R15 expected-output files, inserted immediately
after the `R16 UART RX INIT OK` line and before the first R15
scheduler marker.

### 5.8 String data — `tools/boot_stub.S`

Append after the last-landed R16.M4-001 witness strings (at
approximately line 702):

```asm
# R16-M4-002 (#596): uart_rx_ring witness success message
.global uart_rx_ring_ok_msg
.align 8
uart_rx_ring_ok_msg: .ascii "R16 UART RX RING OK\n\0"

# R16-M4-002 (#596): uart_rx_ring witness failure message
.global uart_rx_ring_fail_msg
.align 8
uart_rx_ring_fail_msg: .ascii "R16 UART RX RING FAIL\n\0"
```

No other rodata changes. No per-sub-test failure messages — the
witness is compact enough that a single-line failure is sufficient
(same discipline as R16-M4-001, which also uses a single fail
message; per-sub-test failure strings were considered in R16-M3-007
where the witness was much larger, and are appropriate only when
the failure surface has multiple structurally-independent
sub-witnesses).

### 5.9 Fingerprint files — marker insertion

Insert `R16 UART RX RING OK` in three files:

| File                                        | Insert after            | Insert before          |
|---------------------------------------------|-------------------------|------------------------|
| `tests/r14b/expected-boot-r14b-loader.txt`  | `R16 UART RX INIT OK`   | `LOADER OK`            |
| `tests/r15/expected-boot-r15-ring3.txt`     | `R16 UART RX INIT OK`   | `R15 IDLE TASK OK`     |
| `tests/r15/expected-boot-r15-process.txt`   | `R16 UART RX INIT OK`   | `R15 IDLE TASK OK`     |

Contains-in-order matching makes the addition strictly additive —
no earlier line reorders. All 5-mode smoke stages that do not
observe R16 markers (`boot_r8_only`, `boot_r10`, `boot_r11`,
`boot_r12`, `boot_r12_denial`) stay byte-identically green.

## 6. Alternatives considered / follow-ups

### 6.1 Combine with #597 (rx_isr) in one PR

**Rejected.** #597 is the ISR body that drains RBR into this ring
and depends on the ring existing. Landing them together would
either (a) leave the ring untested in isolation, or (b) balloon
the witness with a synthetic IRQ trigger. Splitting keeps each
issue's regression surface minimal.

### 6.2 Ring size 128 or 512 instead of 256

**Rejected.** 128 halves the burst-absorb budget; 512 doubles .bss
without demonstrated need. 256 is the tactical-plan value and
matches the "one page byte-scale" heuristic used in tmpfs (also
256 vnodes). See §3.5 for the FIFO-headroom calculation.

### 6.3 One-slot-wasted classic ring (`(head+1)&0xFF == tail` full check)

**Rejected.** Loses one byte of capacity (255 usable), gains zero
LOC savings (the classic full check is still 2 instructions:
`add head, 1; and result, 0xFF; cmp result, tail`), and forfeits
the future SPSC lock-free discipline that monotonic counters unlock
(one-slot-wasted needs a memory barrier between the enqueue store
and the head update, or the consumer can observe a "full" state
before the byte becomes visible). See §3.4 table.

### 6.4 Store head/tail as u32 instead of u64

**Rejected — mildly, with a note.** u32 saves 8 bytes of .bss and
would fit the current wrap arithmetic (u32 overflow at 2^32 bytes
is still 71 minutes at 1 Gbaud, adequate for R16.M4 but tight for
sustained high-rate SMP RX at R17). u32 accesses would use
`mov [rip + sym], eax` — however, `mov reg32, [rip + sym]` (the
32-bit RIP-relative load) has **no landed precedent** in the
kernel tree today (all `mov eax, [...]` uses are register+offset,
not RIP-relative). Adding an encoder proof for RIP-relative 32-bit
load is a distinct paideia-as concern that would spawn a cross-repo
escalation, blocking #596 on encoder work that isn't otherwise
needed. u64 avoids the entire question and costs 8 bytes. The
task's field-typing hint of `u32` in the issue prompt is
non-binding — the ring's contract is byte-values in the slab,
head/tail width is an internal representation choice.

### 6.5 Add a `_uart_rx_dropped_count : u64` overrun counter

**Deferred to #597.** The ISR is the only party that observes the
enqueue-full return code; the counter belongs adjacent to the ISR,
not adjacent to the ring. Adding a counter here would create a
storage symbol with no writer at #596-landing (the witness never
provokes full via the ISR path). Better to co-locate with the ISR
in `rx_isr.pdx`.

### 6.6 Move the ring to `boot/` next to `uart_init`

**Rejected.** Symmetrical to R16-M4-001 §6.5: `boot/` is for
boot-critical code that runs during long-mode transition. The RX
ring is a post-boot data structure, so `core/uart/` is correct.

### 6.7 Provide an `uart_rx_ring_init()` function

**Rejected.** `.bss` zero-init makes head=tail=0 at kernel entry,
which IS the correct empty state. An explicit init call would be
dead code with no observable postcondition change; adding it
would require a call from kernel_main early boot and a witness
call-count check to prove it fired — pure overhead. Same
discipline as `Port` (ipc/port.pdx) which likewise ships without
init because .bss zero is the correct empty state.

### 6.8 Emit `R16 UART RX RING OK` from within enqueue/dequeue

**Rejected.** Same discipline as every other R16 subsystem: leaf
functions are silent, witnesses emit. Keeps enqueue/dequeue
reusable by non-witness callers (the ISR at #597 and sys_read at
#600 will call them hundreds of times per second — printing on
each call would flood the console and destroy the console UX).

## 7. Invariants

### 7.1 `head >= tail` at all times

- **Base case**: .bss zero-init gives `head = tail = 0`.
- **Enqueue**: head += 1 only if `head - tail < 256` (unsigned).
  If `head >= tail` held pre-call, `head + 1 >= tail` still holds.
- **Dequeue**: tail += 1 only if `head != tail`. Since `head >= tail`,
  `head != tail` implies `head > tail`, so `tail + 1 <= head`, so
  `head >= tail + 1 >= new_tail`. Invariant preserved.
- **Implication**: `head - tail` (unsigned) is always the true
  count of pending bytes, in [0, 256].

### 7.2 The ring never overwrites unread data

- Enqueue's full check `head - tail >= 256` rejects any write that
  would advance head past `tail + 256`. Since `head - tail` is the
  count of pending bytes, `>= 256` means the ring already holds
  all 256 slots' worth of data — writing anywhere would land on
  an already-pending slot at index `head & 0xFF`, which equals
  `tail & 0xFF` (because `head - tail == 256` implies
  `head ≡ tail (mod 256)`).

### 7.3 The ring never returns unwritten data

- Dequeue's empty check `head == tail` rejects any read when no
  byte has been enqueued since the last dequeue. In the empty
  state the byte at `_uart_rx_ring[tail & 0xFF]` is either .bss
  zero (before first enqueue at that slot) or a stale byte from a
  previous wrap; either way the caller receives DEQUEUE_EMPTY and
  never sees the stale content.

### 7.4 FIFO ordering

- Head and tail both monotonically increase. Enqueue writes to
  slot `head_pre & 0xFF` then advances head. Dequeue reads from
  slot `tail_pre & 0xFF` then advances tail. For any byte
  enqueued at head-value h, it will be dequeued at tail-value h
  (uniquely, since counter values monotonically increase and the
  ring never overwrites). Since dequeue advances tail by 1 each
  call, and tail must reach h before that byte is read, all
  bytes with smaller head-values are read first. FIFO by
  construction.

### 7.5 Byte-lane fidelity

- Enqueue: `mov_b [r10 + 0], rax` writes AL only. Whatever the
  caller places in `rdi[7:0]` becomes the stored byte.
- Dequeue: `xor rax, rax; mov_b rax, [r10 + 0]` clears the upper
  56 bits then loads AL, so the returned rax has AL = stored
  byte and upper 56 bits = 0. Sub-test B's exact-equality check
  `cmp rax, 0x41` requires exactly this behavior.

### 7.6 Idempotence of empty-dequeue and full-enqueue

- **Empty dequeue**: on `head == tail`, returns 0xFFFF and does
  not touch tail. Repeated empty dequeues all return 0xFFFF and
  leave state unchanged.
- **Full enqueue**: on `head - tail >= 256`, returns 1 and does
  not touch head or the ring. Repeated full enqueues all return
  1 and leave state unchanged.

### 7.7 SPSC serialization (deferred contract; documented)

- The R16.M4 UP configuration relies on: (a) sole enqueuer is the
  ISR, (b) sole dequeuer is the sys_read path, (c) sys_read
  runs with local interrupts disabled. Under these constraints,
  no in-flight producer-consumer race exists; the ring is
  effectively single-threaded.
- On R17 SMP: needs `sfence` after enqueue's head store, `lfence`
  before dequeue's head load. These do not belong in the R16.M4
  bodies (would silently degrade UP performance on hardware where
  no fence is needed).

## 8. Cross-cutting risks

- **`.bss` symbol placement.** The three storage symbols must
  land in `.bss` (not `.data` or `.rodata`) for zero-init to hold.
  paideia-as's `uninit @align(N)` and `= 0` initializers both go
  to `.bss` per the existing tree's consistent behavior (verified
  by prior-art in port.pdx, runqueue.pdx). If a future paideia-as
  change alters this, the AC "initial dequeue returns 0xFFFF"
  becomes a false-negative canary — the empty check `head == tail`
  would evaluate on garbage.
- **Sentinel collision.** 0xFFFF is the empty sentinel. A caller
  that legitimately expects a byte in the range 0..0xFF must
  filter 0xFFFF explicitly. Documented in the function contract;
  #600 sys_read must check `rax > 0xFF` (or `rax == 0xFFFF`) and
  block/return -EWOULDBLOCK accordingly.
- **Counter wrap at 2^64.** Head and tail wrap only after 2^64
  bytes of UART traffic. At 1 Gbaud (unreachable for a 16550)
  that is 584 years. Not a real risk. On wrap, the invariant
  `head >= tail` breaks momentarily (head wraps to 0 while tail
  is near 2^64), and the very next enqueue's full check
  `head - tail >= 256` returns a huge unsigned number that is
  correctly `>= 256`, so the ring stops accepting bytes until
  tail also wraps. Formally this is a stall bug at 2^64, not a
  correctness bug; noted for completeness only.
- **False sharing on future SMP.** head and tail sit in adjacent
  qwords (16 bytes apart at whatever `.bss` placement the
  linker chooses). On SMP with producer on one CPU and consumer
  on another, both counters land on the same cache line, causing
  cache-line ping-pong on every enqueue/dequeue. Fix at R17:
  add `@align(64)` padding between them or hoist each into its
  own cache line. Not fixed here — R16.M4 is UP.
- **ISR reentrancy.** IDT vector 0x24 will be installed by #598
  and routed by #599; at that point IRQ 4 delivery triggers the
  ISR with `cli` implicit. As long as the ISR does not `sti`
  before its `iretq`, no reentrant enqueue can happen. This
  discipline is the ISR author's responsibility (#597), not
  the ring's — the ring itself has no reentrancy guard.

## 9. LOC estimate

| File                                                        | LOC        |
|-------------------------------------------------------------|------------|
| `src/kernel/core/uart/rx_ring.pdx` (new)                    | ~90        |
|   - module boilerplate + constants                          |   ~15      |
|   - storage declarations (ring + 2 counters)                |    ~5      |
|   - `uart_rx_enqueue` (18 insns + justification)            |   ~35      |
|   - `uart_rx_dequeue` (15 insns + justification)            |   ~30      |
|   - inline comments                                         |    ~5      |
| `src/kernel/boot/kernel_main.pdx` (witness block)           | ~85        |
|   - 4 sub-tests + labels                                    |   ~72      |
|   - fail/success emit + comment banner                      |   ~10      |
|   - blank lines / structural spacing                        |    ~3      |
| `tools/boot_stub.S` (2 messages)                            | ~8         |
| 3 expected-output fingerprint files (1 marker each)         | ~3         |
| `design/kernel/r16-m4-002-uart-rx-ring.md` (this doc)       | (this)     |
| **Total executable / testing / test-data**                  | **~186**   |

Executable code path: ~90 LOC. Witness + fingerprint: ~96 LOC.
Roughly 2× larger than R16-M4-001 (~86 LOC) — the extra size is
entirely in the witness (4 sub-tests + a 256-iteration fill loop
+ a 256-iteration drain loop), not in the module body. The module
body is a pair of leaf functions with no nested state.

## 10. Tractability

**HIGH — a well-scoped data-structure issue.**

- **Zero paideia-as encoder gap.** Every mnemonic proven at
  `core/fs/path.pdx` (byte-narrow load/store idioms) and
  `core/sched/wake_block.pdx` (RIP-relative qword load).
- **Two leaf functions**, both with only caller-save clobbers, no
  nested calls, no stack manipulation, no effect-set composition
  beyond `{mem}`, no capability composition.
- **Empty/full strategy is deterministic** and matches the SPSC
  discipline the subsystem will need at #597/#600 — no
  refactoring debt.
- **Witness is self-contained** — no fixture slab, no vnode
  wiring, no fd table interaction, no cross-subsystem call. The
  ring is the fixture.
- **Marker line is contains-in-order** — strictly additive to
  fingerprints; no reordering risk.
- **No cross-repo escalation risk.**
- **Sizing (~186 LOC total)** is 2× R16-M4-001 and 1.5× smaller
  than any R16.M3 issue. Reflects that the ring is a genuine
  reusable primitive whose witness has to prove ordering under
  wrap.

Estimated implementation time: **~60 minutes of a workerbee
session** (double R16-M4-001, driven by the 4-sub-test witness).

Estimated risk of regressing an existing smoke mode:
**near-zero** — purely additive (one new module, one new witness
block, one new emit line, two new rodata strings, marker inserted
after the immediately-preceding R16.M4-001 marker).

**Known follow-ups (do NOT block #596's landing)**:

- **#597 (rx_isr)** — real producer: reads RBR on IRQ 4, calls
  `uart_rx_enqueue`, likely adds `_uart_rx_dropped_count` for
  software overrun tracking.
- **#598 (idt vector 0x24 wire)** — installs #597 at vector 0x24.
- **#599 (ioapic route IRQ4)** — programs IRQ 4 → vector 0x24.
- **#600 (rx_notify)** — real consumer path: wires ISR to
  KIND_NOTIFICATION cap, unblocking sys_read on ring-non-empty
  via `uart_rx_dequeue`.
- **R17 SMP (deferred)** — add `sfence` in enqueue after head
  store; add `lfence` in dequeue before head load;
  cache-line-pad head and tail to eliminate false sharing.

## 11. References

- Issue: paideia-os#596
- Milestone: paideia-os R16.M4 (UART input driver — 16550 RX
  interrupt-driven)
- Prereq issues: R16-M4-001 (#595, LANDED)
- Blocks: #597 (indirectly #600 via consumer plumbing)
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 14, item 2
- Master plan: `design/milestones/r14b-master-plan.md` §M20
  (UART input)
- Structural template: `design/kernel/r16-m4-001-uart-rx-init.md`
  (R16.M4 sibling — same witness insertion pattern, same
  fingerprint discipline)
- Prior-art bounded circular structure: `src/kernel/core/ipc/port.pdx`
  (R13-m6-004 — 64-slot .bss port pool; direct-mapped slot vs
  ring's circular indexing, but same .bss + fixed-slot pattern)
- Prior-art byte load/store idioms: `src/kernel/core/fs/path.pdx`
  (R16-M1-004 — `lea + add + mov_b [reg+0], rax` write;
  `xor rax; mov_b rax, [reg]` zero-extending read)
- Prior-art scalar u64 load/store idioms:
  `src/kernel/core/sched/wake_block.pdx:41`
  (`mov rax, [rip + _current_tcb]`);
  `src/kernel/core/syscall/entry.pdx:29`
  (`mov [rip + _saved_user_rsp], rsp`)
- Lamport, "Proving the Correctness of Multiprocess Programs",
  IEEE TSE SE-3(2), 1977 — SPSC lock-free ring proof (relied on
  for the invariant argument in §7.7).
- NS PC16550D §3.1.1 — Receive Buffer Register semantics (context
  for why the ring exists, though the ring itself is
  device-agnostic).
