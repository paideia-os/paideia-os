# tools/boot_stub.S — 32-bit PVH bridge to 64-bit paideia-as kernel.
# Per Intel SDM Vol 3A §9.8.5 + Xen PVH ABI.

.section .note.PVH-boot, "a", @note
    .long 4                      # n_namesz
    .long 8                      # n_descsz (8 bytes for ELF64 image)
    .long 18                     # n_type = XEN_ELFNOTE_PHYS32_ENTRY
    .ascii "Xen\0"
    .quad _pvh_entry             # 64-bit address

.section .text.boot, "ax", @progbits
.code32

.global _pvh_entry
_pvh_entry:
    cli
    lgdt gdt32_ptr

    # PML4[0] = PDPT phys | RW | P (PDPT is 32-bit aligned, fits in low 32)
    movl $pdpt, %eax
    orl  $0x03, %eax
    movl %eax, pml4 + 0
    movl $0,   pml4 + 4

    # PDPT[0..3] = 1 GiB pages: PS | RW | P at 0/1/2/3 GiB
    movl $0x00000083, pdpt + 0
    movl $0,          pdpt + 4
    movl $0x40000083, pdpt + 8
    movl $0,          pdpt + 12
    movl $0x80000083, pdpt + 16
    movl $0,          pdpt + 20
    movl $0xC0000083, pdpt + 24
    movl $0,          pdpt + 28

    # R13-m3-001 Phase 1 (#445): higher-half aliasing.
    # PML4[256] mirrors PML4[0] so VA 0xFFFF_8000_XXXX_XXXX resolves via
    # the same PDPT (identity map). Installs the mapping only; execution
    # remains at low VA. Phase 2 (#480) relocates kernel VMA.
    movl $pdpt, %eax
    orl  $0x03, %eax               # RW | P
    movl %eax, pml4 + (256 * 8)    # PML4[256].lo = PDPT phys | flags
    movl $0,   pml4 + (256 * 8) + 4  # PML4[256].hi = 0

    # CR3 <- pml4
    movl $pml4, %eax
    movl %eax, %cr3

    # CR4.PAE
    movl %cr4, %eax
    orl  $0x20, %eax
    movl %eax, %cr4

    # EFER.LME via MSR 0xC0000080
    movl $0xC0000080, %ecx
    rdmsr
    orl  $0x100, %eax
    wrmsr

    # CR0.PG | PE | WP  (WP = bit 16, enforces R-only PTEs from ring 0 — required for CoW)
    movl %cr0, %eax
    orl  $0x80010001, %eax
    movl %eax, %cr0

    # Far jump to 64-bit code segment (selector 0x18)
    # In 32-bit code: ljmp opcode=0xEA, 4-byte offset, 2-byte selector
    # GAS .code32 requires us to explicitly encode this since .code32 inside .code64 context is tricky
    # Workaround: use .byte sequence for ljmp $0x18, $long_mode_trampoline
    .byte 0xEA                   # ljmp opcode
    .long long_mode_trampoline   # 32-bit offset (will be relocated)
    .word 0x18                   # 16-bit selector

.code64
long_mode_trampoline:
    # Reload data segments with 64-bit data selector 0x20
    movw $0x20, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw %ax, %fs
    movw %ax, %gs

    # Jump to paideia-as kernel entry
    # R14B-M3-000: absolute far jump — avoids R_X86_64_PC32 overflow
    # when kernel VMA (higher-half) is far from boot stub LMA (#489 split).
    movabsq $_start, %rax
    jmpq    *%rax

.section .rodata.boot, "a", @progbits
.align 8
gdt32:
    .quad 0                          # 0x00 null
    .quad 0x00CF9A000000FFFF         # 0x08 code32
    .quad 0x00CF92000000FFFF         # 0x10 data32
    .quad 0x00AF9A000000FFFF         # 0x18 code64 (L=1)
    .quad 0x00AF92000000FFFF         # 0x20 data64
gdt32_ptr:
    .word 5*8 - 1                    # limit
    .long gdt32                      # base (32-bit, flat zero-base GDT)

.section .rodata, "a", @progbits
.align 8

# R14B-M3-000c (#643): 64-bit absolute-address slot for boot PML4.
# Bridges cross-VA rip-refs from higher-half kernel .pdx code to low-VA
# .bss.boot pml4 (avoids R_X86_64_PC32 overflow once #489 splits VMA).
# Linker emits R_X86_64_64 here → filled with runtime absolute VA of pml4.
.global _pml4_addr
.align 8
_pml4_addr:
    .quad pml4

# B3-004: Banner string for kernel startup message
.global banner_msg
.align 8
banner_msg:
    .ascii "PaideiaOS R8\n\0"

# B5-005: Capability system smoke test message
.global cap_ok_msg
.align 8
cap_ok_msg:
    .ascii "CAP OK\0"

# R9-m1-002: IDT installation message
.global idt_ok_msg
.align 8
idt_ok_msg:
    .ascii "IDT OK\n\0"

# R13-m4-002: TSS installation message
.global tss_ok_msg
.align 8
tss_ok_msg:
    .ascii "TSS OK\n\0"

# R14B-M3-008 (#496): Higher-half execution witness.
.global hi_va_msg
.align 8
hi_va_msg:
    .ascii "HI VA FFFF8000\n\0"

# R14b-m5-008 (#660): CR0.WP enabled — ring-0 respects R-only PTEs (CoW substrate).
.global cr0_wp_ok_msg
.align 8
cr0_wp_ok_msg:
    .ascii "R14B CR0 WP OK\n\0"

# R14b-M5-008 (#660): pf_handler CoW fast-flip witness success message
.global pf_flip_ok_msg
.align 8
pf_flip_ok_msg:
    .ascii "R14B PF FLIP OK\n\0"

# R14b-M5-008 (#660): pf_handler CoW fast-flip witness failure message
.global pf_flip_fail_msg
.align 8
pf_flip_fail_msg:
    .ascii "R14B PF FLIP FAIL\n\0"

# R14.M4-009 (#505): KPTI structural witness success message
.global kpti_ok_msg
.align 8
kpti_ok_msg:
    .ascii "KPTI OK\n\0"

# R14.M4-009 (#505): KPTI structural witness failure message
.global kpti_fail_msg
.align 8
kpti_fail_msg:
    .ascii "KPTI FAIL\n\0"

# R14b-m4-006b (#645): KPTI scratch-slot round-trip witness success message
.global kpti_scratch_ok_msg
.align 8
kpti_scratch_ok_msg:
    .ascii "KPTI SCRATCH OK\n\0"

# R14b-m5-007 (#512): Self-IPI smoke success message
.global ipi_ok_msg
.align 8
ipi_ok_msg:   .ascii "IPI OK\n\0"

# R14b-m5-007 (#512): Self-IPI smoke failure message
.global ipi_fail_msg
.align 8
ipi_fail_msg: .ascii "IPI FAIL\n\0"

# R14b-m5-007b (#646): Self-IPI runtime delivery success message
.global self_ipi_ok_msg
.align 8
self_ipi_ok_msg:   .ascii "SELF IPI OK\n\0"

# R14b-m5-007b (#646): Self-IPI runtime delivery failure message
.global self_ipi_fail_msg
.align 8
self_ipi_fail_msg: .ascii "SELF IPI FAIL\n\0"

# R15-M1-008 (#520): Loader success witness message
.global loader_ok_msg
.align 8
loader_ok_msg: .ascii "LOADER OK\n\0"

# R15-M1-008 (#520): Loader failure witness message
.global loader_fail_msg
.align 8
loader_fail_msg: .ascii "LOADER FAIL\n\0"

# R15-M1-008b (#648): ELF-lite loader runtime success witness message
.global elf_load_ok_msg
.align 8
elf_load_ok_msg: .ascii "ELF LOAD OK\n\0"

# R15-M1-008b (#648): ELF-lite loader runtime failure witness message
.global elf_load_fail_msg
.align 8
elf_load_fail_msg: .ascii "ELF LOAD FAIL\n\0"

# R15-M6-009 (#560): child_hello ELF embed structural witness — success.
# Emitted after kernel-side elf_lite_load(child_hello.elf) into a fresh
# aspace returns ELF_OK. Proves the embed resolves, the ELF header is
# well-formed, and the ELF-lite loader accepts the segment layout.
# Runtime chain (init→fork→exec→child→wait) is deferred to the follow-up
# that unblocks #671 (SC+ execve dispatcher) and reverts #678 (shell-bypass).
.global child_hello_embed_ok_msg
.align 8
child_hello_embed_ok_msg: .ascii "R15 CHILD HELLO EMBED OK\n\0"

.global child_hello_embed_fail_msg
.align 8
child_hello_embed_fail_msg: .ascii "R15 CHILD HELLO EMBED FAIL\n\0"

# #723 (revert of #678): init is the initial ring-3 task; init forks+execs
# its children (shell, child_hello) via sys_execve. The shell-bypass shortcut
# landed in d9393d4 (#678) has been removed now that #554/#555/#671 land.
.global init_boot_ok_msg
.align 8
init_boot_ok_msg: .ascii "INIT BOOT OK\n\0"

# R17-M0-730 D10a (#730): /bin/child_hello tmpfs seed strings and markers.
# See design/kernel/r17-m0-730-d10-execve-complete.md §D10a.
.global bin_seed_name
.align 8
bin_seed_name: .ascii "bin\0"

.global child_hello_seed_name
.align 8
child_hello_seed_name: .ascii "child_hello\0"

.global bin_seed_ok_msg
.align 8
bin_seed_ok_msg: .ascii "R17 BIN CHILD HELLO SEED OK\n\0"

.global bin_seed_fail_msg
.align 8
bin_seed_fail_msg: .ascii "R17 BIN CHILD HELLO SEED FAIL\n\0"

# R17-M5-636 (paideia-os #636): /bin/sh tmpfs seed strings + markers.
# See design/kernel/r17-m5-636-shell-binary-seed.md.
.global sh_seed_name
.align 8
sh_seed_name: .ascii "sh\0"

.global bin_sh_seed_ok_msg
.align 8
bin_sh_seed_ok_msg: .ascii "R17 BIN SH SEED OK\n\0"

.global bin_sh_seed_fail_msg
.align 8
bin_sh_seed_fail_msg: .ascii "R17 BIN SH SEED FAIL\n\0"

# R17.M5 #638 (paideia-os): /bin/true tmpfs seed strings + markers.
# /bin/true is a trivial 2-syscall self-contained user binary
# (src/user/true.pdx) that emits "TRUE OK\n" then sys_exit(0). Seeded
# into /bin at boot alongside /bin/child_hello and /bin/sh, using the
# same vnode_cache_or_alloc pattern to avoid the #754 vnode conflation
# bug (see design/kernel/r17-m0-665-vnode-conflation-fix.md).
.global true_seed_name
.align 8
true_seed_name: .ascii "true\0"

.global bin_true_seed_ok_msg
.align 8
bin_true_seed_ok_msg: .ascii "R17 BIN TRUE SEED OK\n\0"

.global bin_true_seed_fail_msg
.align 8
bin_true_seed_fail_msg: .ascii "R17 BIN TRUE SEED FAIL\n\0"

# logging-m9-001 (#708): KIND_DMESG cap witness strings and markers.
# See design/kernel/kernel-logging-substrate.md §12.10 + §14 Q6.
.global dmesg_cap_ok_msg
.align 8
dmesg_cap_ok_msg: .ascii "R18 DMESG CAP OK\n\0"

.global dmesg_cap_fail_msg
.align 8
dmesg_cap_fail_msg: .ascii "R18 DMESG CAP FAIL\n\0"

# Scratch buffer the DMESG cap witness copies ring bytes into for OP_READ_TAIL.
.global _dmesg_cap_witness_scratch
.align 8
_dmesg_cap_witness_scratch: .zero 512

