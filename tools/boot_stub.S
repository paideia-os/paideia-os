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
    jmp _start

.section .rodata
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

# R9-m1-004: Exception handler trace messages
.global _exc0_msg
.align 8
_exc0_msg:
    .ascii "EXC0 div\n\0"

.global _exc3_msg
.align 8
_exc3_msg:
    .ascii "EXC3 bp\n\0"

.global _exc6_msg
.align 8
_exc6_msg:
    .ascii "EXC6 ud\n\0"

.global _exc8_msg
.align 8
_exc8_msg:
    .ascii "EXC8 df\n\0"

.global _exc13_msg
.align 8
_exc13_msg:
    .ascii "EXC13 gp\n\0"

.global _exc14_msg
.align 8
_exc14_msg:
    .ascii "EXC14 pf\n\0"

.global _exc32_msg
.align 8
_exc32_msg:
    .ascii "EXC32 timer\n\0"

.global _exc33_msg
.align 8
_exc33_msg:
    .ascii "EXC33 kbd\n\0"

.section .bss
.align 4096
.global pml4
pml4: .skip 4096
.align 4096
.global pdpt
pdpt: .skip 4096
