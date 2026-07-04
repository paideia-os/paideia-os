/* PaideiaOS higher-half kernel linker script — R14.M3 VMA/LMA split.
 *
 * Layout:
 *   - Boot stub sections (.text.boot, .rodata.boot, .bss.boot,
 *     .note.PVH-boot) live at low identity map (VMA=LMA=0x100000+).
 *   - Kernel sections (.text, .rodata, .data, .bss) live at higher-half
 *     via VMA = KERNEL_VMA_BASE + LMA. LMA continues packing from low.
 *
 * KERNEL_VMA_BASE = 0xFFFF800000000000 is PML4[256]'s alias base: the
 * boot stub aliases PML4[256] → PDPT[0..3] identity, so VMA
 * (KERNEL_VMA_BASE + phys) → phys directly. Kernel .text at
 * VMA 0xFFFF800000103xxx, LMA 0x103xxx executes correctly.
 *
 * PVH ELF Note for QEMU -kernel handoff placed in text_low.
 */

OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(_pvh_entry)

KERNEL_VMA_BASE = 0xFFFF800000000000;
KERNEL_PHYS_BASE = 0x100000;

PHDRS
{
    text_low  PT_LOAD FLAGS(5);
    text_high PT_LOAD FLAGS(5);
    data_high PT_LOAD FLAGS(6);
    bss_high  PT_LOAD FLAGS(6);
    note      PT_NOTE FLAGS(4);
}

SECTIONS
{
    . = KERNEL_PHYS_BASE;
    _kernel_phase1_start = .;
    ASSERT(_kernel_phase1_start == KERNEL_PHYS_BASE,
           "ERROR: _kernel_phase1_start must be at 0x100000")

    .text.boot     : ALIGN(4K) { KEEP(*(.text.boot)) }              :text_low
    .rodata.boot   : ALIGN(8)  { *boot_stub.o(.rodata.boot) }       :text_low
    .bss.boot      : ALIGN(4K) { *boot_stub.o(.bss.boot) }          :text_low
    .note.PVH-boot : ALIGN(4)  { KEEP(*(.note.PVH-boot)) }          :text_low :note

    _kernel_phase1_end = .;

    /* Step . into the higher-half alias. LMA continues from where . was. */
    . = . + KERNEL_VMA_BASE;

    .text   : AT(ADDR(.text)   - KERNEL_VMA_BASE) ALIGN(4K) {
                KEEP(*(.text._start))
                *(.text .text.*)
            } :text_high

    _kernel_high_text_start = ADDR(.text);
    _kernel_high_entry = kernel_main_64;

    .rodata : AT(ADDR(.rodata) - KERNEL_VMA_BASE) ALIGN(4K) {
                *(.rodata .rodata.*)
            } :text_high

    .data   : AT(ADDR(.data)   - KERNEL_VMA_BASE) ALIGN(4K) {
                *(.data .data.*)
            } :data_high

    .bss (NOLOAD) : ALIGN(4K) {
                *(COMMON)
                *(.bss .bss.*)
                . = ALIGN(4K);
            } :bss_high

    /DISCARD/ : {
        *(.comment)
        *(.eh_frame*)
        *(.note.Xen)
    }
}
