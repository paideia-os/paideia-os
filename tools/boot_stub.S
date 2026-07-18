# tools/boot_stub.S — 32-bit PVH bridge to 64-bit paideia-as kernel.
# Per Intel SDM Vol 3A §9.8.5 + Xen PVH ABI.

.section .note.PVH-boot, "a", @note
    .long 4                      # n_namesz
    .long 8                      # n_descsz (8 bytes for ELF64 image)
    .long 18                     # n_type = XEN_ELFNOTE_PHYS32_ENTRY
    .ascii "Xen\0"
    .quad _pvh_entry             # 64-bit address

.section .text.boot, "ax", @progbits
.code32

.global _pvh_entry
_pvh_entry:
    cli
    lgdt gdt32_ptr

    # PML4[0] = PDPT phys | RW | P (PDPT is 32-bit aligned, fits in low 32)
    movl $pdpt, %eax
    orl  $0x03, %eax
    movl %eax, pml4 + 0
    movl $0,   pml4 + 4

    # PDPT[0..3] = 1 GiB pages: PS | RW | P at 0/1/2/3 GiB
    movl $0x00000083, pdpt + 0
    movl $0,          pdpt + 4
    movl $0x40000083, pdpt + 8
    movl $0,          pdpt + 12
    movl $0x80000083, pdpt + 16
    movl $0,          pdpt + 20
    movl $0xC0000083, pdpt + 24
    movl $0,          pdpt + 28

    # R13-m3-001 Phase 1 (#445): higher-half aliasing.
    # PML4[256] mirrors PML4[0] so VA 0xFFFF_8000_XXXX_XXXX resolves via
    # the same PDPT (identity map). Installs the mapping only; execution
    # remains at low VA. Phase 2 (#480) relocates kernel VMA.
    movl $pdpt, %eax
    orl  $0x03, %eax               # RW | P
    movl %eax, pml4 + (256 * 8)    # PML4[256].lo = PDPT phys | flags
    movl $0,   pml4 + (256 * 8) + 4  # PML4[256].hi = 0

    # CR3 <- pml4
    movl $pml4, %eax
    movl %eax, %cr3

    # CR4.PAE
    movl %cr4, %eax
    orl  $0x20, %eax
    movl %eax, %cr4

    # EFER.LME via MSR 0xC0000080
    movl $0xC0000080, %ecx
    rdmsr
    orl  $0x100, %eax
    wrmsr

    # CR0.PG | PE
    movl %cr0, %eax
    orl  $0x80000001, %eax
    movl %eax, %cr0

    # Far jump to 64-bit code segment (selector 0x18)
    # In 32-bit code: ljmp opcode=0xEA, 4-byte offset, 2-byte selector
    # GAS .code32 requires us to explicitly encode this since .code32 inside .code64 context is tricky
    # Workaround: use .byte sequence for ljmp $0x18, $long_mode_trampoline
    .byte 0xEA                   # ljmp opcode
    .long long_mode_trampoline   # 32-bit offset (will be relocated)
    .word 0x18                   # 16-bit selector

.code64
long_mode_trampoline:
    # Reload data segments with 64-bit data selector 0x20
    movw $0x20, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw %ax, %fs
    movw %ax, %gs

    # Jump to paideia-as kernel entry
    # R14B-M3-000: absolute far jump — avoids R_X86_64_PC32 overflow
    # when kernel VMA (higher-half) is far from boot stub LMA (#489 split).
    movabsq $_start, %rax
    jmpq    *%rax

.section .rodata.boot, "a", @progbits
.align 8
gdt32:
    .quad 0                          # 0x00 null
    .quad 0x00CF9A000000FFFF         # 0x08 code32
    .quad 0x00CF92000000FFFF         # 0x10 data32
    .quad 0x00AF9A000000FFFF         # 0x18 code64 (L=1)
    .quad 0x00AF92000000FFFF         # 0x20 data64
gdt32_ptr:
    .word 5*8 - 1                    # limit
    .long gdt32                      # base (32-bit, flat zero-base GDT)

.section .rodata, "a", @progbits
.align 8

# R14B-M3-000c (#643): 64-bit absolute-address slot for boot PML4.
# Bridges cross-VA rip-refs from higher-half kernel .pdx code to low-VA
# .bss.boot pml4 (avoids R_X86_64_PC32 overflow once #489 splits VMA).
# Linker emits R_X86_64_64 here → filled with runtime absolute VA of pml4.
.global _pml4_addr
.align 8
_pml4_addr:
    .quad pml4

# B3-004: Banner string for kernel startup message
.global banner_msg
.align 8
banner_msg:
    .ascii "PaideiaOS R8\n\0"