# logging-m9-002 (#709): sys_dmesg witness strings and markers.
.global sys_dmesg_ok_msg
.align 8
sys_dmesg_ok_msg: .ascii "R18 SYS DMESG OK\n\0"

.global sys_dmesg_fail_msg
.align 8
sys_dmesg_fail_msg: .ascii "R18 SYS DMESG FAIL\n\0"

# logging-m9-003 (#710): audit-log bridge witness — paths, tag, markers.
.global system_dir_name
.align 8
system_dir_name: .ascii "system\0"

.global audit_dir_name
.align 8
audit_dir_name: .ascii "audit\0"

.global audit_log_name
.align 8
audit_log_name: .ascii "log.pdaudit\0"

.global audit_bridge_ok_msg
.align 8
audit_bridge_ok_msg: .ascii "R18 AUDIT BRIDGE OK\n\0"

.global audit_bridge_fail_msg
.align 8
audit_bridge_fail_msg: .ascii "R18 AUDIT BRIDGE FAIL\n\0"

# Tag emitted during the ERROR-level test line to make it grep-recognizable
# in the audit log after flush.
.global audit_test_tag
.align 8
audit_test_tag: .ascii "AUDIT TEST\0"

# Scratch buffer the audit bridge witness copies the audit log content into.
.global _audit_bridge_witness_scratch
.align 8
_audit_bridge_witness_scratch: .zero 4096

.global init_boot_fail_msg
.align 8
init_boot_fail_msg: .ascii "INIT BOOT FAIL\n\0"

.global init_boot_returned_msg
.align 8
init_boot_returned_msg: .ascii "INIT BOOT RETURNED\n\0"

# R15-M2-005-followup (#651): enter_userland_initial relocation success witness message
.global enter_reloc_ok_msg
.align 8
enter_reloc_ok_msg: .ascii "ENTER USER RELOC OK\n\0"

# R15-M2-005-followup (#651): enter_userland_initial relocation failure witness message
.global enter_reloc_fail_msg
.align 8
enter_reloc_fail_msg: .ascii "ENTER USER RELOC FAIL\n\0"

# #679 debug: exception-handler emit marker. exc_handle used to cpu_halt
# silently — any unhandled exception left NO trace on serial, which hid
# #679's post-iretq faults. Now emitted before halt so triage is possible.
.global exc_halt_msg
.align 8
exc_halt_msg: .ascii "EXC HALT\n\0"


# M3-003 (#691): Fake-panic emission chain witness marker
.global ud_panic_witness_msg
.align 8
ud_panic_witness_msg: .ascii "UD PANIC WITNESS\n\0"

# M5-001 (#695): klog_walk_rbp stack walker witness success message
.global m5_walk_ok_msg
.align 8
m5_walk_ok_msg: .ascii "M5 STACK WALK OK\n\0"

# R15-M2-006b (#652): Ring-3 witness start message
.global ring3_start_msg
.align 8
ring3_start_msg: .ascii "R15 RING3 START\n\0"

# R15-M2-006b (#652): Debug message after saving RSP
.global ring3_saved_rsp_msg
.align 8
ring3_saved_rsp_msg: .ascii "R15 SAVED RSP\n\0"


# R15-M2-006b (#652): Debug message before creating PML4
.global ring3_create_pml4_msg
.align 8
ring3_create_pml4_msg: .ascii "R15 CREATE PML4\n\0"

# R15-M2-006b (#652): Debug message after aspace_create
.global ring3_aspace_done_msg
.align 8
ring3_aspace_done_msg: .ascii "R15 ASPACE DONE\n\0"

# R15-M2-006b (#652): Debug message before phys_alloc
.global ring3_phys_alloc_msg
.align 8
ring3_phys_alloc_msg: .ascii "R15 PHYS ALLOC\n\0"

# R15-M2-006b (#652): Debug message after phys_alloc
.global ring3_phys_done_msg
.align 8
ring3_phys_done_msg: .ascii "R15 PHYS DONE\n\0"

# R15-M2-006b (#652): Debug message before calculating VA
.global ring3_calc_va_msg
.align 8
ring3_calc_va_msg: .ascii "R15 CALC VA\n\0"

# R15-M2-006b (#652): Debug message before writing hlt
.global ring3_write_hlt_msg
.align 8
ring3_write_hlt_msg: .ascii "R15 WRITE HLT\n\0"

# R15-M2-006b (#652): Debug message after writing hlt byte
.global ring3_wrote_hlt_msg
.align 8
ring3_wrote_hlt_msg: .ascii "R15 WROTE HLT\n\0"

# R15-M2-006b (#652): Debug message before aspace_map
.global ring3_aspace_map_msg
.align 8
ring3_aspace_map_msg: .ascii "R15 ASPACE MAP\n\0"

# R15-M2-006b (#652): Debug message before user_stack_alloc
.global ring3_stack_alloc_msg
.align 8
ring3_stack_alloc_msg: .ascii "R15 STACK ALLOC\n\0"

# R15-M2-006b (#652): Debug message after user_stack_alloc
.global ring3_stack_done_msg
.align 8
ring3_stack_done_msg: .ascii "R15 STACK DONE\n\0"

# R15-M2-006b (#652): Debug message before entering ring-3
.global ring3_enter_msg
.align 8
ring3_enter_msg: .ascii "R15 ENTER RING3\n\0"

# R15-M2-006b (#652): Debug message if enter_userland_initial returns
.global ring3_returned_msg
.align 8
ring3_returned_msg: .ascii "R15 RETURNED FROM RING3\n\0"

# R14-M3-007c (#650): #UD witness failure message (armed but not fired).
.global ud_witness_fail_msg
.align 8
ud_witness_fail_msg: .ascii "R14 UD FAIL\n\0"

# R15-M2-006b (#652): Ring-3 witness failure message (setup failed)
.global ring3_fail_msg
.align 8
ring3_fail_msg: .ascii "R15 RING3 FAIL\n\0"


# M2-001 (#687): klog_ring_write witness success message
.global m2_ring_ok_msg
.align 8
m2_ring_ok_msg: .ascii "M2 RING OK\n\0"

# M2-001 (#687): klog_ring_write witness failure message
.global m2_ring_fail_msg
.align 8
m2_ring_fail_msg: .ascii "M2 RING FAIL\n\0"

# M2-001 (#687): klog_ring_write witness buffer (3 bytes: "AB\n")
.global _m2_ring_witness_buf
.align 8
_m2_ring_witness_buf: .ascii "AB\n"

# M2-002 (#688): klog_ring_dump_panic witness tags (5 markers)
.global pdmp_w1_tag
.align 8
pdmp_w1_tag: .ascii "PDMP W1 OK\0"

.global pdmp_w2_tag
.align 8
pdmp_w2_tag: .ascii "PDMP W2 OK\0"

.global pdmp_w3_tag
.align 8
pdmp_w3_tag: .ascii "PDMP W3 OK\0"

.global pdmp_w4_tag
.align 8
pdmp_w4_tag: .ascii "PDMP W4 OK\0"

.global pdmp_w5_tag
.align 8
pdmp_w5_tag: .ascii "PDMP W5 OK\0"

# R15-M1-010 (#649): phys_free bitmap release witness success message
.global phys_free_ok_msg
.align 8
phys_free_ok_msg: .ascii "PHYS FREE ROUNDTRIP OK\n\0"

# R15-M1-010 (#649): phys_free bitmap release witness failure message
.global phys_free_fail_msg
.align 8
phys_free_fail_msg: .ascii "PHYS FREE ROUNDTRIP FAIL\n\0"

# R15-M5-007 (#549): fd_table witness success message
.global fd_witness_ok_msg
.align 8
fd_witness_ok_msg: .ascii "R15 FD TABLE OK\n\0"

# R15-M5-007 (#549): fd_table witness failure message
.global fd_witness_fail_msg
.align 8
fd_witness_fail_msg: .ascii "R15 FD TABLE FAIL\n\0"

# R15-M5-006 (#548): task_new witness success message
.global task_new_witness_ok_msg
.align 8
task_new_witness_ok_msg: .ascii "R15 TASK NEW OK\n\0"

# R15-M5-006 (#548): task_new witness failure message
.global task_new_witness_fail_msg
.align 8
task_new_witness_fail_msg: .ascii "R15 TASK NEW FAIL\n\0"

# R15-M5-008 (#550): task_free witness success message
.global task_free_witness_ok_msg
.align 8
task_free_witness_ok_msg: .ascii "R15 TASK FREE OK\n\0"

# R15-M5-008 (#550): task_free witness failure message
.global task_free_witness_fail_msg
.align 8
task_free_witness_fail_msg: .ascii "R15 TASK FREE FAIL\n\0"

# R15-M5-009 (#551): task pool witness — 3-task success message
.global pool_witness_ok_msg
.align 8
pool_witness_ok_msg: .ascii "R15 TASK pool ok pids=1,2,3\n\0"

# R15-M5-009 (#551): task pool witness — failure message
.global pool_witness_fail_msg
.align 8
pool_witness_fail_msg: .ascii "R15 TASK pool FAIL\n\0"

# R15-M6-006 (#557): sys_exit witness success message
.global sys_exit_witness_ok_msg
.align 8
sys_exit_witness_ok_msg: .ascii "R15 SYS EXIT OK\n\0"

# R15-M6-006 (#557): sys_exit witness failure message
.global sys_exit_witness_fail_msg
.align 8
sys_exit_witness_fail_msg: .ascii "R15 SYS EXIT FAIL\n\0"

# R15-M6-005 (#556): sys_wait witness success message
.global sys_wait_witness_ok_msg
.align 8
sys_wait_witness_ok_msg: .ascii "R15 SYS WAIT OK\n\0"

# R15-M6-005 (#556): sys_wait witness failure message
.global sys_wait_witness_fail_msg
.align 8
sys_wait_witness_fail_msg: .ascii "R15 SYS WAIT FAIL\n\0"

# R15-M6-004 (#555): sys_execve witness success message
.global sys_execve_witness_ok_msg
.align 8
sys_execve_witness_ok_msg: .ascii "R15 SYS EXECVE OK\n\0"

# R15-M6-004 (#555): sys_execve witness failure message
.global sys_execve_witness_fail_msg
.align 8
sys_execve_witness_fail_msg: .ascii "R15 SYS EXECVE FAIL\n\0"

# R15-M6-007 (#558): orphan_adoption witness success message
.global orphan_adoption_witness_ok_msg
.align 8
orphan_adoption_witness_ok_msg: .ascii "R15 ORPHAN ADOPT OK\n\0"

# R15-M6-007 (#558): orphan_adoption witness failure message
.global orphan_adoption_witness_fail_msg
.align 8
orphan_adoption_witness_fail_msg: .ascii "R15 ORPHAN ADOPT FAIL\n\0"

# R15-M6-003 (#554): sys_fork witness success + failure messages
.global sys_fork_witness_ok_msg
.align 8
sys_fork_witness_ok_msg: .ascii "R15 SYS FORK OK\n\0"

.global sys_fork_witness_fail_msg
.align 8
sys_fork_witness_fail_msg: .ascii "R15 SYS FORK FAIL\n\0"

# R16-M1-002 (#571): vnode_pool witness success + failure messages
.global vnode_pool_ok_msg
.align 8
vnode_pool_ok_msg: .ascii "R16 VNODE POOL OK\n\0"

.global vnode_pool_fail_msg
.align 8
vnode_pool_fail_msg: .ascii "R16 VNODE POOL FAIL\n\0"

# R16-M1-003 (#572): vops dispatch witness success + failure messages
.global vops_ok_msg
.align 8
vops_ok_msg: .ascii "R16 VOPS OK\n\0"

.global vops_fail_msg
.align 8
vops_fail_msg: .ascii "R16 VOPS FAIL\n\0"

# R16-M1-004 (#573): path_resolve witness success + failure messages
.global path_resolve_ok_msg
.align 8
path_resolve_ok_msg: .ascii "R16 PATH RESOLVE OK\n\0"

.global path_resolve_fail_msg
.align 8
path_resolve_fail_msg: .ascii "R16 PATH RESOLVE FAIL\n\0"

# R16-M1-005 (#574): mount_table witness success + failure messages
.global mount_table_ok_msg
.align 8
mount_table_ok_msg: .ascii "R16 MOUNT TABLE OK\n\0"

.global mount_table_fail_msg
.align 8
mount_table_fail_msg: .ascii "R16 MOUNT TABLE FAIL\n\0"

# R17-M0-665 Phase 3: mount_witness sub-test E message
.global mount_witness_e_fail_msg
.align 8
mount_witness_e_fail_msg: .ascii "MOUNT WITNESS E FAIL\n\0"

# R16-M1-006 (#575): vfs_open witness success + failure messages
.global vfs_open_ok_msg
.align 8
vfs_open_ok_msg: .ascii "R16 VFS OPEN OK\n\0"

.global vfs_open_fail_msg
.align 8
vfs_open_fail_msg: .ascii "R16 VFS OPEN FAIL\n\0"

.global vfs_close_ok_msg
.align 8
vfs_close_ok_msg: .ascii "R16 VFS CLOSE OK\n\0"

.global vfs_close_fail_msg
.align 8
vfs_close_fail_msg: .ascii "R16 VFS CLOSE FAIL\n\0"

# #664 verification: vfs_open O_CREAT witness success + failure messages
.global ocreat_ok_msg
.align 8
ocreat_ok_msg: .ascii "R16 OCREAT OK\n\0"

.global ocreat_fail_msg
.align 8
ocreat_fail_msg: .ascii "OCREAT FAIL\n\0"

# TEMP DEBUG (#664 diagnosis, to be removed): per-sub-test fail markers
.global ocreat_debug_a_msg
.align 8
ocreat_debug_a_msg: .ascii "OCREAT DEBUG FAIL A\n\0"

.global ocreat_debug_b_msg
.align 8
ocreat_debug_b_msg: .ascii "OCREAT DEBUG FAIL B\n\0"

.global ocreat_debug_c_msg
.align 8
ocreat_debug_c_msg: .ascii "OCREAT DEBUG FAIL C\n\0"


# R16-M1-008 (#577): vfs_read/vfs_write witness success + failure messages
.global vfs_rw_ok_msg
.align 8
vfs_rw_ok_msg: .ascii "R16 VFS READ WRITE OK\n\0"

.global vfs_rw_fail_msg
.align 8
vfs_rw_fail_msg: .ascii "R16 VFS READ WRITE FAIL\n\0"

# R16-M1-001 (#578): VFS integration checkpoint message (all R16.M1 witnesses pass)
.global vfs_ok_msg
.align 8
vfs_ok_msg: .ascii "VFS OK\n\0"

# R16-M2-001 (#579): tmpfs inode pool witness success + failure messages
.global tmpfs_inode_pool_ok_msg
.align 8
tmpfs_inode_pool_ok_msg: .ascii "R16 TMPFS INODE POOL OK\n\0"

.global tmpfs_inode_pool_fail_msg
.align 8
tmpfs_inode_pool_fail_msg: .ascii "R16 TMPFS INODE POOL FAIL\n\0"

# R16-M2-002 (#580): tmpfs_init witness success + failure messages
.global tmpfs_init_ok_msg
.align 8
tmpfs_init_ok_msg: .ascii "R16 TMPFS INIT OK\n\0"

.global tmpfs_init_fail_msg
.align 8
tmpfs_init_fail_msg: .ascii "R16 TMPFS INIT FAIL\n\0"

# R16-M2-003 (#581): tmpfs_lookup witness name strings
.global witness_name_tmp
.align 8
witness_name_tmp: .ascii "tmp\0"

.global witness_name_missing
.align 8
witness_name_missing: .ascii "missing\0"

.global witness_name_any
.align 8
witness_name_any: .ascii "x\0"

# R16-M2-003 (#581): tmpfs_lookup witness success + failure messages
.global tmpfs_lookup_ok_msg
.align 8
tmpfs_lookup_ok_msg: .ascii "R16 TMPFS LOOKUP OK\n\0"

.global tmpfs_lookup_fail_msg
.align 8
tmpfs_lookup_fail_msg: .ascii "R16 TMPFS LOOKUP FAIL\n\0"

# R16-M2-004 (#582): tmpfs_create witness success + failure messages
.global tmpfs_create_ok_msg
.align 8
tmpfs_create_ok_msg: .ascii "R16 TMPFS CREATE OK\n\0"

.global tmpfs_create_fail_msg
.align 8
tmpfs_create_fail_msg: .ascii "R16 TMPFS CREATE FAIL\n\0"

# R16-M2-005 (#583): tmpfs_write witness — 100-byte source buffer
.global tmpfs_write_src_buf
.align 8
tmpfs_write_src_buf:
	.rept 100
	.byte 0x41						# 'A'
	.endr

# R16-M2-005 (#583): tmpfs_write witness success + failure messages
.global tmpfs_write_ok_msg
.align 8
tmpfs_write_ok_msg: .ascii "R16 TMPFS WRITE OK\n\0"

.global tmpfs_write_fail_msg
.align 8
tmpfs_write_fail_msg: .ascii "R16 TMPFS WRITE FAIL\n\0"

# R16-M2-006 (#584): tmpfs_read witness — 128-byte destination buffer
# (16 u64 slots; covers the 100-byte read from /tmp/x plus tail slack)
.global tmpfs_read_dst_buf
.align 8
tmpfs_read_dst_buf:
	.rept 16
	.quad 0x0000000000000000
	.endr

# R16-M2-006 (#584): tmpfs_read witness success + failure messages
.global tmpfs_read_ok_msg
.align 8
tmpfs_read_ok_msg: .ascii "R16 TMPFS READ OK\n\0"

.global tmpfs_read_fail_msg
.align 8
tmpfs_read_fail_msg: .ascii "R16 TMPFS READ FAIL\n\0"

# R16-M2-007 (#585): tmpfs_unlink witness success + failure messages
.global tmpfs_unlink_ok_msg
.align 8
tmpfs_unlink_ok_msg: .ascii "R16 TMPFS UNLINK OK\n\0"

.global tmpfs_unlink_fail_msg
.align 8
tmpfs_unlink_fail_msg: .ascii "R16 TMPFS UNLINK FAIL\n\0"

# R16-M2-008 (#586): tmpfs vops table wire-up witness success + failure + name
.global tmpfs_vops_ok_msg
.align 8
tmpfs_vops_ok_msg: .ascii "R16 TMPFS VOPS OK\n\0"

.global tmpfs_vops_fail_msg
.align 8
tmpfs_vops_fail_msg: .ascii "R16 TMPFS VOPS FAIL\n\0"

# R16-M3-001 (#587): sys_open witness success message
.global sys_open_ok_msg
.align 8
sys_open_ok_msg: .ascii "R16 SYS OPEN OK\n\0"

# R16-M3-001 (#587): sys_open witness failure message
.global sys_open_fail_msg
.align 8
sys_open_fail_msg: .ascii "R16 SYS OPEN FAIL\n\0"

# R16-M3-002 (#588): sys_close witness success message
.global sys_close_ok_msg
.align 8
sys_close_ok_msg: .ascii "R16 SYS CLOSE OK\n\0"

# R16-M3-002 (#588): sys_close witness failure message
.global sys_close_fail_msg
.align 8
sys_close_fail_msg: .ascii "R16 SYS CLOSE FAIL\n\0"

# R16-M3-003 (#589): sys_read witness success message
.global sys_read_ok_msg
.align 8
sys_read_ok_msg: .ascii "R16 SYS READ OK\n\0"

# R16-M3-003 (#589): sys_read witness failure message
.global sys_read_fail_msg
.align 8
sys_read_fail_msg: .ascii "R16 SYS READ FAIL\n\0"

# R16-M3-004 (#590): sys_write witness success message
.global sys_write_ok_msg
.align 8
sys_write_ok_msg: .ascii "R16 SYS WRITE OK\n\0"

# R16-M3-004 (#590): sys_write witness failure message
.global sys_write_fail_msg
.align 8
sys_write_fail_msg: .ascii "R16 SYS WRITE FAIL\n\0"

# R16-M3-005 (#591): sys_dup2 witness success message
.global sys_dup2_ok_msg
.align 8
sys_dup2_ok_msg: .ascii "R16 SYS DUP2 OK\n\0"

# R16-M3-005 (#591): sys_dup2 witness failure message
.global sys_dup2_fail_msg
.align 8
sys_dup2_fail_msg: .ascii "R16 SYS DUP2 FAIL\n\0"

# R16-M3-006 (#592): fd_inherit witness success message
.global fd_inherit_ok_msg
.align 8
fd_inherit_ok_msg: .ascii "R16 FD INHERIT OK\n\0"

# R16-M3-006 (#592): fd_inherit witness failure message
.global fd_inherit_fail_msg
.align 8
fd_inherit_fail_msg: .ascii "R16 FD INHERIT FAIL\n\0"

# R16-M3-007 (#593): fd_cloexec witness success message
.global fd_cloexec_ok_msg
.align 8
fd_cloexec_ok_msg: .ascii "R16 FD CLOEXEC OK\n\0"

# R16-M3-007 (#593): fd_cloexec witness failure message
.global fd_cloexec_fail_msg
.align 8
fd_cloexec_fail_msg: .ascii "R16 FD CLOEXEC FAIL\n\0"

# Debug messages for fd_cloexec witness
.global fd_cloexec_fail_setup
.align 8
fd_cloexec_fail_setup: .ascii "R16 FD CLOEXEC FAIL (setup)\n\0"

.global fd_cloexec_fail_execve
.align 8
fd_cloexec_fail_execve: .ascii "R16 FD CLOEXEC FAIL (execve)\n\0"

.global fd_cloexec_fail_sub_a
.align 8
fd_cloexec_fail_sub_a: .ascii "R16 FD CLOEXEC FAIL (sub-test A)\n\0"

.global fd_cloexec_fail_sub_b
.align 8
fd_cloexec_fail_sub_b: .ascii "R16 FD CLOEXEC FAIL (sub-test B)\n\0"

.global fd_cloexec_fail_sub_c
.align 8
fd_cloexec_fail_sub_c: .ascii "R16 FD CLOEXEC FAIL (sub-test C)\n\0"

# R16-M3-008 (#594): FD OK — milestone closure marker
.global fd_ok_msg
.align 8
fd_ok_msg: .ascii "FD OK\n\0"

# R16-M4-001 (#595): uart_rx_init witness success message
.global uart_rx_init_ok_msg
.align 8
uart_rx_init_ok_msg: .ascii "R16 UART RX INIT OK\n\0"

# R16-M4-001 (#595): uart_rx_init witness failure message
.global uart_rx_init_fail_msg
.align 8
uart_rx_init_fail_msg: .ascii "R16 UART RX INIT FAIL\n\0"

# R17-M0-665 Phase 1: vnode_cache_or_alloc witness success message
.global vcache_witness_ok_msg
.align 8
vcache_witness_ok_msg: .ascii "R17 VCACHE OK\n\0"

# R17-M0-665 Phase 1: vnode_cache_or_alloc witness failure message
.global vcache_witness_fail_msg
.align 8
vcache_witness_fail_msg: .ascii "R17 VCACHE FAIL\n\0"

# R17-M0-665 Phase 2: backend_registry witness success message
.global backend_reg_ok_msg
.align 8
backend_reg_ok_msg: .ascii "R17 BACKEND REG OK\n\0"

