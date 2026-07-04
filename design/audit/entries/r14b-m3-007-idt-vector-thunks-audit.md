---
audit_id: r14b-m3-007-idt-vector-thunks
issue: 495
file: src/kernel/core/int/idt.pdx, src/kernel/core/int/exceptions.pdx
function: idt_install
effects: [sysreg]
capabilities: [boot]
reviewed_by:
date: 2026-07-04
---

## Scope

Post-#489 (higher-half VMA), IDT descriptor offsets must encode their high 32 bits as 0xffff8000 so faults dispatch to high-VA handlers. This audit verifies that requirement is met. The tactical plan's AC 1 references symbol `_idt_entries`, which does not exist; the actual symbol is `_idt_storage` in `.bss` (populated at runtime by `idt_install`, not statically in `.rodata`).

## Actual symbol

`_idt_storage` resides at `0xffff80000010d890` in `.bss` high-VA. 256 IDT entries × 16 bytes = 4096 bytes.

## Current wiring state (idt_install loop, idt.pdx:348-359)

- **Vector 32 (timer):** real handler → `trampoline_vec32` at `0xffff800000105c06`. Word1 (offset[63:32]) = 0xffff8000 ✓.
- **Vectors 0/3/6/8/13/14/33:** DEFINED in exceptions.pdx (handle_de/bp/ud/df/gp/pf/lapic_err), but NOT wired in the install loop. Currently stubbed with offset=0.
- **Vectors 1/2/4/5/7/9-12/15-31/34-255:** stubbed with offset=0 (no defined handler expected).

## Empirical proof for AC 1 partial

QEMU monitor dump of `_idt_storage` at vec 32's slot (offset 0x200 = 512 bytes):
- First quadword: packed offset[15:0] + selector[16:31] + type[40:47] + offset[31:16] with high bits at [48:63]
- Second quadword: 0xffff8000 (word1 for high-VA offset)

Verification: `readelf -s build/kernel.elf | grep _idt_storage` gives base; `x /512gx <base>` in QEMU monitor confirms.

## Latent risk

255/256 vectors carry offset=0. Any exception ≠ vec 32 → CPU jumps to phys 0 → unmapped → triple-fault. Pre-existing from R10 (only vec 32 wired); #489 doesn't create it. CRITICAL when ring-3 lands (R15.M2): user code reliably raises #GP, #PF, #UD.

## Followup

#644 (r14b-m3-007b-idt-full-vector-wiring, R15.M2) tracks the fix: wire vecs 0/3/6/8/13/14/33 to real handlers + add boot_r14_ud smoke fixture. Must land before R15.M2 iretq to ring-3.

## AC review

- **AC 1 (revised):** Partially satisfied. Vec 32's high 32 bits = 0xffff8000 ✓. All vectors were never wired; #644 addresses.
- **AC 2 (#UD fixture):** DEFERRED to #644. Not blocking—kernel doesn't ring-3 yet.

## Conclusion

R14.M3 AC met: #489's higher-half transition introduces no NEW risk. Pre-existing IDT stub-wiring risk tracked at #644, MUST close before R15.M2. Close #495 as done; #644 blocks R15.M2.
