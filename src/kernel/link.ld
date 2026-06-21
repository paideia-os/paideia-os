/* PaideiaOS minimum-viable kernel linker script.
 *
 * QEMU's -kernel loader places ELF64 binaries at the address declared
 * by the ELF program headers. We pin the kernel at the conventional
 * 1 MiB mark for the Phase-0 smoke; higher-half remap lands later
 * once the 32->64 transition + page-table setup are in place.
 *
 * ENTRY symbol _start: defined by src/kernel/boot/entry.pdx. The
 * linker places its containing section first within .text so QEMU
 * lands on it directly.
 */

OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

SECTIONS
{
    . = 0x100000;

    .text : ALIGN(4K) {
        *(.text._start)
        *(.text*)
    }

    .rodata : ALIGN(4K) {
        *(.rodata*)
    }

    .data : ALIGN(4K) {
        *(.data*)
    }

    .bss : ALIGN(4K) {
        *(COMMON)
        *(.bss*)
    }

    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
