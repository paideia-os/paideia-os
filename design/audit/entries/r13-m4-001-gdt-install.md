---
audit_id: r13-m4-001-gdt-install
issue: 423
file: src/kernel/boot/gdt.pdx
function: gdt_install
effects: [sysreg, mem]
capabilities: [boot]
reviewed_by:
date: 2026-07-03
---

# AUDIT r13-m4-001 — GDT real install with SYSRET layout (R13-m4-001)

## Overview

`gdt_install` builds and loads a real 8-entry Global Descriptor Table (GDT) with a layout
designed to support SYSRET-compatible user/kernel transitions. The implementation populates
8 slots (0x00–0x38) with byte-exact segment descriptor encodings, constructs a 10-byte GDTR,
and loads it via the privileged `lgdt` instruction. Slots 6–7 are reserved for TSS installation
in a follow-up issue (m4-002).

**CRITICAL FIX**: The boot-phase GDT (tools/boot_stub.S) defined code32 at selector 0x08.
However, IDT trampolines use CS=0x08 to dispatch ISRs in 64-bit mode. This mismatch is a
latent bug: the CPU would fetch ISR handlers using 32-bit code-segment semantics. m4-001
corrects this by making 0x08 a proper code64 descriptor.

## SYSRET layout rationale

SYSRET requires specific segment selector layouts:
- `SYSRET` in 64-bit mode loads CS from `STAR[63:48]` + 16 (user code selector)
- `SYSRET` loads SS from `STAR[63:48]` + 8 (user data selector)
- `SYSCALL` loads CS from `STAR[47:32]` (kernel code selector)

This implementation adopts the standard layout:
```
STAR[63:48] = 0x20  (user data selector; user code at 0x20+16=0x28)
STAR[47:32] = 0x08  (kernel code selector)
```

The GDT layout reflects this:
- 0x20: user data (RPL 3)
- 0x28: user code64 (RPL 3)
- 0x08: kernel code64 (RPL 0)
- 0x10: kernel data (RPL 0)

## Byte-exact slot table

| Slot | Selector | Descriptor        | Encoding              | Purpose                            |
|------|----------|-------------------|-----------------------|------------------------------------|
| 0    | 0x00     | null              | 0x0000000000000000    | GDT entry 0 (reserved)             |
| 1    | 0x08     | kernel code64     | 0x00AF9A000000FFFF    | Kernel mode code (64-bit)          |
| 2    | 0x10     | kernel data       | 0x00AF92000000FFFF    | Kernel mode data                   |
| 3    | 0x18     | reserved          | 0x0000000000000000    | Deferred use                       |
| 4    | 0x20     | user data         | 0x00AFF2000000FFFF    | User mode data (SYSRET SS source)  |
| 5    | 0x28     | user code64       | 0x00AFFA000000FFFF    | User mode code (SYSRET CS source)  |
| 6    | 0x30     | TSS low           | 0x0000000000000000    | TSS base address [0:63] (m4-002)   |
| 7    | 0x38     | TSS high          | 0x0000000000000000    | TSS base address [64:95] (m4-002)  |

### Descriptor field breakdown (slots 1, 2, 4, 5)

Each non-null descriptor is encoded as:

```
bits [0:15]   = limit_lo (0xFFFF for flat 4GB)
bits [16:39]  = base[0:23] (0x0000 for identity mapping)
bits [40:47]  = type_attr:
                  P=1   (present)
                  DPL   (0 for kernel, 3 for user)
                  S=1   (segment, not system)
                  Type: 
                    0xA = code (execute-read)
                    0x2 = data (read-write)
bits [48:51]  = limit_hi (0xF for 4GB, with G=1)
bits [52:55]  = flags (G=1 for page granularity; L=1 for 64-bit code; D=0 for data)
bits [56:63]  = base[24:31] (0x00 for identity mapping)
```

Examples:
- Kernel code64: type_attr=0x9A (P=1, DPL=0, S=1, Type=0xA), flags include L=1
- User data: type_attr=0xF2 (P=1, DPL=3, S=1, Type=0x2)
- User code64: type_attr=0xFA (P=1, DPL=3, S=1, Type=0xA), L=1

## GDTR layout

The GDTR (GDT Register) descriptor, stored in `_gdt_ptr`, contains:

```
bytes [0:1]   = limit (u16) = 0x003F (8 entries × 8 bytes − 1 = 63)
bytes [2:9]   = base (u64)  = address of _gdt_new
```

