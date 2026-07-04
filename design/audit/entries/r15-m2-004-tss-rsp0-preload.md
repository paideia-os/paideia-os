# r15-m2-004-tss-rsp0-preload: TSS.rsp0 Kernel Stack Preload

**Issue:** #525 (R15-m2-004)

**Module:** `src/kernel/core/int/tss.pdx::tss_install`

**Function:** `tss_install() -> () !{sysreg, mem} @{boot}`

## Summary

Audits that the Task State Segment (TSS) `.rsp0` field is populated at boot to point at the kernel stack top (`&_kernel_stack + 16384`), enabling hardware ring-3→ring-0 transitions to fetch a valid ring-0 stack pointer from the TSS. Verifies supporting fields (IST1/2/3, IOMAP_BASE) and GDT descriptor installation.

## Implementation Checklist

| Aspect | Detail | Status |
|--------|--------|--------|
| **_tss allocation** | 13 u64s = 104 bytes, 16-byte aligned | ✓ (line 39) |
| **RSP0 write** | Offset +4; set via `kernel_stack_top()` call (line 76) | ✓ |
| **kernel_stack_top()** | LEA + ADD 16384; returns &_kernel_stack + 16384 (lines 47–50) | ✓ |
| **IST1 write** | Offset +36; set via `ist1_top()` call (line 81) | ✓ |
| **IST2 write** | Offset +44; set via `ist2_top()` call (line 85) | ✓ |
| **IST3 write** | Offset +52; set via `ist3_top()` call (line 89) | ✓ |
| **IOMAP_BASE** | Offset +102 (qword 96, bits 48–63); written as 0x68 (IOMAP_DISABLED) (lines 95–100) | ✓ |
| **GDT slot 6** | limit_lo(0x67) \| base[23:0]<<16 \| 0x89<<40 \| base[31:24]<<56 (lines 108–126) | ✓ |
| **GDT slot 7** | base[63:32] (lines 128–131) | ✓ |
| **TSS selector** | 0x30 (bits [15:3]=6, RPL=0, TI=0 → GDT slots 6+7) (line 134) | ✓ |
| **ltr instruction** | `ltr 0x30` loads TSS descriptor into TR (line 135) | ✓ |

## Ring-Transition Flow

When CPU delivers ring-3→ring-0 transition (via IRETQ pending #GP/#PF, SYSCALL, or interrupt):
1. CPU reads TR (currently points to GDT[6:7]) to fetch TSS descriptor.
2. TSS descriptor base and limit validated; TSS read into internal state.
3. CPU reads TSS.RSP0 (offset +4) or IST[N] if IDT entry selects one.
4. CPU switches to that stack and pushes SS/RSP/RFLAGS/CS/RIP (and error code if applicable).
5. Handler invoked on ring-0 stack.

## References

- **R13-m4-002 (#424):** Prior audit `design/audit/entries/r13-m4-002-tss-install.md`.
- **R13-m4-003 (#425):** IST stack allocation `src/kernel/core/int/ist.pdx`.
- **Intel SDM Vol 3A §8.2.5:** TSS descriptor format (64-bit mode).
- **Intel SDM Vol 3A §§5.8.2–5.8.4:** Ring transitions and task register.

## Acceptance Criteria

- [x] _tss allocated and zero-filled.
- [x] RSP0 populated with `kernel_stack_top()` result.
- [x] IST1/IST2/IST3 populated with respective stack-top addresses.
- [x] IOMAP_BASE set to 104 (I/O map disabled).
- [x] TSS descriptor packed into GDT slots 6+7 (limit=103, access=0x89).
- [x] `ltr 0x30` executed to load TSS descriptor into TR.

## Conclusion

All AC verified by existing R13-m4-002 (#424) implementation. **No change needed.** Ring-3→ring-0 transitions will correctly fetch RSP0 from the preloaded TSS.

---
**Audit:** R15-m2-004 bundle (July 2026)
