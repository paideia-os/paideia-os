/* PaideiaOS audio_supervisor linker script (R33.M5-001 / #1157).
 * Same layout as acpi_supervisor.ld / pci_enumerator.ld: text at
 * 0x00400000, data at 0x00600000, .bss contiguous with .data.
 * audio_supervisor is single-object (one .pdx file, one .elf pattern) so
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

    /* R31.M2-1595 (#1595): .bss follows .data CONTIGUOUSLY. See
     * acpi_supervisor.ld for the full argument. */
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