The `lgdt [rdi]` instruction loads this 10-byte structure into the CPU's internal GDTR.

## Fix of latent CS=0x08 code32 bug

### Before (boot_stub.S GDT)
```
// tools/boot_stub.S
gdt:
  dq 0x0000000000000000       // slot 0: null
  dq 0x0020980000000000       // slot 1: code32 at 0x08 (!!! P=1, DPL=0, Type=10, D=1)
  dq 0x0020920000000000       // slot 2: data at 0x10
```

The boot GDT descriptor at slot 1 has D=1 (32-bit code), which is incorrect for 64-bit ISR dispatch.

### After (m4-001 GDT)
```
module Gdt → _gdt_new:
  [0] = 0x0000000000000000    // slot 0: null
  [1] = 0x00AF9A000000FFFF    // slot 1: code64 at 0x08 (!!! L=1, 64-bit code)
  [2] = 0x00AF92000000FFFF    // slot 2: data at 0x10
  ...
```

The m4-001 GDT descriptor has L=1 (64-bit code) and uses proper base/limit fields for
compatibility with SYSRET. CS=0x08 now correctly identifies 64-bit code.

**Impact**: IDT trampolines (Idt module, trampoline_vec32 and others) use CS=0x08 to
dispatch ISR handlers. Before m4-001, this selector pointed to code32 (latent bug).
After m4-001, CS=0x08 correctly identifies code64, enabling safe 64-bit ISR delivery.

## Slots 6-7 deferred to m4-002

Slots 0x30 (TSS low) and 0x38 (TSS high) are initialized to zero. A follow-up issue
(m4-002) will populate these with the address and size of the Task State Segment (TSS),
enabling:

- Per-core IST (Interrupt Stack Table) stacks for double-fault and other exceptions.
- Ring-transition stack pointers (RSP0 for ring-3→ring-0 transitions).
- Per-core task-state tracking for context switching.

For m4-001, these slots remain inert (zero).

## Call sequence

In `kernel_main.pdx`:

```
call cap_dispatch_smoke;
call gdt_install;          // ← Load new GDT with code64 at 0x08
call idt_install;          // ← Now safe: IDT trampolines use correct CS=0x08
```

The GDT must be loaded **before** the IDT, because IDT entry construction or delivery
may implicitly reference the CS descriptor for ISR dispatch.

## Acceptance criteria

- [x] `_gdt_new` contains 8 u64 entries, bytes 0–63.
- [x] `_gdt_ptr` contains GDTR descriptor: limit=0x3F, base=&_gdt_new.
- [x] Slots 1–5 populated with byte-exact descriptor encodings (per table above).
- [x] Slots 0, 6–7 initialized to zero.
- [x] `lgdt [rdi]` loads descriptor where rdi=&_gdt_ptr.
- [x] Call inserted in `kernel_main.pdx` before `idt_install`.
- [x] Build succeeds and no regressions in smoke tests.
- [x] No segment register reloads in m4-001 (deferred to m4-002+ or future versions).

## Cross-references

- **Issue**: #423 (R13-m4-001)
- **Precursor**: #356–#359 (R9-m1..m4, IDT + ISR dispatch structure)
- **Related**: #363 (R13-m3, protection bits: SMEP/SMAP/NX)
- **Follow-up**: m4-002 (TSS install, slots 6–7)
- **Audit**: `idt-install-001.md` (IDT structure and trampolines)

## Verification checklist

When this entry lands:

1. Build `./tools/build.sh` — should succeed.
2. Verify symbol export: `nm build/kernel.elf | grep _gdt_new` — should show global symbol.
3. Disassembly: `objdump -d build/kernel.elf --disassemble=gdt_install` — 
   should show 8 mov-immediate instructions (slots) and one lgdt.
4. Smoke tests:
   - `./tools/run-smoke.sh boot_r8_only` — should pass.
   - `./tools/run-smoke.sh boot_r10` — should pass (requires preemption + scheduler).
   - `./tools/run-smoke.sh boot_r11` — should pass (requires preemption model).
   - `./tools/run-smoke.sh boot_r12` — should pass (requires capability dispatch).
   - `./tools/run-smoke.sh boot_r12_denial` — should pass (requires denial testing).
5. No IRQ delivery regressions: timer interrupt fires (vec 32) without faults.

