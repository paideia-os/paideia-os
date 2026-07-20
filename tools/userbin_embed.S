# R15-M1-007 (#519): Embed user shell binary into kernel .rodata.userbin.
# R17-M2-005 (#620): Embed init binary alongside shell.
.section .rodata.userbin, "a", @progbits
.balign 4096
.global _shell_bin_start
_shell_bin_start:
.incbin "build/user/shell.elf"
.global _shell_bin_end
_shell_bin_end:
.balign 4096
.global _init_bin_start
_init_bin_start:
.incbin "build/user/init.elf"
.global _init_bin_end
_init_bin_end:
.balign 4096
