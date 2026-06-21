# PaideiaOS — Boot Path

**Status:** Draft v0.1 — Phase-0 decision.
**Date:** 2026-06-20
**Scope:** Boot mechanism for Phase-0 (kernel skeleton) and Phase-1 (long-mode + banner + capability system). UEFI deferral catalogued.

**Hard inputs:**
- `design/00-feature-inventory.md` Pillar 5 — "UEFI + ACPI + x2APIC + PCIe + NVMe + USB3+ are the minimum hardware contract."
- `design/02-development-environment.md` Part V — UEFI as canonical boot- and disk-image convention.
- User decisions of 2026-06-20: QEMU `-kernel` for Phase-0/Phase-1; NASM stub skipped; all-paideia-as entry path.

---

## 0. Decisions summary

| ID    | Choice                                                       | Rationale                                                                                          |
|-------|--------------------------------------------------------------|----------------------------------------------------------------------------------------------------|
| BP-D1 | QEMU `-kernel` direct boot for Phase-0/Phase-1               | Fastest bring-up; no GRUB/UEFI dependency; bootstrap-the-bootstrap.                                |
| BP-D2 | NASM stub skipped for 32→64 transition                       | All-assembly = paideia-as honored to the letter; one toolchain, one debugger story.                |
| BP-D3 | UEFI direct boot deferred to a post-Phase-1 milestone        | Substantial bring-up cost; needs paideia-as PE32+/EFI emitter OR a NASM UEFI stub (contradicts BP-D2). |
| BP-D4 | Long-mode transition lives in `unsafe { }` in paideia-as     | No typed surface for CR/MSR/LJMP intrinsics until paideia-as Phase 5+.                             |
| BP-D5 | Phase-0 kernel halts (`cli; hlt; jmp $-1`); no transition yet | First smoke is build-chain validation, not boot functionality.                                     |

---

## 1. What QEMU `-kernel` does

The Phase-0 boot invocation is:

```
qemu-system-x86_64 -kernel build/kernel.elf -nographic -serial mon:stdio
```

QEMU's `-kernel` loader behaviour:

1. Parses the ELF64 binary `build/kernel.elf`.
2. Loads each `PT_LOAD` segment at the program-header VA (1 MiB per `link.ld`).
3. Sets up a minimal multiboot-style boot info structure. Note: this is QEMU's own simplified handoff, **not** Multiboot2-compliant.
4. Jumps to the ELF entry point (`_start`).
5. **CPU mode at entry: 32-bit protected mode**, despite the binary being ELF64. This is a QEMU quirk and is the single most consequential property of this boot path: the 32→64 transition is on the kernel, not on the loader.

Reference: QEMU x86 system emulation documentation (`qemu-system-x86_64(1)`, `-kernel` option).

This boot path does **not** require a bootloader, an EFI system partition, a disk image, or a Multiboot2 header. The kernel ELF alone suffices. That is precisely what makes it the right Phase-0 choice — it removes every dependency except the build chain itself.

---

## 2. The 32→64 transition (deferred to Phase-1)

Phase-0 does not transition to long mode. Phase-1 introduces it. The canonical x86_64 sequence the kernel must execute is:

```nasm
; 1. Disable interrupts.
cli

; 2. Set up a minimal 32-bit GDT for the transition (code + data).
lgdt [gdt32_descriptor]

; 3. Build identity-mapping page tables in .bss:
;    PML4[0] -> PDPT; PDPT[0..3] -> 4 x 1 GiB pages (PS bit set).
;    Identity-maps the first 4 GiB with 1 GiB pages.

; 4. Load CR3 with the PML4 base.
mov cr3, eax

; 5. Set CR4.PAE (bit 5).
mov eax, cr4
or  eax, 1 << 5
mov cr4, eax

; 6. Enable IA-32e mode via IA32_EFER.LME (MSR 0xC0000080, bit 8).
mov ecx, 0xC0000080
rdmsr
or  eax, 1 << 8
wrmsr

; 7. Set CR0.PG (bit 31) and CR0.PE (bit 0; should already be set under -kernel).
mov eax, cr0
or  eax, (1 << 31) | (1 << 0)
mov cr0, eax

; 8. Long-jump to a 64-bit code-segment selector.
jmp 0x08:long_mode_start
```

In paideia-as, this sequence lives in `src/kernel/boot/long_mode.pdx` (future file) as a single large `unsafe { }` block. Every x86_64 instruction the lowered IR does not yet typed-surface (CR0/CR3/CR4 manipulation, EFER MSR, far jumps) sits inside that block, with its effect-set, capability-set, and justification recorded for the audit catalog.

---

## 3. Why no NASM stub

The user's all-assembly constraint (NASM or paideia-as, never an HLL) plus BP-D2 (paideia-as as the sole assembler) excludes NASM today.

- **Cost:** more `unsafe { }` blocks in the entry path until paideia-as Phase 5+ surfaces CR/MSR/LJMP intrinsics.
- **Benefit:** one toolchain, one debugger story, no NASM ↔ paideia-as ABI boundary, and every privileged instruction logged through the paideia-as audit catalog.