# R17-M0-665 Phase 2: backend_registry witness failure message
.global backend_reg_fail_msg
.align 8
backend_reg_fail_msg: .ascii "R17 BACKEND REG FAIL\n\0"

# R17-M0-665 Phase 0: word-store landmine microbench success message
.global _wsl_ok_msg
.align 8
_wsl_ok_msg: .ascii "R17 WORD STORE OK\n\0"

# R17-M0-665 Phase 0: word-store landmine microbench failure message
.global _wsl_fail_msg
.align 8
_wsl_fail_msg: .ascii "R17 WORD STORE FAIL\n\0"

# R16-M4-002 (#596): uart_rx_ring witness success message
.global uart_rx_ring_ok_msg
.align 8
uart_rx_ring_ok_msg: .ascii "R16 UART RX RING OK\n\0"

# R16-M4-002 (#596): uart_rx_ring witness failure message
.global uart_rx_ring_fail_msg
.align 8
uart_rx_ring_fail_msg: .ascii "R16 UART RX RING FAIL\n\0"

# R16-M4-003 (#597): uart_rx_isr witness success message
.global uart_rx_isr_ok_msg
.align 8
uart_rx_isr_ok_msg: .ascii "R16 UART RX ISR OK\n\0"

# R16-M4-003 (#597): uart_rx_isr witness failure message
.global uart_rx_isr_fail_msg
.align 8
uart_rx_isr_fail_msg: .ascii "R16 UART RX ISR FAIL\n\0"

# R16-M4-004 (#598): idt vector 0x24 witness success message
.global idt_vec24_ok_msg
.align 8
idt_vec24_ok_msg: .ascii "R16 IDT VEC24 OK\n\0"

# R16-M4-004 (#598): idt vector 0x24 witness failure message
.global idt_vec24_fail_msg
.align 8
idt_vec24_fail_msg: .ascii "R16 IDT VEC24 FAIL\n\0"

# R16-M4-005 (#599): ioapic irq4 witness success message
.global ioapic_irq4_ok_msg
.align 8
ioapic_irq4_ok_msg: .ascii "R16 IOAPIC IRQ4 OK\n\0"

# R16-M4-005 (#599): ioapic irq4 witness failure message
.global ioapic_irq4_fail_msg
.align 8
ioapic_irq4_fail_msg: .ascii "R16 IOAPIC IRQ4 FAIL\n\0"

# R16-M4-006 (#600): uart_rx_notify witness success message
.global uart_rx_notify_ok_msg
.align 8
uart_rx_notify_ok_msg: .ascii "R16 UART RX NOTIFY OK\n\0"

# R16-M4-006 (#600): uart_rx_notify witness failure message
.global uart_rx_notify_fail_msg
.align 8
uart_rx_notify_fail_msg: .ascii "R16 UART RX NOTIFY FAIL\n\0"

# R16-M4-007 (#601): uart_rx_smoke witness prefix (fingerprint AC)
.global uart_rx_smoke_prefix_msg
.align 8
uart_rx_smoke_prefix_msg: .ascii "UART RX: \0"

# R16-M4-007 (#601): uart_rx_smoke witness failure message
.global uart_rx_smoke_fail_msg
.align 8
uart_rx_smoke_fail_msg: .ascii "R16 UART RX SMOKE FAIL\n\0"

# R16-M5-001 (#602): tty_init witness success message
.global tty_ok_msg
.align 8
tty_ok_msg: .ascii "R16 TTY VNODE OK\n\0"

# R16-M5-001 (#602): tty_init witness failure message
.global tty_fail_msg
.align 8
tty_fail_msg: .ascii "R16 TTY VNODE FAIL\n\0"

# R16-M5-002 (#603): tty_vops_init witness success message
.global tty_vops_ok_msg
.align 8
tty_vops_ok_msg: .ascii "R16 TTY VOPS OK\n\0"

# R16-M5-002 (#603): tty_vops_init witness failure message
.global tty_vops_fail_msg
.align 8
tty_vops_fail_msg: .ascii "R16 TTY VOPS FAIL\n\0"

# R16-M5-003 (#604): tty_line_buffer witness success message
.global tty_line_ok_msg
.align 8
tty_line_ok_msg: .ascii "R16 TTY LINE OK\n\0"

# R16-M5-003 (#604): tty_line_buffer witness failure message
.global tty_line_fail_msg
.align 8
tty_line_fail_msg: .ascii "R16 TTY LINE FAIL\n\0"

# R16-M5-004 (#605): tty_process_input witness success message
.global tty_input_ok_msg
.align 8
tty_input_ok_msg: .ascii "R16 TTY INPUT OK\n\0"

# R16-M5-004 (#605): tty_process_input witness failure message
.global tty_input_fail_msg
.align 8
tty_input_fail_msg: .ascii "R16 TTY INPUT FAIL\n\0"

# R16-M5-005 (#606): tty_read witness success message
.global tty_read_ok_msg
.align 8
tty_read_ok_msg: .ascii "R16 TTY READ OK\n\0"

# R16-M5-005 (#606): tty_read witness failure message
.global tty_read_fail_msg
.align 8
tty_read_fail_msg: .ascii "R16 TTY READ FAIL\n\0"

# R17-M5 (#748): tty_stdin_bridge witness success message
.global tty_stdin_bridge_ok_msg
.align 8
tty_stdin_bridge_ok_msg: .ascii "R17 TTY STDIN BRIDGE OK\n\0"

# R17-M5 (#748): tty_stdin_bridge witness failure message
.global tty_stdin_bridge_fail_msg
.align 8
tty_stdin_bridge_fail_msg: .ascii "R17 TTY STDIN BRIDGE FAIL\n\0"

# R16-M5-006 (#607): tty_write witness success message
.global tty_write_ok_msg
.align 8
tty_write_ok_msg: .ascii "R16 TTY WRITE OK\n\0"

# R16-M5-006 (#607): tty_write witness failure message
.global tty_write_fail_msg
.align 8
tty_write_fail_msg: .ascii "R16 TTY WRITE FAIL\n\0"

# R16-M5-007 (#608): tty_connect_init witness success message
.global tty_connect_ok_msg
.align 8
tty_connect_ok_msg: .ascii "R16 TTY CONNECT OK\n\0"

# R16-M5-007 (#608): tty_connect_init witness failure message
.global tty_connect_fail_msg
.align 8
tty_connect_fail_msg: .ascii "R16 TTY CONNECT FAIL\n\0"

# R16-M5-009 (#609): tty_smoke integration witness success message
.global tty_smoke_ok_msg
.align 8
tty_smoke_ok_msg: .ascii "TTY OK\n\0"

# R16-M5-009 (#609): tty_smoke integration witness failure message
.global tty_smoke_fail_msg
.align 8
tty_smoke_fail_msg: .ascii "TTY SMOKE FAIL\n\0"

# R17-M1-006 (#615): libc_test_witness start message
.global libc_test_start_msg
.align 8
libc_test_start_msg: .ascii "LIBC TEST START\n\0"

# R17-M1-006 (#615): libc_test_witness success message
.global libc_test_ok_msg
.align 8
libc_test_ok_msg: .ascii "LIBC TEST OK\n\0"

# R17-M1-006 (#615): libc_test_witness failure message
.global libc_test_fail_msg
.align 8
libc_test_fail_msg: .ascii "LIBC TEST FAIL\n\0"

# R17-M2-005 (#620): init_bootstrap witness success message
.global init_load_ok_msg
.align 8
init_load_ok_msg: .ascii "R17 INIT LOAD OK\n\0"

# R17-M2-005 (#620): init_bootstrap witness failure message
.global init_load_fail_msg
.align 8
init_load_fail_msg: .ascii "R17 INIT LOAD FAIL\n\0"

.global tmpfs_vops_witness_name_tmp
.align 8
tmpfs_vops_witness_name_tmp: .ascii "tmp\0"

# R16-M1-004 (#573): witness path strings for path_resolve sub-tests
.global witness_path_slash
.align 8
witness_path_slash: .ascii "/\0"

.global witness_path_dot
.align 8
witness_path_dot: .ascii ".\0"

.global witness_path_dotdot
.align 8
witness_path_dotdot: .ascii "..\0"

.global witness_path_foo_bar
.align 8
witness_path_foo_bar: .ascii "/foo/bar\0"

.global witness_path_nope
.align 8
witness_path_nope: .ascii "/nope\0"

# #664 verification: vfs_open O_CREAT witness path/name strings
.global witness_path_newfile
.align 8
witness_path_newfile: .ascii "/newfile\0"

.global witness_name_newfile
.align 8
witness_name_newfile: .ascii "newfile\0"

.global witness_path_double_slash
.align 8
witness_path_double_slash: .ascii "//foo//bar\0"

# R16-M3-003 (#589): sys_read witness path for /tmp/x
.global witness_path_tmp_x
.align 8
witness_path_tmp_x: .ascii "/tmp/x\0"



# R15-M7-001 (#562): idle-task witness success message
.global idle_witness_ok_msg
.align 8
idle_witness_ok_msg: .ascii "R15 IDLE TASK OK\n\0"

# R15-M7-001 (#562): idle-task witness failure message
.global idle_witness_fail_msg
.align 8
idle_witness_fail_msg: .ascii "R15 IDLE TASK FAIL\n\0"

# R15-M7-002 (#563): runqueue witness success message
.global runq_witness_ok_msg
.align 8
runq_witness_ok_msg: .ascii "R15 RUNQUEUE OK\n\0"

# R15-M7-002 (#563): runqueue witness failure message
.global runq_witness_fail_msg
.align 8
runq_witness_fail_msg: .ascii "R15 RUNQUEUE FAIL\n\0"

# R15-M7-003 (#564): sched_switch witness success message
.global sched_switch_witness_ok_msg
.align 8
sched_switch_witness_ok_msg: .ascii "R15 SCHED SWITCH OK\n\0"

# R15-M7-003 (#564): sched_switch witness failure message
.global sched_switch_witness_fail_msg
.align 8
sched_switch_witness_fail_msg: .ascii "R15 SCHED SWITCH FAIL\n\0"

# R15-M7-006 (#567): sched_block/sched_wake witness success message
.global block_wake_witness_ok_msg
.align 8
block_wake_witness_ok_msg: .ascii "R15 BLOCK WAKE OK\n\0"

# R15-M7-006 (#567): sched_block/sched_wake witness failure message
.global block_wake_witness_fail_msg
.align 8
block_wake_witness_fail_msg: .ascii "R15 BLOCK WAKE FAIL\n\0"

# R15-M7-566 (#566): timer-preempt witness success/failure messages
.global preempt_witness_ok_msg
.align 8
preempt_witness_ok_msg: .ascii "R15 PREEMPT OK\n\0"

.global preempt_witness_fail_msg
.align 8
preempt_witness_fail_msg: .ascii "R15 PREEMPT FAIL\n\0"

# R15-M6-004 (#555): sys_execve witness — bad-ELF payload for sub-test B.
# 64 bytes; first 4 bytes deliberately NOT \x7fELF, so elf_lite_load
# rejects at the magic gate (returns ELF_BAD_HDR = 0xFFFFFFFF).
.global _bad_elf_stub_start
.align 8
_bad_elf_stub_start:
    .byte 0xDE, 0xAD, 0xBE, 0xEF
    .byte 0x02, 0x01, 0x01, 0x00
    .fill 56, 1, 0
.global _bad_elf_stub_end
_bad_elf_stub_end:


# R15-M6-008 (#559): frame_meta refcount witness success message
.global frame_meta_ok_msg
.align 8
frame_meta_ok_msg: .ascii "R15 FRAME META OK\n\0"

# R15-M6-008 (#559): frame_meta refcount witness failure message
.global frame_meta_fail_msg
.align 8
frame_meta_fail_msg: .ascii "R15 FRAME META FAIL\n\0"

