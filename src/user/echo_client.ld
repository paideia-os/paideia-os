/* PaideiaOS echo_client linker script (R20b.M6-003 / #1566).
 * Text at 0x00400000, data at 0x00600000, bss contiguous with data.
 *
 * R31.M2-1590 (#1590): .bss no longer starts at a fixed 0x00700000.
 * R31.M2-1595 (#1595): the other seven scripts now match this one.
 *
 * The layout note that used to live here described echo_client as the
 * exception -- the one script whose .bss followed .data, against seven
 * that forced it to 0x00700000 while assigning BOTH sections to the
 * single `data` PT_LOAD. That asymmetry is gone: #1595 fixed all seven,
 * so "same layout as init.ld / child_hello.ld / true.ld" is true again.
 *
 * The hazard those seven carried is worth keeping stated, because it is
 * the reason this file reads the way it does. Two sections sharing one
 * PHDR with a location-counter jump between them do not produce two
 * segments; they produce ONE segment stretched across the gap. With a
 * non-empty .data the linker emits p_memsz = 0x102000 -- 1 MiB of program
 * header for 8 bytes of data and 4 KiB of bss -- and elf_lite_load
 * allocates one frame per 4 KiB of it: 258 frames out of a 1024-frame
 * pool for a program needing about six.
 *
 * echo_client was the only image with a non-empty .data
 * (`req_payload = "PAIDEIA!"`), which is why it was the only one where
 * the defect was ever observable. That is also why it was nearly
 * invisible: with an empty .data, ld drops the zero-size section from the
 * segment and no hole appears in any program header at all.
 *
 * tools/verify-user-image-extent.sh now polices both forms -- the live
 * one from the linked ELF, and the latent one from the script source.
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

    /* R31.M2-1590: contiguous with .data — see the header note. */
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
