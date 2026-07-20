---
issue: 595
milestone: R16.M4 (UART input driver — 16550 RX interrupt-driven)
subsystem: 14 — UART input driver (16550 RX interrupt-driven)
topic: uart_rx_init — write IER=0x01 to COM1 (0x3F9); leaf function; port-read witness
prereq:
  - "P1-006/007 (LANDED; the existing Uart module in src/kernel/boot/uart.pdx runs `uart_init` at kernel_main entry, and that init leaves COM1 in the DLAB=0 state this issue relies on — port 0x3F9 aliases IER when DLAB=0)"
  - "R11-m1-003 (LANDED; pic_mask_all masks all 8259 legacy IRQs at boot — so IER=0x01 alone cannot yet cause a spurious delivery through the legacy path; the 8259 stays quiet, and IRQ 4 delivery is deferred to items 4/5 of this subsystem via IOAPIC)"
blocks:
  - "#596 (r16-m4-002 uart_rx_ring — static 256-byte ring buffer; independent of this issue but sequenced next)"
  - "#597 (r16-m4-003 uart_rx_isr — reads RBR, drains ring; will assume IER=0x01 has already been set)"
  - "#598 (r16-m4-004 idt-vector-24 wire — installs the ISR at vector 0x24)"
  - "#599 (r16-m4-005 ioapic-route-irq4 — routes IRQ 4 → vector 0x24 on CPU 0; this issue's IER=0x01 becomes observable at that point)"
  - "#600 (r16-m4-006 uart_rx_notification_cap — wires ISR to KIND_NOTIFICATION cap)"
touching:
  - src/kernel/core/uart/rx_init.pdx                    (new module — ~40 LOC incl. justification)
  - src/kernel/boot/kernel_main.pdx                     (witness block — ~35 LOC after last-landed R16.M3 witness)
  - tools/boot_stub.S                                   (2 rodata additions: ok_msg, fail_msg)
  - tests/r14b/expected-boot-r14b-loader.txt            (marker: `R16 UART RX INIT OK`)
  - tests/r15/expected-boot-r15-ring3.txt               (marker)
  - tests/r15/expected-boot-r15-process.txt             (marker)
  - design/kernel/r16-m4-001-uart-rx-init.md            (this doc)
related:
  - src/kernel/boot/uart.pdx                            (P1-006/007 — freezes the 7-step init sequence
                                                          that leaves COM1 DLAB=0, so port 0x3F9
                                                          unambiguously aliases IER here. Its
                                                          step-7 wrote `IER = 0x00` explicitly; this
                                                          issue advances IER from 0x00 → 0x01.
                                                          Also freezes the `mov dx, imm16;
                                                          in_al al` / `out_al al` idioms used verbatim.)
  - src/kernel/core/apic/pic_mask.pdx                   (R11-m1-003 — precondition: 8259 masked so
                                                          IRQ 4 delivery cannot leak through the legacy
                                                          path while items 4/5 remain unlanded)
  - design/milestones/r14b-tactical-plan.md             §Subsystem 14, item 1 (this issue's plan pointer)
  - design/kernel/r16-m3-003-sys-read.md                (structural template for this doc — R16 witness pattern)
---

# R16-M4-001 — `uart_rx_init`: set IER=0x01 on COM1 (#595)

## 1. Scope

Land the first R16.M4 subsystem-14 issue: a single leaf function
that writes `0x01` to COM1's Interrupt Enable Register (port
`0x3F9`), enabling the "Received Data Available Interrupt"
(ERBFI, IER bit 0).

```
uart_rx_init() -> ()
    side effect: 8-bit write of 0x01 to I/O port 0x3F9
    postcondition: COM1 IER == 0x01 (only ERBFI set; THRE / RLS /
                                     MSI all disabled)
```

The witness confirms the postcondition by reading port 0x3F9
back — the acceptance criterion (`AC: rdmsr / port read confirms
IER=1`) is satisfied literally by comparing the read-back byte
against 1.

### 1.1 What this issue proves

