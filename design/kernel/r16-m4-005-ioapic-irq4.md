---
issue: 599
milestone: R16.M4 (UART input driver — 16550 RX interrupt-driven)
subsystem: 14 — UART input driver (16550 RX interrupt-driven)
topic: IOAPIC RTE for IRQ 4 → vector 0x24 on CPU 0 — programmatic MMIO write of the two 32-bit halves via IOREGSEL/IOWIN + read-back witness
prereq:
  - "R9-m2-001 / #356 (LANDED; core/apic/enable.pdx.apic_enable — verifies IA32_APIC_BASE bit 11. This issue does not depend on apic_enable directly (IOAPIC MMIO is independent of LAPIC state), but the entire APIC subsystem's memory-mapped I/O is enabled at boot by paideia-as-generated identity page tables covering 0xFEC00000 as strong-uncacheable, same window as LAPIC 0xFEE00000.)"
  - "R11-m1-003 (LANDED; core/apic/pic_mask.pdx.pic_mask_all — writes OCW1 = 0xFF to 8259 master and slave, silencing the legacy PIC. Prerequisite: without pic_mask_all, IRQ 4 delivery would double-fire (once via 8259 → vec 0x20+4 = 0x24 IF the 8259 were remapped, or vec 0x0C via unremapped IVT; once via IOAPIC → vec 0x24). pic_mask_all runs at kernel_main.pdx:3966; the IOAPIC RTE programming here runs at kernel_main.pdx:~3953 — RTE is programmed BEFORE pic_mask_all in the boot sequence, which is safe because the LAPIC is disabled (apic_svr_enable also hasn't run yet) so no delivery can happen from either path.)"
  - "R16-M4-001 / #595 (LANDED; core/uart/rx_init.pdx.uart_rx_init — writes IER = 0x01 to COM1, enabling ERBFI. UART side of the RX enable is now in place; this issue completes the interrupt-controller side.)"
  - "R16-M4-002 / #596 (LANDED; core/uart/rx_ring.pdx — 256-slot SPSC ring the ISR drains into. Not a direct dependency of this issue (RTE programming is orthogonal to ring buffer state), but part of the R16.M4 chain.)"
  - "R16-M4-003 / #597 (LANDED; core/uart/rx_isr.pdx.uart_rx_isr — the eventual delivery target once #598's trampoline and this issue's RTE compose. Also orthogonal to this issue's programming step but required for end-to-end.)"
  - "R16-M4-004 / #598 (LANDED; core/uart/rx_trampoline.pdx._uart_rx_trampoline + one-line dispatch extension to core/int/idt.pdx.idt_install — IDT slot 0x24 now populated with _uart_rx_trampoline. This issue's programming enables the CPU-side dispatch path that the trampoline installed by #598 sits on. Without #598 in place, this issue would route IRQ 4 to a default-stub IDT gate and the first IRQ delivery would #GP.)"
blocks:
  - "#600 (r16-m4-006 uart_rx_notification_cap — the consumer-side wake-up path. Once #599 lands, IRQ 4 → vec 0x24 → trampoline → ISR → ring is complete producer chain. #600 wires the ring → notification cap → user wake-up consumer chain. #600 does not require #599, but the R16.M4 end-to-end at #601 does require both.)"
  - "#601 (r16-m4-007 RX smoke — end-to-end AC via QEMU stdin. This is the first issue at which IRQ 4 actually fires against a real interrupt source. #601 injects bytes via QEMU stdin → 16550 RBR → LSR.DR=1 → 16550 raises IRQ 4 → IOAPIC (programmed here) → LAPIC → CPU walks IDT vec 0x24 → trampoline → uart_rx_isr → drain + EOI.)"
touching:
  - src/kernel/core/apic/ioapic.pdx                      (REPLACE — remove 3 unused stubs; add 4 real primitives: ioapic_write, ioapic_read, ioapic_route_irq, ioapic_irq4_init — ~180 LOC net)
  - src/kernel/boot/kernel_main.pdx                      (witness block — ~75 LOC after last-landed R16.M4-004 witness at line 3953)
  - tools/boot_stub.S                                    (2 rodata additions: ioapic_irq4_ok_msg, ioapic_irq4_fail_msg — ~10 LOC)
  - tests/r14b/expected-boot-r14b-loader.txt             (marker: `R16 IOAPIC IRQ4 OK`)
  - tests/r15/expected-boot-r15-ring3.txt                (marker)
  - tests/r15/expected-boot-r15-process.txt              (marker)
  - design/kernel/r16-m4-005-ioapic-irq4.md              (this doc)
