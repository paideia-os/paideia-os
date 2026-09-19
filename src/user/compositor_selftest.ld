/* PaideiaOS compositor_selftest linker script (Wave β β-01).
 * Same layout as init.ld / child_hello.ld / true.ld: text at 0x00400000,
 * data at 0x00600000, bss contiguous with .data. Two objects link here
 * (selftest.o + buffer_age.o), but the layout is otherwise identical to
 * every other trivial fixture -- see the R31.M2-1595 (#1595) contiguity
 * note in child_hello.ld for why .bss must never get its own `. = ...`.
 */

OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

PHDRS
{
    text PT_LOAD FLAGS(5);
    data PT_LOAD FLAGS(6);
}

SECTIONS
{
    . = 0x00400000;

    .text : ALIGN(4K) {
        KEEP(*(.text._start))
        *(.text .text.*)
    } :text

    .rodata : ALIGN(8) {
        *(.rodata .rodata.*)
    } :text

    . = 0x00600000;

    .data : ALIGN(4K) {
        *(.data .data.*)
    } :data

    .bss (NOLOAD) : ALIGN(4K) {
        *(COMMON)
        *(.bss .bss.*)
        . = ALIGN(4K);
    } :data

    /DISCARD/ : {
        *(.comment)
        *(.eh_frame*)
        *(.note.*)
    }
}
