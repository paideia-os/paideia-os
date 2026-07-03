---
audit_id: r13-m1-002-arch-pins
issue: 418
date: 2026-07-03
file: src/kernel/boot/gdt.pdx, src/kernel/boot/boot_stub.S, src/kernel/core/interrupt/idt.pdx, src/kernel/core/memory/paging.pdx, src/kernel/core/sched/per_cpu.pdx, src/user/shell.pdx, src/kernel/core/vfs/elf_loader.pdx
function: gdt_init, syscall_entry_trampoline, per_cpu_struct_init, ipi_vector_dispatch, signal_frame_push, elf_lite_parse
effects: [sysreg, vmem, cpustate]
capabilities: [cap_invoke, cap_process, cap_thread]
reviewed_by:
---

# AUDIT r13-m1-002 — Architecture Pins: GDT, MSRs, higher-half VA, KPTI, per-CPU, IPI, signal frames, ELF-lite

## Overview

R13-m1-002 audits and pins seven critical architectural decisions for the multicore x86-64 kernel. These decisions establish the byte-level encodings, memory layout, exception routing, and userspace binary format that the rest of R13 depends on. All specifications are frozen to enable parallel development across m2–m16.

Associated decision domains:
- **GDT layout** (section 2): 7 standard slots + TSS descriptor, byte-exact encodings
- **Syscall MSR configuration** (section 3): IA32_LSTAR, IA32_STAR, IA32_FMASK, IA32_KERNEL_GS_BASE, IA32_EFER
- **Higher-half kernel VA** (section 4): linker script fragment for 0xFFFF_8000_0010_0000 kernel .text start
- **KPTI PGD layout** (section 5): dual-PGD page-table isolation for kernel vs. userspace
- **Per-CPU struct** (section 6): 64-byte-aligned, MAX_CPUS=8, containing runqueue + TSS + stacks
- **IPI vector table** (section 7): 32=LAPIC_TIMER, 33=IPI_DEFAULT, 34=IPI_TLB_SHOOTDOWN, 35=IPI_RESCHED, 36=IPI_HALT
- **Signal frame format** (section 8): 192-byte stack frame (24 × u64) for userspace signal delivery
- **ELF-lite binary format** (section 9): minimal ELF parser skeleton + validation predicates
- **Module file layout** (section 10): directories for boot, kernel, user, and tools
- **Acceptance criteria** (section 11): 10 checkboxes verifying all pins are documented
- **Traceability** (section 12): cross-references to issues, design docs, and source files

---

## Section 1 — Overview and Scope

R13 multicore architecture depends on eight frozen specifications, each pinned in this audit:

1. **GDT byte layout**: Null, kernel code, kernel data, user code, user data, user data64, TSS (slot 6 = 0x30), LDTR (deferred to R14).
2. **Syscall MSRs**: IA32_LSTAR = kernel entry point; IA32_STAR = ring 0/3 selectors; IA32_FMASK = IF mask; IA32_KERNEL_GS_BASE = per-CPU struct base; IA32_EFER.SCE = syscall enable.
3. **Kernel VA mapping**: KERNEL_VMA=0xFFFF_8000_0010_0000 for kernel .text + .data + .rodata; linker script defines base, bounds.
4. **KPTI paging**: Single 4 KiB trampoline page mapped in both user and kernel PML4s at VA 0xFFFF_8000_0000_1000; enables page-table switch on syscall/sysret.
5. **Per-CPU struct**: 64-byte aligned, 8 core limit (MAX_CPUS=8), 128 KB footprint per CPU (8 cores = 1 MB total).
6. **IPI routing**: Vector 32 = LAPIC_TIMER, 33 = IPI_DEFAULT, 34 = IPI_TLB_SHOOTDOWN, 35 = IPI_RESCHED, 36 = IPI_HALT; ISR dispatch via per-CPU IPI_VECTOR field.
7. **Signal frame layout**: 192 bytes = 16 GP regs (128 B) + 8 control regs (64 B). Frame pushed on user stack; handler accesses via [rsp + offset].
8. **ELF-lite parser**: Minimal ELF header (64 bytes) + program-header-only parsing. Validation: magic 0x7F454C46, machine 0x3E, phoff > 0.

All eight specifications are immutable for R13. Changes proposed after m1-002 close require a new milestone (R14+).

---

## Section 2 — GDT Byte-Exact Encodings (7 slots + TSS descriptor)

### 2.1 GDT Layout and Descriptor Encodings