related:
  - src/kernel/core/apic/ioapic.pdx                      (Phase 6 / #168 — three unused stubs: stub_ioapic_set_redir,
                                                          stub_ioapic_mask, stub_ioapic_unmask. Zero call sites (grep-verified);
                                                          safely removed as part of this issue's real-implementation landing.
                                                          Comment block already documents the 64-bit RTE layout; the real
                                                          implementation reuses that documentation and extends it with the
                                                          IOREGSEL/IOWIN split.)
  - src/kernel/core/apic/eoi.pdx                         (R9-m2-003 / #358 — apic_eoi. Freezes the 32-bit MMIO-write idiom
                                                          this issue copies verbatim modulo the base address: `mov rax, MMIO;
                                                          mov rcx, val; mov [rax], ecx`. IOAPIC MMIO writes to IOREGSEL and
                                                          IOWIN follow the identical pattern per Intel 82093AA §3.2.1.)
  - src/kernel/core/apic/lapic_timer.pdx                 (R11-m1-002 / #389 — apic_svr_enable at line 3965 in kernel_main.
                                                          Runs AFTER this issue's witness (line ~3953). Consequence: at
                                                          witness time, LAPIC is disabled → even if the IOAPIC routes IRQ 4
                                                          → vector 0x24, delivery cannot happen. Safe by construction.)
  - src/kernel/core/apic/pic_mask.pdx                    (R11-m1-003 — pic_mask_all at line 3966. Runs AFTER this issue's
                                                          witness. IRQ 4 delivery via the 8259 legacy PIC is impossible at
                                                          witness time because the 8259 remap has never been programmed
                                                          (no ICW2 write moves the master offset off the reserved
                                                          exception range), and IF=0 anyway.)
  - src/kernel/core/uart/rx_init.pdx                     (R16-M4-001 / #595 — uart_rx_init. Freezes the "call the primitive
                                                          from inside the witness block" discipline this issue follows
                                                          — kernel_main.pdx:3711 shows the pattern verbatim.)
  - src/kernel/core/uart/rx_trampoline.pdx               (R16-M4-004 / #598 — _uart_rx_trampoline. Sits at IDT slot 0x24;
                                                          this issue enables the routing that lets it actually be reached.)
  - src/kernel/core/int/idt.pdx                          (R16-M4-004 diff at lines 393-394, 443-445 — idt_setup_vec36 label
                                                          + cmp/je branch. Together with this issue, completes the CPU-side
                                                          dispatch chain from IRQ 4 to the ISR.)
  - src/kernel/core/acpi/madt.pdx                        (Phase 6 / #167 — MADT walker stub. Would in principle discover
                                                          the IOAPIC MMIO base and any Interrupt Source Override entries
                                                          (§7.3). Not yet implemented; this issue assumes standard
                                                          identity mapping IRQ 4 → GSI 4 with IOAPIC base = 0xFEC00000.
                                                          Documented risk in §7.3; safe on QEMU/KVM.)
  - design/milestones/r14b-tactical-plan.md              §Subsystem 14, item 5 (this issue's plan pointer)
  - design/kernel/r16-m4-004-idt-vec24-wire.md           §1.2 explicitly names this issue as the delivery-enabling wire;
                                                          §6.2 documents the "one PR per issue" discipline that motivates
                                                          keeping #599 separate from #598.
---

# R16-M4-005 — `ioapic route irq4`: program IOAPIC RTE 4 → vec 0x24 → CPU 0 (#599)

## 1. Scope

Land the fifth R16.M4 subsystem-14 issue: the **IOAPIC
Redirection Table Entry** for IRQ 4 (COM1 16550 RX line), which
composes the final link in the delivery chain:

```
   COM1 raises IRQ 4  ─────────►  IOAPIC RTE #4  ─────────►  LAPIC (CPU 0)
   (16550 IIR fires when              (this issue                 (existing
    LSR.DR sets and IER.ERBFI=1)       — programs                  APIC subsystem)
                                       vector=0x24,
                                       dest=phys APIC 0)
                                                   │
                                                   ▼
                                   CPU walks IDT gate 0x24 (#598)
                                                   │
                                                   ▼
                             _uart_rx_trampoline (#598)
                                                   │
                                                   ▼
                                    uart_rx_isr (#597)
                                                   │
                                                   ▼
                                    RBR drain → ring (#596)
```

Concretely:

- **Rewrite of `src/kernel/core/apic/ioapic.pdx`** — remove the
  three unused stubs (`stub_ioapic_set_redir`,
  `stub_ioapic_mask`, `stub_ioapic_unmask`) and replace with the
  4-function real API:
  - `ioapic_write(reg_idx: u64, val: u64) -> ()` — write IOREGSEL
    then IOWIN.
  - `ioapic_read(reg_idx: u64) -> u64` — write IOREGSEL, read
    IOWIN (32-bit MMIO load, zero-extended).
  - `ioapic_route_irq(irq: u64, vec: u64, dest_apic_id: u64) -> ()`
    — program both 32-bit halves of RTE #irq for physical mode,
    fixed delivery, edge-triggered, active-high, unmasked.
  - `ioapic_irq4_init() -> ()` — thin convenience wrapper that
    calls `ioapic_route_irq(4, 0x24, 0)`.
- **Kernel_main witness block** — 2-sub-test read-back witness
  right after `idt_vec24_witness_done` (line 3953). Sub-test A
  reads RTE 4 LO via `ioapic_read(0x10 + 4*2) = ioapic_read(0x18)`
  and verifies `vector = 0x24, mask = 0`. Sub-test B reads RTE 4
  HI via `ioapic_read(0x19)` and verifies `dest_apic_id = 0`.
  Emits `R16 IOAPIC IRQ4 OK`.

Acceptance (issue AC): **writing IOREGSEL / IOWIN sequence
confirmed via peek.** Sub-test A confirms the LO write via
read-back; sub-test B confirms the HI write via read-back;
success emits the marker on all three fingerprint files.

### 1.1 What this issue proves

- **The IOREGSEL/IOWIN indirection protocol works.** The IOAPIC
  cannot be addressed as a flat MMIO register file — every access
  is a 2-step: 32-bit write to IOREGSEL (offset +0x00, selects
  register), then 32-bit read/write on IOWIN (offset +0x10, the
  data window). This issue is the *first* code in the tree to
  exercise that protocol against real hardware (QEMU emulates it
  identically to the Intel 82093AA / ICH IOAPIC).
- **The RTE bit layout is packed correctly.** The two 32-bit
  halves (RTE LO = IOAPIC register `0x10 + irq*2`; RTE HI =
  register `0x10 + irq*2 + 1`) split the 64-bit RTE at bit 32.
  Sub-tests A and B independently verify both halves — LO fields
  (vector, mask) via A; HI field (dest_apic_id in bits 24-31) via
  B. Together they exercise every non-reserved bit written by
  `ioapic_route_irq`.
- **The programming call is idempotent and read-back-observable.**
  Sub-test A calls `ioapic_irq4_init` then `ioapic_read(0x18)`;
  a second identical call would produce identical read-back. This
  guarantees #601 can re-invoke the programming call from its
  end-to-end harness without breaking the RTE state.
- **The IOAPIC MMIO window (0xFEC00000, one 4 KiB page) is
  reachable at boot time.** No mapping instruction is emitted
  here; the paideia-as-generated identity page table for the
  boot .bss covers the [0xFEC00000, 0xFED00000) window as
  strong-uncacheable, same window class as LAPIC MMIO
  (0xFEE00000) which is already exercised by `apic_eoi`,
  `apic_svr_enable`, and `lapic_timer_init`. This issue proves
  the window is *usable* — successful read-back means the memory
  type + PTE + physical mapping all compose.

### 1.2 What this issue deliberately does NOT do

- **No live IRQ delivery.** Programming the IOAPIC RTE is
  necessary but not sufficient for IRQ 4 delivery to reach the
  CPU. Delivery additionally requires: (a) LAPIC globally enabled
  via `apic_svr_enable` (line 3965, AFTER this witness), (b) IF=1
  via `sti` (post-`_current_tcb` init, far after this witness),
  (c) COM1 RX FIFO fills (needs stdin injection at #601). None
  of those hold at witness time; the witness is a strictly
  read-only test that reads back MMIO to prove the write went
  through.
- **No self-generated IRQ 4 to trigger delivery.** Would require
  the LAPIC to be software-enabled (per Intel SDM Vol 3A
  §10.4.7.1, ICR writes are undefined when SVR.enabled=0), *and*
  would end up executing the real `uart_rx_isr` against an empty
  16550 FIFO (indistinguishable from #597's witness — zero
  incremental coverage), *and* would need EOI accounting for
  the in-service bit. Deferred to #601.
- **No MADT walk to discover IOAPIC base or GSI override.**
  `core/acpi/madt.pdx` is stubbed (Phase 6, #167); real MADT
  parsing lands post-R17. This issue hard-codes the standard
  IOAPIC MMIO base `0xFEC00000` and the identity assumption
  IRQ 4 → GSI 4 (Global System Interrupt). Both are correct on
  QEMU and every PC-compatible chipset; documented as a §7.3
  risk with mitigation plan.
- **No mask-then-unmask sequencing.** RTE is written with
  `mask = 0` (unmasked) from the start. Rationale: LAPIC is
  disabled at witness time (§1.1 constraint (a)), so setting
  mask=0 cannot produce delivery. Programming mask=1 first,
  reading back, then re-programming mask=0 would add a
  redundant MMIO round-trip that proves nothing — the mask
  bit is written in the same 32-bit word as vector; if the
  vector-write succeeded, the mask-write succeeded.
- **No LAPIC LDR/DFR programming.** Physical destination mode
  (dest_mode = 0 in RTE LO bit 11) routes by APIC ID, not
  Logical Destination Address. On CPU 0 with APIC ID 0 (BSP
  default from QEMU), physical delivery with dest = 0 hits the
  BSP unambiguously. Logical mode would require setting up LDR
  (register 0xD0) and DFR (register 0xE0) on every AP — deferred
  to R17+ SMP work.
- **No IOAPIC ID (register 0x00) read to verify presence.**
  The read-back of RTE 4 LO in sub-test A implicitly verifies
  the IOAPIC MMIO window is live (a dead window would return
  0xFFFFFFFF or trap #GP). A separate register-0x00 read would
  add coverage of one more register but tautologically — if the
  RTE read returned the value we wrote, the IOAPIC is present.
- **No IOAPIC ID reprogramming.** The IOAPIC ID (register 0x00)
  is set by firmware to `0x0F` on QEMU (or similar). The RTE
  destination field selects target LAPIC by APIC ID, not by
  IOAPIC ID; the IOAPIC's own ID is used only by the interrupt
  bus arbitration on legacy chipsets. Not relevant on
  memory-mapped IOAPIC on QEMU/ICH.
- **No changes to `pic_mask_all`, `apic_enable`,
  `apic_svr_enable`, or the boot sequence ordering.** Every
  existing init call site is preserved verbatim.
- **No `ioapic_route_irq` invocation for any IRQ other than 4.**
  IRQ 0 (PIT — obsolete under LAPIC timer), IRQ 1 (keyboard —
  deferred to R17+), IRQ 8 (RTC — no consumer), IRQ 12 (mouse
  — deferred to R17+) are not routed by this issue. `ioapic_route_irq`
  is a general primitive; future issues invoke it with different
  (irq, vec, dest) triples.

## 2. Prereq check

### 2.1 What is in place

| Primitive                       | Location                                    | Contract used                                                                              |
|---------------------------------|---------------------------------------------|--------------------------------------------------------------------------------------------|
| Identity mapping of MMIO high window | `boot/pml4_setup` (Phase 5)             | 0xFEC00000 is inside the [0xFE000000, 0xFF000000) 16 MiB PTE that also covers LAPIC 0xFEE00000. Strong-uncacheable per boot PAT. Read/write from ring-0 succeeds. Proven transitively by every LAPIC MMIO access in the tree. |
| 32-bit MMIO write idiom         | `core/apic/eoi.pdx:35-37`                   | `mov rax, MMIO_ADDR; mov rcx, VAL; mov [rax], ecx;` — 3 instructions. This issue copies the pattern verbatim modulo the base address (0xFEC00000 vs 0xFEE000B0). Also proven at `lapic_timer.pdx:73-75, 88-90, 93-95`. |
| 32-bit MMIO read idiom (zero-ext) | `core/sched/tasks.pdx:96, 143`; `core/syscall/handlers/sys_wait.pdx:34, 39` | `mov eax, [rN]` — 32-bit load, upper 32 bits of rax cleared by convention. Same encoding class as `mov ecx, [rN]` used at tasks.pdx:96. |
| `_uart_rx_trampoline` at IDT slot 0x24 | `core/uart/rx_trampoline.pdx` + `core/int/idt.pdx:393-394, 443-445` (R16-M4-004 #598) | CPU dispatch target once IRQ 4 delivery is enabled. |
| `pic_mask_all`                  | `core/apic/pic_mask.pdx` (R11-m1-003)       | 8259 silenced by boot init at kernel_main.pdx:3966. Prevents duplicate delivery once IRQ 4 fires. |
| `uart_rx_init`                  | `core/uart/rx_init.pdx` (R16-M4-001 #595)   | IER = 0x01 enables ERBFI. Called at witness time from kernel_main.pdx:3711 — freezes the "call primitive from witness" discipline this issue follows. |
| `uart_puts`                     | `boot/uart.pdx`                             | Console output helper used by every witness for OK/FAIL markers. |
| callee-save r12/r13 push/pop discipline | Every witness (see kernel_main.pdx:3884-3885, 3952-3953) | This issue's witness pushes r12 to save the trampoline of read-back values across the `call ioapic_read` sequence. |

### 2.2 What is NOT in place

- **Any real IOAPIC primitive.** `core/apic/ioapic.pdx` currently
  contains three unused stubs with return type `u64` and empty
  bodies (`fn(_: ()) -> 0`). None have call sites (grep-verified
  across `src/`). This issue replaces the file entirely.
- **`_ioapic_base` symbol or `IOAPIC_MMIO_BASE` constant used
  from any live code path.** Introduced by this issue as a
  module-scope `let`.
- **`R16 IOAPIC IRQ4 OK` / `R16 IOAPIC IRQ4 FAIL` rodata strings.**
  Added to `boot_stub.S` alongside the last-landed R16.M4-004
  witness strings at lines 724-732.
- **MADT walker to discover the IOAPIC base.** `core/acpi/madt.pdx`
  is stubbed. Not needed on QEMU (base is at the standard
  0xFEC00000); documented as a §7.3 risk with a mitigation plan
  for R17+ hardware with non-standard IOAPIC placement.

### 2.3 Encoder gaps

**None.** Every mnemonic used has landed precedent.

| Mnemonic form                        | Proven at                                                         |
|--------------------------------------|-------------------------------------------------------------------|
| `mov rax, imm64` (large literal)     | Every MMIO helper (eoi.pdx:35, lapic_timer.pdx:73/88/93).         |
| `mov rcx, imm64`                     | Every MMIO helper (eoi.pdx:36, lapic_timer.pdx:74/89).            |
| `mov [rax], ecx` (32-bit store)      | `core/apic/eoi.pdx:37`; `core/apic/lapic_timer.pdx:75/90/95`.     |
| `mov eax, [rax]` (32-bit load, zx)   | Same encoding class as `mov ecx, [rax]` at `core/sched/tasks.pdx:96`; also `mov eax, [rN + off]` at `kernel_main.pdx:964, 969, 974, 1017, 1027, 1082, 1087, 1092` (all zero-extend into rax by hardware default). |
| `add rax, imm8`                      | `kernel_main.pdx:3892` (`add rax, 576`).                          |
| `add rdi, rsi` (register-to-register)| Ubiquitous in scheduler + syscall handlers.                       |
| `shl rax, imm8` / `shr rax, imm8`    | `core/int/idt.pdx:460-471`; witness at kernel_main.pdx:3926, 3928. |
| `and rax, imm32` (mask 0xFF/0xFFFF)  | `kernel_main.pdx:3715` (`and rax, 0xFF`); witness at 3899, 3921.  |
| `or rax, rcx`                        | Ubiquitous — see kernel_main.pdx:3929, 3936.                      |
| `cmp rax, imm` + `jne label`         | Every witness.                                                    |
| `push rN` / `pop rN`                 | Every witness prologue/epilogue.                                   |
| `call sym` (same-module + cross-module) | Every witness — same-module (`call uart_rx_init` at 3711), cross-module (`call uart_puts` everywhere). |
| `ret`                                | Every leaf function.                                              |

No SIB. No REX.B on extended-register variants beyond what
`apic_eoi` and `lapic_timer_init` already use. No new addressing
mode. **Cross-repo escalation not needed.**

### 2.4 Verified assumptions

- **Ports 0xFEC00000 (IOREGSEL) and 0xFEC00010 (IOWIN) are
  memory-mapped, not port-mapped.** Confirmed via Intel 82093AA
  I/O APIC datasheet §3.1 ("These registers appear in the
  physical memory space") and ICH9 §13.5.4 ("IOAPIC registers
  are located at FEC0_0000h"). QEMU emulates this identically.
- **32-bit-only access.** Per §3.2.1 of the 82093AA datasheet:
  "All accesses to IOAPIC registers must be 32-bit". This
  issue's use of `mov [rax], ecx` (32-bit store) and `mov eax,
  [rax]` (32-bit load) satisfies the requirement. A 64-bit
  access (`mov [rax], rcx`) would produce undefined behavior on
  real hardware (QEMU tolerates it but this issue does not
  exploit the tolerance).
- **RTE bit layout matches Intel/AMD IOAPIC spec.** Vector in
  bits 0-7 of LO; mask in bit 16 of LO; dest_apic_id in bits
  24-31 of HI (equivalent to bits 56-63 of the packed 64-bit
  RTE). Confirmed against Intel 82093AA §3.2.4 and the
  existing stub-doc comment at `ioapic.pdx:25-36`.
- **QEMU MADT publishes IOAPIC at 0xFEC00000 with GSI base 0
  and no Interrupt Source Override for IRQ 4.** Confirmed
  via `acpidump` inspection of QEMU-generated tables. Identity
  mapping IRQ n → GSI n holds for all ISA IRQs except sometimes
  IRQ 0 (PIT — remapped to GSI 2 by some BIOSes; not our
  concern).

## 3. Design

### 3.1 File and module structure

**Rewritten file**: `src/kernel/core/apic/ioapic.pdx`. Complete
replacement — the three existing stubs have zero callers and
carry no compatibility contract.

Module name: `Ioapic` (unchanged from stub file). Public exports:

- `pub let ioapic_write : (u64, u64) -> () !{sysreg, mem} @{boot}`
- `pub let ioapic_read : (u64) -> u64 !{sysreg, mem} @{boot}`
- `pub let ioapic_route_irq : (u64, u64, u64) -> () !{sysreg, mem} @{boot}`
- `pub let ioapic_irq4_init : () -> () !{sysreg, mem} @{boot}`

Module-scope `let`s (constants, no code):

- `IOAPIC_MMIO_BASE : u64 = 0xFEC00000`
- `IOAPIC_IOREGSEL_OFFSET : u64 = 0x00`
- `IOAPIC_IOWIN_OFFSET : u64 = 0x10`
- `IOAPIC_REDIRTBL_BASE : u64 = 0x10`
- `IOAPIC_RTE_LO_MASK : u64 = 0x00010000` (mask bit position — documentation only, not used at runtime)
- `IOAPIC_RTE_LO_DEFAULT_FLAGS : u64 = 0x00000000` (fixed delivery, physical mode, edge, active-high, unmasked)

No storage symbols. No `.bss`. No init function separate from
the primitives.

### 3.2 IOAPIC register selection idiom

The IOAPIC uses a 2-register indirection: `IOREGSEL` (32-bit
write-only index register) selects which internal register the
`IOWIN` window reads/writes. This is materially different from
LAPIC (which is a flat MMIO register file at 0xFEE00000).

**`ioapic_write(reg_idx, val)` sequence** (5 instructions +
prologue/epilogue):

```asm
    ; rdi = reg_idx, rsi = val
    mov rax, 0xFEC00000                ; IOAPIC base
    mov [rax], edi                     ; IOREGSEL <- reg_idx (32-bit)
    mov [rax + 0x10], esi              ; IOWIN <- val (32-bit)
    ret
```

**`ioapic_read(reg_idx)` sequence** (4 instructions +
prologue/epilogue):

```asm
    ; rdi = reg_idx, returns u64 in rax
    mov rax, 0xFEC00000                ; IOAPIC base
    mov [rax], edi                     ; IOREGSEL <- reg_idx (32-bit)
    mov eax, [rax + 0x10]              ; rax = zero-extended IOWIN value
    ret
```

Note on the `mov eax, [rax + 0x10]` line: this reuses `rax` (base
address) as both the source for the address computation and the
destination for the loaded value. Legal — x86 encoding orders
memory-address decoding before destination write, so the loaded
32-bit value replaces rax with zero-extension into the upper 32
bits. Same pattern that `sys_wait.pdx:34` uses (`mov edx, [rax +
4]` — same base, different offset).

**Why no `mov rcx, [rax + 0x10]` (64-bit load)?** Per §2.4, IOAPIC
requires 32-bit-only access. A 64-bit load would (a) attempt to
load both IOWIN (offset 0x10) and IOWIN+4 (offset 0x14 = pad word,
undefined) in one bus transaction, and (b) produce undefined data
in the upper 32 bits on real hardware. `mov eax, [rax + 0x10]` is
the correct 32-bit-only form.

### 3.3 RTE encoding for IRQ 4 → vec 0x24 → CPU 0

RTE #4 lives at IOAPIC internal registers 0x18 (LO, bits 0-31 of
the packed 64-bit RTE) and 0x19 (HI, bits 32-63).

**Formula**: `LO_reg = 0x10 + 2*irq`, `HI_reg = 0x10 + 2*irq + 1`.
For IRQ 4: LO = 0x18, HI = 0x19.

**LO layout (bits 0-31 of the 64-bit RTE)**:

| Bits  | Field           | Value for IRQ 4 → 0x24 → CPU 0 | Rationale                    |
|-------|-----------------|--------------------------------|-----------------------------|
| 0-7   | vector          | 0x24                           | IDT slot #598 wired at 0x24 |
| 8-10  | delivery_mode   | 000 (Fixed)                    | Standard IRQ delivery       |
| 11    | dest_mode       | 0 (Physical)                   | Route by APIC ID, not LDR   |
| 12    | delivery_status | 0 (RO, cleared)                | No pending IRQ              |
| 13    | polarity        | 0 (Active High)                | 16550 UART IRQ is active-high per NS PC16550D |
| 14    | remote_IRR      | 0 (RO, cleared)                | Only meaningful for level-triggered |
| 15    | trigger_mode    | 0 (Edge)                       | ISA-legacy IRQ 4 is edge-triggered |
| 16    | mask            | 0 (Unmasked)                   | Enable delivery              |
| 17-31 | reserved        | 0                              | MUST be 0                    |

**Composite LO value: `0x00000024`.**

**HI layout (bits 32-63 of the 64-bit RTE, but the register is
32-bit-wide starting at bit 32)**:

| Bits (in HI reg) | Field           | Value for CPU 0 | Rationale                       |
|------------------|-----------------|-----------------|---------------------------------|
| 0-23             | reserved        | 0               | MUST be 0                       |
| 24-31            | dest_apic_id    | 0 (BSP)         | CPU 0's APIC ID is 0 on QEMU BSP |

**Composite HI value: `0x00000000`.**

Encoding function (pseudocode):

```
lo = vec                        ; 0x24
    | (delivery_mode  <<  8)    ; 0
    | (dest_mode      << 11)    ; 0
    | (polarity       << 13)    ; 0
    | (trigger_mode   << 15)    ; 0
    | (mask           << 16)    ; 0
   = 0x24

hi = (dest_apic_id << 24)       ; 0
   = 0x00000000
```

Since every field except vector and dest_apic_id is 0 for this
configuration, the encoding collapses to `lo = vec, hi =
dest_apic_id << 24`.

### 3.4 `ioapic_route_irq` — general primitive

The public API is a general 3-argument primitive so future issues
can route arbitrary IRQs to arbitrary vectors on arbitrary target
LAPICs. R16.M4 only uses it for IRQ 4, but keyboard (IRQ 1) at
R17 and other devices (R17+ device driver plane) will reuse it.

**Signature**: `(irq: u64, vec: u64, dest_apic_id: u64) -> ()`
!{sysreg, mem} @{boot}.

**Body sketch** (SysV: rdi=irq, rsi=vec, rdx=dest_apic_id):

```asm
    ; --- Compute LO register index: 0x10 + irq*2 ---
    ; rdi = irq → r8 = 0x10 + irq*2 (LO register index)
    mov r8, rdi
    shl r8, 1                          ; r8 = irq * 2
    add r8, 0x10                       ; r8 = 0x10 + irq*2 = LO reg

    ; --- Compute HI register index: LO + 1 ---
    mov r9, r8
    add r9, 1                          ; r9 = HI reg

    ; --- Assemble LO value: LO = vec (all other fields 0 for R16.M4-005 default) ---
    ; rsi = vec → r10 = vec (rest of bits 0 by default)
    mov r10, rsi                       ; r10 = LO value = vector byte

    ; --- Assemble HI value: HI = dest_apic_id << 24 ---
    ; rdx = dest_apic_id → r11 = dest_apic_id << 24
    mov r11, rdx
    shl r11, 24                        ; r11 = HI value = dest << 24

    ; --- Program HI first (mask stays effectively unmasked at 0 in LO), then LO ---
    ; Standard IOAPIC discipline (Intel §3.2.4): write HI (dest) before LO (mask+vec)
    ; so the CPU never sees a half-written RTE with the wrong dest.
    ; At witness time, LAPIC is disabled so RTE half-writes are inert; still
    ; observing the convention for R17+ SMP correctness.
    sub rsp, 8                         ; align for nested SysV calls (rsp%16 == 0 → 8)

    mov rdi, r9                        ; arg0: HI reg
    mov rsi, r11                       ; arg1: HI value
    call ioapic_write

    mov rdi, r8                        ; arg0: LO reg
    mov rsi, r10                       ; arg1: LO value
    call ioapic_write

    add rsp, 8                         ; restore alignment
    ret
```

**Register discipline**: r8/r9/r10/r11 are SysV caller-save
(the two nested `call ioapic_write` do not preserve them; but
they're computed once and consumed on the same side of any
call). Actually — trace: r8/r9 (reg indices) are computed
BEFORE the two calls. r10/r11 (values) are also computed BEFORE
the two calls. Then the calls consume them one at a time via
rdi/rsi. Because `ioapic_write` is SysV caller-save it may
clobber r8-r11. Fix: **use callee-save r12-r15 for the four
computed values** so they survive the two nested calls.

**Revised body** (with proper callee-save discipline):

```asm
    ; --- 4-push prologue: preserve r12-r15 for computed values ---
    push r12                           ; will hold LO reg index
    push r13                           ; will hold HI reg index
    push r14                           ; will hold LO value
    push r15                           ; will hold HI value
    ; rsp = -32 → rsp%16 = 8 (SysV entry alignment: rsp%16 = 8 on entry, after 4 pushes rsp%16 = 8)

    ; --- Compute LO/HI register indices from IRQ ---
    mov r12, rdi                       ; r12 = irq
    shl r12, 1                         ; r12 = irq*2
    add r12, 0x10                      ; r12 = 0x10 + irq*2 = LO reg
    mov r13, r12
    add r13, 1                         ; r13 = HI reg

    ; --- Assemble LO value: vec (fields 8-31 all 0) ---
    mov r14, rsi                       ; r14 = LO value

    ; --- Assemble HI value: dest_apic_id << 24 ---
    mov r15, rdx
    shl r15, 24                        ; r15 = HI value

    ; --- Program HI first (dest), then LO (vector + mask=0) ---
    mov rdi, r13
    mov rsi, r15
    call ioapic_write                  ; HI programmed

    mov rdi, r12
    mov rsi, r14
    call ioapic_write                  ; LO programmed

    ; --- Epilogue ---
    pop r15
    pop r14
    pop r13
    pop r12
    ret
```

**Alignment trace**: on entry, SysV says `rsp % 16 == 8` (return
address just pushed by the caller). After 4 pushes, `rsp % 16 ==
8 - 32 mod 16 = 8`. Nested `call ioapic_write` sees rsp%16 == 8
at entry — correct. No `sub rsp, 8` needed.

**Instruction count**: 4 (prologue) + 3 (LO idx) + 2 (HI idx) +
1 (LO val) + 2 (HI val) + 3 (HI write) + 3 (LO write) + 4
(epilogue) + 1 (ret) = **23 instructions**.

### 3.5 `ioapic_irq4_init` — convenience wrapper

Thin shim: `ioapic_route_irq(4, 0x24, 0)`. Two responsibilities:

1. Freeze the IRQ 4 / vector 0x24 / dest CPU 0 magic numbers in
   ONE named callsite. Future callers say "route the UART" not
   "route 4 to 36 on CPU 0" — the name carries the semantic.
2. Provide a call target that the witness (§5) and the eventual
   post-R16.M4 boot-init call site (probably alongside
   `pic_mask_all`) can share without repeating the constants.

**Body** (5 instructions):

```asm
    mov rdi, 4                         ; irq = 4 (COM1 UART)
    mov rsi, 0x24                      ; vec = 0x24 (IDT slot 36, from #598)
    xor rdx, rdx                       ; dest_apic_id = 0 (BSP)
    ; Tail call: reuses ioapic_route_irq's ret.
    jmp ioapic_route_irq
```

**Why `jmp` (tail call) and not `call ... ret`?** `ioapic_irq4_init`
has no work to do after `ioapic_route_irq` returns. Tail-jumping
saves one stack frame and one `ret`. Same discipline as
paideia-as's own generated tail-call codegen (proven idiom in
`core/sched/sched_pick_next.pdx:*`). If future R17+ growth adds
post-init bookkeeping, revisit to `call ioapic_route_irq; ret`.

**Alignment**: caller's rsp%16 == 8 (SysV entry). No prologue,
so at the `jmp` boundary rsp%16 is still 8 — which is what
`ioapic_route_irq` expects at its own entry. Correct.

**Instruction count**: **4 instructions**.

### 3.6 `ioapic_write` — full body

Signature: `(reg_idx: u64, val: u64) -> ()` !{sysreg, mem}
@{boot}. SysV: rdi=reg_idx, rsi=val.

```asm
    mov rax, 0xFEC00000                ; IOAPIC MMIO base
    mov [rax], edi                     ; IOREGSEL <- reg_idx (32-bit write, low32 of rdi)
    mov [rax + 0x10], esi              ; IOWIN <- val (32-bit write, low32 of rsi)
    ret
```

**Instruction count**: **4 instructions**. Leaf function; no
prologue.

**Why `edi` / `esi` and not `rcx` / another register?** SysV
already places reg_idx in rdi and val in rsi. Using their 32-bit
halves (edi, esi) directly avoids two extra `mov` instructions
that would just copy rdi→rcx and rsi→rcx. Same idiom as
`sys_wait.pdx:34` which uses `[rax + 4]` with source-address
computation reusing the destination register.

**Encoder note**: `mov [rax], edi` and `mov [rax + 0x10], esi`
are 32-bit-source memory stores. The `MOV r/m32, r32` encoding
(opcode 0x89) with the appropriate ModR/M. paideia-as has
emitted this class of instruction since R11-m1-002 via `mov
[rax], ecx` at eoi.pdx:37; the switch from `ecx` to `edi`/`esi`
requires only different REX/ModR/M bytes for the source-register
selection — the same encoding class.

### 3.7 `ioapic_read` — full body

Signature: `(reg_idx: u64) -> u64` !{sysreg, mem} @{boot}. SysV:
rdi=reg_idx, returns via rax.

```asm
    mov rax, 0xFEC00000                ; IOAPIC MMIO base
    mov [rax], edi                     ; IOREGSEL <- reg_idx (32-bit write, low32 of rdi)
    mov eax, [rax + 0x10]              ; rax = zero-extended IOWIN (32-bit load)
    ret
```

**Instruction count**: **4 instructions**. Leaf function; no
prologue.

**Why `mov eax, ...` (not `mov rax, ...`)?** 32-bit loads
zero-extend the upper 32 bits of rax by convention (Intel Vol 2A
§3.4.1.1). This produces a proper `u64` return in rax with the
IOWIN value in bits 0-31 and 0s in bits 32-63 — which is what
callers expect. A 64-bit load (`mov rax, [rax + 0x10]`) would
violate the IOAPIC "32-bit only" access rule per §2.4.

### 3.8 File contents — `ioapic.pdx` (complete)

```pdx
// src/kernel/core/apic/ioapic.pdx — R16-M4-005 (#599)
// I/O APIC Redirect Table Programmer.
//
// Superseded the Phase 6 stubs (stub_ioapic_set_redir,
// stub_ioapic_mask, stub_ioapic_unmask) which had zero call
// sites. This module provides the real primitives needed to
// route platform IRQs to specific CPU cores and interrupt
// vectors via the IOAPIC's Redirection Table.
//
// The IOAPIC exposes its registers via a 2-step MMIO protocol:
//   1. Write the 8-bit register index to IOREGSEL @ base + 0x00
//   2. Read/write the 32-bit data via IOWIN @ base + 0x10
// All accesses are 32-bit-only (Intel 82093AA §3.2.1).
//
// Each Redirection Table Entry (RTE) is 64 bits split across
// two consecutive 32-bit IOAPIC registers:
//   RTE #n LO = IOAPIC register 0x10 + n*2   (bits 0-31 of RTE)
//   RTE #n HI = IOAPIC register 0x10 + n*2+1 (bits 32-63 of RTE)
//
// RTE layout (Intel 82093AA §3.2.4):
//   LO bits 0-7:   vector (interrupt vector delivered to LAPIC)
//   LO bits 8-10:  delivery mode (0=Fixed, 1=Lowest Priority, ...)
//   LO bit 11:     destination mode (0=Physical, 1=Logical)
//   LO bit 12:     delivery status (RO)
//   LO bit 13:     polarity (0=Active High, 1=Active Low)
//   LO bit 14:     remote IRR (RO, for level-triggered)
//   LO bit 15:     trigger mode (0=Edge, 1=Level)
//   LO bit 16:     mask (0=Unmasked, 1=Masked — no delivery)
//   LO bits 17-31: reserved (0)
//   HI bits 0-23:  reserved (0)
//   HI bits 24-31: destination (APIC ID in physical mode)
//
// This module exports four primitives:
//   ioapic_write(reg_idx, val)                  → generic register write
//   ioapic_read(reg_idx)                        → generic register read
//   ioapic_route_irq(irq, vec, dest_apic_id)    → program RTE #irq
//   ioapic_irq4_init()                          → wrapper for IRQ 4 → 0x24 → CPU 0
//
// The R16.M4 driver uses ioapic_irq4_init only; ioapic_route_irq
// is exposed for R17+ device driver reuse (keyboard IRQ 1, etc.).
//
// See design/kernel/r16-m4-005-ioapic-irq4.md for full contract.

module Ioapic = structure {
  // ============================================================================
  // I/O APIC Constants
  // ============================================================================

  // IOAPIC MMIO base on standard PC platforms (Intel ICH9, QEMU q35/pc).
  // MADT walk would confirm this at runtime; hard-coded here pending
  // core/acpi/madt.pdx implementation (Phase 6 stub, #167).
  let IOAPIC_MMIO_BASE : u64 = 0xFEC00000

  // Register offsets from IOAPIC_MMIO_BASE.
  let IOAPIC_IOREGSEL_OFFSET : u64 = 0x00
  let IOAPIC_IOWIN_OFFSET    : u64 = 0x10

  // Base of the Redirection Table register range (register 0x10 = RTE #0 LO).
  // RTE #n occupies registers [0x10 + n*2, 0x10 + n*2 + 1].
  let IOAPIC_REDIRTBL_BASE : u64 = 0x10

  // Standard maximum RTE count on a 24-input IOAPIC (register 0x00 IOAPICVER
  // bits 16-23 encode the max redirection entry count; 24 for ICH IOAPICs).
  let IOAPIC_MAX_INPUTS : u64 = 24

  // ============================================================================
  // ioapic_write — write a 32-bit value to an IOAPIC internal register
  //
  // Input:  rdi = reg_idx (8-bit; e.g. 0x18 for RTE #4 LO)
  //         rsi = val (32-bit; upper 32 bits ignored)
  // Output: (none)
  //
  // Side effects:
  //   32-bit MMIO write to IOAPIC_MMIO_BASE + 0x00 (IOREGSEL) selects the
  //   internal register, then 32-bit MMIO write to +0x10 (IOWIN) commits
  //   the value into the selected register.
  //
  // Clobbers (SysV caller-save):
  //   rax.
  // ============================================================================
  pub let ioapic_write : (u64, u64) -> () !{sysreg, mem} @{boot} =
    fn (reg_idx: u64, val: u64) -> unsafe {
      effects: { sysreg, mem },
      capabilities: { boot },
      justification: "R16-M4-005 (#599): 32-bit MMIO write to IOAPIC internal register via the standard IOREGSEL/IOWIN 2-step protocol (Intel 82093AA §3.2.1). Load IOAPIC MMIO base 0xFEC00000 into rax, write low32 of reg_idx (rdi) to IOREGSEL at base+0x00 (`mov [rax], edi`), then write low32 of val (rsi) to IOWIN at base+0x10 (`mov [rax + 0x10], esi`). Both stores are 32-bit as required by the IOAPIC spec — 64-bit access would attempt to load the pad word at offset +0x14 and produce undefined behavior on real hardware. Address 0xFEC00000 is covered by paideia-as-generated identity-map boot page tables as strong-uncacheable, same window class as LAPIC MMIO exercised by apic_eoi (core/apic/eoi.pdx:35, R9-m2-003). Leaf function: no prologue/epilogue, no nested call, no stack frame. Encoder: 32-bit-source-to-memory store class (`MOV r/m32, r32` opcode 0x89) proven at eoi.pdx:37 and lapic_timer.pdx:75/90/95; the switch from `ecx` to `edi`/`esi` requires only different REX/ModR/M bytes. Reads of the pair from real hardware appear as two independent bus transactions per Intel 82093AA §3.2.2 — first IOREGSEL, then IOWIN — no fence needed between them because MMIO stores are serialized in program order on the same address window per Intel SDM Vol 3A §11.3.1. Audit: r16-m4-005-ioapic-irq4.",
      block: {
        mov rax, 0xFEC00000
        mov [rax], edi
        mov [rax + 0x10], esi
        ret
      }
    }

  // ============================================================================
  // ioapic_read — read a 32-bit value from an IOAPIC internal register
  //
  // Input:  rdi = reg_idx (8-bit)
  // Output: rax = 32-bit register value, zero-extended to 64 bits
  //
  // Side effects:
  //   32-bit MMIO write to IOREGSEL (selects register), then 32-bit
  //   MMIO read from IOWIN (returns the selected register's value).
  //
  // Clobbers (SysV caller-save):
  //   rax (return value).
  // ============================================================================
  pub let ioapic_read : (u64) -> u64 !{sysreg, mem} @{boot} =
    fn (reg_idx: u64) -> unsafe {
      effects: { sysreg, mem },
      capabilities: { boot },
      justification: "R16-M4-005 (#599): 32-bit MMIO read from IOAPIC internal register via IOREGSEL/IOWIN protocol (Intel 82093AA §3.2.1). Load IOAPIC base into rax, write reg_idx to IOREGSEL at base+0x00, then load IOWIN via `mov eax, [rax + 0x10]` — 32-bit load zero-extends into the upper 32 bits of rax per Intel Vol 2A §3.4.1.1, producing a proper u64 return with the IOWIN value in bits 0-31 and 0s in bits 32-63. Reuses rax as both base-address source AND destination for the load — legal because x86 encoding orders address computation before destination write. Same reuse-pattern as sys_wait.pdx:34 (`mov edx, [rax + 4]`). Leaf function: no prologue/epilogue. Encoder: 32-bit-memory-to-register load class proven ubiquitously (tasks.pdx:96 with `mov ecx, [rax]`; kernel_main.pdx:964,969,974 with `mov eax, [r12 + N]`). Read is 32-bit-only — a 64-bit load would attempt to also load the pad word at offset +0x14 producing undefined data in bits 32-63. Audit: r16-m4-005-ioapic-irq4.",
      block: {
        mov rax, 0xFEC00000
        mov [rax], edi
        mov eax, [rax + 0x10]
        ret
      }
    }

  // ============================================================================
  // ioapic_route_irq — program IOAPIC Redirection Table Entry for `irq`
  //
  // Input:  rdi = irq (0..23; IOAPIC input line)
  //         rsi = vec (0..255; IDT vector delivered to LAPIC)
  //         rdx = dest_apic_id (0..255; physical APIC ID of target LAPIC)
  // Output: (none)
  //
  // Programmed RTE flags: Fixed delivery, Physical destination mode,
  //   Active High polarity, Edge trigger, Unmasked (mask=0). These
  //   defaults are correct for ISA-legacy edge-triggered IRQs (UART,
  //   keyboard, RTC). Level-triggered IRQs (PCI legacy INT#, IOAPIC
  //   PIRQ) would require polarity=Active Low + trigger=Level — add
  //   a future variant `ioapic_route_irq_level` for that.
  //
  // Side effects:
  //   Two nested `call ioapic_write` for the HI and LO halves of the
  //   RTE. HI is programmed first (dest), then LO (which includes vec
  //   and mask=0). Ordering per Intel §3.2.4 to avoid transient
  //   half-written RTE state visible to the LAPIC.
  //
  // Clobbers (SysV caller-save):
  //   rax, rcx, rdi, rsi, r8-r11 (transitively via ioapic_write).
  // ============================================================================
  pub let ioapic_route_irq : (u64, u64, u64) -> () !{sysreg, mem} @{boot} =
    fn (irq: u64, vec: u64, dest_apic_id: u64) -> unsafe {
      effects: { sysreg, mem },
      capabilities: { boot },
      justification: "R16-M4-005 (#599): General primitive to program IOAPIC RTE for any IRQ with vector/destination/standard-flags. R16.M4 caller (ioapic_irq4_init) uses it for IRQ 4 → vec 0x24 → CPU 0; R17+ device driver plane will reuse for keyboard IRQ 1, mouse IRQ 12, etc. Body: (1) 4-push prologue preserving r12-r15 for the four computed values (LO reg idx, HI reg idx, LO value, HI value) that must survive the two nested `call ioapic_write` — those calls are SysV caller-save so r8-r11 would be clobbered. rsp entry-alignment %16==8 → after 4 pushes still %16==8, matching nested call requirement. (2) Compute LO reg = 0x10 + irq*2 into r12 via `shl r12, 1; add r12, 0x10`; HI reg = r12 + 1 into r13. (3) LO value = vec directly (delivery=fixed=0, dest_mode=phys=0, polarity=high=0, trigger=edge=0, mask=0 → LO = vec byte). HI value = dest_apic_id << 24 (dest field is bits 24-31 of the 32-bit HI register). (4) Program HI first (`call ioapic_write` with rdi=r13, rsi=r15), then LO (`call ioapic_write` with rdi=r12, rsi=r14). HI-first ordering per Intel §3.2.4: ensures the LAPIC never sees a half-written RTE where the vector is programmed but the destination still points at the wrong LAPIC. At R16.M4-005 witness time, LAPIC is disabled so any ordering would be inert; observing the convention is R17+ SMP correctness insurance. (5) 4-pop epilogue + ret. Runs with IF=0 by construction (witness slot in kernel_main is inside the boot cli window). Encoder: no new mnemonics — `push/pop r12-r15`, `shl reg, imm8`, `add reg, imm8`, `mov reg, reg`, `call sym` all proven. Audit: r16-m4-005-ioapic-irq4.",
      block: {
        // 4-push prologue: preserve r12-r15 across nested ioapic_write calls
        push r12
        push r13
        push r14
        push r15

        // r12 = LO reg = 0x10 + irq*2
        mov r12, rdi
        shl r12, 1
        add r12, 0x10

        // r13 = HI reg = LO + 1
        mov r13, r12
        add r13, 1

        // r14 = LO value = vec (all other fields default 0)
        mov r14, rsi

        // r15 = HI value = dest_apic_id << 24 (dest field at bits 24-31)
        mov r15, rdx
        shl r15, 24

        // --- Program HI first (dest), then LO (vec + mask=0). ---
        // Ordering per Intel 82093AA §3.2.4: HI-first prevents the LAPIC
        // from seeing a valid vector routed to the wrong destination in
        // a hypothetical mid-write interrupt window.
        mov rdi, r13
        mov rsi, r15
        call ioapic_write

        mov rdi, r12
        mov rsi, r14
        call ioapic_write

        // Epilogue
        pop r15
        pop r14
        pop r13
        pop r12
        ret
      }
    }

  // ============================================================================
  // ioapic_irq4_init — thin wrapper: route IRQ 4 → vector 0x24 → CPU 0
  //
  // Input:  (none)
  // Output: (none)
  //
  // Freezes the IRQ 4 / vector 0x24 / CPU 0 magic numbers in a single
  // named call site. Used by the R16-M4-005 witness (kernel_main.pdx)
  // and any future boot-init call that wants "route the UART" without
  // repeating the parameter triple.
  //
  // Idempotent: safe to call multiple times. Subsequent calls
  // re-write the RTE with identical values (no state divergence).
  //
  // Side effects:
  //   Transitively via ioapic_route_irq: two 32-bit MMIO writes to
  //   IOAPIC_MMIO_BASE (IOREGSEL) + IOWIN, for both LO (0x18) and
  //   HI (0x19) halves of RTE #4.
  //
  // Clobbers (SysV caller-save):
  //   rax, rcx, rdi, rsi, rdx, r8-r11 (transitively).
  // ============================================================================
  pub let ioapic_irq4_init : () -> () !{sysreg, mem} @{boot} = fn () -> unsafe {
    effects: { sysreg, mem },
    capabilities: { boot },
    justification: "R16-M4-005 (#599): Wrapper for the R16.M4 UART RX interrupt routing configuration. Sets rdi=4 (IRQ 4 = COM1 in standard PC ISA IRQ assignment; identity-mapped to GSI 4 on QEMU q35/pc — MADT would confirm dynamically post-#167), rsi=0x24 (IDT slot 36 wired to _uart_rx_trampoline by R16-M4-004 #598), rdx=0 (CPU 0 = BSP = APIC ID 0 on QEMU default), then tail-jumps to ioapic_route_irq. Tail-jmp instead of call+ret saves one stack frame and one ret since this function has no post-call work; matches the same-idiom in sched_pick_next tail-call codegen. Alignment: caller's rsp%16==8 (SysV entry) preserved through the jmp (no prologue), so ioapic_route_irq sees rsp%16==8 at its own entry — correct. Encoder: `mov rN, imm`, `xor rdx, rdx`, `jmp sym` all proven. Audit: r16-m4-005-ioapic-irq4.",
    block: {
      mov rdi, 4          // irq = 4 (COM1 UART)
      mov rsi, 0x24       // vec = 0x24 (IDT slot 36, from #598)
      xor rdx, rdx        // dest_apic_id = 0 (BSP)
      jmp ioapic_route_irq
    }
  }
}
```

**Total LOC** (including comments, blanks, justification blocks):
approximately **210 lines** for the whole file. Executable
instruction count: 4 (write) + 4 (read) + 21 (route + prologue/
epilogue) + 4 (irq4_init) = **33 real instructions**.

### 3.9 Alternatives considered — API shape

| Variant                                             | Rejected because                                                                                          |
|-----------------------------------------------------|-----------------------------------------------------------------------------------------------------------|
| **`ioapic_write`/`ioapic_read` + `ioapic_route_irq` + `ioapic_irq4_init` (chosen)** | Three orthogonal layers: MMIO primitive (write/read), semantic primitive (route), concrete configuration (irq4_init). Each layer is independently testable and independently reusable. `ioapic_route_irq` becomes the API surface for R17+ device drivers. |
| Only `ioapic_irq4_init` (no generic route helper)   | Would force R17+ device drivers to reimplement RTE packing — bit-position magic numbers get duplicated. Diverges from paideia-as's "one canonical primitive per hardware operation" discipline (compare apic_eoi being reused by handle_timer, uart_rx_isr, and every IPI trampoline). |
| `ioapic_route_irq` only (no `irq4_init`)            | Forces the boot site + the witness to both spell out `(4, 0x24, 0)` as literal magic numbers. Named wrapper is a 4-instruction shim with high semantic gain per byte of code. |
| Fused `ioapic_write_rte(irq, lo_val, hi_val)`       | Hides the LO/HI split — future variants (level-triggered, logical-mode, mask-then-unmask sequences) would either grow this signature or shadow it. `ioapic_route_irq` with named RTE-field arguments is easier to extend. |
| Generic `ioapic_set_rte(irq, rte_u64)` taking a packed 64-bit value | Callers must know the packing formula. This spreads the RTE bit-layout knowledge across every callsite. `ioapic_route_irq` is the packing site; callers pass semantic arguments (vec, dest_apic_id) not bit-packed values. |
| Split ioapic_write into `ioapic_select` (IOREGSEL) + `ioapic_data_write` (IOWIN) | Two-step protocol becomes visible to callers. Every caller must remember to `select` before `read`/`write`. Wrong abstraction — the atomic unit is (select, access), not each MMIO write. |

### 3.10 Alternatives considered — RTE encoding function

| Variant                                             | Rejected because                                                                                          |
|-----------------------------------------------------|-----------------------------------------------------------------------------------------------------------|
| **Fields collapse to `LO = vec, HI = dest << 24` because all other bits are 0 (chosen)** | Optimal for the R16.M4 default configuration (fixed/physical/edge/high/unmasked). Zero-cost at runtime — no OR chain. |
| Explicit OR chain: `LO = vec | (fixed << 8) | (phys << 11) | ... | (unmasked << 16)` | All `<< N` produce 0 for the default values, so the OR chain reduces to `LO = vec`. Adds instructions that always produce identical output. If R17+ level-triggered IRQ 1 needs different polarity/trigger, factor at that time via a new `ioapic_route_irq_level` variant. |
| Compile-time constant folding of the flag bits      | paideia-as does not yet have compile-time integer folding for this class of expression. Requires either literal encoding (chosen) or runtime OR chain (rejected above). |

### 3.11 Alternatives considered — programming call placement in boot

| Variant                                             | Rejected because                                                                                          |
|-----------------------------------------------------|-----------------------------------------------------------------------------------------------------------|
| **Inside the R16-M4-005 witness block, right before the read-back peek (chosen)** | Matches R16-M4-001 discipline (uart_rx_init is called at kernel_main.pdx:3711, inside the witness block). Concentrates all R16.M4 subsystem-14 boot state under the witness umbrella. |
| Alongside `pic_mask_all` at kernel_main.pdx:3966    | Would decouple the programming call from the witness peek — the witness would just observe the state programmed 10 lines earlier. Fine for post-#601 hardening, but the R16.M4 idiom is "witness OWNS both provoke and check". Post-#601, moving the call is a trivial 2-line diff. |
| At AP-startup path (per-CPU init) | Wrong — IOAPIC is not per-CPU; it's a single chip that routes IRQs *to* per-CPU LAPICs. Programming it once from CPU 0 is sufficient. |
| Before `idt_install` at kernel_main.pdx:80          | Programming the RTE before the trampoline is even in the IDT would create a race window: if IRQ 4 fires (impossible pre-`apic_svr_enable`, but structurally possible in principle), it would #GP. Deferred until AFTER the IDT wire. Since #598 lands at line 3953 witness, this issue's witness (line ~3953) is after `idt_install` and after #598's structural witness — safe. |

## 4. Witness placement

### 4.1 Position in kernel_main.pdx

Inserted immediately after `idt_vec24_witness_done:` (line 3953,
the last-landed R16.M4 witness `_done` label). Insertion point:

```
      idt_vec24_witness_done:
          pop  r13;
          pop  r12;

      <-- INSERT R16-M4-005 WITNESS HERE

      // R14b-m5-002 (#507): IA32_GS_BASE = &_cpu_locals[0] on CPU0.
      lea rax, [rip + _cpu_locals];
```

Structurally independent — no data flow into or out of the
preceding `idt_vec24_witness` block, and no data flow into any
subsequent init call (GS_BASE setup, process_init, apic_enable,
apic_svr_enable, pic_mask_all). The IOAPIC MMIO writes produce
no state visible to any later witness.

### 4.2 Ordering constraints — safety

- **Must run AFTER `idt_install` (line 80)** so IDT slot 0x24
  is populated. Trivially satisfied — line ~3953 is 3873 lines
  after line 80.
- **Must run AFTER #598's `idt_vec24_witness_done`** (line 3953)
  so the IDT slot has been positively verified before we make
  it reachable. Trivially satisfied by placement.
- **Must run BEFORE `apic_svr_enable` (line 3965)**. Without
  LAPIC software-enabled, no delivery can happen from any
  source. This gives an air-tight guarantee that programming
  the RTE (which sets mask=0, i.e. unmasked) cannot produce a
  live IRQ during the witness. Preserved by placement between
  3953 and 3965.
- **Must run BEFORE `sti` (post-`_current_tcb` init, far later
  in kernel_main)**. IF=0 during witness → no interrupt can
  preempt the read-back. Preserved by placement inside the
  kernel_main `cli` window.
- **Placement relative to `pic_mask_all` is irrelevant**. IRQ
  4 delivery via the 8259 legacy PIC path requires: (a) 8259
  master offset remapped (never happens in this tree — the
  8259 stays at its power-on offset which puts IRQ 4 at CPU
  vector 0x0C, a #GP-adjacent slot), (b) 8259 not masked. Neither
  hold at any point in boot; pic_mask_all is defense-in-depth.

### 4.3 No witness slab needed

The witness reads back MMIO registers into general-purpose
registers and computes on them. No new .bss symbols, no new
fixture data.

## 5. Test canary — kernel_main witness block

### 5.1 Sub-test structure

**Two mandatory sub-tests**:

- **Sub-test A — RTE 4 LO round-trip**: after
  `ioapic_irq4_init`, read RTE 4 LO via `ioapic_read(0x18)`.
  Two assertions on the result:
  - A1: low 8 bits (vector field) == 0x24
  - A2: bit 16 (mask field) == 0
  Rationale: sub-test A is the primary proof — it demonstrates
  that the LO write reached IOWIN via IOREGSEL, that the RTE
  bit layout is packed correctly, and that the mask field is
  in the unmasked state ready for delivery. A1 and A2 are
  merged into one sub-test because they read from the same
  32-bit word (one `ioapic_read` call covers both), but each
  gets its own `jne witness_fail` for diagnostic bisection.
- **Sub-test B — RTE 4 HI round-trip**: read RTE 4 HI via
  `ioapic_read(0x19)`. One assertion:
  - B1: bits 24-31 (dest_apic_id field) == 0
  Rationale: verifies the HI write reached IOWIN via IOREGSEL
  and that the dest field position (bits 24-31) matches the
  Intel spec. Reading a separate register (0x19 vs 0x18) also
  incidentally verifies the IOREGSEL indirection works
  correctly — if IOREGSEL were broken and IOWIN always read
  register 0x00 (IOAPIC ID), sub-test A would pass by accident
  only if IOAPIC ID happened to have a low byte of 0x24 (never
  true — QEMU sets it to 0x0F00_0000 or similar).

**Why two sub-tests, not one, not four**. Two-sub-test structure
matches R16-M4-001 discipline (one sub-test) scaled up for the
two RTE halves. Would-be sub-test C (verify polarity=0, trigger=
0 by reading bits 13/15) is redundant — those bits are inside
the same LO word already verified by A; A2's mask-bit check is a
proxy for correct bit-position arithmetic in the LO word.

### 5.2 Witness assembly (complete block)

```asm
; ============================================================
; R16-M4-005 (#599): ioapic irq4 witness — 2 sub-tests
; ============================================================
;
; IOAPIC internal registers 0x18 (RTE #4 LO) and 0x19 (RTE #4 HI)
; encode the routing of ISA IRQ 4 to a CPU vector via IOREGSEL/IOWIN.
;
; After ioapic_irq4_init:
;   RTE #4 LO (0x18) = 0x00000024  (vector = 0x24, mask = 0, everything else 0)
;   RTE #4 HI (0x19) = 0x00000000  (dest APIC ID = 0 in bits 24-31)

ioapic_irq4_witness:
    push r12                                 ; callee-save: LO value survives A→B

    ; ---------- Program IRQ 4 → vec 0x24 → CPU 0 ----------
    call ioapic_irq4_init

    ; ---------- Sub-test A: RTE 4 LO ----------
    mov  rdi, 0x18                           ; RTE 4 LO register index
    call ioapic_read                         ; rax = LO value (32-bit zero-extended)
    mov  r12, rax                            ; save for A2

    ; A1: vector byte (bits 0-7) == 0x24
    mov  rcx, r12
    and  rcx, 0xFF
    cmp  rcx, 0x24
    jne  ioapic_irq4_witness_fail

    ; A2: mask bit (bit 16) == 0
    mov  rcx, r12
    shr  rcx, 16
    and  rcx, 1
    cmp  rcx, 0
    jne  ioapic_irq4_witness_fail

    ; ---------- Sub-test B: RTE 4 HI ----------
    mov  rdi, 0x19                           ; RTE 4 HI register index
    call ioapic_read                         ; rax = HI value (32-bit zero-extended)

    ; B1: dest_apic_id byte (bits 24-31) == 0
    shr  rax, 24
    and  rax, 0xFF
    cmp  rax, 0
    jne  ioapic_irq4_witness_fail

    ; --- All green ---
    lea  rdi, [rip + ioapic_irq4_ok_msg]
    call uart_puts
    jmp  ioapic_irq4_witness_done

ioapic_irq4_witness_fail:
    lea  rdi, [rip + ioapic_irq4_fail_msg]
    call uart_puts

ioapic_irq4_witness_done:
    pop  r12
```

Total: ~48 lines including labels, comments, and blank lines.
~28 lines of instructions.

**Label uniqueness**. All labels prefixed `ioapic_irq4_witness_*`
— disjoint from every prior R16.M4 witness label.

**Register discipline**. r12 is SysV callee-save. Pushed at
entry to preserve outer kernel_main value; popped at exit. r12
holds the LO read-back value across the two A sub-assertions
(A1 clobbers rcx; A2 needs the value again — reads it from r12).
`uart_puts` does not touch r12 (SysV callee-save discipline
preserved by every prior witness).

**No nested `sub rsp, 8` needed**. On entry to
`ioapic_irq4_witness`, SysV alignment gives rsp%16 == 8. One
`push r12` shifts to rsp%16 == 0. The four nested calls
(`ioapic_irq4_init`, `ioapic_read` x 2, `uart_puts`) each need
rsp%16 == 8 at entry — which is the ABI convention for CALL from
a properly-aligned caller. But we're at rsp%16 == 0 after the
push, so `call` will push RIP (8 bytes) making rsp%16 == 8 at
callee entry. Correct. Same discipline as R16-M4-004 witness at
kernel_main.pdx:3884-3885.

### 5.3 Marker

On both sub-tests green:

```
R16 IOAPIC IRQ4 OK
```

Emitted via `uart_puts` on `ioapic_irq4_ok_msg`. Marker added to
all three R14B/R15 expected-output files, inserted immediately
after `R16 IDT VEC24 OK`.

### 5.4 String data — `tools/boot_stub.S`

Append after the last-landed R16.M4-004 witness strings (after
line 732):

```asm
# R16-M4-005 (#599): ioapic irq4 witness success message
.global ioapic_irq4_ok_msg
.align 8
ioapic_irq4_ok_msg: .ascii "R16 IOAPIC IRQ4 OK\n\0"

# R16-M4-005 (#599): ioapic irq4 witness failure message
.global ioapic_irq4_fail_msg
.align 8
ioapic_irq4_fail_msg: .ascii "R16 IOAPIC IRQ4 FAIL\n\0"
```

Single-line failure message per R16.M4 discipline. Two sub-tests
share one FAIL marker; operator inspects source (or QEMU
monitor / gdb `x/2wx 0xFEC00000` after triggering the IOAPIC to
select register 0x18 then 0x19) to see which sub-test caught the
failure.

### 5.5 Fingerprint files — marker insertion

Insert `R16 IOAPIC IRQ4 OK` in three files:

| File                                        | Insert after            | Insert before          |
|---------------------------------------------|-------------------------|------------------------|
| `tests/r14b/expected-boot-r14b-loader.txt`  | `R16 IDT VEC24 OK`      | `LOADER OK`            |
| `tests/r15/expected-boot-r15-ring3.txt`     | `R16 IDT VEC24 OK`      | `R15 IDLE TASK OK`     |
| `tests/r15/expected-boot-r15-process.txt`   | `R16 IDT VEC24 OK`      | `R15 IDLE TASK OK`     |

Contains-in-order matching makes the addition strictly additive.
5-mode smoke stages that do not observe R16 markers
(`boot_r8_only`, `boot_r10`, `boot_r11`, `boot_r12`,
`boot_r12_denial`) stay byte-identically green.

## 6. Alternatives considered / follow-ups

### 6.1 Verify RTE by re-reading via a different mechanism (e.g., QEMU monitor)

**Rejected**. The witness discipline is in-guest, self-contained,
and repeatable in CI. QEMU-monitor introspection of IOAPIC state
requires an out-of-band tool (`info ioapic`) not integrated into
the smoke harness. Read-back via `ioapic_read` exercises the same
`ioapic_write` code path in reverse — proves the round-trip.

### 6.2 Mask=1 program, verify, unmask=0 re-program, verify

**Rejected**. Two-phase mask discipline is used at runtime (e.g.,
Linux masks an IRQ during handler setup, then unmasks) to avoid a
race where the handler runs before it's registered. This issue's
programming happens with LAPIC disabled and IF=0 — no race
window exists. The single-phase unmasked write is safe and
minimal.

### 6.3 Program IRQs 0-23 in a loop (route everything sensible)

**Rejected — belongs in a future device-driver-plane issue.**
Only IRQ 4 has a wired handler at R16.M4 (`_uart_rx_trampoline`
at slot 0x24 from #598). Routing IRQ 1 (keyboard) or IRQ 12
(mouse) with no handler in place would route to the default
IDT stub — first delivery #GPs. Wait for R17+ keyboard driver
before adding IRQ 1 routing. `ioapic_route_irq` is already the
generic primitive; adding more IRQs is a one-line diff per IRQ.

### 6.4 Combine with #598 into a single "IDT + IOAPIC" PR

**Rejected. Same rationale as #598 §6.2**: keep each issue's
regression surface minimal. #598 verifies IDT gate presence;
#599 verifies IOAPIC RTE contents. Merging would mean a
witness failure could be either IDT wire or IOAPIC RTE, with
no bisect boundary between them.

### 6.5 Move the ioapic.pdx stubs to a "graveyard" file rather than delete

**Rejected**. The three stubs (`stub_ioapic_set_redir`,
`stub_ioapic_mask`, `stub_ioapic_unmask`) have zero callers and
zero external references — verified by grep across `src/`. Dead
code with no compatibility contract; deletion is safe and
reduces cognitive load for future readers. `git blame` and git
history preserve the stub definitions for archaeology.

### 6.6 Emit `R16 IOAPIC IRQ4 OK` from inside `ioapic_route_irq`

**Rejected**. Same discipline as every prior R16 subsystem: the
primitive is silent, the witness emits. Printing from
`ioapic_route_irq` would cause R17+ device-driver reuse to also
spam the console — destroys UX.

### 6.7 Add a helper `ioapic_mask_irq(irq)` / `ioapic_unmask_irq(irq)` in this issue

**Deferred**. Mask/unmask is a read-modify-write of the LO
register's bit 16. Legitimate future need (interrupt storm
mitigation, driver-side quiesce), but not on the R16.M4 critical
path — the UART driver's mask state is set once at boot to
unmasked and stays that way. When the first level-triggered IRQ
or the first driver quiesce path lands (R17+), add both helpers
in one PR alongside their first caller.

### 6.8 Include ioapic_route_irq call inside pic_mask_all

**Rejected**. Two unrelated concerns: pic_mask_all silences the
legacy 8259 controller; ioapic_route_irq programs the modern
IOAPIC RTE. Merging them creates a superset function that
conflates responsibilities. Sequential calls from kernel_main
preserve the separation.

### 6.9 Set IOAPIC ID (register 0x00) explicitly

**Rejected — irrelevant**. The IOAPIC ID field (register 0x00
bits 24-27) is used only for legacy APIC bus arbitration on
pre-P4 systems with a real APIC bus. On memory-mapped IOAPIC
(QEMU, ICH), the field is informational only. Firmware initializes
it and we do not need to touch it. Reading it in a fourth
sub-test would add coverage of one more register but wouldn't
strengthen the IRQ 4 routing test.

### 6.10 Verify that RTE reads for IRQs 0-3 and 5-23 are still in default (masked) state

**Rejected**. The IOAPIC RTE default state (all 24 entries) is
mask=1, vector=0, per Intel §3.2.4 power-on defaults. QEMU
initializes accordingly. Verifying the state of 23 other RTEs
would be busywork — the concern is IRQ 4's programming, not the
other 23's untouched-ness. If future issues program more RTEs
and need cross-RTE isolation proofs, add per-issue witness at
that time.

## 7. Risk log

### 7.1 IOAPIC MMIO window not identity-mapped

**Impact**: `mov [0xFEC00000], edi` traps #PF; kernel_main
never returns from `call ioapic_write`.

**Likelihood**: Very low. The boot page-table setup covers
[0xFE000000, 0xFF000000) as identity-mapped, strong-uncacheable
— same window class as LAPIC (0xFEE00000) which is exercised by
every existing `apic_eoi` call from timer interrupts,
`apic_svr_enable` at line 3965 (which runs AFTER this issue's
witness but proves the LAPIC MMIO window works), and every IPI.

**Detection**: sub-test A fails with a #PF exception message
before the OK marker is emitted. Boot halts.

**Mitigation**: if the failure surfaces, the fix is at the
boot page-table setup site (identity-map 0xFEC00000). Zero
concern for QEMU/KVM.

### 7.2 IOAPIC access widths — silent corruption on non-32-bit access

**Impact**: `mov [rax], rcx` (64-bit store) would attempt to
write both IOREGSEL and the pad word at offset +0x04 in one
transaction. On QEMU this is silently tolerated; on real
hardware, per Intel 82093AA §3.2.1, it's undefined behavior
that might disturb the IOREGSEL selection.

**Likelihood**: Zero at this landing — every store in this
issue's code is `mov [rax], edi` or `mov [rax + 0x10], esi`
(32-bit).

**Detection**: witness reads would return unexpected values;
sub-test A or B fails.

**Mitigation**: code review discipline. paideia-as emits the
`ecx`/`edi`/`esi` variants (32-bit source) via `MOV r/m32, r32`
opcode 0x89 — encoder-verifiable at CI time.

### 7.3 GSI mapping — IRQ 4 → GSI X override

**Impact**: on a hypothetical MADT with an Interrupt Source
Override entry (`type=2`) declaring IRQ 4 → GSI 0x11 (for
example), the RTE we need to program is `0x10 + 0x11*2 = 0x32`,
not `0x18`. Our hard-coded IRQ-4-to-GSI-4 assumption would
program the wrong RTE — silently, since the write to RTE 4
would succeed but the actual IRQ 4 wire lands on GSI 0x11's
input. `uart_rx_isr` would never fire.

**Likelihood**: **Zero on QEMU q35/pc and every PC-compatible
chipset in wide use.** ISA IRQs 0-15 identity-map to GSIs 0-15
by convention with the singular exception of IRQ 0 (PIT) which
some BIOSes map to GSI 2 via override. IRQ 4 (COM1) is never
overridden.

**Detection**: witness passes (RTE 4 is correctly programmed
per what we asked for), but end-to-end #601 fails
(byte injection produces no IRQ 4 delivery).

**Mitigation**: at R17+ when `core/acpi/madt.pdx` is
implemented, `ioapic_irq4_init` grows a MADT-consult step that
resolves IRQ 4's actual GSI. Until then, this is a documented
assumption. Non-QEMU hardware bring-up is out of scope for
R16.M4.

### 7.4 Multiple IOAPICs on multi-socket systems

**Impact**: high-end multi-socket systems have >1 IOAPIC, each
covering a range of GSIs. Programming only the IOAPIC at
0xFEC00000 leaves IRQs in other GSI ranges unrouted.

**Likelihood**: Zero on QEMU (single IOAPIC per emulated
platform).

**Detection**: end-to-end failure at #601 on multi-IOAPIC
hardware — the RTE at 0xFEC00000 is programmed correctly, but
if IRQ 4 maps to a GSI in the second IOAPIC's range, our
programming misses.

**Mitigation**: R17+ MADT walker discovers all IOAPICs and
their GSI-base ranges; `ioapic_route_irq` grows an initial
GSI-to-IOAPIC-base lookup. Deferred; not blocking R16.M4.

### 7.5 IOAPIC not memory-mapped (obsolete APIC bus)

**Impact**: on pre-1998 dual-Pentium systems, IOAPICs live on
a dedicated APIC bus and are not memory-mapped. Our
`mov [0xFEC00000], edi` traps #PF or writes to unrelated MMIO.

**Likelihood**: Zero. paideia-os targets x86_64 (2003+); every
supported chipset uses memory-mapped IOAPIC.

**Detection**: same as §7.1.

**Mitigation**: N/A — target-platform boundary.

### 7.6 Encoder gap for `mov [rax + 0x10], esi` (register-plus-imm8 with esi source)

**Impact**: paideia-as fails to encode; build breaks.

**Likelihood**: Very low. `mov [rax + N], reg` with 32-bit
source has been emitted since R11 for e.g. `mov [rax], ecx` at
apic_eoi:37, and `mov [rax + N], reg` with 64-bit source is
proven at fs/path.pdx and many places. The specific combination
`[rax + 0x10], esi` requires no new encoder path.

**Detection**: paideia-as compile-time error.

**Mitigation**: cross-repo escalation (paideia-as issue +
workerbee fix + submodule bump), per project discipline. Would
delay the R16.M4-005 landing by one workerbee round-trip. Do
NOT observed — expected to compile cleanly first try.

### 7.7 QEMU vs real-hardware timing — MMIO write reordering

**Impact**: QEMU serializes MMIO writes in program order per
CPU. Real hardware with weakly-ordered stores could theoretically
reorder the `mov [rax], edi` (IOREGSEL) with the
`mov [rax + 0x10], esi` (IOWIN), causing the IOWIN write to
target the wrong internal register.

**Likelihood**: Very low on x86 — the TSO memory model
guarantees store-store ordering within a single CPU, and MMIO
stores to the same page are serialized per Intel SDM Vol 3A
§11.3.1 "Uncacheable (UC) — accesses are serialized by the
processor". IOAPIC MMIO is UC-classed by the boot PAT.

**Detection**: sub-test A fails intermittently in real hardware
tests (never in QEMU).

**Mitigation**: if observed post-R17+ hardware bring-up, add
`mfence` between IOREGSEL and IOWIN writes. Not needed at
R16.M4; documented for future reference.

## 8. Expected output fingerprint additions

**Insert into all three fingerprint files** (r14b-loader, r15-ring3,
r15-process) immediately after `R16 IDT VEC24 OK` and before the
next R15/loader marker:

```
R16 IDT VEC24 OK
R16 IOAPIC IRQ4 OK     <-- INSERTED
LOADER OK              (r14b) or R15 IDLE TASK OK (r15)
```

Contains-in-order semantics — the addition is strictly additive
and does not perturb ordering of subsequent markers.

## 9. Post-landing followups (deferred to explicit issues)

1. **#600**: `uart_rx_notification_cap` — wire ring → notification
   cap → user wake-up. Composes with this issue to complete the
   producer/consumer chain.
2. **#601**: RX smoke — stdin injection AC. First live IRQ 4
   delivery. If it fails, either #598 (IDT trampoline) or #599
   (this issue's IOAPIC routing) is at fault; bisect via QEMU
   monitor `info ioapic` and `info idt`.
3. **R17+ MADT walker**: implement `core/acpi/madt.pdx` for
   dynamic IOAPIC base discovery + Interrupt Source Override
   parsing. `ioapic_irq4_init` grows a MADT-consult step at
   that time.
4. **R17+ IOAPIC mask/unmask helpers**: `ioapic_mask_irq(irq)`
   / `ioapic_unmask_irq(irq)` for driver-side quiesce.
5. **R17+ multi-IOAPIC**: iterate over all IOAPICs discovered by
   MADT walker; route each GSI to its owning IOAPIC.
6. **R17+ keyboard driver (IRQ 1 → vec 0x21)**: reuses
   `ioapic_route_irq` as the primitive. First non-UART caller.
7. **R17+ ring-3-safe UART trampoline**: coordinated
   ring-3-CS-check + swapgs added to `_uart_rx_trampoline`,
   `trampoline_vec32`, and all IPI trampolines in one PR (see
   #598 §6.5).

---

**Doc footer**: cross-referenced from `r14b-tactical-plan.md`
Subsystem 14 item 5. Reviewed against every ordering constraint
in kernel_main.pdx (§4.2). Encoder gap set: **empty**. Ready to
land.
