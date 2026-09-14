/* tests/kernel/compositor/test_harness/test.ld -- Wave π (π-02).
 *
 * Dedicated linker script for build/tests/compositor-runner.elf
 * (tools/build.sh --compositor-tests). Byte-identical shape to
 * src/user/link.ld (the generic PaideiaOS user-program script,
 * R15-m1-003 / #515) -- this runner is loaded the same way any other
 * user ELF is (a flat two-PT_LOAD image at the standard 0x00400000 /
 * 0x00600000 split) -- kept as its own file rather than reusing
 * link.ld directly so the test-harness build path (tools/build.sh)
 * never has an implicit dependency on tools/build-user.sh's script set,
 * and so a future divergence (e.g. a larger .bss reservation for a
 * bigger test battery) can land here without touching the shared
 * user-binary script every other src/user/*.pdx target links against.
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

    /* See src/user/link.ld's own extended comment (R31.M2-1595 / #1595)
     * for why .bss follows .data CONTIGUOUSLY with no intervening
     * `. = 0x00700000;` -- the same p_memsz-bloat hazard applies here.
     * tools/verify-user-image-extent.sh's PT_LOAD-hole check covers
     * src/user/*.ld only at landing; this script mirrors the safe shape
     * from day one rather than relying on a future extension of that
     * gate to this path.
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
