# r11-pic-mask-001: 8259 PIC Interrupt Masking (DORMANT)

**Issue:** #390 (R11-m1-003)

**Module:** `src/kernel/core/apic/pic_mask.pdx::PicMask`

**Function:** `pic_mask_all() -> () !{sysreg} @{boot}`

## Summary

Masks all 8259 Programmable Interrupt Controller (PIC) IRQs by writing 0xFF to the Interrupt Mask Register (IMR) on both master (port 0x21) and slave (port 0xA1) PICs. This prevents spurious PIC-delivered interrupts from interfering with LAPIC-based timer delivery during boot.

This is a **DORMANT** module — currently called but has no observable effect (PIC is masked, LAPIC is the only active interrupt source). If LAPIC delivery fails in the future, the PIC can be re-enabled by calling `pic_unmask_irq()` (not yet implemented).

## Implementation

| Aspect | Detail |
|--------|--------|
| **Master IMR port** | 0x21 (write 0xFF to mask all 8 IRQs) |
| **Slave IMR port** | 0xA1 (write 0xFF to mask all 8 IRQs) |
| **Value written** | 0xFF (all bits set = all IRQs masked) |
| **Encoding** | Two `out_al` instructions (port I/O writes) |
| **Real body** | `mov dx, 0x21; mov al, 0xFF; out_al al; mov dx, 0xA1; mov al, 0xFF; out_al al` |
| **Silent behavior** | No print or halt; pure side-effect (masks IRQs) |

## Justification

Per 8259 PIC specification:
- The Interrupt Mask Register (IMR) controls which IRQs are forwarded to the CPU.
- Writing 0xFF to both master and slave IMRs masks all 16 IRQs (8 master + 8 slave).
- Masked IRQs are held pending in the PIC but never delivered to the CPU.

This prevents:
1. **Spurious IRQs from legacy PIC devices** (PS/2, etc.) interfering with LAPIC timer
2. **Vector collisions** if both LAPIC and PIC try to deliver on the same vector
3. **Interrupt handler confusion** during boot when TCB state is being initialized

**Dormant rationale:** R10-m2-003 already has LAPIC timer delivering reliably (with periodic mode fallback). PIC is not needed for boot. If LAPIC fails later (e.g., due to QEMU or CPU issues), PIC can be unmasked as a fallback (requires implementing `pic_unmask_irq()`).

**paideia-as support:** I/O port writes via `out_al` (v0.6.0+).

## Call order rationale (R11-m1-003)

In `kernel_main_64`:
1. `apic_enable` — Verify LAPIC global enable bit (MSR)
2. `apic_svr_enable` — Enable LAPIC via SVR bit 8
3. `pic_mask_all` — **Mask PIC to prevent interference** (NEW, called here)
4. `lapic_timer_init` — Program LVT Timer register
5. All other boot steps...

This ensures PIC is masked **before** any timer interrupts can fire.

## Cross-module references

None (side-effect-only, no calls to external modules).

## Future work (DORMANT activation)

If needed, implement `pic_unmask_irq(irq: u8)` to selectively re-enable PIC IRQs:
```pdx
pub let pic_unmask_irq : (u8) -> () !{sysreg} @{boot} = fn(irq: u8) -> unsafe {
  // Read current IMR, clear bit `irq`, write back to master or slave
}
```

Also add exception handlers for PIC vectors (0x20–0x2F) if re-enabling.

## Phase 6 integration

- Follows design/infrastructure/apic-system.md §3 (PIC masking during LAPIC boot).
- Precedes `lapic_timer_init` to ensure clean interrupt environment.
- Dormant in R11-m1; activation depends on LAPIC reliability assessment in R11-m2+.

---
**Audit:** R11-m1-003 bundle (July 2026)