# B5-005: Capability system smoke test message
.global cap_ok_msg
.align 8
cap_ok_msg:
    .ascii "CAP OK\n\0"

# B6-004: IPC smoke test message
.global ipc_ok_msg
.align 8
ipc_ok_msg:
    .ascii "IPC OK\n\0"

# R9-m1-002: IDT installation message
.global idt_ok_msg
.align 8
idt_ok_msg:
    .ascii "IDT OK\n\0"

# R13-m4-002: TSS installation message
.global tss_ok_msg
.align 8
tss_ok_msg:
    .ascii "TSS OK\n\0"

# R14B-M3-008 (#496): Higher-half execution witness.
.global hi_va_msg
.align 8
hi_va_msg:
    .ascii "HI VA FFFF8000\n\0"

# R14.M4-009 (#505): KPTI structural witness success message
.global kpti_ok_msg
.align 8
kpti_ok_msg:
    .ascii "KPTI OK\n\0"

# R14.M4-009 (#505): KPTI structural witness failure message
.global kpti_fail_msg
.align 8
kpti_fail_msg:
    .ascii "KPTI FAIL\n\0"

# R14b-m4-006b (#645): KPTI scratch-slot round-trip witness success message
.global kpti_scratch_ok_msg
.align 8
kpti_scratch_ok_msg:
    .ascii "KPTI SCRATCH OK\n\0"

# R14b-m5-007 (#512): Self-IPI smoke success message
.global ipi_ok_msg
.align 8
ipi_ok_msg:   .ascii "IPI OK\n\0"

# R14b-m5-007 (#512): Self-IPI smoke failure message
.global ipi_fail_msg
.align 8
ipi_fail_msg: .ascii "IPI FAIL\n\0"

# R15-M1-008 (#520): Loader success witness message
.global loader_ok_msg
.align 8
loader_ok_msg: .ascii "LOADER OK\n\0"

# R15-M1-008 (#520): Loader failure witness message
.global loader_fail_msg
.align 8
loader_fail_msg: .ascii "LOADER FAIL\n\0"

# R15-M1-008b (#648): ELF-lite loader runtime success witness message
.global elf_load_ok_msg
.align 8
elf_load_ok_msg: .ascii "ELF LOAD OK\n\0"

# R15-M1-008b (#648): ELF-lite loader runtime failure witness message
.global elf_load_fail_msg
.align 8
elf_load_fail_msg: .ascii "ELF LOAD FAIL\n\0"

# R15-M2-005-followup (#651): enter_userland_initial relocation success witness message
.global enter_reloc_ok_msg
.align 8
enter_reloc_ok_msg: .ascii "ENTER USER RELOC OK\n\0"

# R15-M2-005-followup (#651): enter_userland_initial relocation failure witness message
.global enter_reloc_fail_msg
.align 8
enter_reloc_fail_msg: .ascii "ENTER USER RELOC FAIL\n\0"

# R15-M2-006b (#652): Ring-3 witness start message
.global ring3_start_msg
.align 8
ring3_start_msg: .ascii "R15 RING3 START\n\0"

# R15-M2-006b (#652): Debug message after saving RSP
.global ring3_saved_rsp_msg
.align 8
ring3_saved_rsp_msg: .ascii "R15 SAVED RSP\n\0"

# R15-M2-006b (#652): Debug message after saving RIP marker
.global ring3_saved_rip_msg
.align 8
ring3_saved_rip_msg: .ascii "R15 SAVED RIP\n\0"

# R15-M2-006b (#652): Debug message before creating PML4
.global ring3_create_pml4_msg
.align 8
ring3_create_pml4_msg: .ascii "R15 CREATE PML4\n\0"

# R15-M2-006b (#652): Debug message after aspace_create
.global ring3_aspace_done_msg
.align 8
ring3_aspace_done_msg: .ascii "R15 ASPACE DONE\n\0"

# R15-M2-006b (#652): Debug message before phys_alloc
.global ring3_phys_alloc_msg
.align 8
ring3_phys_alloc_msg: .ascii "R15 PHYS ALLOC\n\0"

# R15-M2-006b (#652): Debug message after phys_alloc
.global ring3_phys_done_msg
.align 8
ring3_phys_done_msg: .ascii "R15 PHYS DONE\n\0"

# R15-M2-006b (#652): Debug message before calculating VA
.global ring3_calc_va_msg
.align 8
ring3_calc_va_msg: .ascii "R15 CALC VA\n\0"

# R15-M2-006b (#652): Debug message before writing hlt
.global ring3_write_hlt_msg
.align 8
ring3_write_hlt_msg: .ascii "R15 WRITE HLT\n\0"

# R15-M2-006b (#652): Debug message after writing hlt byte
.global ring3_wrote_hlt_msg
.align 8
ring3_wrote_hlt_msg: .ascii "R15 WROTE HLT\n\0"

# R15-M2-006b (#652): Debug message before aspace_map
.global ring3_aspace_map_msg
.align 8
ring3_aspace_map_msg: .ascii "R15 ASPACE MAP\n\0"

# R15-M2-006b (#652): Debug message before user_stack_alloc
.global ring3_stack_alloc_msg
.align 8
ring3_stack_alloc_msg: .ascii "R15 STACK ALLOC\n\0"

# R15-M2-006b (#652): Debug message after user_stack_alloc
.global ring3_stack_done_msg
.align 8
ring3_stack_done_msg: .ascii "R15 STACK DONE\n\0"

# R15-M2-006b (#652): Debug message before entering ring-3
.global ring3_enter_msg
.align 8
ring3_enter_msg: .ascii "R15 ENTER RING3\n\0"

# R15-M2-006b (#652): Debug message when witness is resumed from exception handler
.global ring3_resumed_msg
.align 8
ring3_resumed_msg: .ascii "R15 WITNESS RESUMED\n\0"

# R15-M2-006b (#652): Debug message if enter_userland_initial returns
.global ring3_returned_msg
.align 8
ring3_returned_msg: .ascii "R15 RETURNED FROM RING3\n\0"

# R15-M2-006b (#652): Debug message when handler is called
.global ring3_handler_called_msg
.align 8
ring3_handler_called_msg: .ascii "R15 HANDLER CALLED\n\0"

# R15-M2-006b (#652): Debug message when exception handler is called
.global ring3_gp_debug_msg
.align 8
ring3_gp_debug_msg: .ascii "R15 GP DEBUG\n\0"

# R15-M2-006b (#652): Ring-3 witness success message (user hlt → #GP → resume)
.global ring3_hello_ok_msg
.align 8
ring3_hello_ok_msg: .ascii "R15 RING3 HELLO OK\n\0"

# R14-M3-007c (#650): #UD witness success message.
.global ud_witness_ok_msg
.align 8
ud_witness_ok_msg: .ascii "R14 UD OK\n\0"

# R14-M3-007c (#650): #UD witness failure message (armed but not fired).
.global ud_witness_fail_msg
.align 8
ud_witness_fail_msg: .ascii "R14 UD FAIL\n\0"

# R15-M2-006b (#652): Ring-3 witness failure message (setup failed)
.global ring3_fail_msg
.align 8
ring3_fail_msg: .ascii "R15 RING3 FAIL\n\0"

# R9-m4-001: Tick worker message (emitted every K=16 IRQs)
.global _tick_msg
.align 8
_tick_msg:
    .ascii "TICK\n\0"

# R10-m4-002: Task A entry message
.global _task_a_msg
.align 8
_task_a_msg:
    .ascii "TASK A\n\0"

# R10-m4-002: Task B entry message
.global _task_b_msg
.align 8
_task_b_msg:
    .ascii "TASK B\n\0"

# R15-M1-010 (#649): phys_free bitmap release witness success message
.global phys_free_ok_msg
.align 8
phys_free_ok_msg: .ascii "PHYS FREE ROUNDTRIP OK\n\0"

# R15-M1-010 (#649): phys_free bitmap release witness failure message
.global phys_free_fail_msg
.align 8
phys_free_fail_msg: .ascii "PHYS FREE ROUNDTRIP FAIL\n\0"

# R15-M5-007 (#549): fd_table witness success message
.global fd_witness_ok_msg
.align 8
fd_witness_ok_msg: .ascii "R15 FD TABLE OK\n\0"

# R15-M5-007 (#549): fd_table witness failure message
.global fd_witness_fail_msg
.align 8
fd_witness_fail_msg: .ascii "R15 FD TABLE FAIL\n\0"

# R15-M5-006 (#548): task_new witness success message
.global task_new_witness_ok_msg
.align 8
task_new_witness_ok_msg: .ascii "R15 TASK NEW OK\n\0"

# R15-M5-006 (#548): task_new witness failure message
.global task_new_witness_fail_msg
.align 8
task_new_witness_fail_msg: .ascii "R15 TASK NEW FAIL\n\0"

# R15-M4-003 (#537): Exit marker message
.global exit_marker_msg
.align 8
exit_marker_msg: .ascii "[exit]\n\0"

.section .bss.boot, "aw", @nobits
.align 4096
.global pml4
pml4: .skip 4096
.align 4096
.global pdpt
pdpt: .skip 4096
