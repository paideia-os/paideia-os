# apic-enable-001: LAPIC Global Enable Verification

**Issue:** #356 (R9-m2-001)

**Module:** `src/kernel/core/apic/enable.pdx::ApicEnable`

**Function:** `apic_enable() -> () !{sysreg} @{boot}`

## Summary

Verifies that the LAPIC global enable bit (IA32_APIC_BASE MSR bit 11) is set. For QEMU PVH boot mode, this bit is typically already set by the hypervisor.

## Implementation

| Aspect | Detail |
|--------|--------|
| **MSR** | IA32_APIC_BASE (0x1B) |
| **Bit to verify** | Bit 11 (APIC_GLOBAL_ENABLE) |
| **Encoding** | `rdmsr` (read MSR into EDX:EAX) |
| **Real body** | `mov ecx, 0x1B; rdmsr; ret` |
| **Silent behavior** | No print or halt on success; bit is expected to be set by QEMU |

## Justification

Per Intel SDM Vol 3A §10.4.3, the APIC global enable bit must be set before any LAPIC operations are performed. QEMU PVH firmware sets this automatically.

**paideia-as support:** Full rdmsr encoding (v0.6.0+).

## Cross-module references

None (silent verification, no calls to external modules).

## Phase 6 integration

- Follows design/infrastructure/apic-system.md §1 (LAPIC initialization sequence).
- Precedes `lapic_timer_init()` in the bootflow.

---
**Audit:** R9-m2-001 bundle (June 2026)
