# tools/ap_trampoline.S — R18-M1-002 (paideia-os #761)
#
# AP boot trampoline: real-mode -> protected -> long mode -> jmp _ap_entry.
#
# Standalone module: assembled with `as --64`, linked with tools/ap_trampoline.ld
# to a fixed VMA of 0x8000, then `objcopy -O binary` produces a flat blob at
# build/ap_trampoline.bin. tools/ap_trampoline_embed.S `.incbin`s that blob
# into kernel .rodata.ap_trampoline. At boot, ap_trampoline_install (in
# src/kernel/core/smp/ap_trampoline_relocate.pdx) memcpys the blob to
# physical 0x8000 before ap_wake_all (src/kernel/core/smp/ap_boot.pdx#760)
# issues INIT-SIPI-SIPI with vector 0x08.
#
# On AP wake the CPU lands in real mode at CS:IP = 0x0800:0000 — physical
# 0x8000 — i.e., the first byte of _ap_trampoline_start. The blob is
# position-DEPENDENT: the linker resolves all intra-blob references
# assuming runtime base 0x8000, so relocating to any other page requires
# re-linking. That contract is documented on ap_trampoline_install.
#
# GDT template mirrors tools/boot_stub.S verbatim: selectors 0x08 code32 /
# 0x10 data32 / 0x18 code64 / 0x20 data64. This is the trampoline's OWN
# GDT — the kernel GDT (src/kernel/boot/gdt.pdx) is not yet reachable
# from the AP until it loads a kernel PML4. #762 (per-CPU init) reloads
# the kernel GDT once _ap_entry is running under kernel address space.
#
# Parameter slots (patched by the caller AFTER install, BEFORE ap_wake):
#   _ap_pml4_pa_slot : u32 — kernel PML4 physical address (< 4 GiB, per
#                             boot_stub layout). CR3 write is 32-bit in
#                             .code32; the low 32 bits are what matters.
#   _ap_stack_slot   : u64 — per-AP kernel stack top. #762 populates.
#   _ap_entry_slot   : u64 — kernel VA of `_ap_entry` (higher-half).
#                             #762/#763 patches after resolving via nm-map
#                             or via an installer variant that takes the
#                             address as an argument.
#
# The three slot BYTE OFFSETS within the blob are exported as
# `_ap_trampoline_pml4_offset`, `_ap_trampoline_stack_offset`, and
# `_ap_trampoline_entry_offset` so the caller can locate them by offset
# from the dst_phys install address without re-parsing the blob.
#
# Standalone-link discipline: the trampoline does NOT reference any kernel
# symbol directly. `_ap_entry` reaches the trampoline via the entry slot
# above; kernel PML4 phys via the pml4 slot. This keeps ap_trampoline.elf
# linkable in isolation (no kernel symbols in scope) and avoids a
# kernel-link-time-address baked into the flat blob.
#
# Blob size: ~130 bytes of code + ~64 bytes of GDT + slots — comfortably
# under a single 4 KiB page (AC criterion in #761).

.equ AP_SEL_CODE32, 0x08
.equ AP_SEL_DATA32, 0x10
.equ AP_SEL_CODE64, 0x18
.equ AP_SEL_DATA64, 0x20

.section .text, "ax", @progbits
.code16

.global _ap_trampoline_start
_ap_trampoline_start:
    cli
    cld

    # Flat real-mode data segments (ES/SS/etc = 0).
    xor  %ax, %ax
    mov  %ax, %ds
    mov  %ax, %es
    mov  %ax, %ss
    mov  %ax, %fs
    mov  %ax, %gs

    # Load 32-bit-aware GDT descriptor. `lgdtl` in .code16 emits the
    # data32 (0x66) prefix so LGDT interprets ap_gdt_ptr as 16-bit limit
    # + 32-bit base (matching how ap_gdt_ptr is laid out below).
    lgdtl ap_gdt_ptr

    # CR0.PE = 1.
    mov  %cr0, %eax
    or   $1, %eax
    mov  %eax, %cr0

    # Far jump to protected-mode code selector. `ljmpl` in .code16 emits
    # the data32-prefixed 5-byte far jump (0x66 0xEA off32 sel16).
    ljmpl $AP_SEL_CODE32, $ap_prot_start