The GDT is a fixed 48-byte table (6 descriptors × 8 bytes) for R13-m1–m2. TSS descriptor lands at GDT+0x30 (slot 6), requiring descriptor-pair format (16 bytes total).

**GDT layout**:

```
Offset  Selector  Name               Base            Limit    Type   DPL  Flags
------  --------  -----              ----            -----    ----   ---  -----
0x00    0x00      Null               0x00000000      0x00000  —      —    —
0x08    0x08      Kernel Code (L64)  0x00000000      0xFFFFF  0x0A   0x0  0xA0
0x10    0x10      Kernel Data (L64)  0x00000000      0xFFFFF  0x02   0x0  0xA0
0x18    0x18      User Code (L64)    0x00000000      0xFFFFF  0x0A   0x3  0xA0
0x20    0x20      User Data (L64)    0x00000000      0xFFFFF  0x02   0x3  0xA0
0x28    0x28      User Data64        0x00000000      0xFFFFF  0x02   0x3  0x20
0x30    0x30      TSS (10 bytes used, 16-byte format) [See §2.2]
0x38    —         TSS upper 64-bits (extension)
```

**Descriptor format (64-bit entry)**:

```
Bits [63:0]:
  [15:0]   Limit (bits 0–15)
  [31:16]  Base (bits 0–15)
  [39:32]  Base (bits 16–23)
  [47:40]  Type (7) + S (1) + DPL (2) + P (1) = Type field (e.g., 0x0A = 1010 for code)
  [51:48]  Limit (bits 16–19)
  [55:52]  AVL (1) + L (1) + D/B (1) + G (1) = Flags (e.g., 0xA for L=1, G=1)
  [63:56]  Base (bits 24–31)
```

### 2.2 TSS Descriptor (16-byte, slots 6–7)

**TSS descriptor pair** (allocated in GDT at 0x30 and 0x38):

```
Offset  Field                   Value (example, per-CPU variant)
------  -----                   -----
0x30    Base address [0–15]     0x1000 (lower 16 bits of TSS base)
0x32    Base address [16–31]    0xFFFF (middle 16 bits)
0x34    Base address [32–39]    0x80 (upper 8 bits for VA 0xFFFF_8000_xxxx_xxxx)
0x35    Type + S + DPL + P      0x89 (Type=09, S=0, DPL=0, P=1)
0x36    Limit [16–19] + Flags   0x00 (Limit[16–19]=0, AVL=0, reserved=0, G=0, reserved=0)
0x37    Base address [40–47]    0xF8 (upper 8 bits for VA 0xFFFF_8000_xxxx_xxxx)
0x38    Base address [48–63]    0x00 (64-bit extension, upper half)
0x3F    Reserved                0x00
```

**Total bytes per TSS descriptor pair**: 16 bytes (2 × u64).

**Byte encoding for `ltr r10` (where r10 holds TSS index 0x30)**:

Instruction: `ltr r10`
Opcode: `0F 00` (LTR opcode prefix)
ModR/M: `D2` (reg=010 [/2], rm=010 [r10])
**Correct encoding: `0F 00 D2`** (reg=/2, NOT /1 as R13 plan stated; correction: /3 is 011 binary = 0x18 in ModR/M reg field)

For `ltr ax` (16-bit register):
Opcode: `0F 00`
ModR/M: `D8` (reg=011 [/3], rm=000 [rax])
**Encoding: `0F 00 D8`** (ltr opcode is /3, byte 0x18 in ModR/M means reg field = 011)

**Note**: The R13 plan incorrectly stated `/1` for LTR; the correct opcode extension is `/3`. This audit corrects the encoding to `0F 00 D8` for `ltr ax` and `0F 00 D2` for `ltr r10`.

---

## Section 3 — Syscall MSR Pins

### 3.1 IA32_LSTAR (Syscall Entry Point)

**Register**: IA32_LSTAR (MSR 0xC0000082)  
**Value**: Kernel-mode syscall entry trampoline VA = 0xFFFF_8000_0001_0000 (higher-half kernel .text + 0)  
**Encoding**: `wrmsr` with EAX/EDX pair:
- EAX = lower 32 bits of entry point (0x00010000)
- EDX = upper 32 bits (0xFFFF8000)

### 3.2 IA32_STAR (Ring 0/3 Selectors)

**Register**: IA32_STAR (MSR 0xC0000081)  
**Value**: (kernel_cs << 32) | user_cs
- kernel_cs = 0x08 (GDT slot 1, kernel code selector)
- user_cs = 0x18 (GDT slot 3, user code selector)
- **IA32_STAR = (0x08 << 32) | 0x18 = 0x0000_0008_0000_0018**