- **IER can be programmed at runtime after `uart_init`.** The
  existing `uart_init` sequence at `boot/uart.pdx:41-48` writes
  `IER=0x00` in step 1 and again in step 7, deliberately leaving
  RX interrupts disabled. This issue is the first upgrade of
  that IER state — proving that a subsequent 8-bit write to
  0x3F9 sticks and can be observed by a port read.
- **The `in_al al` pattern round-trips through IER.** `uart_putc`
  (line 63) polls LSR (0x3FD) with `in_al al` in a tight loop but
  never validates the read value against a known write — the LSR
  is device-driven. This issue is the first `in_al al` invocation
  whose value comes from a preceding `out_al al` to the same port
  (write 0x01 to 0x3F9, then read 0x3F9, expect 0x01). Establishes
  the "programmed register read-back" idiom that #599's IOAPIC
  witness will reuse in a heavier variant.
- **DLAB stays 0 across boot.** `uart_init` step 5 clears DLAB by
  writing `LCR=0x03`. Nothing between then and this issue's
  witness touches LCR. So port `0x3F9` unambiguously aliases IER
  (not DLM). Verified transitively — if DLAB had drifted to 1,
  the read-back would return DLM (which was written to 0x00 in
  step 3) and the witness would fail with `rax==0`.

### 1.2 What this issue deliberately does NOT do

- **No IRQ 4 unmask at the 8259.** The subsystem's goal statement
  reads "Set IER=0x01 on COM1; unmask IRQ 4" but the AC narrows
  that to just the IER port read. R11-m1-003 `pic_mask_all` masks
  every 8259 IRQ at boot, and R16.M4 items 4/5 land the modern
  IOAPIC path (vector 0x24 wired at item 4; IOAPIC RTE for IRQ 4
  routed at item 5). Attempting to unmask the 8259 here would
  either (a) do nothing at the IOAPIC path, or (b) create a
  spurious-IRQ hazard until the ISR lands at item 3. Deferring
  the unmask to item 5 respects the LAPIC/APIC discipline this
  kernel adopted from R11 onward.
- **No ISR install.** Vector 0x24 remains at the IDT's default
  (typed_handler_default per idt.pdx). Any IRQ delivered before
  #598 lands would panic, but no IRQ can be delivered (item 5
  IOAPIC routing not yet in place, and legacy 8259 masked). Safe
  by construction.
- **No ring-buffer allocation.** `_uart_rx_ring[256]` is #596's
  concern. IER=0x01 sets the interrupt-source enable bit at the
  UART, but no producer yet exists for the ring.
- **No FIFO reconfiguration.** `uart_init` step 5 set FCR=0xC7
  (FIFO enabled, 14-byte RX trigger, transmit + receive FIFO
  cleared). That trigger threshold cooperates with IER=ERBFI:
  the interrupt fires when the FIFO reaches the trigger level
  or when a timeout expires with data present. The existing
  FCR settings are correct for IER=0x01 — no change here.
- **No modem-status or line-status interrupts.** ERBFI only.
  IER bits 1 (THRE), 2 (RLS), 3 (MSI) stay 0. Those interrupt
  sources are unwanted at R16.M4 (all polling for TX; no modem
  wiring; framing errors are handled by the ISR draining LSR
  each round rather than by dedicated RLS delivery).
- **No `!{sysreg}` effect audit at the callsite.** `uart_rx_init`
  runs from the boot witness under kernel privilege — same
  discipline as `uart_init`. Effect declared as `{sysreg}` in
  the module (I/O port write), justification frozen in the
  function's comment. No new capability required — inherits
  boot capability at the callsite.

## 2. Prereq check

### 2.1 What is in place

