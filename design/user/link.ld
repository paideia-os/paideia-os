/* design/user/link.ld — sketch for m8-002 user binary linker script.
 * NOT consumed by tools/build.sh at R13 — src/user/ is outside kernel scope.
 * m8-002 will produce build/shell.elf via a separate build-user.sh invocation
 * using this script; objcopy -O binary then produces build/shell.bin for .incbin.
 */
OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)

USER_VMA = 0x400000;   /* 4 MiB — conventional user text base */

SECTIONS {
    . = USER_VMA;

    .text : {
        *(.text.user._start)
        *(.text .text.*)
    }

    .rodata : ALIGN(4K) {
        *(.rodata .rodata.*)
    }

    .data : ALIGN(4K) {
        *(.data .data.*)
    }

    .bss : ALIGN(4K) {
        *(COMMON)
        *(.bss .bss.*)
    }

    /DISCARD/ : {
        *(.comment)
        *(.eh_frame*)
        *(.note.Xen)
        *(.note.PVH-boot)
    }
}
