/* PaideiaOS init program linker script (R17-m2-001 / #616). */

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
     * Both .data and .bss are assigned to the single `data` PT_LOAD above.
     * Forcing .bss to a fixed 0x00700000 while .data sits at 0x00600000
     * therefore does not create a second segment; it stretches the ONE
     * segment across the 1 MiB hole between them, and the linker emits
     * p_memsz = 0x102000 for any image whose .data is non-empty. That is a
     * 1 MiB program header describing a few KiB of real content.
     *
     * It cost nothing for as long as nothing loaded these images and every
     * one of them happened to have an empty .data. Both halves of that
     * stopped being true: #1590 made the loader spawn user images as real
     * ring-3 tasks and fixed elf_lite_load's per-page mapping loop, so the
     * whole p_memsz extent is now mapped -- one phys_alloc frame per 4 KiB
     * out of a 1024-frame pool, 258 frames for a program needing six. The
     * trigger is adding ONE initialised mutable to a .pdx under src/user/,
     * an edit with no visible connection to memory layout.
     *
     * echo_client.ld was fixed this way in #1590 (it was the only image
     * with a non-empty .data at the time). tools/verify-user-image-extent.sh
     * now fails the build if any PT_LOAD in any user image reacquires a
     * hole, so the eighth script cannot drift back the way these seven did.
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