# R15-M6-001 (#552): aspace_clone_cow witness markers (6 rodata strings)
.global clone_cow_empty_ok_msg
.align 8
clone_cow_empty_ok_msg: .ascii "R15 CLONE COW EMPTY OK\n\0"

.global clone_cow_empty_fail_msg
.align 8
clone_cow_empty_fail_msg: .ascii "R15 CLONE COW EMPTY FAIL\n\0"

.global clone_cow_1page_ok_msg
.align 8
clone_cow_1page_ok_msg: .ascii "R15 CLONE COW 1PAGE OK\n\0"

.global clone_cow_1page_fail_msg
.align 8
clone_cow_1page_fail_msg: .ascii "R15 CLONE COW 1PAGE FAIL\n\0"

.global clone_cow_multi_ok_msg
.align 8
clone_cow_multi_ok_msg: .ascii "R15 CLONE COW MULTI OK\n\0"

.global clone_cow_multi_fail_msg
.align 8
clone_cow_multi_fail_msg: .ascii "R15 CLONE COW MULTI FAIL\n\0"

# R16-M0-D11a: aspace_teardown leak-plug witness messages.
.global aspace_teardown_ok_msg
.align 8
aspace_teardown_ok_msg: .ascii "R16 M0 D11A TEARDOWN OK\n\0"

.global aspace_teardown_fail_msg
.align 8
aspace_teardown_fail_msg: .ascii "R16 M0 D11A TEARDOWN FAIL\n\0"


# R15-M4-007 (#541): user_ptr_ok witness messages
.global user_ptr_ok_msg
.align 8
user_ptr_ok_msg: .ascii "R15 USER PTR OK\n\0"

.global user_ptr_fail_msg
.align 8
user_ptr_fail_msg: .ascii "R15 USER PTR FAIL\n\0"

# M0-001 (#681): u64_to_hex and u64_to_dec leaf helpers witness messages
.global logp_hex_ok_msg
.align 8
logp_hex_ok_msg: .ascii "LOGP HEX OK\n\0"

# #712: byte-compare failure message + 6 fixture strings for u64_to_hex/u64_to_dec canaries
.global logp_hex_fail_msg
.align 8
logp_hex_fail_msg: .ascii "LOGP HEX FAIL\n\0"

# u64_to_hex fixtures — each is exactly 18 bytes ("0x" + 16 hex nibbles MSB-first)
.global logp_hex_expect_0
.align 8
logp_hex_expect_0: .ascii "0x0000000000000000"

.global logp_hex_expect_deadbeef
.align 8
logp_hex_expect_deadbeef: .ascii "0xdeadbeefcafef00d"

.global logp_hex_expect_max
.align 8
logp_hex_expect_max: .ascii "0xffffffffffffffff"

# u64_to_dec fixtures — variable-length decimal render
.global logp_dec_expect_0
.align 8
logp_dec_expect_0: .ascii "0"

.global logp_dec_expect_12345
.align 8
logp_dec_expect_12345: .ascii "12345"

# 2^64 - 1 = 18446744073709551615 (20 digits)
.global logp_dec_expect_max
.align 8
logp_dec_expect_max: .ascii "18446744073709551615"

# M0-002 (#682): kread_tsc and kread_cpu_id witness messages
.global logp_tsc_ok_msg
.align 8
logp_tsc_ok_msg: .ascii "LOGP TSC OK\n\0"

.global logp_tsc_fail_msg
.align 8
logp_tsc_fail_msg: .ascii "LOGP TSC FAIL\n\0"

# M1-003 (#685): klog_emit_core witness tags
.global tag_m1_emit_ok
.align 8
tag_m1_emit_ok: .ascii "M1 EMIT OK\0"

# M1-004 (#686): per-arity wrappers witness tags
.global tag_m1_s1_ok
.align 8
tag_m1_s1_ok: .ascii "M1 S1 OK\0"

.global tag_m1_s1x1
.align 8
tag_m1_s1x1: .ascii "M1 S1X1\0"

.global tag_m1_s1x2
.align 8
tag_m1_s1x2: .ascii "M1 S1X2\0"

.global tag_m1_s1x3
.align 8
tag_m1_s1x3: .ascii "M1 S1X3\0"

.global tag_m1_s1x4
.align 8
tag_m1_s1x4: .ascii "M1 S1X4\0"

.global tag_m1_s1d1
.align 8
tag_m1_s1d1: .ascii "M1 S1D1\0"

.global tag_m1_sxd
.align 8
tag_m1_sxd: .ascii "M1 SXD\0"

# M1-004 (#686): per-arity wrappers witness KV keys
.global k_cr2
.align 8
k_cr2: .ascii "cr2\0"

.global k_vec
.align 8
k_vec: .ascii "vec\0"

.global k_err
.align 8
k_err: .ascii "err\0"

.global k_rip
.align 8
k_rip: .ascii "rip\0"

.global k_cs
.align 8
k_cs: .ascii "cs\0"

.global k_pid
.align 8
k_pid: .ascii "pid\0"

.global k_line
.align 8
k_line: .ascii "line\0"


# R20b.M1-001 (#1552): KIND_IPC_ENDPOINT capability witness — post-R20 IPC
# substrate foundation. See design/ipc/userspace-server-substrate.md §3.1.
.global endpoint_cap_ok_msg
.align 8
endpoint_cap_ok_msg: .ascii "R20b ENDPOINT CAP OK\n\0"

.global endpoint_cap_fail_msg
.align 8
endpoint_cap_fail_msg: .ascii "R20b ENDPOINT CAP FAIL\n\0"


# R29.M0-001 (#1017): KIND_HW base-kind witness fingerprints — promotes
# slot 14 of the 16-slot base_kind enum from the prior "fault" placeholder
# to KIND_HW, the base kind for hardware-adjacent caps. KIND_HW_INTERRUPT
# and KIND_HW_MSIX_VECTOR derive over it in R29.M1 (#1019-#1022);
# KIND_DMA_DOMAIN (R29.M5, #1036) landed over KIND_MEMORY instead — the
# planning skeleton's `KIND_HW_DMA_DOMAIN` name is retired, see
# src/kernel/core/cap/kind_dma_domain.pdx §"Naming reconciliation".
# KIND_HW_TIMELINE remains reserved. See:
#   - src/kernel/core/cap/kind.pdx (KIND_HW = 14 declaration + rationale)
#   - design/capabilities/linearity-and-tags.md §3.1a
#   - design/architecture/next-wave-derived-kinds.md §KIND_HW
#   - design/roadmap/next-wave-synthesis.md §10 D6
.global kind_hw_ok_msg
.align 8
kind_hw_ok_msg: .ascii "R29 KIND_HW OK\n\0"

.global kind_hw_fail_msg
.align 8
kind_hw_fail_msg: .ascii "R29 KIND_HW FAIL\n\0"


# R29.M1-001..003 (#1019/#1020/#1021): KIND_HW_INTERRUPT derived-kind
# witness fingerprints — derived over KIND_HW (base slot 14, R29.M0-001
# #1017). Numeric derived tag 0x140 (decimal 320), above the 4-bit base
# range. See:
#   - src/kernel/core/cap/kind_hw_interrupt.pdx (module implementation)
#   - src/kernel/core/cap/kind.pdx (KIND_HW_INTERRUPT = 0x140 declaration)
#   - src/kernel/core/cap/invoke.pdx (call_kind_hw_interrupt branch)
#   - design/architecture/next-wave-derived-kinds.md §KIND_HW_INTERRUPT
#   - design/roadmap/next-wave-softarch.md §3 R29 (tail spec)
.global kind_hw_int_ok_msg
.align 8
kind_hw_int_ok_msg: .ascii "R29 KIND_INTERRUPT OK\n\0"

.global kind_hw_int_fail_msg
.align 8
kind_hw_int_fail_msg: .ascii "R29 KIND_INTERRUPT FAIL\n\0"


# R29.M1-004 (#1022): KIND_HW_MSIX_VECTOR derived-kind witness
# fingerprints — second derived kind over KIND_HW (base slot 14),
# layered atop KIND_HW_INTERRUPT (0x140). Numeric derived tag 0x141
# (decimal 321). Witness at kernel_main.pdx §kind_hw_msix_witness
# mints one KIND_HW_INTERRUPT parent and 4 KIND_HW_MSIX_VECTOR
# children, verifies each tail decode, then revokes the parent and
# asserts all four children are auto-revoked via
# msix_cascade_revoke_by_parent. See:
#   - src/kernel/core/cap/kind_hw_msix_vector.pdx (module implementation)
#   - src/kernel/core/cap/kind.pdx (KIND_HW_MSIX_VECTOR = 0x141 declaration)
#   - src/kernel/core/cap/invoke.pdx (call_kind_hw_msix_vector branch)
#   - src/kernel/core/cap/kind_hw_interrupt.pdx (cascade call site)
#   - design/architecture/next-wave-derived-kinds.md §KIND_HW_MSIX_VECTOR
.global kind_hw_msix_ok_msg
.align 8
kind_hw_msix_ok_msg: .ascii "R29 KIND_MSIX_VECTOR OK\n\0"

.global kind_hw_msix_fail_msg
.align 8
kind_hw_msix_fail_msg: .ascii "R29 KIND_MSIX_VECTOR FAIL\n\0"


# R29.M5-001 (#1036) + R29.M5-002 (#1037): KIND_DMA_DOMAIN derived-kind
# witness fingerprints — per-driver-process IOMMU domain, derived over
# KIND_MEMORY (= KIND_PAGE, base slot 4) rather than KIND_HW. Numeric
# derived tag 0x142 (decimal 322), third entry in the R29 derived-kind
# block. Witness at kernel_main.pdx §kind_dma_domain_witness mints a
# KIND_MEMORY parent, mints two domains under it with distinct
# {iommu_ctx_id, bus_dev_fn, capacity_bytes, coherency} tuples, asserts
# the encode->decode identity for all four tail fields through
# cap_invoke_dispatch, walks every failure edge (bad parent kind,
# insufficient rights, out-of-range coherency, zero capacity, row-table
# exhaustion, revoke of a foreign kind, double revoke), then
# cascade-revokes both domains via the memory parent and asserts the
# rows and descriptors are cleared. See:
#   - src/kernel/core/cap/kind_dma_domain.pdx (module implementation)
#   - src/kernel/core/cap/kind.pdx (KIND_MEMORY + KIND_DMA_DOMAIN decls)
#   - src/kernel/core/cap/invoke.pdx (call_kind_dma_domain branch)
#   - design/architecture/next-wave-derived-kinds.md §KIND_DMA_DOMAIN
.global kind_dma_domain_ok_msg
.align 8
kind_dma_domain_ok_msg: .ascii "R29 KIND_DMA_DOMAIN OK\n\0"

.global kind_dma_domain_fail_msg
.align 8
kind_dma_domain_fail_msg: .ascii "R29 KIND_DMA_DOMAIN FAIL\n\0"


# R30.M3-001 (#1061): KIND_OP_REGION witness fingerprints — the address-
# space window capability, and the security boundary of R30. The witness
# mints two ROOT windows (one memory-like over a KIND_MEMORY parent, one
# port-like over a KIND_IO_PORT parent), proves the derivation asymmetry
# by trying each space against the wrong parent kind, derives a contained
# sub-window, REFUSES an uncontained one with OPREG_MINT_NO_COVER without
# allocating or clipping, refuses a window with no covering capability at
# all, and finally cascade-revokes transitively so no grandchild row
# outlives the root that justified it. See:
#   - src/kernel/core/cap/kind_op_region.pdx (module implementation)
#   - src/kernel/core/cap/kind.pdx (KIND_OP_REGION decl)
#   - src/kernel/core/cap/invoke.pdx (call_kind_op_region branch)
#   - design/architecture/next-wave-derived-kinds.md §KIND_OP_REGION
.global kind_op_region_ok_msg
.align 8
kind_op_region_ok_msg: .ascii "R30 KIND_OP_REGION OK\n\0"

