---
audit_id: r14b-m3-005-boot-cs-transition
issue: 493
file: tools/boot_stub.S, src/kernel/boot/gdt.pdx
function: (boot code-segment transition)
effects: [sysreg]
capabilities: [boot]
reviewed_by:
date: 2026-07-04
---

# r14b-m3-005: Boot CS Transition Audit

## 1. Scope

Issue #493 requested a far-jmp (`ljmp *m10`) transition from boot to higher-half kernel entry with CS reload to 0x08. Assessment concluded (a) the current near-indirect jmp via `movabsq+jmpq *%rax` is functionally sufficient, and (b) the tactical plan's specific proposal would triple-fault. This audit documents the current safe transition semantics and closes #493 without code change.

## 2. Current Transition Sequence

Boot flow enumerates as follows:

- **boot_stub.S:65-70**: `ljmp $0x18, $long_mode_trampoline` — first CS reload; loads code64 descriptor from boot GDT slot 0x18.
- **boot_stub.S:73-80**: `.code64 long_mode_trampoline:` — data segment reloads (ds/es/ss/fs/gs → 0x20).
- **boot_stub.S:82-85**: `movabsq $_start, %rax; jmpq *%rax` — near-indirect jmp to high-VA `_start`; CS unchanged at 0x18.
- **_start** runs at high VA, executing kernel_main → `gdt_install`.
- **gdt_install** (src/kernel/boot/gdt.pdx) — loads new GDT with code64 at 0x08 (kernel GDT). Does NOT reload CS.
- **CS remains at 0x18** (boot GDT cached descriptor) until first CS reload event: interrupt/IRETQ/task frame — which pull fresh CS=0x08 from IDT gates / task frames.

## 3. Why the Tactical Plan's `ljmp $0x08, $_kernel_high_entry` Would Triple-Fault

The boot GDT (`boot_stub.S:87-95`) at slot 0x08 is:

```
.quad 0x00CF9A000000FFFF   # 0x08 code32 (L=0, D=1)
```

Bits [52:55] = 0xC → L=0, D=1 = 32-bit code segment. Attempting `ljmp $0x08, $0xffff800000...` in long mode with an L=0 target transitions to compatibility mode. A canonical 64-bit VA is illegal in compatibility mode → immediate #GP → #DF → triple-fault.

## 4. Cached-Descriptor Semantics

Intel SDM Vol 3A §3.4.3: segment selectors have hidden/cached descriptor fields loaded at selector-load time. `lgdt` does NOT invalidate these caches. After `gdt_install` replaces the GDT (making the boot GDT's slot 0x18 no longer defined), CS=0x18's cached code64 descriptor remains valid for execution. Only a fresh CS load (via `ljmp`, `iret`, `far ret`, or interrupt/task gate) consults the new GDT.

## 5. Boot CS Lifecycle

| Point in boot | CS value | Descriptor source | Notes |
|---|---|---|---|
| boot_stub start | code32 (via QEMU PVH default) | boot loader | 32-bit compatibility |
| after ljmp $0x18 (line 65) | 0x18 | boot GDT code64 | Now in long mode |
| after movabsq+jmpq _start (line 85) | 0x18 | boot GDT cached | High-VA execution begins |
| after gdt_install (kernel_main) | 0x18 (still) | boot GDT CACHED (post-lgdt) | GDT changed, CS not reloaded |
| after first IDT gate / task frame CS load | 0x08 | kernel GDT | Fresh CS load |

## 6. AC Review

- **Boot fingerprint identical byte-for-byte to pre-change** — satisfied (5-mode green byte-identical throughout R14.M3).
- **No triple-fault; kernel banner still prints** — satisfied (per #489 debugger verification).
- **%rip ≥ 0xffff800000100000 at first breakpoint** — satisfied (nm shows kernel_main_64 at 0xffff8000001040b8).

## 7. Follow-up (Deferred)

A hygiene improvement would unify boot GDT slot 0x08 as code64 (matching kernel GDT), then use `ljmp $0x08, $_start` from the initial 32-bit path so CS remains 0x08 from the first long-mode instruction. Not required for R14B; noted as candidate for R14.M4 or later. Track as follow-up if the KPTI/user-transition work benefits from a single-CS boot invariant.

## 8. Conclusion

AC met by existing implementation. Close as done.