.code32
ap_prot_start:
    # Reload 32-bit data segments.
    mov  $AP_SEL_DATA32, %ax
    mov  %ax, %ds
    mov  %ax, %es
    mov  %ax, %ss
    mov  %ax, %fs
    mov  %ax, %gs

    # CR3 <- kernel PML4 phys (patched by installer). 32-bit .code32 mov
    # to CR3 loads the low 32 bits and clears the upper 32 — safe here
    # because the boot PML4 (boot_stub.S) sits well below 4 GiB.
    mov  ap_pml4_pa_slot, %eax
    mov  %eax, %cr3

    # CR4.PAE = 1.
    mov  %cr4, %eax
    or   $0x20, %eax
    mov  %eax, %cr4

    # EFER.LME = 1 via MSR 0xC000_0080.
    mov  $0xC0000080, %ecx
    rdmsr
    or   $0x100, %eax
    wrmsr

    # CR0.PG | PE | WP (WP = bit 16; matches boot_stub.S rationale —
    # ring-0 honours R-only PTEs, prerequisite for CoW substrate).
    mov  %cr0, %eax
    or   $0x80010001, %eax
    mov  %eax, %cr0

    # Far jump to long mode. Byte-encoded to sidestep any GAS surprise
    # around ljmp operand-size selection under mixed .code32/.code64
    # in a single .text — mirrors boot_stub.S's identical construct.
    .byte 0xEA
    .long ap_long_start
    .word AP_SEL_CODE64

.code64
ap_long_start:
    # Reload 64-bit data segments.
    mov  $AP_SEL_DATA64, %ax
    mov  %ax, %ds
    mov  %ax, %es
    mov  %ax, %ss
    mov  %ax, %fs
    mov  %ax, %gs

    # Per-AP kernel stack (patched by installer; #762 wires the actual
    # per-CPU stack — for now the slot is zero and this load parks
    # %rsp at 0, which is fine because _ap_entry today is a hlt-loop).
    mov  ap_stack_slot(%rip), %rsp

    # Absolute jump to kernel `_ap_entry` — reads the entry-slot VA and
    # transfers control. `_ap_entry` today is a hlt-loop stub in
    # src/kernel/core/smp/ap_entry.pdx; #762 replaces it with real
    # per-CPU init.
    mov  ap_entry_slot(%rip), %rax
    jmp  *%rax

# --------------------------------------------------------------------------
# Data: GDT + parameter slots.
# --------------------------------------------------------------------------

.align 8
ap_gdt:
    .quad 0                          # 0x00 null
    .quad 0x00CF9A000000FFFF         # 0x08 code32 (L=0, D=1)
    .quad 0x00CF92000000FFFF         # 0x10 data32
    .quad 0x00AF9A000000FFFF         # 0x18 code64 (L=1, D=0)
    .quad 0x00AF92000000FFFF         # 0x20 data64
ap_gdt_ptr:
    .word 5*8 - 1                    # limit (5 entries * 8 bytes - 1)
    .long ap_gdt                     # base (32-bit; linker resolves via VMA=0x8000+)

# Parameter slots. Caller patches AFTER ap_trampoline_install memcpys
# the blob, BEFORE the ap_wake_all INIT-SIPI-SIPI kick.
.align 4
.global _ap_pml4_pa_slot
_ap_pml4_pa_slot:
ap_pml4_pa_slot:
    .long 0

.align 8
.global _ap_stack_slot
_ap_stack_slot:
ap_stack_slot:
    .quad 0

.global _ap_entry_slot
_ap_entry_slot:
ap_entry_slot:
    .quad 0

.global _ap_trampoline_end
_ap_trampoline_end:

# Byte offsets of the parameter slots within the blob. Callers use
# these to locate the slots at (dst_phys + offset) after install.
.global _ap_trampoline_pml4_offset
.set    _ap_trampoline_pml4_offset,  ap_pml4_pa_slot - _ap_trampoline_start

.global _ap_trampoline_stack_offset
.set    _ap_trampoline_stack_offset, ap_stack_slot   - _ap_trampoline_start

.global _ap_trampoline_entry_offset
.set    _ap_trampoline_entry_offset, ap_entry_slot   - _ap_trampoline_start