.global kind_op_region_fail_msg
.align 8
kind_op_region_fail_msg: .ascii "R30 KIND_OP_REGION FAIL\n\0"


# R29.M2-001 (#1023): driver lifecycle FSM witness fingerprints — opens
# R29.M2 (Lifecycle FSM real bodies + regression corpus). The FSM has
# six states (Init/Running/Suspended/Handoff/Stopping/Stopped) and its
# whitelist of nine legal transitions is enforced by
# driver_lifecycle_transition against the driver descriptor at
# _driver_table[slot]. Witness at kernel_main.pdx §driver_lifecycle_witness
# walks the full Init->Stopped path and asserts every rejected-transition
# error code (ERR_BAD_SLOT / ERR_UNKNOWN_STATE / ERR_INVALID_TRANSITION).
# See:
#   - src/kernel/core/driver/lifecycle.pdx (FSM constants + transition_valid)
#   - src/kernel/core/driver/driver_table.pdx (32-slot descriptor storage)
#   - design/architecture/next-wave-derived-kinds.md §Driver lifecycle FSM
#   - design/roadmap/next-wave-softarch.md §3 R29 (Milestones — R29.M2)
# R29.M5-003 (#1038) + R29.M5-004 (#1039): per-driver-process DMA domain
# + IOMMU domain-switching contract fingerprints — closes R29.M5.
# D1.b fixes IOMMU granularity at exactly ONE KIND_DMA_DOMAIN per driver
# process; driver_lifecycle_start mints it on the FSM's single Init ->
# Running entry edge and driver_lifecycle_teardown revokes it after the
# terminal Stopped state. iommu_domain_switch is the kernel-owned path
# from a domain capability to a VT-d context entry: it validates holder,
# authority, liveness, quiescence, BDF-in-binding and context-entry
# exclusivity, each with its own refusal code, and drives the row [+24]
# state machine (NONE / PENDING / PROGRAMMED). The real VT-d write is
# wired to vtd_context_program but dormant behind the R22.M5 backing
# registration (Features.IOMMU_ENABLED = 0). Witness at kernel_main.pdx
# §dma_domain_switch_witness spawns two fake driver processes, proves the
# duplicate-mint refusal, walks every switch refusal edge, and asserts no
# row leaks across two spawn/exit cycles. See:
#   - src/kernel/core/iommu/domain_switch.pdx (the contract)
#   - src/kernel/core/driver/lifecycle.pdx (start / teardown)
#   - src/kernel/core/driver/driver_table.pdx (the cardinality gate)
#   - design/drivers/blob-policy.md §2.5 / §2.6
.global dma_domain_switch_ok_msg
.align 8
dma_domain_switch_ok_msg: .ascii "R29 DMA DOMAIN SWITCH OK\n\0"

.global dma_domain_switch_fail_msg
.align 8
dma_domain_switch_fail_msg: .ascii "R29 DMA DOMAIN SWITCH FAIL\n\0"


.global driver_lifecycle_ok_msg
.align 8
driver_lifecycle_ok_msg: .ascii "R29 LIFECYCLE FSM OK\n\0"

.global driver_lifecycle_fail_msg
.align 8
driver_lifecycle_fail_msg: .ascii "R29 LIFECYCLE FSM FAIL\n\0"


# R29.M2-004 (#1026): driver lifecycle FSM fuzz witness fingerprints.
# Runs a 1000-iteration Knuth-LCG fuzz over the six-state FSM: for each
# iter, derives (cur, new) from the LCG state, seeds driver row slot=0
# with cur via driver_table_write_state_byte, computes the whitelist
# predicate via driver_lifecycle_transition_valid(cur, new), invokes
# driver_lifecycle_transition(0, new), and asserts the two agree
# (predicate == 1 iff transition returns OK AND state == new;
#  predicate == 0 iff transition returns non-zero AND state unchanged).
# The 3-bit (cur, new) slice covers values in [0..8), forcing ~25%
# of iters to exercise ERR_UNKNOWN_STATE / ERR_INVALID_TRANSITION paths.
# See:
#   - src/kernel/core/driver/lifecycle.pdx (FSM primitives)
#   - src/kernel/boot/kernel_main.pdx §driver_lifecycle_fuzz_witness
#   - design/ipc/driver-lifecycle-schema.md §6 (kernel-side coupling)
.global driver_lifecycle_fuzz_ok_msg
.align 8
driver_lifecycle_fuzz_ok_msg: .ascii "R29 LIFECYCLE FUZZ OK\n\0"

.global driver_lifecycle_fuzz_fail_msg
.align 8
driver_lifecycle_fuzz_fail_msg: .ascii "R29 LIFECYCLE FUZZ FAIL\n\0"


# R29.M3-001 (#1028) + R29.M3-002 (#1029): driver registry v2 witness —
# path components + fingerprints.
#
# The witness seeds /system/registry/{drivers.pdxreg,drivers.pdxreg.new}
# on tmpfs (/system itself is created by the audit-bridge witness), binds
# the two inode indices into registry_persist.pdx, encodes two driver
# records projected from driver_table slots 0 and 1, seals the image
# (content checksum + ML-DSA-65 signature block with an all-zero scaffold
# body), publishes it shadow-first, reads it back, and asserts the
# round-trip is byte-exact across all 3549 bytes. It then exercises five
# failure edges against the read-back copy (corrupt magic, corrupt
# record, non-zero signature body, out-of-range record index,
# out-of-range publish count).
#
# The shadow file name is a sibling rather than a dotfile because tmpfs
# stores a 32-byte inline name; "drivers.pdxreg.new" (18 B) fits without
# truncation and cannot collide with "drivers.pdxreg" (14 B).
#
# See:
#   - design/drivers/registry-v2.md (schema, layout, versioning, signing)
#   - src/kernel/core/driver/registry_v2.pdx
#   - src/kernel/core/driver/registry_persist.pdx
#   - src/kernel/boot/kernel_main.pdx §registry_v2_witness
.global registry_dir_name
.align 8
registry_dir_name: .ascii "registry\0"

.global registry_file_name
.align 8
registry_file_name: .ascii "drivers.pdxreg\0"

.global registry_shadow_name
.align 8
registry_shadow_name: .ascii "drivers.pdxreg.new\0"

.global registry_v2_ok_msg
.align 8
registry_v2_ok_msg: .ascii "R29 REGISTRY V2 OK\n\0"

.global registry_v2_fail_msg
.align 8
registry_v2_fail_msg: .ascii "R29 REGISTRY V2 FAIL\n\0"


# R29.M3-003 (#1030) + R29.M3-004 (#1031): registry lookup / hot-reload /
# snapshot-rollback witness fingerprints.
#
# The witness rebuilds a two-record image over driver_table slots 0
# (uart-16550, driven to RUNNING) and 1 (nvme-pcie, left at INIT),
# publishes it, then exercises: lookup by name (hit, hit, prefix-miss,
# absent-miss, over-long key), lookup by slot (hit, hit, absent-miss,
# out-of-range), a no-op hot-reload, snapshot -> mutate -> rollback with
# the mutation proven gone in memory AND on disk, two bad-snapshot
# rejections, a hot-reload that would change a RUNNING driver's manifest
# (rejected with ERR_RELOAD_CONFLICT, live image proven untouched), and a
# hot-reload that changes a non-RUNNING driver's manifest (adopted, with
# the generation id bumped).
#
# See:
#   - design/drivers/registry-v2.md §8 (lookup + hot-reload), §9 (snapshot)
#   - src/kernel/core/driver/registry_lookup.pdx
#   - src/kernel/core/driver/registry_snapshot.pdx
#   - src/kernel/boot/kernel_main.pdx §registry_lookup_witness
.global registry_lookup_ok_msg
.align 8
registry_lookup_ok_msg: .ascii "R29 REGISTRY LOOKUP OK\n\0"

.global registry_lookup_fail_msg
.align 8
registry_lookup_fail_msg: .ascii "R29 REGISTRY LOOKUP FAIL\n\0"


# R29.M4-001/002 (#1032/#1033): pinned keyring + driver-artifact
# signature-verifier witness fingerprints.
#
# Exercises: keyring fsck clean over all three roles; lookup hit for
# paideia_root / vendor_intel / vendor_realtek with the three key blobs
# proven distinct and 64-byte aligned; lookup miss (ERR_NO_SUCH_KEY) for
# an unknown role; the declared 1952-byte ML-DSA-65 pk length; a bounded
# metadata read; scaffold-epoch fingerprints; then the verifier's full
# gate taxonomy — SIG_BAD_ALGO / _ARTIFACT / _ARTIFACT_LEN / _SIG_PTR /
# _LENGTH / _PK_PTR / _PK_ALIGN / SIG_UNVERIFIABLE — and, centrally, that
# an all-zero signature over a well-formed artifact returns
# SIG_UNSIGNED_SCAFFOLD and that driver_sig_verdict_is_ok rejects it.
# No path in the verifier returns SIG_OK at R29.
#
# See:
#   - design/drivers/blob-policy.md §1.7 (verdict taxonomy), §1.8 (keyring)
#   - src/kernel/core/driver/keyring.pdx
#   - src/kernel/core/driver/sig_verify.pdx
#   - src/kernel/boot/kernel_main.pdx §sig_keyring_witness
.global sig_keyring_ok_msg
.align 8
sig_keyring_ok_msg: .ascii "R29 SIG KEYRING OK\n\0"

.global sig_keyring_fail_msg
.align 8
sig_keyring_fail_msg: .ascii "R29 SIG KEYRING FAIL\n\0"


# R29.M4-003/004 (#1034/#1035): blob-driver DUAL-SIGNATURE enforcement
# and its telemetry / audit path.
#
# Exercises the D1.a two-gate rule end to end: a firmware blob is
# accepted only if BOTH the vendor signature (against the pinned
# vendor_intel / vendor_realtek keyring role) AND the Paideia manifest
# re-sign (against paideia_root) pass. Both gates always run — there is
# no control-flow edge from the vendor gate to a return — and the
# combined verdict names WHICH half failed, because a vendor-sig failure
# (tampered/substituted blob) and a paideia-sig failure (unreviewed
# blob) get different operator responses.
#
# Covers: both-scaffold -> BLOB_UNSIGNED_SCAFFOLD and NOT BLOB_OK;
# vendor half malformed -> BLOB_ERR_VENDOR_SIG_BAD; paideia half
# malformed -> BLOB_ERR_PAIDEIA_SIG_BAD; both -> BLOB_ERR_BOTH_SIG_BAD;
# blob/manifest length disagreement -> BLOB_ERR_LEN_MISMATCH; a supplied
# digest that differs from manifest.blob_hash -> BLOB_ERR_HASH_MISMATCH;
# the five manifest-malformed codes; the single-valid-signature rule
# (one half SIG_OK, the other unsigned -> REJECTED, both directions);
# the SHA3-256 R32 dependency reported as BLOB_ERR_HASH_UNAVAILABLE
# rather than skipped; and that every outcome appended an audit record
# at the right level, with failures reaching the audit bridge.
#
# No path in the verifier returns BLOB_OK at R29.
#
# See:
#   - design/drivers/blob-policy.md §1.9 (dual gate), §1.10 (telemetry)
#   - src/kernel/core/driver/blob_load.pdx
#   - src/kernel/core/driver/sig_telemetry.pdx
#   - src/kernel/boot/kernel_main.pdx §blob_dualsig_witness
.global blob_dualsig_ok_msg
.align 8
blob_dualsig_ok_msg: .ascii "R29 BLOB DUALSIG OK\n\0"

.global blob_dualsig_fail_msg
.align 8
blob_dualsig_fail_msg: .ascii "R29 BLOB DUALSIG FAIL\n\0"


