# tools/ap_trampoline_embed.S — R18-M1-002 (paideia-os #761)
#
# Embeds the flat AP boot trampoline blob into kernel .rodata so
# ap_trampoline_install (src/kernel/core/smp/ap_trampoline_relocate.pdx)
# can memcpy it out to physical 0x8000 at boot.
#
# The blob at build/ap_trampoline.bin is produced by tools/build.sh via
# `as` + `ld -T tools/ap_trampoline.ld` + `objcopy -O binary` on
# tools/ap_trampoline.S. See that file's header for the layout and
# parameter-slot conventions.
#
# .rodata.ap_trampoline is placed by the kernel linker script's default
# .rodata catch-all in link.ld (SECTIONS block, .rodata rule collects
# .rodata.*), so no linker script change is required.

.section .rodata.ap_trampoline, "a", @progbits
.balign 16

.global _ap_trampoline_blob_start
_ap_trampoline_blob_start:
.incbin "build/ap_trampoline.bin"
.global _ap_trampoline_blob_end
_ap_trampoline_blob_end:
