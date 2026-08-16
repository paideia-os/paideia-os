/* ===================================================================
 * DELIBERATELY BAD LINKER SCRIPT — DO NOT LINK ANYTHING WITH THIS.
 * ===================================================================
 *
 * R31.M2-1601 (#1601). This file is a TEST FIXTURE for rule 3 of
 * tools/verify-user-image-extent.sh ("linker-script lint: no
 * location-counter jump between two output sections that share one
 * program header"). It is not a build input. Nothing under
 * tools/build-user.sh references it; every real link script is named
 * explicitly there, and this one is not and must never be.
 *
 * WHAT IS WRONG WITH IT, ON PURPOSE
 *
 * `.data` and `.bss` are both assigned to the single `data` PT_LOAD,
 * and a `. = 0x00700000;` sits BETWEEN them. That does not create a
 * second segment. It stretches the one segment across the 1 MiB gap,
 * and ld emits p_memsz = 0x102000 the moment `.data` is non-empty.
 * This is the exact defect seven src/user/*.ld scripts carried, fixed
 * in #1595.
 *
 * WHY THE FIXTURE EXISTS
 *
 * Rule 3 must FLAG this file on every invocation of the gate. If it
 * ever stops flagging it, the gate fails with
 * `rule3-selftest-fixture-not-flagged`. See the #1601 comment block in
 * tools/verify-user-image-extent.sh for why a positive self-test is
 * necessary here and not merely nice: rule 3's own vacuity guards all
 * pass on the buggy extractor, because the extractor still finds ONE
 * location-counter statement (the first, at the top of SECTIONS) and
 * every output section with its :phdr. Nothing is empty; the match
 * merely stops happening where it matters. Only a known-bad input that
 * MUST produce a HOLE detects that.
 *
 * DO NOT "FIX" THIS FILE. Repairing the layout below silently deletes
 * the coverage it exists to provide.
 * =================================================================== */

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

    /* Legal: crosses from the `text` PHDR to the `data` PHDR, so the
     * jump lands between two DIFFERENT segments. Rule 3 must NOT flag
     * this one -- it is here so the fixture also proves the rule is
     * discriminating and not just "any dot statement is a hole". */
    . = 0x00600000;

    .data : ALIGN(4K) {
        *(.data .data.*)
    } :data

    /* THE DEFECT. `.data` above and `.bss` below are both `:data`.
     * This jump is inside one program header. Rule 3 must flag it. */
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
