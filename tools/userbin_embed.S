# R15-M1-007 (#519): Embed user shell binary into kernel .rodata.userbin.
# R17-M2-005 (#620): Embed init binary alongside shell.
# R15-M6-009 (#560): Embed child_hello binary alongside init.
# R17.M5 #638:      Embed /bin/true (trivial child-process test binary).
# R20b.M5-001 (#1563): Embed echo_server (R20b userspace-server closure witness).
# R20b.M6-003 (#1566): Embed echo_client (dual-endpoint RPC target-shape).
# R30.M9-002 (#1086):  Embed acpi_supervisor (userspace ACPICA bubble target).
# R48-PREP-005.M2:     Embed elevate_broker_daemon (svc.elevate-broker drainer).
# R61.M1-001 (#1820):  Embed ls, cat, ps, rm, mv, cp, mkdir, touch, dmesg
#                       (R57/R58/R60 tool ELFs, previously build-only).
# R64v2 (#1976/#1977): Embed mkfs.pdxfs, mount.pdxfs, umount.pdxfs
#                       (satellite-repo volume tools, linked via
#                       tools/build.sh's r64v2-tools step into
#                       build/user/*.elf).
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
.global _echo_client_bin_start
_echo_client_bin_start:
.incbin "build/user/echo_client.elf"
.global _echo_client_bin_end
_echo_client_bin_end:
.balign 4096
.global _acpi_supervisor_bin_start
_acpi_supervisor_bin_start:
.incbin "build/user/acpi_supervisor.elf"
.global _acpi_supervisor_bin_end
_acpi_supervisor_bin_end:
.balign 4096
# R33.M5-004 (#1160): audio_supervisor userspace image.
.global _audio_supervisor_bin_start
_audio_supervisor_bin_start:
.incbin "build/user/audio_supervisor.elf"
.global _audio_supervisor_bin_end
_audio_supervisor_bin_end:
.balign 4096
# R48-PREP-005.M2: elevate_broker_daemon userspace image.
.global _elevate_broker_daemon_bin_start
_elevate_broker_daemon_bin_start:
.incbin "build/user/elevate_broker_daemon.elf"
.global _elevate_broker_daemon_bin_end
_elevate_broker_daemon_bin_end:
.balign 4096
# R61.M1-001 (#1820): ls userspace image.
.global _ls_bin_start
_ls_bin_start:
.incbin "build/user/ls.elf"
.global _ls_bin_end
_ls_bin_end:
.balign 4096
# R61.M1-001 (#1820): cat userspace image.
.global _cat_bin_start
_cat_bin_start:
.incbin "build/user/cat.elf"
.global _cat_bin_end
_cat_bin_end:
.balign 4096
# R61.M1-001 (#1820): ps userspace image.
.global _ps_bin_start
_ps_bin_start:
.incbin "build/user/ps.elf"
.global _ps_bin_end
_ps_bin_end:
.balign 4096
# R61.M1-001 (#1820): rm userspace image.
.global _rm_bin_start
_rm_bin_start:
.incbin "build/user/rm.elf"
.global _rm_bin_end
_rm_bin_end:
.balign 4096
# R61.M1-001 (#1820): mv userspace image.
.global _mv_bin_start
_mv_bin_start:
.incbin "build/user/mv.elf"
.global _mv_bin_end
_mv_bin_end:
.balign 4096
# R61.M1-001 (#1820): cp userspace image.
.global _cp_bin_start
_cp_bin_start:
.incbin "build/user/cp.elf"
.global _cp_bin_end
_cp_bin_end:
.balign 4096
# R61.M1-001 (#1820): mkdir userspace image.
.global _mkdir_bin_start
_mkdir_bin_start:
.incbin "build/user/mkdir.elf"
.global _mkdir_bin_end
_mkdir_bin_end:
.balign 4096
# R61.M1-001 (#1820): touch userspace image.
.global _touch_bin_start
_touch_bin_start:
.incbin "build/user/touch.elf"
.global _touch_bin_end
_touch_bin_end:
.balign 4096
# R61.M1-001 (#1820): dmesg userspace image.
.global _dmesg_bin_start
_dmesg_bin_start:
.incbin "build/user/dmesg.elf"
.global _dmesg_bin_end
_dmesg_bin_end:
.balign 4096
# R64v2 (#1976/#1977): mkfs.pdxfs userspace image.
.global _mkfs_pdxfs_bin_start
_mkfs_pdxfs_bin_start:
.incbin "build/user/mkfs.pdxfs.elf"
.global _mkfs_pdxfs_bin_end
_mkfs_pdxfs_bin_end:
.balign 4096
# R64v2 (#1976/#1977): mount.pdxfs userspace image.
.global _mount_pdxfs_bin_start
_mount_pdxfs_bin_start:
.incbin "build/user/mount.pdxfs.elf"
.global _mount_pdxfs_bin_end
_mount_pdxfs_bin_end:
.balign 4096
# R64v2 (#1976/#1977): umount.pdxfs userspace image.
.global _umount_pdxfs_bin_start
_umount_pdxfs_bin_start:
.incbin "build/user/umount.pdxfs.elf"
.global _umount_pdxfs_bin_end
_umount_pdxfs_bin_end:
.balign 4096