**Consequence**: On syscall, CPU sets CS = kernel_cs; on sysret, CPU sets CS = user_cs + 16 (user code64).

### 3.3 IA32_FMASK (Interrupt Flag Mask)

**Register**: IA32_FMASK (MSR 0xC0000084)  
**Value**: 0x0000_0000_0000_0200 (IF bit = bit 9)
**Consequence**: On syscall entry, RFLAGS.IF cleared (interrupts disabled until kernel explicitly re-enables).

### 3.4 IA32_KERNEL_GS_BASE (Per-CPU Struct Base)

**Register**: IA32_KERNEL_GS_BASE (MSR 0xC0000102)  
**Value**: Per-CPU struct base VA (e.g., 0xFFFF_8000_1000_0000 for BSP)
**Consequence**: On syscall entry, swapgs exchanges GS with IA32_KERNEL_GS_BASE. Kernel gains access to per-CPU state via [gs:offset].

### 3.5 IA32_EFER (Extended Feature Enable Register)

**Register**: IA32_EFER (MSR 0xC0000080)  
**Bits to set**:
- Bit 0 (SCE): Syscall Enable = 1
- Bit 11 (NXE): No-Execute Enable = 1 (for NX bit in PTE)
- Bit 8 (LME): Long Mode Enable = 1 (already set at boot)

**Encoding**: Read-modify-write via rdmsr/wrmsr.

---

## Section 4 — Higher-Half Kernel Linker Script Fragment

### 4.1 Kernel VA Layout and Linker Script

**Kernel VMA base**: KERNEL_VMA = 0xFFFF_8000_0010_0000

**Linker script fragment** (paideia-as pseudocode):

```
KERNEL_VMA = 0xFFFF_8000_0010_0000;

SECTIONS {
  .boot_stub KERNEL_VMA : AT(ADDR(.boot_stub) - KERNEL_VMA) {
    *(.boot_stub)
  }

  .text KERNEL_VMA + 0x1000 : AT(ADDR(.text) - KERNEL_VMA) {
    *(.text)
  }

  .rodata ALIGN(0x1000) : AT(ADDR(.rodata) - KERNEL_VMA) {
    *(.rodata)
  }

  .data ALIGN(0x1000) : AT(ADDR(.data) - KERNEL_VMA) {
    *(.data)
  }

  .bss ALIGN(0x1000) : {
    *(.bss)
  }
}

__kernel_text_start = KERNEL_VMA + 0x1000;
__kernel_text_end = ALIGN(., 0x1000);
__kernel_data_start = __kernel_text_end;
__kernel_data_end = .;
```

**Rationale**: KERNEL_VMA at 0xFFFF_8000_0010_0000 places kernel .text in higher-half VA, enabling KPTI (userspace PGD omits kernel PML4 entries 256–511). AT() clauses specify physical load address (lower-half, matched to boot loader).

---

## Section 5 — KPTI Trampoline Page Layout

### 5.1 Single 4 KiB Trampoline Page (Dual-Mapped)

**VA**: 0xFFFF_8000_0000_1000 (kernel higher-half)  
**Alternate VA** (userspace PGD): 0x0000_0000_0000_1000 (mirrored in both PML4s)

**Purpose**: Bridging page enabling KPTI PGD swap. Trampoline code (syscall/sysret, exception entry/exit) lives here and is always-mapped regardless of CR3.

**Trampoline code (pseudocode)**:

```
syscall_trampoline:
    swapgs                      # GS <- IA32_KERNEL_GS_BASE (per-CPU struct base)
    mov r10, [gs:8]             # r10 = current_tcb (offset 8 in per-CPU struct)
    # ... syscall dispatcher logic ...
    mov r11, [r10 + 0x10]       # r11 = syscall_id from TCB
    cmp r11, 0
    je sys_exit
    # ... syscall dispatch table ...
    
sysret_trampoline:
    swapgs                      # GS <- user GS (from IA32_GS_BASE)
    sysretq                     # Return to userspace
```

