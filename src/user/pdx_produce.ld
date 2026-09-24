/* PaideiaOS pdx_produce linker script (R121.M5 / paideia-os #2499).
 *
 * Identical layout to child_hello.ld / true.ld / cat.ld: text at
 * 0x00400000, data at 0x00600000, .bss contiguous with .data. Single
 * -object image (pdx_produce is self-contained), so there is nothing
 * distinctive here beyond ENTRY(_start).
 *
 * See child_hello.ld's own header for the .bss-contiguous-with-.data
 * rationale (R31.M2-1595 / #1595 + #1590 tools/verify-user-image-
 * extent.sh guard).
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