| Primitive         | Location                                   | Contract used                                                                       |
|-------------------|--------------------------------------------|-------------------------------------------------------------------------------------|
| `uart_init`       | `boot/uart.pdx:36-50` (P1-006, LANDED)     | Runs at `kernel_main_64` entry (line 71). Leaves COM1 DLAB=0, IER=0x00, FCR=0xC7.   |
| `uart_puts`       | `boot/uart.pdx:81-98` (B3-003, LANDED)     | Used by witness to emit the ok/fail marker.                                          |
| `pic_mask_all`    | `core/apic/pic_mask.pdx` (R11-m1-003)      | 8259 masked at boot — legacy path silent, so IER=0x01 alone can't spuriously deliver. |
| `in_al al` idiom  | `boot/uart.pdx:63` (B3-002)                | `mov dx, imm16` + `in_al al` reads port DX into AL, upper RAX bits untouched.       |
| `out_al al` idiom | `boot/uart.pdx:41-47` (R1.5-002)           | `mov dx, imm16` + `mov al, imm8` + `out_al al` writes AL to port DX.                 |
| `and rax, imm8`   | `boot/uart.pdx:64` (`and rax, 0x20`)       | Masks upper RAX bits so the compare tests only the read byte.                        |

### 2.2 What is NOT in place

- **No `src/kernel/core/uart/` directory.** The tactical plan
  places this issue under `core/uart/rx_init.pdx`. Only
  `boot/uart.pdx` exists today (the TX-side driver, which stays
  in `boot/` because it runs during long-mode transition
  witness output). The RX subsystem is a proper post-boot
  driver, so it earns a `core/uart/` home. This issue creates
  that directory alongside the sibling `core/apic/`, `core/int/`,
  etc.
- **No `uart_rx_init_ok_msg` / `uart_rx_init_fail_msg` symbols
  in `boot_stub.S`.** Added alongside the existing R16.M3
  witness strings (see §5.4).

### 2.3 Encoder gaps

**None.** Every instruction used has landed precedent:

| Mnemonic                | Proven at                                                       |
|-------------------------|-----------------------------------------------------------------|
| `mov dx, imm16`         | `boot/uart.pdx:41-47` (7 sites).                                 |
| `mov al, imm8`          | `boot/uart.pdx:41-47`.                                           |
| `out_al al`             | `boot/uart.pdx:41-47`, `core/apic/pic_mask.pdx:40,45`.           |
| `in_al al`              | `boot/uart.pdx:63`.                                              |
| `and rax, imm8`         | `boot/uart.pdx:64` (`and rax, 0x20`).                            |
| `cmp rax, imm8`         | Ubiquitous.                                                     |
| `jne` / `je` / `jmp`    | Ubiquitous.                                                     |
| `call sym` (direct)     | Ubiquitous.                                                     |
| `lea rdi, [rip + sym]`  | Ubiquitous.                                                     |
| `ret`                   | Ubiquitous.                                                     |

No SIB, no REX.B-extended-base, no 32-bit port I/O, no immediate
port form. The 8-bit `out dx, al` and `in al, dx` encodings are
both single-byte opcodes with no ModR/M byte — the paideia-as
`out_al`/`in_al` mnemonics already handle both. **Cross-repo
escalation not needed.**

## 3. Design

### 3.1 File and module structure

New file: `src/kernel/core/uart/rx_init.pdx`. Establishes the
`core/uart/` directory that #596–#600 will populate:

```
src/kernel/core/uart/
    rx_init.pdx     <-- THIS ISSUE (#595)
    rx_ring.pdx     (#596, planned)
    rx_isr.pdx      (#597, planned)
    rx_notify.pdx   (#600, planned)
```

Module name: `UartRx`. Public export: `uart_rx_init`.

### 3.2 Register discipline — leaf, zero-push

`uart_rx_init` is a leaf function: three instructions before
`ret`, no nested call, no callee-save need. It uses only caller-
save scratch (`dx`, `al` / low RAX). No prologue, no epilogue.
Identical shape to `uart_init` (which is also leaf; the 7 port
writes are inlined).

**Stack alignment.** `rsp % 16 == 8` at entry (SysV, post-call).
No sub-frame, no nested call — alignment is irrelevant to a leaf
that never dispatches. `ret` pops the return address, restoring
`rsp % 16 == 0` in the caller.

**Volatility.** On return, `dx`, `al`, and the low 8 bits of
`rax` are whatever the last port write / caller-set value left
them at. Callers must treat all caller-save regs as clobbered
across the call — standard SysV discipline. Documented in the
justification comment.

### 3.3 `uart_rx_init` — body

