# R15-M1-007 (#519): Embed user shell binary into kernel .rodata.userbin.
# R17-M2-005 (#620): Embed init binary alongside shell.
# R15-M6-009 (#560): Embed child_hello binary alongside init.
# R17.M5 #638:      Embed /bin/true (trivial child-process test binary).
# R20b.M5-001 (#1563): Embed echo_server (R20b userspace-server closure witness).
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
.global _child_hello_bin_start
_child_hello_bin_start:
.incbin "build/user/child_hello.elf"
.global _child_hello_bin_end
_child_hello_bin_end:
.balign 4096
.global _true_bin_start
_true_bin_start:
.incbin "build/user/true.elf"
.global _true_bin_end
_true_bin_end:
.balign 4096
.global _echo_server_bin_start
_echo_server_bin_start:
.incbin "build/user/echo_server.elf"
.global _echo_server_bin_end
_echo_server_bin_end:
.balign 4096
