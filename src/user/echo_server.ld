/* PaideiaOS echo_server linker script (R20b.M5-001 / #1563).
 * Same layout as init.ld / child_hello.ld / true.ld: text at 0x00400000,
 * data at 0x00600000, bss at 0x00700000. echo_server is single-object
 * (one .pdx file, one .elf pattern — same as child_hello.elf and
 * true.elf), so there is nothing distinctive here beyond ENTRY(_start).
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

    . = 0x00700000;

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
