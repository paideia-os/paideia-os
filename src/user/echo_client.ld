/* PaideiaOS echo_client linker script (R20b.M6-003 / #1566).
 * Text at 0x00400000, data at 0x00600000, bss contiguous with data.
 *
 * R31.M2-1590 (#1590): .bss no longer starts at a fixed 0x00700000.
 *
 * The other seven user linker scripts place .data at 0x00600000 and .bss
 * at 0x00700000 while assigning BOTH to the single `data` PT_LOAD. That
 * is inert for every binary whose .data is empty — the segment simply
 * begins at .bss — and echo_client was, until #1590, the only image with
 * a non-empty .data (`req_payload = "PAIDEIA!"`). With .data occupied,
 * the segment spans from 0x00600000 to past 0x00700000 and the linker
 * emits p_memsz = 0x102000: a 1 MiB program header describing 8 bytes of
 * real data, 4 KiB of real bss, and 1 MiB of hole.
 *
 * Nothing noticed because nothing ever loaded this image: echo_client
 * shipped as a target-shape binary driven by kernel-side witnesses. The
 * moment #1590 actually spawned it, elf_lite_load rejected it with
 * ELF_BAD_SIZE (p_memsz > image_len), and had that gate not existed it
 * would instead have tried to allocate 258 physical frames out of a
 * 1024-frame pool for a program that needs about six.
 *
 * Letting .bss follow .data contiguously is the minimal fix and keeps the
 * program-header count at two, so no loader behaviour changes beyond the
 * sizes. The identical hazard remains latent in the other seven scripts;
 * it is filed separately rather than fixed here, because changing the
 * layout of init.elf and shell.elf is not a change to make in a commit
 * whose subject is the spawn path.
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
