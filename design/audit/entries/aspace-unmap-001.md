---
audit_id: aspace-unmap-001
issue: 248
file: src/kernel/core/mm/aspace_unmap.pdx
function: local_invlpg
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-06-21
---

# AUDIT aspace-unmap-001 — local TLB flush on unmap (R5.5-004)

## Justification
After clearing a leaf PTE, the originating CPU must invalidate its own TLB entry
for the unmapped vaddr (INVLPG) before any subsequent access; otherwise a stale
translation could read freed physical memory. INVLPG is privileged → unsafe.
Cross-CPU consistency is handled separately by queueing a shootdown request in
the per-CPU mailbox (drained by R6.5-005, the IPI delivery path).

Citation: Intel SDM Vol 3A §4.10.4.1 (INVLPG) and §4.10.5 (TLB shootdown via
IPI). **Verification TODO.**

## Phase-5 honest scope gaps
- **INVLPG encoder** + **[reg] memory operand**: not in paideia-as 0.6.0;
  `local_invlpg` emits `mov rax, rax`. The PTE-clear store is gated identically
  (see aspace-map-001).
- Implemented for real: the per-CPU shootdown mailbox bookkeeping
  (`queue_shootdown` sets a pending bit for every CPU except self).

## Caller discipline
```
RDI ← as_root, RSI ← vaddr, RDX ← self_cpu
```
After return, `shootdown_mailbox` has a set bit per other CPU and
`shootdown_vaddr` holds the queued address.

> Retired: 2026-07-03 by r13-m2-004-aspace-unmap (issue #422). Content preserved for historical reference.
