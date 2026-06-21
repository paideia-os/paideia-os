---
audit_id: boot-zerobss-001
issue: 5
file: src/kernel/boot/zero_bss.pdx
function: zero_bss
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-06-21
---

# AUDIT boot-zerobss-001 — .bss zeroing via rep stosq

## Justification
The .bss section (uninitialized data) must be cleared to zero before kernel
runtime begins. The x86_64 ABI provides `rep stosq` as an efficient bulk-zeroing
instruction: it clears RCX qwords (8-byte units) starting at [RDI], with the
value from RAX.

Caller pre-loads registers per x86_64 system ABI:
- RDI: destination address (_bss_start, provided by linker symbol)
- RAX: value to write (0x0)
- RCX: count of qwords ((_bss_end - _bss_start) / 8, computed by caller)

The `rep stosq` instruction executes in privileged mode and has no memory
access constraints at Phase-1: the .bss section is always readable and writable
by the kernel. No capabilities or type-system guarantees required.

## Implementation notes
The function signature `fn (start_addr: u64) -> ()` takes the start address as
a parameter (placed in RDI by the x86_64 calling convention), though the
register is pre-populated by the caller before invocation. This matches the
caller discipline and passes the architectural constraint to paideia-as.

The unsafe block justification covers:
- `sysreg` effect: rep stosq modifies RDI and RCX during execution
  (though the primary effect is the bulk memory write).
- No external capabilities required: the .bss section is controlled by the
  kernel's linker script and is always valid memory in the Phase-1
  identity-mapped region.

## Known limitations
None at Phase-1. Full .bss allocation (symbol anchors _bss_start and _bss_end)
is defined by link.ld. Future phases may require CPUID-based size detection if
the kernel grows beyond 4 KiB of uninitialized data.

## Mnemonic encoding status
The `rep_stosq` mnemonic was successfully encoded by paideia-as m2-009 encoder
without U1606 errors (zero-operand instruction parsing in unsafe blocks).
