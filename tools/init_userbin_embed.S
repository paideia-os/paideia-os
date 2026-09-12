# tools/init_userbin_embed.S — R113 (paideia-os #2441)
#
# Userland-side embed of the real /bin/ls, /bin/cat, /bin/ps ELFs into
# init.elf's .rodata so src/user/rootfs_seed.pdx can seed them via
# chunked sys_write instead of the 9-byte "R57 stub\n" placeholder.
#
# Mirrors tools/userbin_embed.S's kernel-side shape. Symbols are
# prefixed `_init_` to distinguish them from the kernel-side
# `_ls_bin_start` etc. that userbin_embed.S already defines against
# the kernel's .rodata.userbin.
#
# Layout note: init.ld's `.rodata` output section is `:text` (folded
# into the RX PT_LOAD alongside init's code), and its input glob is
# `*(.rodata .rodata.*)`, so `.rodata.initbin` is picked up without
# any init.ld edit. Alignment stays at 8 bytes: the payloads are
# consumed byte-by-byte through the kernel's user_read_bytes_via_walk
# in dispatch_write, so page alignment (as userbin_embed.S uses on
# the kernel side, where bin_seeds.pdx's tmpfs_write loop wants a
# trivial per-page memcpy) would only bloat init.elf without helping
# the read path. 4 KiB alignment would round the three ELFs up by up
# to 12 KiB of dead padding for zero functional gain here.
#
# Ordering discipline: `.incbin` reads the referenced ELF bytes at
# assembly time, so this file must be assembled AFTER build-user.sh
# links build/user/ls.elf, build/user/cat.elf and build/user/ps.elf
# (see the matching reordering in tools/build-user.sh).
#
# Path convention: assembled with `cwd = REPO_ROOT` (matching
# tools/build.sh's userbin_embed.S invocation shape), so the
# `build/user/*.elf` paths are repo-relative.

.section .rodata.initbin, "a", @progbits

.balign 8
.global _init_ls_bin_start
_init_ls_bin_start:
.incbin "build/user/ls.elf"
.global _init_ls_bin_end
_init_ls_bin_end:

.balign 8
.global _init_cat_bin_start
_init_cat_bin_start:
.incbin "build/user/cat.elf"
.global _init_cat_bin_end
_init_cat_bin_end:

.balign 8
.global _init_ps_bin_start
_init_ps_bin_start:
.incbin "build/user/ps.elf"
.global _init_ps_bin_end
_init_ps_bin_end:
