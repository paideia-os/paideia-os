/* PaideiaOS /bin/run linker script (Wave UMB-W13 R125.M5 paideia-os #2595).
 *
 * Identical shape to cat.ld / touch.ld / ps.ld: text at 0x00400000, data
 * at 0x00600000, .bss contiguous with .data per the R31.M2-1595 (#1595)
 * discipline.  run.pdx is single-object, so there is nothing distinctive
 * here beyond ENTRY(_start).
 *
 * run_blob (160 B .bss @align(8)) and the string literals (.rodata) are
 * both laid down by the SECTIONS clauses below.  Immutable string parts
 * live in .rodata and are folded into the text PT_LOAD by the ALIGN(8)
 * .rodata clause; the single mutable scratch (run_blob) lives in .bss
 * backed by the data PT_LOAD.
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

    /* R31.M2-1595 (#1595): .bss follows .data CONTIGUOUSLY -- there is
     * no `. = 0x00700000;` here, and there must not be one.  See true.ld
     * for the full rationale (the 1 MiB PT_LOAD hole this discipline
     * closes).
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