```asm
; ================================================================
; uart_rx_init() -> ()
;   Writes IER=0x01 to COM1 (port 0x3F9), enabling Received Data
;   Available Interrupt (ERBFI, bit 0). All other IER sources
;   (THRE, RLS, MSI) remain disabled.
;
;   Effects: {sysreg}   Capabilities: {}   (inherits boot cap at callsite)
; ================================================================
uart_rx_init:
    mov dx, 0x3F9        ; COM1 base 0x3F8 + 1 = IER (DLAB=0 assumed)
    mov al, 0x01         ; ERBFI: bit 0 set; other sources clear
    out_al al            ; 8-bit port write
    ret
```

**Instruction count**: 4 (3 body + `ret`). This is the minimum
possible — matches each of the 7 stanzas in `uart_init` byte-
for-byte in shape.

### 3.4 Why 0x01 and not `0x0F` or `0x05`

| Value | Bits set               | Rejected because                                                                                    |
|-------|------------------------|-----------------------------------------------------------------------------------------------------|
| 0x01  | ERBFI (RX data avail)  | **Chosen.** RX is the only interrupt source R16.M4 needs.                                            |
| 0x02  | ETBEI (THRE / TX ready) | TX at R16.M4 remains polled (`uart_putc` at `boot/uart.pdx:55-71`); no ISR wants THRE delivery.       |
| 0x04  | ELSI  (Line-status)    | Framing/parity errors handled inline by RX ISR (item 3) reading LSR each round; no dedicated IRQ.    |
| 0x08  | EDSSI (Modem-status)   | No modem wiring at R16 or R17. Bit stays 0 permanently.                                              |
| 0x0F  | All four               | Enables three unwanted sources — each would fire without a handler ready.                            |

IER bits 4-7 are reserved on the 16550 and must be written 0.
`0x01` writes exactly that: bit 0 set, bits 1-7 clear.

### 3.5 Why the port-read is a real read, not a shadow variable

The AC (`rdmsr / port read confirms IER=1`) explicitly names the
port read as the witness modality. Alternatives were briefly
considered:

- **Shadow variable in `.data`.** Set a `_uart_rx_ier_shadow`
  byte at write time; witness reads the shadow. Rejected: proves
  only that the code path executed, not that the write reached
  the device. IER shadowing would need to be maintained by every
  future IER mutator (a burden), and a shadow can silently drift
  from device state.
- **CPU-side "did we execute" flag.** Set a flag in .bss after
  the `out_al`. Rejected: same shortcoming as shadow variable.
