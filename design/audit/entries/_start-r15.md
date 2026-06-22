---
audit_id: _start-r15
issue: 269
file: src/kernel/boot/entry.pdx
function: _start
effects: [sysreg]
capabilities: []
reviewed_by: Santiago
date: 2026-06-21
---

# AUDIT _start-r15 — _start long-mode entry (R1.5-004)

## Justification

_start orchestrates the 32-bit protected mode to 64-bit long mode transition.
Entry point loaded by QEMU via -kernel at 1 MiB (link.ld pinned address).
Upon entry: 32-bit protected mode, GDT loaded, paging disabled.

### 9-Step Long-Mode Entry Sequence

Per Intel SDM Vol 3A §9.8.5, steps in order:

1. **cli** — Disable maskable interrupts (privileged instruction)
   - Byte: 0xfa

2. **lgdt [gdt_ptr]** — Load GDT with 64-bit code/data segment descriptors
   - GDT layout: null, 64-bit code (0x08), 64-bit data (0x10), 32-bit code (for 16-bit calls)
   - Byte: 0x0f 0x01 0x15 (+ addr) — lgdt near operand

3. **mov cr4, rax** (PAE bit set) — Enable Physical-Address-Extension
   - Caller pre-loads RAX with 0x20 (CR4 |= PAE, bit 5)
   - Bytes: 0x0f 0x22 0xe0 — mov cr4, rax

4. **mov cr3, rdi** (PML4 base) — Load page-table root
   - Caller pre-loads RDI with PML4 base address
   - Bytes: 0x0f 0x22 0xdf — mov cr3, rdi

5. **wrmsr** — Set EFER.LME via MSR write
   - Caller pre-loads:
     - ECX = 0xC0000080 (EFER MSR index)
     - EDX:EAX = EFER value with LME (bit 8 = 0x100)
   - Bytes: 0x0f 0x30 — wrmsr

6. **mov cr0, rax** (PG|PE bits) — Enable paging + protected mode
   - Caller pre-loads RAX with 0x80000001 (CR0 |= PG|PE, bits 31+0)
   - Bytes: 0x0f 0x22 0xc0 — mov cr0, rax

7. **ljmp 0x08:long_mode_entry** — Far-jump to 64-bit code segment
   - Selector 0x08 (64-bit code), offset = long_mode_entry symbol address
   - Bytes: 0xea (seg:offset, 7 bytes total)
   - Flushes pipeline, enforces 64-bit decode

8. **[long_mode_entry label]** — 64-bit code begins here
   - call kernel_main_64 — Invoke 64-bit kernel main function
   - Bytes: 0xe8 (rel32 call, 5 bytes)

9. **loop { hlt }** — Infinite halt loop
   - hlt: 0xf4 (halt until interrupt)
   - jmp $ (or jmp -1): 0xeb 0xfe (2-byte relative jump)
   - Loop infinitely or fall back to cli+hlt

### Caller Discipline (Register Pre-Load)

Per x86-64 ABI, caller arranges values in:
- **RDI**: PML4 (page-table) base address
- **RSI**: GDT address (or GDT descriptor ptr for lgdt [rsi])
- **RAX**: CR4 value with PAE bit (0x20)
- **RCX**: EFER MSR index (0xC0000080)
- **RDX:EAX**: EFER value with LME (bit 8)

Full x86-64 context setup (GDT, paging tables, EFER) provided by
prior bootloader phases (multiboot, UEFI, etc.) or bootstrap code.

## Implementation Status (R1.5-004)

**Honest scope:** paideia-as 0.6.0 does not support:
- Zero-operand instructions: cli, hlt (parser fires U1606)
- Far-jump: ljmp m16:64 (syntax not in resolver table)
- Control-flow: Unconditional jmp for loop (m4-002 pending)

**Current:** Placeholder (mov rax, rax). Demonstrates:
- sysreg effect signature (privileged instructions)
- Cross-module linkage to kernel_main_64 (future call site)
- Documentation of full 9-step sequence

**Full byte-emit** deferred to paideia-as Phase 5:
- m2-002: Zero-operand instruction encoder (cli, hlt, nop)
- m4-010: Far-jump ljmp m16:64 encoder
- m4-002: Unconditional jmp for loops

## Blocking Issues

- paideia-as #713: Zero-operand instruction parsing (cli, hlt) in unsafe blocks — m2-002
- paideia-as #727: Far-jump ljmp m16:64 encoder — m4-010
- paideia-as #706: Unconditional jmp for loops — m4-002

## Mnemonic Encoding Status

| Instruction | Opcode | Encoder | Status |
|---|---|---|---|
| cli | 0xfa | m2-002 | **Deferred** (U1606 parser error) |
| lgdt [addr] | 0x0f 0x01 0x15 + disp | m3-004 | **Deferred** (mem-read operand) |
| mov cr4, rax | 0x0f 0x22 0xe0 | m2-012 | **Deferred** (cr4 not in resolver) |
| mov cr3, rdi | 0x0f 0x22 0xdf | m2-011 | **Deferred** (cr3 not in resolver) |
| wrmsr | 0x0f 0x30 | m2-013 | **Deferred** |
| mov cr0, rax | 0x0f 0x22 0xc0 | m2-010 | **Deferred** (cr0 not in resolver) |
| ljmp 0x08:addr | 0xea + ... | m4-010 | **Deferred** |
| call kernel_main_64 | 0xe8 + rel32 | PA7-002 | **Available** (cross-module call) |
| hlt | 0xf4 | m2-002 | **Deferred** |

## Cross-Module Linkage

_start will call kernel_main_64 (defined in kernel_main.pdx). paideia-as PA7-002
(inter-function calls) is available; full integration pending completion of above encoders.

Expected relocation: R_X86_64_PLT32 kernel_main_64 + 0 at call site.

## Next Steps (Priority Order)

1. **Zero-operand instructions (paideia-as #713, m2-002):** cli, hlt, nop parsing
   - Est. 1 week. Unblocks basic control-flow in kernel entry.

2. **Control registers (m2-010..013):** mov cr0/cr3/cr4 encoders
   - Est. 2 weeks. Prerequisite for paging + long-mode setup.

3. **Memory-read operand (paideia-as #708, m3-004):** lgdt [addr], lidt [addr]
   - Est. 2-3 weeks. Required for table loads.

4. **Far-jump (paideia-as #727, m4-010):** ljmp m16:64 syntax + encoding
   - Est. 1-2 weeks. Unblocks 32->64 segment switch.

5. **Unconditional jmp (m4-002):** jmp $ loop
   - Est. 1 week. Used for halt loops.

## Citation

Intel SDM Vol 3A, Section 9.8.5 (Initializing IA-32e Mode)
Intel SDM Vol 3A, Section 5.3 (Control Registers)
x86-64 ABI: Caller-saved registers, long-mode operation
