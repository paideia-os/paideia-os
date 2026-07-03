/* PaideiaOS minimum-viable kernel linker script.
 *
 * QEMU's -kernel loader places ELF64 binaries at the address declared
 * by the ELF program headers. We pin the kernel at the conventional
 * 1 MiB mark for the Phase-0/1 smoke; higher-half remap lands later
 * once the 32->64 transition + page-table setup land.
 *
 * ENTRY symbol _start: defined by src/kernel/boot/entry.pdx. The
 * linker places its containing section first within .text so QEMU
 * lands on it directly.
 *
 * P1-004 higher-half preview: the kernel's eventual canonical
 * virtual base is 0xFFFFFFFF80000000 (the -2 GiB region). Phase-1
 * boots in the identity-mapped low region (1 MiB physical, equal
 * virtual). When P1-003's long-mode transition + identity map land,
 * the kernel writes the higher-half PML4 entry and a far-jmp into
 * the higher-half-mapped .text. The placeholder symbol below names
 * the higher-half base so downstream code can reference it.
 */

OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(_pvh_entry)

/* Higher-half kernel base. R13-m3-001 Phase 1 (#445): PML4[256] alias now
 * installed, mapping 0xFFFF_8000_0000_0000 through the same PDPT as 0x0.
 * Execution remains in low VA until Phase 2 (#480) relocates kernel VMA. */
KERNEL_VMA_HIGHER_HALF = 0xFFFFFFFF80000000;

/* Phase-1 load address (1 MiB physical, identity-mapped virtual). */
KERNEL_VMA_PHASE1 = 0x100000;

PHDRS
{
    text PT_LOAD FLAGS(5);
    note PT_NOTE FLAGS(4);
}

SECTIONS
{
    . = KERNEL_VMA_PHASE1;

    /* Boot-time start label, in the low region for the QEMU -kernel handoff. */
    _kernel_phase1_start = .;
    ASSERT(_kernel_phase1_start == KERNEL_VMA_PHASE1,
           "ERROR: _kernel_phase1_start must be at 0x100000, not a collision with paideia-as _start")

    .text : ALIGN(4K) {
        KEEP(*(.text.boot))     /* boot_stub.S _pvh_entry — MUST be first */
        KEEP(*(.text._start))   /* paideia-as kernel entry */
        *(.text .text.*)        /* rest of code */
    } :text

    .rodata : ALIGN(4K) {
        *(.rodata*)
    } :text

    .data : ALIGN(4K) {
        *(.data*)
    } :text

    .bss : ALIGN(4K) {
        *(COMMON)
        *(.bss*)
        . = ALIGN(4096);
    } :text

    /* PVH ELF Note section for QEMU -kernel handoff. boot_stub.S emits as .note.PVH-boot.
     * Placed in both PT_LOAD (so QEMU PVH loader can find it) and PT_NOTE (for ELF readers). */
    .note.PVH-boot : ALIGN(4) {
        KEEP(*(.note.PVH-boot))
    } :text :note

    /* End-of-Phase-1-image marker; downstream tools can read this to know
     * how far the kernel image spans in physical memory. */
    _kernel_phase1_end = .;

    /* Higher-half preview symbols. Not yet wired to any actual section;
     * the long-mode remap (P1-003 + future) will reuse these names when
     * the PML4 entry for KERNEL_VMA_HIGHER_HALF is populated. */
    _kernel_higher_half_base = KERNEL_VMA_HIGHER_HALF;
    _kernel_higher_half_text = KERNEL_VMA_HIGHER_HALF + 0x1000;

    /DISCARD/ : {
        *(.comment)
        *(.eh_frame*)
        *(.note.Xen)  /* Drop paideia-as PVH notes to avoid duplication */
    }
}
