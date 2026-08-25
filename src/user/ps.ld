/* PaideiaOS /bin/ps linker script (R57.M4-003 / paideia-os #1799).
 * Identical shape to true.ld / child_hello.ld: text at 0x00400000, data
 * at 0x00600000, bss CONTIGUOUS with .data.  ps is single-object, so
 * there is nothing distinctive here beyond ENTRY(_start).
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

    /* R31.M2-1595 (#1595): .bss follows .data CONTIGUOUSLY -- there is no
     * `. = 0x00700000;` here, and there must not be one.
     *
     * See true.ld's own version of this comment for the full rationale --
     * a `. = 0x00700000;` here would stretch the single `data` PT_LOAD to
     * cover the 1 MiB hole between .data and .bss, driving p_memsz to
     * 0x102000 and forcing the loader to map 258 frames for six frames of
     * real content.  tools/verify-user-image-extent.sh fails the build if
     * any user image reacquires that hole.
     */
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
