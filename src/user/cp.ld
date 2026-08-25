/* PaideiaOS /bin/cp linker script (R58.M5 paideia-os #1808).
 * Identical to true.ld / cat.ld / child_hello.ld: text at 0x00400000, data at
 * 0x00600000, bss contiguous with .data. cp is single-object, so there
 * is nothing distinctive here beyond ENTRY(_start).
 *
 * The 4 KiB cp_buf (uninit @align(8)) lives in .bss. Immutable string
 * parts (cp_src_path, cp_dst_path, cp_msg_prefix, cp_msg_nl, cp_err_*)
 * live in .rodata and are folded into the text PT_LOAD by the ALIGN(8)
 * .rodata clause below. .data is empty for this binary; the R31.M2-1595
 * (#1595) contiguity rule between .data and .bss is preserved verbatim.
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
     * `. = 0x00700000;` here, and there must not be one. See true.ld for
     * the full rationale (the 1 MiB PT_LOAD hole this discipline closes).
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
