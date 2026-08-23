/* PaideiaOS elevate_broker_daemon linker script (R48-PREP-005.M2).
 * Same layout as init.ld / child_hello.ld / true.ld / echo_server.ld /
 * acpi_supervisor.ld / pci_enumerator.ld / audio_supervisor.ld: text at
 * 0x00400000, data at 0x00600000, bss contiguous with .data.
 * elevate_broker_daemon is single-object (one .pdx file, one .elf
 * pattern), so there is nothing distinctive here beyond ENTRY(_start).
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
     * `. = 0x00700000;` here, and there must not be one. See
     * echo_server.ld / acpi_supervisor.ld for the full rationale (a fixed
     * .bss origin stretches the single `data` PT_LOAD across the 1 MiB
     * hole between 0x00600000 and 0x00700000, and
     * tools/verify-user-image-extent.sh fails the build if any PT_LOAD in
     * any user image reacquires that hole).
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