- **Trigger an actual interrupt.** Cannot at #595 — IDT vector
  0x24 not installed (#598), IOAPIC not routed (#599). Also,
  triggering an interrupt from the witness would require driving
  data into COM1's RX side, which needs QEMU-side stdin injection
  (test-harness change).

The direct `in al, 0x3F9` after the `out al, 0x3F9` gives a
device-level round-trip in a single kernel path, no external
choreography. On a real 16550 (and QEMU's emulation), reading
IER when DLAB=0 returns exactly the last IER value written.

### 3.6 File contents

```pdx
// src/kernel/core/uart/rx_init.pdx — R16-M4-001 (#595)
// uart_rx_init: enable Received Data Available Interrupt on COM1.
//
// Writes 0x01 to port 0x3F9 (COM1 IER, DLAB=0), setting IER bit 0
// (ERBFI). Leaf function; no arguments; no return; no nested call.
// Postcondition: reading port 0x3F9 returns 0x01 (verified by the
// kernel_main witness at boot).
//
// Assumes uart_init (boot/uart.pdx:36-50) has run, leaving COM1
// in DLAB=0 state. Depends on pic_mask_all (core/apic/pic_mask.pdx)
// for legacy-IRQ silence; IOAPIC routing lands in #599.
//
// See design/kernel/r16-m4-001-uart-rx-init.md for full contract.

module UartRx = structure {
  // ==========================================================================
  // uart_rx_init — enable COM1 RX data-available interrupt (IER bit 0)
  //
  // Input:  (none)
  // Output: (none)
  //
  // Side effects:
  //   8-bit write of 0x01 to I/O port 0x3F9 (COM1 IER).
  //   Postcondition: IER == 0x01 (ERBFI set; THRE/RLS/MSI clear).
  //
  // Clobbers (SysV caller-save discipline):
  //   dx, al (low 8 bits of rax).
  // ==========================================================================
  pub let uart_rx_init : () -> () !{sysreg} @{} = fn () -> unsafe {
    effects: { sysreg },
    capabilities: { },
    justification: "R16-M4-001 (#595): COM1 16550 RX interrupt enable. Writes IER = 0x01 to port 0x3F9, setting bit 0 (ERBFI = Enable Received Data Available Interrupt). All other IER bits (THRE, RLS, MSI, and reserved bits 4-7) stay clear per NS PC16550D §3.1.2. Assumes uart_init (boot/uart.pdx:36) has already run and left LCR with DLAB=0 (step 5 of the init sequence writes LCR=0x03, clearing DLAB), so port 0x3F9 aliases IER rather than DLM. IRQ 4 delivery does not happen yet: 8259 stays masked by pic_mask_all (R11-m1-003), IDT vector 0x24 is uninstalled until #598, and IOAPIC IRQ 4 → vector 0x24 routing lands at #599. This issue only programs the UART side of the interrupt-enable chain; delivery composes end-to-end at #599's landing. Leaf function; no prologue/epilogue; caller-save-only clobbers (dx, al). Idiom is byte-identical to each of the 7 stanzas in uart_init: `mov dx, imm16; mov al, imm8; out_al al`. Witness at kernel_main.pdx verifies via `in_al al` port read-back — the read returns the last-written IER value on both real 16550 and QEMU emulation when DLAB=0. Audit: r16-m4-001-uart-rx-init.",
    block: {
      mov dx, 0x3F9;
      mov al, 0x01;
      out_al al;
      ret
    }
  }
}
```

## 4. Witness placement

### 4.1 Position in kernel_main.pdx

Inserted after the last-landed R16.M3 witness. At the time of
architecture, R16.M3 is landing the sys_read → sys_write →
sys_dup2 → fd_inherit → fd_cloexec sequence; the tail witness
label will be `fd_cloexec_witness_done:` once #594 lands. The
insertion anchor is therefore:

```
<last-landed R16.M3 witness>_done:
    <-- INSERT R16.M4-001 WITNESS HERE
    <existing wrmsr / GS_BASE setup around line 3711>
```

If M3 tail issues reorder or slip past #595 in the tempo, the
insertion point moves to the actual last-landed M3 witness's
`_done:` label. The insertion is structurally independent — no
data flow into or out of any M3 witness.

### 4.2 No witness slab needed

Unlike R16.M3 syscall witnesses (`_sys_read_witness_task`, etc.
— 2224-byte task_struct blobs), `uart_rx_init` needs no per-
witness state. The witness is a 4-instruction body call plus a
2-instruction read-back check. No `.bss` allocation, no fixture
task, no fd table.

## 5. Test canary — kernel_main witness block

### 5.1 Sub-test structure

**Sub-test A**: call `uart_rx_init`; read port 0x3F9; assert AL == 1.

Only one sub-test is warranted — the function's contract is a
single postcondition (IER == 0x01), and one port-read fully
verifies it. Multi-part sub-tests (as in sys_read A-E) would add
no coverage: there is no fd, no encoding, no error path, no
boundary condition to enumerate. Attempting to split into A
(call happens), B (IER==1), C (bit 0 only), D (bits 4-7 zero)
would be pedantry — `cmp rax, 1` after `and rax, 0xFF` covers
bit 0 = 1 AND all higher bits = 0 in a single check.

### 5.2 Witness assembly (complete block)

```asm
; ============================================================
; R16-M4-001 (#595): uart_rx_init witness — 1 sub-test
; ============================================================
uart_rx_init_witness:
    ; Sub-test A: after uart_rx_init, port 0x3F9 read returns 0x01
    call uart_rx_init

    mov  dx, 0x3F9
    in_al al
    and  rax, 0xFF                          ; isolate AL (in_al leaves
                                            ; upper 56 bits of rax
                                            ; untouched per x86 semantics)
    cmp  rax, 1
    jne  uart_rx_init_witness_fail

    ; --- All green ---
    lea  rdi, [rip + uart_rx_init_ok_msg]
    call uart_puts
    jmp  uart_rx_init_witness_done

uart_rx_init_witness_fail:
    lea  rdi, [rip + uart_rx_init_fail_msg]
    call uart_puts

uart_rx_init_witness_done:
```

Total: ~14 lines including the two labels.

### 5.3 Marker

On sub-test A green:

```
R16 UART RX INIT OK
```

Emitted via `uart_puts` on `uart_rx_init_ok_msg`. Fingerprint
added to all three R14B/R15 expected-output files, inserted
immediately after the `FD OK` line (which is the R16.M3
subsystem-closure marker) and before the first R15 scheduler
marker (`R15 IDLE TASK OK` in ring3/process; `LOADER OK` in
r14b).

### 5.4 String data — `tools/boot_stub.S`

Append after the last R16.M3 witness string (currently the
`fd_cloexec_*_msg` pair at approximately line 660):

```asm
# R16-M4-001 (#595): uart_rx_init witness success message
.global uart_rx_init_ok_msg
.align 8
uart_rx_init_ok_msg: .ascii "R16 UART RX INIT OK\n\0"

# R16-M4-001 (#595): uart_rx_init witness failure message
.global uart_rx_init_fail_msg
.align 8
uart_rx_init_fail_msg: .ascii "R16 UART RX INIT FAIL\n\0"
```

No other rodata changes.

### 5.5 Fingerprint files — marker insertion

Insert `R16 UART RX INIT OK` in three files:

| File                                     | Insert after   | Insert before      |
|------------------------------------------|----------------|--------------------|
| `tests/r14b/expected-boot-r14b-loader.txt`  | `FD OK`     | `LOADER OK`        |
| `tests/r15/expected-boot-r15-ring3.txt`     | `FD OK`     | `R15 IDLE TASK OK` |
| `tests/r15/expected-boot-r15-process.txt`   | `FD OK`     | `R15 IDLE TASK OK` |

Contains-in-order matching makes the addition strictly additive
— no earlier line reorders. All 5-mode smoke stages that do not
observe R16 markers (`boot_r8_only`, `boot_r10`, `boot_r11`,
`boot_r12`, `boot_r12_denial`) stay byte-identically green.

## 6. Alternatives considered / follow-ups

### 6.1 Combine with #596 (rx_ring) in one PR

**Rejected.** #596 is independent (static ring buffer + head/tail
indices; no I/O). The tactical plan splits them for a reason:
each landing verifies exactly one concern, so a regression
bisects to a 4-instruction module.

### 6.2 Read IER via a wider `in` (e.g., 32-bit)

**Rejected.** paideia-as `in_al al` is the only proven
in-encoder (see `src/drivers/pci/config.pdx:45` — the 32-bit
form is documented as a pending encoder milestone). IER is an
8-bit register; the byte read is the correct width regardless.

### 6.3 Read IER before writing to establish baseline

**Rejected.** `uart_init` step 1 wrote `IER=0x00` at boot; step 7
wrote it again. The baseline is known statically. A read-before-
write would prove that the reset value matches expectations
(useful for a real 16550 on real hardware) but adds 3 instructions
for a defensive check that the boot init already covers.

### 6.4 Write via `outb` (byte-immediate) instead of `out_al al`

**Rejected.** paideia-as does not encode an immediate-port form
of `out` (`out imm8, al`). All port I/O goes through DX. Even if
it did, port 0x3F9 exceeds the imm8 range (0xFF max), so the DX
form is mandatory here.

### 6.5 Move the function to `boot/uart.pdx` next to `uart_init`

**Rejected.** The tactical plan explicitly places it at
`core/uart/rx_init.pdx`. Two structural reasons back the plan:

1. **`boot/` is for boot-critical code that runs during
   long-mode transition.** `uart_init` lives there because it
   is called before any core subsystem is available (banner
   emission is the first observable event). `uart_rx_init` runs
   post-boot, after M3 has landed — it is a driver, not a boot
   sequence.
2. **`core/uart/` is the natural home for the RX driver's other
   modules** (ring, isr, notify — #596/#597/#600). Sharing a
   directory keeps sibling patterns discoverable and lets any
   future `core/uart/` refactor operate on one directory.

### 6.6 Reorder to set IER before pic_mask_all runs

**Rejected — dangerous.** If IER=0x01 is set while the 8259 is
still unmasked at boot, a stray RX byte during boot could
trigger IRQ 4 through the legacy PIC path. With no handler at
vector 0x24 (default IDT slot returns via typed_handler_default,
which panics on unexpected delivery), the kernel would take a
double fault before Task A even starts. Current ordering is
correct: pic_mask_all first (R11-m1-003 at kernel_main early),
uart_rx_init in the post-M3 witness block (this issue).

### 6.7 Emit `R16 UART RX INIT OK` from within `uart_rx_init`

**Rejected.** The function is a driver primitive. Callers own
their emission discipline — the witness block emits, not the
primitive. Same discipline as every other R16 subsystem
(vfs_open, tmpfs_read, sys_close, etc.). Keeps the primitive
reusable by non-witness callers.

## 7. Invariants

### 7.1 IER value after `uart_rx_init` == 0x01

Guaranteed by the 3-instruction body: `mov al, 0x01; out_al al`
writes exactly `0x01` to IER. No branch, no data dependency,
no memory access other than the port. On successful return, IER
is definitively `0x01`.

Verified by sub-test A's read-back.

### 7.2 Idempotence

`uart_rx_init` can be called multiple times without ill effect —
the second call writes the same value to the same port. No
counter, no allocation, no state that could race with itself.
Not exercised by the witness (single call is enough), but the
property is by-construction.

### 7.3 DLAB stays 0 across the call

`uart_rx_init` does not touch LCR (port 0x3FB), so DLAB cannot
change. The read-back in the witness therefore hits IER (not
DLM) as intended.

### 7.4 No interrupt fires as a result of this call

The 8259 is masked (`pic_mask_all` at boot). The IOAPIC has no
RTE programmed for IRQ 4 (item 5 of this subsystem, #599). Even
though the UART's IER now permits it to raise an interrupt on
RX data, the interrupt controller silences delivery. Verified
transitively: if delivery had occurred, the CPU would have
faulted at vector 0x24 (uninstalled IDT slot) — the witness
completes and emits its marker, proving no fault occurred.

## 8. Cross-cutting risks

- **Booting on non-standard COM1 base.** Some machines wire COM1
  to a base other than 0x3F8 (e.g., 0x2F8 for COM2). QEMU's
  default `-serial stdio` binds COM1 at 0x3F8. Real hardware
  probing would need ACPI/PCI enumeration — deferred to a
  future issue if PaideiaOS ever targets bare-metal legacy
  serial. R16.M4 remains QEMU-only for the input path.
- **DLAB drift between `uart_init` and the witness.** No code
  path currently writes LCR after step 5 of `uart_init`. If a
  future R16 subsystem starts touching LCR (e.g., changing baud
  rate mid-boot), it must restore DLAB=0 before this witness
  runs, or the read-back hits DLM (=0x00) and fails
  spuriously. Mitigation: this witness runs early in the
  post-M3 block, before any planned R16.M4/M5 LCR writes. A
  formal LCR-modification audit is out of scope until such a
  modifier appears.
- **QEMU-only property.** The `in al, 0x3F9` returning the
  written value is a documented 16550 property that QEMU emulates
  correctly. Some emulators (rare) might return 0 for
  interrupt-enable registers. Mitigation: PaideiaOS's R16 boot
  is QEMU-first (see `tools/run-smoke.sh`). If a new emulator
  is ever added to smoke, this witness may need to gain a
  side-channel confirmation. Not a concern today.
- **IRQ 4 delivery in the window between #599 and ISR install
  (#598).** #599 (IOAPIC route) lands after #598 (IDT vector
  install), so at any point where IER=0x01 AND the IOAPIC
  delivers, the IDT slot 0x24 already has the ISR trampoline
  wired. No window. This ordering is enforced by the
  tactical-plan prereq chain (item 5 depends on item 4).

## 9. LOC estimate

| File                                                        | LOC        |
|-------------------------------------------------------------|------------|
| `src/kernel/core/uart/rx_init.pdx` (new)                    | ~40        |
|   - module boilerplate + justification                      |   ~30      |
|   - `uart_rx_init` body (4 instructions)                    |    ~5      |
|   - inline comments                                         |    ~5      |
| `src/kernel/boot/kernel_main.pdx` (witness block)           | ~35        |
|   - 1 sub-test + labels                                     |   ~14      |
|   - preceding/trailing comment banner                       |    ~6      |
|   - fail/success emit                                       |   ~10      |
|   - blank lines / structural spacing                        |    ~5      |
| `tools/boot_stub.S` (2 messages)                            | ~8         |
| 3 expected-output fingerprint files (1 marker each)         | ~3         |
| `design/kernel/r16-m4-001-uart-rx-init.md` (this doc)       | (this)     |
| **Total executable / testing / test-data**                  | **~86**    |

Executable code path: ~40 LOC. Witness + fingerprint: ~46 LOC.
An order of magnitude smaller than R16.M3 issues — sys_read was
~265 LOC, sys_close ~200 LOC. Reflects the leaf-function
simplicity.

## 10. Tractability

**HIGH — smallest R16 issue architected to date.**

- **Zero paideia-as encoder gap.** Every mnemonic proven at
  `boot/uart.pdx` (which uses the exact same 8-bit port I/O
  idiom for the 7-step init).
- **Leaf function, single side effect.** No nested calls, no
  register discipline concerns, no stack alignment, no
  effect-set composition, no capability composition.
- **Witness is a single sub-test.** No preamble, no fixture
  slab, no fd table, no vnode wiring, no cross-subsystem
  interaction.
- **Marker line is contains-in-order** — strictly additive to
  fingerprints; no reordering risk.
- **No cross-repo escalation risk.**
- **Sizing (~86 LOC total)** is 3× smaller than any R16.M3
  issue and comparable to R13/R14 boot-flag issues (SMEP/SMAP/NX).

Estimated implementation time: **~30 minutes of a workerbee
session** (the smallest end-to-end R16 landing).

Estimated risk of regressing an existing smoke mode:
**near-zero** — purely additive (one new module, one new
witness block, one new emit line, two new rodata strings).

**Known follow-ups (do NOT block #595's landing)**:

- **#596 (rx_ring)** — 256-byte SPSC ring in `.bss`; independent
  of this issue.
- **#597 (rx_isr)** — the actual ISR body; consumes IER=0x01 to
  make sense.
- **#598 (idt vector 0x24 wire)** — installs #597 at the IDT
  slot for vector 0x24.
- **#599 (ioapic route IRQ4)** — programs the IOAPIC RTE so
  IRQ 4 → vector 0x24 on CPU 0. First point at which IER=0x01
  becomes observably active (interrupt-driven delivery).
- **#600 (rx_notify)** — wires the ISR to a KIND_NOTIFICATION
  cap, unblocking sys_read on ring-non-empty.

## 11. References

- Issue: paideia-os#595
- Milestone: paideia-os R16.M4 (UART input driver — 16550 RX
  interrupt-driven)
- Prereq issues: P1-006/007 (uart_init + uart_putc),
  R11-m1-003 (pic_mask_all)
- Blocks: #596, #597, #598, #599, #600 (subsystem 14 tail)
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 14, item 1
- Master plan: `design/milestones/r14b-master-plan.md` §M20
  (UART input)
- Prior-art body pattern: `src/kernel/boot/uart.pdx` (P1-006/007)
  — the 7-step init sequence freezes the `mov dx / mov al /
  out_al al` idiom copied verbatim by this issue
- Prior-art read-back pattern: `src/kernel/boot/uart.pdx:63-64`
  (`in_al al; and rax, 0x20`) — polling read followed by mask;
  this issue's witness reuses the mask-and-compare shape
- NS PC16550D §3.1.2 — Interrupt Enable Register bit definitions