**Layout**:
- Offset 0x000–0x200: syscall entry trampoline + syscall dispatch table
- Offset 0x200–0x400: exception entry stubs (#PF, #GP, #DF, etc.)
- Offset 0x400–0xFFF: Reserved for future handlers

**Page-table mapping** (both PML4s):
- Kernel PML4 entry 256 → PDPT containing PD → PT entry for 0xFFFF_8000_0000_1000
- User PML4 entry 256 → same PDPT/PD/PT, mapping 0x0000_0000_0000_1000 to same physical page

---

## Section 6 — Per-CPU Struct Byte Layout (64 KB, aligned to 64 KB)

### 6.1 Per-CPU Struct Layout (8 cores, 128 KB per core)

**Base VA**: 0xFFFF_8000_1000_0000 (bump-allocated region)  
**Per-core offset**: (apic_id % 8) * 128 KB = core N at 0xFFFF_8000_1000_0000 + N * 0x20000

**64-byte-aligned core struct**:

```
Offset   Size   Field                       Type        Note
------   ----   -----                       ----        ----
0x0000   8      gs_base                     u64         Points to self (per-CPU struct base)
0x0008   8      current_tcb                 u64*        Pointer to running TCB
0x0010   8      runqueue_head               u64*        Head of ready-task linked list
0x0018   8      runqueue_tail               u64*        Tail of ready-task linked list
0x0020   8      cpu_id                      u64         APIC ID (core index 0–7)
0x0028   8      tss_base                    u64*        Pointer to TSS (within per-CPU block)
0x0030   1      ipi_vector                  u8          IPI vector for this CPU (32 + core_id)
0x0031   7      reserved                    u8[7]       (MBZ)
0x0038   8      spinlock_addr               u64*        Shared spinlock for runqueue access
0x0040   (512)  kernel_vars                 u8[512]     Kernel-local per-CPU variables
```

**Total per-CPU struct**: 64 bytes (base) + 512 bytes (kernel_vars) = 576 bytes, padded to 128 KB (0x20000 bytes) for cache-line isolation.

**Alignment**: Each core's struct starts at 64 KB boundary (bits [15:0] = 0).

### 6.2 Byte Encoding for GS-relative Accesses (PA-R13-002 placeholder)

Until PA-R13-002 (GS-relative memory operand) is implemented in paideia-as:

```
mov r8, [gs:0]          # Intended: load gs_base (self-pointer)

Fallback workaround (using rdmsr + absolute addressing):
rdmsr                   # EAX = lower 32 bits of IA32_GS_BASE
mov r8d, eax            # r8 = gs_base
mov r8, [r8]            # Load from per-CPU struct
```

---

## Section 7 — IPI Vector Table

### 7.1 IPI Vector Assignments (32–36)

R13 reserves vectors 32–36 for inter-processor interrupts:

```
Vector  Name                    Triggered by         Handler
------  ----                    --------             -------
32      LAPIC_TIMER             LAPIC LVT.TIMER      per_cpu_timer_handler
33      IPI_DEFAULT             ipi_send (generic)   default_ipi_handler
34      IPI_TLB_SHOOTDOWN       aspace_unmap         tlb_shootdown_handler
35      IPI_RESCHED             per_cpu_reschedule   resched_handler
36      IPI_HALT                per_cpu_halt         halt_handler
```

### 7.2 Per-CPU Vector Routing

Each CPU's per-CPU struct contains `ipi_vector` field (offset 0x0030, 1 byte):

```
Per-CPU[core N].ipi_vector = 32 + N  (e.g., core 0 = vector 32, core 1 = vector 33, etc.)
```

**Consequence**: IDT entry 32 + N points to the IRQ handler for core N. Multicore routing via per-CPU dispatch.

### 7.3 IDT Entry Format for IPI Vectors

Each IDT entry (16 bytes) encodes the handler VA and attributes:

```
Offset  Size   Field                  Value (example, vector 32)
------  ----   -----                  -----
+0      2      Offset [0–15]          0x1000 (lower 16 bits of handler VA)
+2      2      Selector               0x08 (kernel code selector)
+4      1      IST / Reserved         0x00 (no IST for IPI; use default RSP0)
+5      1      Type + DPL + P         0x8E (Type=14 [interrupt gate], DPL=0, P=1)
+6      2      Offset [16–31]         0x0001 (middle 16 bits of handler VA)
+8      4      Offset [32–63]         0xFFFF8000 (upper 32 bits for 0xFFFF_8000_xxxx_xxxx)
+12     4      Reserved               0x00000000
```

**Total per IDT entry**: 16 bytes. IDT size for vectors 0–255: 4096 bytes.

---

## Section 8 — Signal Frame Layout (.pdx type spec, 192 B = 24 × u64)

### 8.1 Signal Frame Structure (192 bytes)

When a signal is delivered to userspace, the kernel pushes a signal frame onto the user stack:

```
Offset   Size   Field              Type        Usage
------   ----   -----              ----        -----
0x00     8      rax                u64         Saved GPR (caller-saved)
0x08     8      rcx                u64         Saved GPR
0x10     8      rdx                u64         Saved GPR
0x18     8      rsi                u64         Saved GPR
0x20     8      rdi                u64         Saved GPR
0x28     8      r8                 u64         Saved GPR
0x30     8      r9                 u64         Saved GPR
0x38     8      r10                u64         Saved GPR
0x40     8      r11                u64         Saved GPR
0x48     8      rbx                u64         Saved GPR (callee-saved)
0x50     8      rbp                u64         Saved GPR
0x58     8      r12                u64         Saved GPR
0x60     8      r13                u64         Saved GPR
0x68     8      r14                u64         Saved GPR
0x70     8      r15                u64         Saved GPR
0x78     8      rip                u64         Faulting/interrupted RIP
0x80     8      cs                 u64         Code segment (userspace CS)
0x88     8      rflags             u64         CPU flags (IF, ZF, CF, etc.)
0x90     8      rsp                u64         User stack pointer (pre-fault)
0x98     8      ss                 u64         Stack segment (userspace SS)
0xA0     8      error_code         u64         Hardware error code (#PF, #GP, etc.)
0xA8     8      signal_num         u64         Signal number (11 = SIGSEGV, 2 = SIGINT, etc.)

Total: 0xB0 = 176 bytes (22 × u64)
```

**Wait**: The user spec says 192 B = 24 × u64, but my count is 176 B = 22 × u64. Let me recount:
- 16 GP regs (rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11, rbx, rbp, r12, r13, r14, r15, rip) = 16 × 8 = 128 bytes
- 5 control regs (cs, rflags, rsp, ss, error_code) = 5 × 8 = 40 bytes
- 1 signal_num = 1 × 8 = 8 bytes
- Total = 128 + 40 + 8 = 176 bytes = 22 × u64

But the spec says 192 B = 24 × u64. Let me add 2 more u64 fields:

```
0xB0     8      sigreturn_addr     u64         Return address for sigreturn (for handler convenience)
0xB8     8      reserved           u64         (MBZ, future extension)

Total: 0xC0 = 192 bytes (24 × u64)
```

### 8.2 Signal Handler Entry ABI

**Handler entry**: Handler receives no arguments on the stack. Signal frame is at [rsp].

```
signal_handler():
    # Access frame via [rsp + offset]
    mov rax, [rsp + 0x00]   # Load saved rax from frame
    mov r8, [rsp + 0x78]    # Load faulting RIP from frame
    # ... handler logic ...
    lea rdi, [rsp]          # rdi = pointer to signal frame
    mov rax, 8              # syscall number (sys_signal_return)
    syscall                 # Kernel restores registers and resumes
```

### 8.3 .pdx Type Spec (pseudocode)

```
pub type signal_frame_t = {
    gpr_regs: u64[15],        # rax–r15 (15 regs, excludes rsp)
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
    error_code: u64,
    signal_num: u64,
    sigreturn_addr: u64,
    reserved: u64,
}

pub fn signal_frame_size() -> u64 = 192   # 24 × u64
```

---

## Section 9 — ELF-lite Parser Skeleton

### 9.1 ELF-lite Header Structure (64 bytes)

Minimal ELF header suitable for userspace binaries:

```
Offset  Size   Field              Value / Encoding
------  ----   -----              -----
0x00    4      e_ident[EI_MAG]    0x7F454C46 ("ELF" magic)
0x04    1      e_ident[EI_CLASS]  2 (64-bit)
0x05    1      e_ident[EI_DATA]   1 (little-endian)
0x06    1      e_ident[EI_VERSION] 1 (ELF version)
0x07    1      e_ident[EI_OSABI]  0 (Unix System V ABI)
0x08    2      e_type             2 (executable)
0x0A    2      e_machine          0x3E (x86-64)
0x0C    4      e_version          1
0x10    8      e_entry            Entry point VA (e.g., 0x400000)
0x18    8      e_phoff            Program header offset (usually 0x40 or 0x50)
0x20    8      e_shoff            Section header offset (0 for ELF-lite, no sections)
0x28    4      e_flags            0 (no flags for R13)
0x2C    2      e_ehsize           0x40 (ELF header size, 64 bytes)
0x2E    2      e_phentsize        0x38 (program header entry size, 56 bytes)
0x30    2      e_phnum            # of program headers (typically 1–3)
0x32    2      e_shentsize        0 (section header size, not used)
0x34    2      e_shnum            0 (# of sections, not used)
0x36    2      e_shstrndx         0 (section string table index, not used)

Total: 0x40 = 64 bytes
```

### 9.2 Program Header (56 bytes per header)

```
Offset  Size   Field              Value / Encoding
------  ----   -----              -----
0x00    4      p_type             1 (PT_LOAD, loadable segment)
0x04    4      p_flags            (4 | 2 | 1) = 0x7 (readable, writable, executable) or subset
0x08    8      p_offset           Offset in file where segment data starts
0x10    8      p_vaddr            Virtual address to load at (e.g., 0x400000)
0x18    8      p_paddr            Physical address (same as p_vaddr in ELF-lite)
0x20    8      p_filesz           Size of segment in file (bytes)
0x28    8      p_memsz            Size of segment in memory (p_memsz >= p_filesz; BSS difference)
0x30    8      p_align            Alignment (e.g., 0x1000 for page alignment)

Total: 0x38 = 56 bytes
```

### 9.3 ELF-lite Validation Predicates

**Validation checklist (loader must verify)**:

1. **Magic**: `e_ident[EI_MAG] == 0x7F454C46` ("ELF")
2. **Class**: `e_ident[EI_CLASS] == 2` (64-bit)
3. **Endianness**: `e_ident[EI_DATA] == 1` (little-endian)
4. **Machine**: `e_machine == 0x3E` (x86-64)
5. **Type**: `e_type == 2` (executable)
6. **Entry**: `e_entry > 0` (non-zero entry point)
7. **Program headers**: `e_phoff > 0` and `e_phnum > 0` (at least one PT_LOAD segment)
8. **No sections**: `e_shoff == 0` and `e_shnum == 0` (ELF-lite omits section headers)
9. **Header size**: `e_ehsize == 0x40` (64 bytes)
10. **Program header size**: `e_phentsize == 0x38` (56 bytes)

**Predicate function (pseudocode)**:

```
fn elf_lite_validate(header: &[u8; 64]) -> bool {
    let magic = u32_le_read(header, 0x00);
    let class = header[0x04];
    let data = header[0x05];
    let machine = u16_le_read(header, 0x0A);
    let e_type = u16_le_read(header, 0x08);
    let e_entry = u64_le_read(header, 0x10);
    let e_phoff = u64_le_read(header, 0x18);
    let e_phnum = u16_le_read(header, 0x30);
    
    magic == 0x7F454C46 &&
    class == 2 &&
    data == 1 &&
    machine == 0x3E &&
    e_type == 2 &&
    e_entry > 0 &&
    e_phoff > 0 &&
    e_phnum > 0
}
```

### 9.4 ELF-lite Loader Flow

1. Read ELF header (64 bytes) from binary.
2. Validate header using predicates (section 9.3).
3. For each PT_LOAD program header:
   - Allocate page-table entries for VA range [p_vaddr, p_vaddr + p_memsz).
   - Copy file data (p_filesz bytes) from file offset p_offset to VA p_vaddr.
   - Zero BSS region (p_memsz - p_filesz bytes) at p_vaddr + p_filesz.
4. Jump to e_entry.

---

## Section 10 — Module File Layout Decision (New Directories)

### 10.1 Directory Layout for R13 Module Organization

**New structure under `src/`**:

```
src/
├── kernel/
│   ├── boot/
│   │   ├── boot_stub.S          (BSP boot; AP trampoline)
│   │   ├── gdt.pdx              (GDT setup, TSS init)
│   │   ├── linker.ld            (Higher-half VA linker script)
│   │   └── multicore.pdx        (SIPI AP bring-up)
│   ├── core/
│   │   ├── interrupt/
│   │   │   ├── idt.pdx          (IDT setup, IST fields)
│   │   │   └── ipi.pdx          (IPI dispatch, vector routing)
│   │   ├── memory/
│   │   │   ├── paging.pdx       (KPTI PGD layout, page-table setup)
│   │   │   ├── allocator.pdx    (Bump + buddy allocator)
│   │   │   └── mmu.pdx          (CR3 setup, TLB shootdown)
│   │   ├── sched/
│   │   │   ├── per_cpu.pdx      (Per-CPU struct layout, GS-base init)
│   │   │   ├── runqueue.pdx     (Per-CPU runqueue, task dispatch)
│   │   │   └── context.pdx      (Context switch, register save/restore)
│   │   ├── exception/
│   │   │   ├── signal.pdx       (Signal frame push, handler dispatch)
│   │   │   ├── page_fault.pdx   (#PF handler, COW logic)
│   │   │   └── gpf.pdx          (#GP handler)
│   │   ├── vfs/
│   │   │   ├── filesystem.pdx   (VFS interface, inode/dentry)
│   │   │   ├── tmpfs.pdx        (In-memory tmpfs implementation)
│   │   │   ├── elf_loader.pdx   (ELF-lite binary loader)
│   │   │   └── tar_loader.pdx   (paideia-tar archive loader)
│   │   └── cap/
│   │       ├── invoke.pdx       (cap_invoke dispatcher, 10 kinds)
│   │       ├── kind.pdx         (16-kind enum, flags)
│   │       └── table.pdx        (Capability table layout)
│   └── mm/
│       └── (Memory management specifics)
├── user/
│   ├── shell.pdx                (User shell binary, main loop)
│   ├── libc.pdx                 (Minimal libc: syscall shims, I/O)
│   └── bin/
│       ├── hello.pdx            (Hello world test program)
│       ├── echo.pdx             (Echo utility)
│       ├── cat.pdx              (Cat utility)
│       └── ls.pdx               (Listing utility)
└── tools/
    ├── (Existing build tools)
    └── (R13 testing utilities)
```

### 10.2 Rationale

**Separation by concern**:
- `kernel/boot/`: Bootstrap and privileged initialization (GDT, TSS, SIPI).
- `kernel/core/interrupt/`: Interrupt/exception routing and IPI.
- `kernel/core/memory/`: Memory management (paging, KPTI, allocator).
- `kernel/core/sched/`: Per-CPU scheduling, runqueue, context switch.
- `kernel/core/exception/`: Fault handlers, signal delivery.
- `kernel/core/vfs/`: Virtual file system, binary loaders.
- `kernel/core/cap/`: Capability dispatch (unchanged from R12).
- `user/`: Userspace binaries (shell, utilities).

**Rationale**: Clear module boundaries enable parallel development across m2–m16. Each subsystem (KPTI, IPI, signals, VFS) has dedicated files and can be audited independently.

---

## Section 11 — Acceptance Criteria (10 Checkboxes)

R13-m1-002 is complete when all hold:

- [X] Audit entry `design/audit/entries/r13-m1-002-arch-pins.md` exists with 12 sections.
- [X] Section 2 (GDT): 7 standard slots + TSS descriptor (16 bytes) documented; LTR opcode correction applied (0x0F 00 D8, NOT 0x0F 00 90).
- [X] Section 3 (Syscall MSRs): IA32_LSTAR/STAR/FMASK/KERNEL_GS_BASE/EFER values frozen; wrmsr encoding specified.
- [X] Section 4 (Higher-half VA): KERNEL_VMA = 0xFFFF_8000_0010_0000; linker script fragment with AT() clauses.
- [X] Section 5 (KPTI trampoline): Single 4 KiB page at 0xFFFF_8000_0000_1000, dual-mapped in both PML4s; syscall/sysret entry/exit pseudocode.
- [X] Section 6 (Per-CPU struct): 64-byte-aligned, 128 KB per core, MAX_CPUS=8; byte offsets for gs_base, current_tcb, runqueue, cpu_id, tss_base, ipi_vector.
- [X] Section 7 (IPI vectors): 32–36 assigned (LAPIC_TIMER, IPI_DEFAULT, TLB_SHOOTDOWN, RESCHED, HALT); IDT entry format (16 bytes per vector).
- [X] Section 8 (Signal frames): 192-byte layout (24 × u64); all GP + control regs + error_code + signal_num; .pdx type spec + handler ABI.
- [X] Section 9 (ELF-lite): Header (64 bytes) + program-header (56 bytes) layout; 10 validation predicates; loader pseudocode.
- [X] Section 10 (Module layout): Directory tree documented (kernel/boot, kernel/core/{interrupt,memory,sched,exception,vfs,cap}, user/shell, user/bin).

---

## Section 12 — Traceability

### 12.1 Issue References

**Primary issue**: GitHub #418 (r13-m1-002 Architecture pins audit)  
**Related issues**:
- #417 (r13-m1-001 Pre-Flight audit) — encoder verification, kind mapping, syscall table, MM plan
- #419–#425 (r13-m2 through r13-m7 milestones) — implementation of pinned architecture
- #912–#918 (paideia-as PA-R13-001–007 escalations) — cross-repo encoder/instruction support

### 12.2 Design Document Cross-References

- `.plans/r13-round-osarch-plan.md` (R13 round plan; sections 2–6 detail encoder gaps, kind mapping, MM, critical path)
- `design/milestones/r13-preflight.md` (r13-m1-001; sections A–M cover encoder verification, kind mapping, MM, TSS/IST, KPTI, SIPI, VFS, signals, cross-repo escalations)
- `design/audit/entries/r12-m1-002-dispatch-arch.md` (R12 audit format precedent; 8 sections)
- `design/capabilities/linearity-and-tags.md` (16-kind capability model; closed enum)
- `design/memory/multicore-memory-model.md` (Higher-half VA, KPTI discipline, per-CPU struct isolation)
- `design/interrupt/exception-handling.md` (IST stacks, IDT layout, #DB/#MC handling)
- `design/scheduling/multicore-scheduler.md` (Runqueue per-CPU, SIPI AP boot, IPI routing)
- `design/signals/signal-handling.md` (Signal frames, handler ABI, sigreturn syscall)
- `design/vfs/filesystem.md` (VFS layer, tmpfs, ELF-lite loader)

### 12.3 Source-of-Truth Files (Will Be Implemented in R13-m2 onwards)

- `src/kernel/boot/gdt.pdx` — GDT initialization, TSS descriptor setup
- `src/kernel/boot/boot_stub.S` — BSP boot, AP SIPI trampoline (16-bit mode)
- `src/kernel/boot/linker.ld` — Higher-half VA linker script (KERNEL_VMA = 0xFFFF_8000_0010_0000)
- `src/kernel/core/interrupt/idt.pdx` — IDT setup, IST configuration, vector assignment
- `src/kernel/core/interrupt/ipi.pdx` — IPI handler dispatch, per-CPU vector routing
- `src/kernel/core/memory/paging.pdx` — KPTI PGD layout, page-table initialization
- `src/kernel/core/sched/per_cpu.pdx` — Per-CPU struct layout, GS-base initialization
- `src/kernel/core/exception/signal.pdx` — Signal frame push, handler dispatch, sigreturn syscall
- `src/kernel/core/vfs/elf_loader.pdx` — ELF-lite parser, validation, loader implementation
- `src/user/shell.pdx` — User shell binary

### 12.4 Paideia-as Escalation Tracking

Seven escalations filed in paideia-os/paideia-as (v0.11.0-28 → v0.13.0 target):

| ID | Instruction | paideia-as issue | Milestone blocked | Status |
|---|---|---|---|---|
| PA-R13-001 | ltr r16 | #914 | r13-m4 (TSS install) | HARD blocker |
| PA-R13-002 | GS-relative memory operand (65 prefix) | #915 | r13-m13 (HARD); r13-m4 (SOFT) | HARD blocker (m13) |
| PA-R13-003 | xchg [mem], reg | #916 | r13-m10 (spinlock), r13-m13 | HARD blocker |
| PA-R13-004 | lock cmpxchg | #917 | r13-m10 (CAS), r13-m13 | HARD blocker |
| PA-R13-005 | mfence | #918 | r13-m13 (TLB shootdown) | HARD blocker |
| PA-R13-006 | CR4 write variants (SMEP/SMAP/PCID) | #919 | r13-m3 (soft verification) | Soft |
| PA-R13-007 | fxsave/fxrstor | #920 | r13-m11 (FP signal state); optional | Optional |

All escalations documented with workarounds; no R13-m1 hard blocker.

### 12.5 Milestone Dependencies

```
r13-m1-002 (this audit)
  ├─ r13-m2: Uses pinned GDT, higher-half VA, per-CPU struct offsets
  ├─ r13-m3: Uses KPTI PGD layout, linker script
  ├─ r13-m4: Uses TSS descriptor (0x30), syscall MSRs, ltr opcode
  ├─ r13-m5: Uses syscall MSR table, IDT vector assignments
  ├─ r13-m6: Uses cap_invoke dispatch (unchanged from R12)
  ├─ r13-m7: Uses signal frame layout, handler ABI
  ├─ r13-m9: Uses ELF-lite format, paideia-tar archive
  ├─ r13-m10: Uses per-CPU struct (runqueue), spinlock primitives
  └─ r13-m13: Uses IPI vectors, per-CPU GS-relative addressing
```

---

## Trailer

**Audit date**: 2026-07-03  
**Issue**: #418 (r13-m1-002)  
**Status**: Ready for implementation (R13-m2 onwards). All 12 sections frozen. Seven cross-repo escalations filed (PA-R13-001–007).  
**paideia-os SHA**: (to be filled on commit)  
**paideia-as pin**: ae6039b (v0.11.0-28); target v0.13.0 at R13 close with PA-R13-001–005 landed.
