---
audit_id: tlb-ipi-001
issue: 256
file: src/kernel/core/ipi/tlb_shootdown.pdx
function: send_ipi / shootdown_invlpg / tlb_shootdown_isr
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-06-21
---

# AUDIT tlb-ipi-001 — TLB shootdown IPI delivery (R6.5-005)

## Justification
Cross-CPU TLB consistency requires the originating CPU to interrupt the remote
CPU (an IPI via the LAPIC ICR) and the remote CPU to flush the stale entry
(INVLPG). Writing the ICR and executing INVLPG are privileged → unsafe. The
mailbox-drain loop and the ack-counter increment are ordinary computation.

This handler consumes the per-CPU mailbox populated by `aspace_unmap`
(R5.5-004, audit aspace-unmap-001).

Citation: Intel SDM Vol 3A §10.6.1 (Interrupt Command Register), §4.10.5 (TLB
shootdown). **Verification TODO.**

## Intended sequences
- `send_ipi`: `mov [LAPIC+0x310], (target_apic_id<<24)`; `mov [LAPIC+0x300],
  (vector | fixed | assert)`.
- `shootdown_invlpg`: `invlpg [vaddr]`.
- Receiver ISR: read mailbox bit, clear it, INVLPG, `lock inc [ack_counter]`.

## Phase-6 honest scope gaps
- **MMIO store operand** (ICR) + **INVLPG encoder**: not in paideia-as 0.6.0;
  both unsafe blocks emit `mov rax, rax`. The ack increment is non-atomic in the
  current model (LOCK prefix encoder pending). Implemented for real: ICR value
  composition, the dispatch loop over CPUs, and the drain/ack control flow.

## Verification (single-CPU QEMU)
A self-IPI (target = self) causes the vector-33 self-handler to run, drain the
mailbox, and increment the ack counter.
