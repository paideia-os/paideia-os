# r15-m3-001 — SYSCALL/SYSRET MSR Audit Post Higher-Half (#529)

**Outcome: AUDIT-ONLY. No drift. No fix required.**

Opens R15.M3. Verifies that `syscall_msr_init` (originally landed by
r13-m5-001 / #427) still programs correct MSR values after the higher-half
VMA transition landed by r14b-m3 (#489).

## Reference

- Source: `src/kernel/core/syscall/msr.pdx`
- Target: `src/kernel/core/syscall/entry.pdx` (`syscall_entry`)
- Call site: `src/kernel/boot/kernel_main.pdx:136`
- Linker: `src/kernel/link.ld` (KERNEL_VMA_BASE = 0xFFFF800000000000)
- Related: r13-m5-001 audit `design/audit/entries/r13-m5-001-syscall-msrs.md`
- Intel SDM Vol 3A §6.15 (SYSCALL/SYSRET)

## Verified From Disassembly of `build/kernel.elf`

```
syscall_entry     @ 0xFFFF800000104000  (T, .text.syscall_trampoline)
syscall_msr_init  @ 0xFFFF80000010943D  (T, .text)
```

Both live in high-half sections per the linker script; kernel_main_64
(also high-half) invokes `syscall_msr_init` after CR3 has been installed
with PML4[256] aliasing the low identity map. RIP is high at call time.

### (a) IA32_EFER (0xC0000080) — SCE bit

`or rax, 0x1; wrmsr` — bit 0 set idempotently via RMW. **OK.**

### (b) IA32_STAR (0xC0000081) — 0x00180008_00000000

- Bits 47:32 = 0x0008 → SYSCALL loads CS=0x08 (kernel code64), SS=0x10 (kernel data).
- Bits 63:48 = 0x0018 → SYSRET loads CS=0x28 (user code64, RPL forced 3), SS=0x20 (user data).
- Matches GDT layout in `src/kernel/boot/gdt.pdx` (slots 1/2/4/5). **OK.**

### (c) IA32_LSTAR (0xC0000082) — &syscall_entry

Disassembly line:
```
ffff80000010946c: lea -0x5473(%rip),%rax    # ffff800000104000 <syscall_entry>
```
RIP-relative displacement resolves to the high-VA symbol because both
sections (`.text` and `.text.syscall_trampoline`) share the higher-half
VMA base. When executed at high RIP, LEA yields the high VA. **OK.**

### (d) IA32_FMASK (0xC0000084) — 0x00047700

Decomposes to TF|IF|DF|IOPL|NT|AC — matches Linux SYSCALL_MASK. IF
(0x200) is set, so RFLAGS.IF auto-clears on SYSCALL entry. **OK.**

### (e) IA32_KERNEL_GS_BASE (0xC0000102) — &_cpu0_kernel_gs

Not in issue scope, but verified: `lea` resolves to `0xFFFF80000052B190`,
a high-VA `.bss` symbol. **OK.**

## Conclusion

Post-#489 higher-half transition preserves all four in-scope MSR programmings
byte-for-byte. RIP-relative `lea` to `syscall_entry` correctly targets the
high VA because kernel_main_64 executes from the high-half text after the
boot-stub CR3 install, and both source and target sections are linked at
KERNEL_VMA_BASE. Close #529 as audit-only.
