---
audit_id: r13-m4-002-tss-install
issue: 424
file: src/kernel/core/int/tss.pdx
function: tss_install
effects: [sysreg, mem]
capabilities: [boot]
reviewed_by:
date: 2026-07-03
---

# AUDIT r13-m4-002 — TSS structure + RSP0 + IST fields + ltr (R13-m4-002)

## Overview

`tss_install` populates a Task State Segment (TSS) in kernel BSS, installs a 64-bit TSS
descriptor in GDT slots 6–7 (selector 0x30), and loads the task register via `ltr 0x30`.
The TSS is a privileged CPU structure that:

1. **RSP0 field** — used by CPU during ring-3→ring-0 transitions to fetch the kernel stack pointer.
2. **IST1..IST3 fields** — Interrupt Stack Table indices, used by CPU to switch to dedicated
   exception stacks (for #DF, #NMI, #MC exceptions) without relying on the ring-3 stack.
3. **IOMAP_DISABLED** — I/O permission bitmap base (deferred to future work; set to 104 to disable).

**Dependency**: This issue depends on:
- R13-m4-001 (#423): GDT real install (slots 6–7 reserved, must precede tss_install).
- R13-m4-003 (#425): IST stacks (kernel BSS allocation for _ist1..ist3_stack).

**CRITICAL FIX**: After m4-001 (GDT load), CPU has code64 at 0x08 but no TSS loaded.
A ring-3→ring-0 transition (e.g., via `syscall`) would use CPU's cached IOPL=0 to
suppress user-stack memory access, but without RSP0 in the TSS, the CPU has no
kernel stack pointer and will fault or use undefined state. m4-002 fixes this by
populating RSP0 (and IST fields) and loading the TSS selector into TR.

## TSS layout (x86-64 64-bit mode)

The TSS is a 104+ byte structure. For m4-002, we allocate 13 u64s (104 bytes) in kernel BSS.

| Offset | Size | Field            | Value (m4-002)                | Purpose                                  |
|--------|------|------------------|-------------------------------|------------------------------------------|
| +0     | 4    | reserved         | 0                             | Intel SDM reserved field                 |
| +4     | 8    | RSP0             | kernel_stack_top() result     | Ring-0 stack ptr for ring-3→ring-0       |
| +12    | 8    | RSP1             | 0                             | Ring-1 stack ptr (unused, privileged)    |
| +20    | 8    | RSP2             | 0                             | Ring-2 stack ptr (unused, privileged)    |
| +28    | 8    | reserved         | 0                             | Intel SDM reserved                       |
| +36    | 8    | IST1             | ist1_top() result (&_ist1_stack + 16384) | #DF (double fault) stack   |
| +44    | 8    | IST2             | ist2_top() result (&_ist2_stack + 16384) | #NMI (NMI) stack           |
| +52    | 8    | IST3             | ist3_top() result (&_ist3_stack + 16384) | #MC/#PF (machine-check) stack |
| +60    | 8    | IST4..IST7       | 0                             | Reserved (unused)                        |
| +96    | 2    | IOMAP_BASE       | 0x68 (104 in LE u16 at [98:99]) | I/O bitmap disabled                      |
| +104+  | ...  | bitmap           | (not used)                    | I/O permission bitmap (deferred)         |

### TSS Descriptor (64-bit mode)

A 64-bit TSS descriptor spans 16 bytes (2 u64s):

**Slot 6 (bytes 0–7)**:
```
bits [0:15]   = TSS limit (0x67 = 103, covering 0–103 bytes)
bits [16:39]  = base[23:0]
bits [40:47]  = type_attr = 0x89 (P=1, DPL=0, S=0 for system, Type=9=64-bit TSS available)
bits [48:51]  = limit_hi (0x0, no extra bits)
bits [52:55]  = flags (0x0)
bits [56:63]  = base[31:24]
```

**Slot 7 (bytes 8–15)**:
```
bits [0:31]   = base[63:32]
bits [32:63]  = reserved (0x0)
```

Together, slots 6+7 define the full 64-bit base address and 16-bit limit of the TSS.

## Kernel RSP0 stack

The kernel stack for RSP0 is allocated as `_kernel_stack[2048]` u64s = 16384 bytes, 16-byte
aligned (x86-64 SysV ABI requires RSP to be aligned to 16-byte boundary before function entry).

Stack grows downward; RSP0 is set to `&_kernel_stack + 16384` (top of stack).

## IST stacks

Three IST stacks are defined in the Ist module (issue #425):

- `_ist1_stack[2048]` = 16384 bytes (for #DF handler)
- `_ist2_stack[2048]` = 16384 bytes (for #NMI handler)
- `_ist3_stack[2048]` = 16384 bytes (for #MC/#PF handler)

Each stack top is computed via `ist{1,2,3}_top()` functions in the Ist module.

## IOMAP_BASE encoding

The IOMAP_BASE field (at TSS byte offset 102) indicates the start of the I/O permission
bitmap. When IOMAP_BASE >= limit (here, 104 >= 103), the CPU treats the bitmap as disabled
and permits all I/O instructions in any ring (when IOPL allows). In m4-002, we disable
the bitmap entirely to avoid adding a bitmap structure. Future work may enable per-port
I/O permission tracking via IOMAP.

**Encoding caveat**: IOMAP_BASE is a u16 at bytes 102–103. In little-endian:
- Byte 102 (LE LSB) = 0x68 (104 & 0xFF)
- Byte 103 (LE MSB) = 0x00 (104 >> 8)

Since 104 fits in a u8, the full u16 is 0x0068 in memory (LE). This is packed via
qword at offset 96 by clearing bits [48:63] and or-ing in 0x0068000000000000:

```
mov rcx, [tss + 96]              // Read qword at offset 96
mov rdx, 0xFFFFFFFF0000FFFF      // Mask to clear bits [48:63]
and rcx, rdx
mov rdx, 0x0068000000000000      // Pack 0x68 at bits [48:63]
or  rcx, rdx
mov [tss + 96], rcx
```

## Call sequence and ordering

In `kernel_main.pdx`:

```
call gdt_install;                // ← m4-001: populate slots 0–5, zero slots 6–7
call idt_install;                // ← m9-m1-002: load IDT with IST field rewiring (m4-004)
call tss_install;                // ← m4-002: populate TSS, write GDT slots 6–7, ltr 0x30
lea rdi, [rip + tss_ok_msg];      // ← Output "TSS OK\n"
call uart_puts;
call smep_enable;                // ← m3-003: continue with protection bits
```

**CRITICAL RACE WINDOW** (m4-002 to m4-004):
Between `tss_install` (which loads the TSS selector into TR) and `idt_install`'s
`idt_apply_ist_fields` (which rewires IDT entries to use IST1..3), there is a race
window in which:

1. TSS is loaded with RSP0 (for ring-3→ring-0 transitions).
2. IDT entries may still have IST=0 (no stack switch).
3. If an exception fires (e.g., #DE from user mode), the CPU switches to RSP0 but
   the IDT handler doesn't use a dedicated IST stack.

**MITIGATION**: This is NOT a correctness bug in m4-002. The race is present only
during boot (single-threaded, no user-mode code running). IDT entries are marked as
IST=0 (safe, uses RSP0 for stack switch). A future issue (m4-004) rewires exception
vectors 8, 14, 2, 18 to use IST1..3, which hardens the stacks further (enabling
recovery from stack-overflow exceptions).

## Byte-exact TSS descriptor construction

The function assembles the TSS descriptor via:

1. **Slot 6 computation**:
   - Extract base[23:0] from &_tss: `rcx = base & 0xFFFFFF`
   - Shift left by 16 bits: `rcx <<= 16`
   - Or in limit: `rcx |= 0x67` (103 = 0x67)
   - Shift access byte 0x89 left by 40: `rcx |= 0x89 << 40`
   - Extract base[31:24]: `rdx = (base >> 24) & 0xFF`
   - Shift left by 56: `rdx <<= 56`
   - Or into slot 6: `rcx |= rdx`
   - Store at GDT[48] (slot 6)

2. **Slot 7 computation**:
   - Extract base[63:32]: `rcx = base >> 32`
   - Store at GDT[56] (slot 7)

3. **Load TSS**:
   - `mov rax, 0x30` (selector for TSS at GDT[6:7])
   - `ltr ax` (privileged instruction; loads TR = 0x30, enables TSS)

## Verification of ltr instruction encoding

The x86-64 ltr instruction has encoding:
- Opcode: `0F 00 /3` (ModRM byte encodes register operand)
- For `ltr ax` (register operand): `0F 00 D8` (where D8 is ModRM 11 000 000 = register EAX)
- For `ltr [rdi]` (memory operand): `0F 00 37` (ModRM 00 000 111 = [RDI])

In objdump output for tss_install:
```
102097:	0f 00 d8             	ltr    %eax
```

The bytes `0F 00 D8` confirm correct encoding for `ltr eax` (note: `ltr ax` and `ltr eax`
share the same encoding; the operand size is 2 bytes for the selector in all modes).

## Cross-references

- **Issue**: #424 (R13-m4-002)
- **Precursor**: #423 (R13-m4-001, GDT real install with slots 6–7 reserved)
- **Precursor**: #425 (R13-m4-003, IST stack allocation in kernel BSS)
- **Related**: #426 (R13-m4-004, IDT IST field rewiring)
- **Related**: PA-R13-001 (paideia-as v0.12.0, ltr encoder support)
- **Audit**: `r13-m4-001-gdt-install.md` (GDT structure and boot CS32→CS64 fix)
- **Audit**: `r13-m4-003-ist-stacks.md` (IST stack allocation and accessors)
- **Audit**: `r13-m4-004-idt-ist-rewire.md` (IDT entry IST field rewiring)

## Acceptance criteria

- [x] `_kernel_stack[2048]` allocated, 16-byte aligned, in kernel BSS.
- [x] `_tss[13]` allocated, 16-byte aligned, in kernel core/int BSS.
- [x] `kernel_stack_top()` returns &_kernel_stack + 16384.
- [x] `tss_install()` zero-fills _tss (13 qwords).
- [x] `tss_install()` writes RSP0 at offset +4 via kernel_stack_top() call.
- [x] `tss_install()` writes IST1/IST2/IST3 at offsets +36/+44/+52 via ist{1,2,3}_top() calls.
- [x] `tss_install()` writes IOMAP_BASE = 104 (disabled) via qword mask+or at offset +96.
- [x] `tss_install()` constructs TSS descriptor (limit=103, access=0x89) in GDT slots 6–7.
- [x] `tss_install()` loads TR via `ltr 0x30` (paideia-as v0.12.0 ltr encoder).
- [x] Call inserted in `kernel_main.pdx` after `idt_install` and before `smep_enable`.
- [x] "TSS OK\n" message added to `tools/boot_stub.S` and printed after tss_install().
- [x] Build succeeds: `./tools/build.sh` completes without encoder errors.
- [x] No regressions in smoke tests (5-mode: boot_r8_only, boot_r10, boot_r11, boot_r12, boot_r12_denial).
- [x] Serial output shows "IDT OK\nTSS OK\nTASK A" sequence for boot_r10+.
- [x] Disassembly confirms `ltr %eax` encoding = 0F 00 D8 (per Intel SDM Vol 2B).

## Smoke fingerprint updates

Test fingerprint files updated to include "TSS OK\n" between "IDT OK\n" and "TASK A\n":

- `tests/r10/expected-boot-r10.txt` — added "TSS OK" at line 6.
- `tests/r11/expected-boot-r11.txt` — added "TSS OK" at line 6.
- `tests/r12/expected-boot-r12.txt` — added "TSS OK" at line 11.
- `tests/r12/expected-boot-r12-denial.txt` — unchanged (fingerprint shows denial window only).
- `tests/r8/expected-boot-*.txt` — unchanged (boot_r8_only does not reach tss_install).

All 5 modes pass smoke verification with contains-in-order fingerprint matching.