# R29.M6-001..004 (#1040/#1041/#1042/#1043): driver_audit_channel —
# the sealed one-way audit stream.
#
# Covers: the eight-field record schema and its per-record sequence
# number; emission from INSIDE the mint / revoke / handoff primitives
# (so a refused mint is recorded even though it creates no descriptor);
# gap detection by position; hash-chain seal detection, exercised by
# CORRUPTING retained records and requiring both checks to trip and
# then to clear on restore; descriptor-count reconciliation of the
# audit-derived mint/revoke balance against an independently scanned
# live descriptor count, across a cascade revoke that destroys three
# descriptors from one call; the committed-Handoff edge carrying its
# from-state while a refused transition stays silent; and D1.c blob
# parity — identical capability work on a path that produced a
# blob-signature verdict and one that did not yields indistinguishable
# audit records.
#
# See:
#   - design/ipc/driver-audit-schema.md
#   - design/drivers/blob-policy.md §3 (D1.c)
#   - src/kernel/core/driver/audit_channel.pdx
#   - src/kernel/boot/kernel_main.pdx §drv_audit_witness
.global drv_audit_ok_msg
.align 8
drv_audit_ok_msg: .ascii "R29 DRIVER AUDIT OK\n\0"

.global drv_audit_fail_msg
.align 8
drv_audit_fail_msg: .ascii "R29 DRIVER AUDIT FAIL\n\0"


# R29.M7-001/004/005 (#1044/#1047/#1048): cascade-restart witness
# fingerprints. Builds a four-node supervisor tree, kills an interior
# node, and asserts the one-for-one restart set, the ChannelDead wake of
# a blocked client, the refusal of a stale endpoint capability against
# the restarted incarnation, and escalation to permanently-failed once
# the restart budget is exhausted.
#
# See:
#   - design/drivers/cascade-restart.md
#   - src/kernel/core/driver/restart.pdx
#   - src/kernel/boot/kernel_main.pdx §r29_cascade_restart_witness
.global r29_restart_ok_msg
.align 8
r29_restart_ok_msg: .ascii "R29 CASCADE RESTART OK\n\0"

.global r29_restart_fail_msg
.align 8
r29_restart_fail_msg: .ascii "R29 CASCADE RESTART FAIL\n\0"

.global r29_restart_wit_name
.align 8
r29_restart_wit_name: .ascii "restart-witness\0"


# R29.M7-002/003 (#1045/#1046): chaos-harness fingerprints. Drives 100
# kills against each of three victim positions (leaf / mid / root) in the
# same supervisor tree, with a client parked in a blocked recv and an
# undrained message published on the victim at the instant of every kill,
# and re-checks descriptor conservation plus audit reconciliation after
# every single one.
#
# The FAIL line carries three decimal fields — role, cycle and phase —
# so a failing boot log localises the first drift without a debugger.
#
# See:
#   - design/drivers/cascade-restart.md §Verification
#   - src/kernel/core/driver/chaos.pdx
#   - src/kernel/boot/kernel_main.pdx §r29_chaos_witness
.global r29_chaos_ok_msg
.align 8
r29_chaos_ok_msg: .ascii "R29 CHAOS OK\n\0"

.global r29_chaos_fail_msg
.align 8
r29_chaos_fail_msg: .ascii "R29 CHAOS FAIL\n\0"

.global r29_chaos_k_role
.align 8
r29_chaos_k_role: .ascii "role\0"

.global r29_chaos_k_cycle
.align 8
r29_chaos_k_cycle: .ascii "cycle\0"

.global r29_chaos_k_phase
.align 8
r29_chaos_k_phase: .ascii "phase\0"


# R20b.M1-002 (#1553): endpoint_table + payload_arena witness fingerprints —
# exercises endpoint_alloc/endpoint_free/endpoint_lookup round-trip on the
# full 128-slot range AND payload_buf_pa_for(0..127) 4 KiB-alignment +
# contiguity. See src/kernel/core/ipc/endpoint_table.pdx and
# src/kernel/core/ipc/payload_arena.pdx.
.global endpoint_alloc_ok_msg
.align 8
endpoint_alloc_ok_msg: .ascii "R20b ENDPOINT ALLOC OK\n\0"

.global endpoint_alloc_fail_msg
.align 8
endpoint_alloc_fail_msg: .ascii "R20b ENDPOINT ALLOC FAIL\n\0"


# R20b.M1-003 (#1554): svc_broker table + register/lookup witness
# fingerprints — closes M1. Exercises svc_register (name-too-long
# rejection, duplicate rejection, install success) + svc_lookup
# (register/lookup round-trip on 'svc.test'). See
# src/kernel/core/ipc/svc_broker.pdx.
.global broker_ok_msg
.align 8
broker_ok_msg: .ascii "R20b BROKER OK\n\0"

.global broker_fail_msg
.align 8
broker_fail_msg: .ascii "R20b BROKER FAIL\n\0"


# R20b.M2-001 (#1555): 8-byte frame header + frame_encode/frame_decode
# witness fingerprints — opens R20b.M2 (framed variable-length IPC) on
# top of the M1 substrate. Exercises the packed-u64 header shape from
# acpi-supervisor-schema §3 (op@+0, ver@+1, flags@+2..3 LE, payload_len
# @+4..7 LE) via encode → byte-check → packed-decode → field-accessor
# round-trip, plus the FRAME_MAX_PAYLOAD (4088) boundary + rejection +
# buf-not-modified property. See src/kernel/core/ipc/frame.pdx.
.global frame_hdr_ok_msg
.align 8
frame_hdr_ok_msg: .ascii "R20b FRAME HDR OK\n\0"

.global frame_hdr_fail_msg
.align 8
frame_hdr_fail_msg: .ascii "R20b FRAME HDR FAIL\n\0"


# R20b.M2-002 (#1556): pending-msg primitives witness fingerprints —
# second M2 sub-issue. Exercises endpoint_write_pending /
# endpoint_take_pending / endpoint_is_full round-trip on a freshly
# allocated endpoint: publish-once + fill-check + EAGAIN on re-publish
# + take round-trip (hdr + payload byte-compare) + EMPTY on re-take.
# See src/kernel/core/ipc/endpoint_table.pdx (M2-002 helpers).
.global pending_msg_ok_msg
.align 8
pending_msg_ok_msg: .ascii "R20b PENDING MSG OK\n\0"

.global pending_msg_fail_msg
.align 8
pending_msg_fail_msg: .ascii "R20b PENDING MSG FAIL\n\0"


# R20b.M2-003 (#1557): KPTI-safe user<->kernel payload bounce witness
# fingerprints — third + final M2 sub-issue, closes R20b.M2. Exercises the
# user_bounce_send / user_bounce_recv wrappers with init's real user_pml4
# and a 4088-byte (FRAME_MAX_PAYLOAD) round-trip through the endpoint
# arena, verifying both walker directions land bytes on init's real
# user-VA-mapped frames (not the boot PML4's low-identity aliases).
# See src/kernel/core/ipc/user_bounce.pdx.
.global ipc_bounce_ok_msg
.align 8
ipc_bounce_ok_msg: .ascii "R20b IPC BOUNCE OK\n\0"

.global ipc_bounce_fail_msg
.align 8
ipc_bounce_fail_msg: .ascii "R20b IPC BOUNCE FAIL\n\0"


# R20b.M3-001 (#1558): sys_ipc_recv syscall witness fingerprints — first
# sub-issue of the R20b.M3 (server-process model) branch. Exercises the
# sys_ipc_recv_body handler directly (pre-loading a pending msg via
# endpoint_write_pending) to prove the drain path returns hdr + payload
# to init's real user_pml4-mapped page via user_bounce_recv. See
# src/kernel/core/syscall/handlers/sys_ipc_recv.pdx (M3-001 body) and
# src/kernel/core/syscall/dispatch.pdx (sysno 40 dispatch shim).
.global sys_ipc_recv_ok_msg
.align 8
sys_ipc_recv_ok_msg: .ascii "R20b SYS IPC RECV OK\n\0"

.global sys_ipc_recv_fail_msg
.align 8
sys_ipc_recv_fail_msg: .ascii "R20b SYS IPC RECV FAIL\n\0"


# R20b.M3-002 (#1559): sys_ipc_send / sys_ipc_reply syscall witness
# fingerprints — second sub-issue of the R20b.M3 (server-process model)
# branch. Exercises sys_ipc_send_body + sys_ipc_reply_body directly with
# both the no-waiter (msg queued, no wake) and waiter-present (waiter
# runq_enqueue'd, endpoint.waiter_tcb cleared) paths, plus the EAGAIN
# rejection on a full endpoint and the reply-bit (op & 0x80) enforcement.
# See src/kernel/core/syscall/handlers/sys_ipc_send.pdx (M3-002 body),
# src/kernel/core/syscall/handlers/sys_ipc_reply.pdx (M3-002 body), and
# src/kernel/core/syscall/dispatch.pdx (sysno 41/42 dispatch shims).
.global sys_ipc_send_ok_msg
.align 8
sys_ipc_send_ok_msg: .ascii "R20b SYS IPC SEND OK\n\0"

.global sys_ipc_send_fail_msg
.align 8
sys_ipc_send_fail_msg: .ascii "R20b SYS IPC SEND FAIL\n\0"


# R20b.M3-003 (#1560): sys_svc_lookup syscall witness fingerprints — fourth
# (and closing) sub-issue of the R20b.M3 (server-process model) branch.
# Exercises sys_svc_lookup_body directly: walker-bounce a user-VA name
# into the body's kernel scratch, look up the broker row, mint a
# KIND_IPC_ENDPOINT cap in a free cap_table slot with the row's rights_gate
# + a direction derived from those rights bits, and return the slot id.
# See src/kernel/core/syscall/handlers/sys_svc_lookup.pdx (M3-003 body)
# and src/kernel/core/syscall/dispatch.pdx (sysno 43 dispatch shim).
.global sys_svc_lookup_ok_msg
.align 8
sys_svc_lookup_ok_msg: .ascii "R20b SVC LOOKUP OK\n\0"

.global sys_svc_lookup_fail_msg
.align 8
sys_svc_lookup_fail_msg: .ascii "R20b SVC LOOKUP FAIL\n\0"


# R20b.M6-002 (#1565): dispatch cap_slot lookup witness fingerprints —
# closes the syscall-shim cap-lookup gate. Exercises the ipc_slot_to_endpoint
# helper (src/kernel/core/syscall/dispatch.pdx) end-to-end via the modified
# dispatch_ipc_recv shim: mint a KIND_IPC_ENDPOINT cap at a known cap_table
# slot, invoke syscall_dispatch(sysno=40, cap_slot, ...), verify success on
# a valid cap and appropriate -EBADF / -EACCES rejections on empty / wrong-
# kind / insufficient-rights slots.
.global sys_ipc_cap_slot_ok_msg
.align 8
sys_ipc_cap_slot_ok_msg: .ascii "R20b IPC CAP SLOT OK\n\0"

.global sys_ipc_cap_slot_fail_msg
.align 8
sys_ipc_cap_slot_fail_msg: .ascii "R20b IPC CAP SLOT FAIL\n\0"


# R20b.M4-001 (#1561): InitCap sidecar format + validator witness fingerprints
# — first sub-issue of the R20b.M4 (loader capability-seed hook) branch.
# Exercises init_caps_validate (src/kernel/core/loader/init_caps.pdx) against
# a hand-authored 2-entry sidecar synthesized in kernel .bss: accept path
# (valid slot + kind for both entries) plus three reject paths — malformed
# count (array overflows blob), out-of-range slot (>= 256), unknown kind
# (not in {0..15, 0x15, 0x16}). Format documented in
# design/loader/init-caps-sidecar.md §§1..4.
.global init_caps_ok_msg
.align 8
init_caps_ok_msg: .ascii "R20b INIT CAPS FMT OK\n\0"