A counterpoint was considered: a tiny (~50 LoC) NASM stub for the transition alone, then hand off to paideia-as. Rejected because:

1. It introduces a second toolchain to the build chain (assemble, link, ABI-match).
2. The transition is well-defined; writing it in `unsafe { }` is one big block, not many small ones.
3. The audit catalog records the `unsafe { }` block as a single, locatable artefact. A NASM stub leaves no such trail.
4. Two toolchains means two debugger workflows (DWARF emitter parity, symbol munging).

The all-paideia-as path costs a few hundred lines of well-bounded `unsafe { }` and buys toolchain singularity. The trade is taken.

---

## 4. UEFI deferral

UEFI is the canonical boot path per Pillar 5 and `design/02-development-environment.md` Part V. Today's QEMU `-kernel` boot is **dev-only** and does not work on real hardware. The path back to UEFI is catalogued as two routes:

### Route A — paideia-as PE32+/EFI emitter

- Add `--emit pe32-efi` to paideia-as (new emitter; lands in paideia-as Phase 5+ or a follow-up milestone).
- Build a UEFI application binary (`BOOTX64.EFI`).
- The application calls `ExitBootServices()`, sets up the handoff, and jumps to the kernel.
- **Pros:** all-paideia-as; consistent with BP-D2; no NASM.
- **Cons:** substantial paideia-as work (PE32+ object format, EFI runtime types, UEFI protocol bindings; weeks of work).

### Route B — NASM UEFI stub + paideia-as kernel

- Write a small UEFI stub in NASM (~500 LoC: GOP init, `ExitBootServices`, handoff).
- Stub loads the paideia-as-built ELF64 kernel from the EFI System Partition.
- **Pros:** fastest path to real-hardware UEFI boot.
- **Cons:** re-introduces NASM, contradicting BP-D2.

**Gate for re-engagement:** decide between Route A and Route B once Phase-1 is complete (kernel banner via UART, capability system bring-up) and once the cost of Route A is better understood after kernel-typed surface for boot-time intrinsics is in place.

---

## 5. Real-hardware boot

QEMU `-kernel` does not work on real hardware. The UEFI deferral (§4) is the path. Until then, PaideiaOS development is **QEMU-only**.

This is explicitly fine for Phase-0 and Phase-1. Pillar 1 ("x86_64 native") does not require real-hardware boot at every phase; it requires that real-hardware boot is the **final** target. Phase-0 and Phase-1 prove out the build chain, the long-mode transition, the UART driver, and the capability primitives — all of which transfer wholesale to a UEFI boot path once §4 is resolved.

---

## 6. Today's entry point

The Phase-0 entry, in `src/kernel/boot/entry.pdx`:

```paideia
module PaideiaKernel = structure {
  let _start : () -> () !{} @{} = fn () -> unsafe {
    effects:       {},
    capabilities:  {},
    justification: "Bare-metal kernel entry: no ambient runtime, no guarantees.",
    block: {
      cli
      hlt
      jmp $-1
    }
  }
}
```

This is **Phase-0 smoke**. It validates four things and nothing more:

1. The build chain works end-to-end (paideia-as compiles, `ld` links, `link.ld` places `_start` at 1 MiB).
2. `ld` emits a bootable ELF64.
3. QEMU loads the binary at 1 MiB and jumps to `_start`.
4. The kernel does not immediately triple-fault.

If the QEMU monitor reports a halted CPU and no triple fault, Phase-0 is green. That is the contract.

---

## 7. Phase-1 boot extension

Per `design/infrastructure/first-milestone.md`, Phase-1 adds:

- `src/kernel/boot/long_mode.pdx` — the 32→64 transition (§2 sequence, in `unsafe { }`).
- `src/kernel/boot/uart.pdx` — COM1 16550 UART driver (write-only is sufficient for the banner).
- `src/kernel/boot/banner.pdx` — `printf`-style banner emit over the UART.

Boot order in Phase-1:

```
_start                       (32-bit PM, from QEMU -kernel)
  -> identity_map_and_pagetables
  -> enter_long_mode         (cli; CR4.PAE; EFER.LME; CR0.PG; ljmp)
  -> kernel_main             (64-bit)
       -> uart_init
       -> banner()
       -> halt
```

The exit condition of Phase-1 is identical to Phase-0 — a halted CPU — but now after having printed the banner over the serial port. The serial output is the Phase-1 acceptance signal.

---

## 8. Forward links

- `design/infrastructure/build-system.md` — how the kernel ELF is produced (paideia-as → `ld` → `kernel.elf`).
- `design/infrastructure/first-milestone.md` — Phase-0/Phase-1 specification this document supports.
- `design/02-development-environment.md` Part V — long-form boot- and disk-image conventions; the UEFI target re-engaged per §4.
- `design/kernel/memory-model.md` — final memory layout (higher-half kernel) that Phase-1's identity map is a stepping stone toward.
- paideia-as `design/toolchain/phase-transition-4.md` — the walker-activation gate that bounds today's `.pdx` surface and motivates the `unsafe { }` blocks in §2.
