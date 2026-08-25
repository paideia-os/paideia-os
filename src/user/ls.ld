/* PaideiaOS /bin/ls linker script (R57.M4-001 #1797).
 *
 * Mirrors true.ld / child_hello.ld layout: text at 0x00400000, data at
 * 0x00600000, bss contiguous with .data. ls.elf carries a 4 KiB .bss
 * (_ls_buf) plus a handful of .rodata bytes; the two-object link
 * (ls.o + libc/getdents.o) fits well inside the R31.M2-1595 (#1595)
 * 16-page budget policed by tools/verify-user-image-extent.sh.
 *
 * NOTE (R31.M2-1595 #1595, restated across every user linker script):
 *   .bss follows .data CONTIGUOUSLY -- do NOT insert `. = 0x00700000;`
 *   between .data and .bss. Both sections share the `data` PT_LOAD,
 *   and a location-counter jump between them would stretch that ONE
 *   segment across the 1 MiB hole, giving p_memsz = 0x102000 for a few
 *   KiB of real content. tools/verify-user-image-extent.sh (rule 3)
 *   fails the build if any src/user/*.ld drifts back into that shape.
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