.global init_caps_fail_msg
.align 8
init_caps_fail_msg: .ascii "R20b INIT CAPS FMT FAIL\n\0"


# R20b.M4-002 (#1562): loader_seed_caps hook witness fingerprints — closes
# R20b.M4 (loader capability-seed hook). Exercises loader_seed_caps
# (src/kernel/core/loader/seed_caps.pdx) — the caller that binds M4-001's
# init_caps_validate to cap/mint.pdx's cap_mint_write. Witness synthesizes
# a 1-entry sidecar in kernel .bss (_loader_seed_witness_sidecar) and
# drives two sub-tests: 0 = ACCEPT (mint KIND_TIMER cap into slot 5 and
# read-back-verify kind/rights/target_ptr), 1 = REJECT (patch count to
# 0xFFFF, expect LOADER_SEED_FAILED, verify slot 5 unchanged proving the
# fail-fast invariant). See design/loader/init-caps-sidecar.md §5 for the
# loader-side walk contract and design/ipc/userspace-server-substrate.md
# §6.2 for the hook signature.
.global loader_seed_ok_msg
.align 8
loader_seed_ok_msg: .ascii "R20b LOADER SEED OK\n\0"

.global loader_seed_fail_msg
.align 8
loader_seed_fail_msg: .ascii "R20b LOADER SEED FAIL\n\0"


# R20b.M6-001 (#1564): loader phase-2 ELF-symbol walker witness fingerprints
# — retires the R20b.M4-002 (#1562) empty-sidecar wire-in in elf_lite_load.
# Drives a real elf_lite_load call against echo_server.elf (the only current
# userspace image that declares an _init_caps / _init_caps_count sidecar per
# src/user/echo_server.pdx L96-107) and asserts the walker
# (loader_seed_caps_from_symtab in src/kernel/core/loader/seed_caps.pdx)
# resolved both symbols via the ELF section header table + .symtab / .strtab,
# colocated their bytes into its .bss sidecar scratch, and delegated to
# loader_seed_caps which minted a KIND_IPC_ENDPOINT cap into cap_table[0]
# with rights R_IPC_ALL and target_ptr encoding endpoint_id=1 dir=BIDI.
# See kernel_main.pdx §m6_symtab_witness for the 6-sub-test enumeration and
# design/loader/init-caps-sidecar.md §5 for the phase-1 -> phase-2 contract.
.global loader_symtab_seed_ok_msg
.align 8
loader_symtab_seed_ok_msg: .ascii "R20b LOADER SYMTAB SEED OK\n\0"

.global loader_symtab_seed_fail_msg
.align 8
loader_symtab_seed_fail_msg: .ascii "R20b LOADER SYMTAB SEED FAIL\n\0"


# R20b.M5-001 (#1563): echo-server closure witness fingerprints — closes
# R20b.M5 (and the R20b round + the #1015 userspace-server-substrate
# blocker). Kernel-driven roundtrip against init's user_pml4 exercising
# ALL M1..M4 primitives end-to-end:
#   svc_register("svc.echo", 8, <id>)              [M1 broker]
#   cap_mint_write(slot, KIND_IPC_ENDPOINT, ...)   [M4 cap-mint]
#   sys_svc_lookup_body(name_va, 8)                [M3 svc_lookup]
#   sys_ipc_send_body   (request)                  [M3 send + M2 hdr/bounce]
#   sys_ipc_recv_body   (server-side drain)        [M3 recv + M2 bounce]
#   sys_ipc_reply_body  (server-side reply w/ bit-7 flip)  [M3 reply]
#   sys_ipc_recv_body   (client-side drain of reply)       [M3 recv]
# Byte-exact hdr + payload verify per hop.  Witness lives kernel-side in
# kernel_main.pdx (m5_echo_witness label); echo_server userspace binary
# (src/user/echo_server.pdx) is embedded for the shape but not spawned at
# R20b.M5 (deferred with the loader symbol-walker per
# design/loader/init-caps-sidecar.md §5). See the witness comment block
# for the sub-test enumeration and the roundtrip design in
# design/ipc/userspace-server-substrate.md §7.
.global echo_roundtrip_ok_msg
.align 8
echo_roundtrip_ok_msg: .ascii "R20b ECHO ROUNDTRIP OK\n\0"

.global echo_roundtrip_fail_msg
.align 8
echo_roundtrip_fail_msg: .ascii "R20b ECHO ROUNDTRIP FAIL\n\0"

# R20b.M6-003 (#1566): dual-endpoint RPC roundtrip witness fingerprints —
# closes R20b.M6 (substrate hardening; unblocks #820 acpi_supervisor +
# #860 pci_enumerator as real userspace tasks). Proves the same-endpoint
# request/reply race documented in
# design/ipc/userspace-server-substrate.md §4.4 is closed by the
# dual-endpoint pattern:
#   Client sends request to server endpoint (ep=1) with
#     hdr.reply_endpoint_id = client's reply endpoint (ep=2).
#   Server drains from ep=1, preserves reply_endpoint_id in the reply hdr,
#     flips bit 7 of op, calls sys_ipc_reply — which reads
#     reply_endpoint_id from the hdr and publishes to ep=2 (NOT ep=1).
#   Client drains reply from ep=2 — no race with the server's next-recv
#     on ep=1 (they live in disjoint endpoints).
# Witness lives kernel-side in kernel_main.pdx (m6_rpc_witness label);
# echo_server + echo_client userspace binaries embedded for the shape but
# the "real 2-task scheduler-driven" spawn is deferred to R21+ per
# §4.4 "Deferred" paragraph.
.global rpc_roundtrip_ok_msg
.align 8
rpc_roundtrip_ok_msg: .ascii "R20b RPC ROUNDTRIP OK\n\0"

.global rpc_roundtrip_fail_msg
.align 8
rpc_roundtrip_fail_msg: .ascii "R20b RPC ROUNDTRIP FAIL\n\0"

# R20-M4-002 (#820): ACPI supervisor RPC witness fingerprints.
# Closes #820 (userspace acpi_supervisor server — accepts KIND_ACPI +
# serves parse queries). The witness lives kernel-side in
# kernel_main.pdx (m4_002_acpi_rpc_witness label) and drives the four
# RPC ops (enumerate_tables / get_madt_lapic_list / get_mcfg_ranges /
# get_hpet) through sys_ipc_send_body / sys_ipc_recv_body /
# sys_ipc_reply_body against init's user_pml4 — matches the "Option B —
# kernel-side witness driving the RPC" posture used by R20b.M5-001 and
# R20b.M6-003 (the acpi_supervisor userspace binary at
# src/user/acpi_supervisor.pdx exists as the target shape but the
# spawn wires up post-R20b per §4.4 Deferred).
#
# Success marker: "R20b ACPI RPC OK\n" — asserted by boot_r20b_acpi_rpc.
# Failure marker: "R20b ACPI RPC FAIL\n" + line=<stage> KV.
.global acpi_rpc_ok_msg
.align 8
acpi_rpc_ok_msg: .ascii "R20b ACPI RPC OK\n\0"

.global acpi_rpc_fail_msg
.align 8
acpi_rpc_fail_msg: .ascii "R20b ACPI RPC FAIL\n\0"

# R22-M3-005 (#860): PCI enumerator RPC witness fingerprints.
# Closes #860 (userspace pci_enumerator server — walks tree via
# KIND_DEVICE caps). The witness lives kernel-side in kernel_main.pdx
# (m3_005_pci_rpc_witness label) and drives the three RPC ops
# (list_devices / device_info / get_bar_cap) through sys_ipc_send_body /
# sys_ipc_recv_body / sys_ipc_reply_body against init's user_pml4 —
# matches the "Option B — kernel-side witness driving the RPC" posture
# used by R20b.M5-001, R20b.M6-003, and R20-M4-002 (the pci_enumerator
# userspace binary at src/user/pci_enumerator.pdx exists as the target
# shape but the spawn wires up post-R22 per §4.4 Deferred).
#
# Success marker: "R20b PCI RPC OK\n" — asserted by boot_r20b_pci_rpc.
# Failure marker: "R20b PCI RPC FAIL\n" + line=<stage> KV.
.global pci_rpc_ok_msg
.align 8
pci_rpc_ok_msg: .ascii "R20b PCI RPC OK\n\0"

.global pci_rpc_fail_msg
.align 8
pci_rpc_fail_msg: .ascii "R20b PCI RPC FAIL\n\0"

# svc.<name> string for the R20b.M5-001 (#1563) echo witness — used both
# as the broker key (svc_register 3rd-arg scan at kernel VA) AND as the
# body-input for sys_svc_lookup_body's walker copy (published to init's
# user page @ 0x7FFFFFFFB080 via user_write_bytes_via_walk before the
# body call).  8 chars ("svc.echo") + trailing NUL for casual byte-level
# inspection, though both svc_register and sys_svc_lookup are length-
# explicit and never read past name_len.
.global _svc_echo_name
.align 8
_svc_echo_name: .ascii "svc.echo\0"

# svc.<name> strings for the R20b.M1-003 (#1554) broker witness.
# ASCII bytes only; no NUL required (svc_register / svc_lookup are
# length-explicit), but a trailing NUL keeps the buffer safe for casual
# byte-level inspection during debugging. The "long" buffer is 32 raw
# bytes so passing name_len=32 into svc_register triggers the
# name-too-long gate WITHOUT reading past a shorter buffer.
.global _svc_broker_witness_name_test
.align 8
_svc_broker_witness_name_test: .ascii "svc.test\0"

.global _svc_broker_witness_name_other
.align 8
_svc_broker_witness_name_other: .ascii "svc.other\0"

.global _svc_broker_witness_name_short
.align 8
_svc_broker_witness_name_short: .ascii "svc.a\0"

.global _svc_broker_witness_name_long
.align 8
_svc_broker_witness_name_long: .ascii "abcdefghijklmnopqrstuvwxyz012345"  # 32 bytes, no NUL


# M1-003 (#685): Re-entrancy gate for klog_emit_core (accessible from high-half kernel code)
# M3-002 (#690): int3 breakpoint stub — emit breakpoint exception (vec 3)
.section .text, "ax", @progbits
.code64
.global fire_int3
fire_int3:
	.byte 0xcc           # int3 opcode
	ret

.section .bss, "aw", @nobits
.global _klog_in_progress_bsp
.align 8
_klog_in_progress_bsp: .skip 8

.section .bss.boot, "aw", @nobits
.align 4096
.global pml4
pml4: .skip 4096
.align 4096
.global pdpt
pdpt: .skip 4096

# ---------------------------------------------------------------------------
# R30.M4-001 (#1066) / R30.M4-002 (#1067): SCI/GPE dispatch witness markers.
#
# Emitted by tests/kernel/acpi/gpe_synth.pdx §gpe_dispatch_witness, which
# drives the shipping ISR (src/kernel/core/acpi/sci_isr.pdx) against a
# synthetic GPE register window and a synthetic IOAPIC MMIO window.
#
# See also:
#   - src/kernel/core/acpi/gpe_block.pdx (block/bit decomposition)
#   - src/kernel/core/acpi/gpe_io.pdx    (register-access seam + trace)
#   - src/kernel/core/acpi/gpe_table.pdx (registration + event ring)
#   - src/kernel/core/acpi/gpe_ack.pdx   (enable/disable/clear/ack)
#   - src/kernel/core/acpi/sci_route.pdx (SCI_INT -> RTE)
.global gpe_dispatch_ok_msg
.section .rodata
gpe_dispatch_ok_msg: .ascii "R30 GPE DISPATCH OK\n\0"

.global gpe_dispatch_fail_msg
.section .rodata
gpe_dispatch_fail_msg: .ascii "R30 GPE DISPATCH FAIL\n\0"
