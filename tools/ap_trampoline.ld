/* tools/ap_trampoline.ld — R18-M1-002 (paideia-os #761)
 *
 * Standalone linker script for the AP boot trampoline. Places the .text
 * (and any trailing data GAS emits inside .text) at VMA=LMA=0x8000 —
 * the low-memory frame the BSP will copy the blob into before issuing
 * INIT-SIPI-SIPI. The SIPI vector byte is (0x8000 >> 12) = 0x08, so an
 * AP receiving SIPI vector 0x08 wakes at CS:IP = 0x0800:0000, i.e.,
 * physical 0x8000 — the first byte of _ap_trampoline_start.
 *
 * All intra-blob references (data slot loads, ap_gdt_ptr's base field,
 * near jumps into ap_prot_start / ap_long_start) are resolved by the
 * linker with VMA=0x8000, so the blob is ready to execute AS-IS once
 * memcpy'd to 0x8000. Any relocation to a different low-memory page
 * requires re-linking with a different VMA in this script.
 *
 * The resulting ap_trampoline.elf is not itself linked into kernel.elf;
 * `objcopy -O binary` extracts the flat bytes to build/ap_trampoline.bin,
 * which tools/ap_trampoline_embed.S then .incbin's into kernel .rodata.
 */

OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(_ap_trampoline_start)

SECTIONS
{
    . = 0x8000;

    .text : {
        *(.text)
        *(.text.*)
    }

    /DISCARD/ : {
        *(.note*)
        *(.comment)
        *(.eh_frame*)
    }
}
