# PaideiaOS Audit Catalog

Every `unsafe { }` block in PaideiaOS kernel source carries an audit
entry under `design/audit/entries/`. The entry records:

- The IR effect (`sysreg`, `mmio`, `rawmem`, etc.) that the block performs.
- The capability set required (often empty for kernel-internal blocks).
- A human-readable justification ≥ 20 characters.

## Entry schema

```yaml
---
audit_id: <slug>
issue: <gh-issue-number>
file: src/kernel/.../<basename>.pdx
function: <function name>
effects: [<effect-name>, ...]
capabilities: [<cap-name>, ...]
reviewed_by:
date: YYYY-MM-DD
---

# AUDIT <slug> — <function name>

## Justification
<paragraph explaining why this block needs unsafe>
```

The `effects` field uses paideia-as effect names (`sysreg` for CR/DR/MSR
ops, `rawmem` for unbounded memory writes, `mmio` for device-port I/O).
The `capabilities` field is currently empty for all kernel-internal
operations; once userspace exposure begins, capabilities will be required.

## Phase-1 entries (12 unsafe blocks across 9 files)

| Audit ID | File | Function | Effects |
|----------|------|----------|---------|
| boot-gdt-001 | boot/gdt.pdx | gdt_load | sysreg |
| boot-pagetables-001 | boot/pagetables.pdx | (data; no fn) | sysreg |
| boot-longmode-001 | boot/long_mode.pdx | transition | sysreg |
| boot-zerobss-001 | boot/zero_bss.pdx | zero_bss | sysreg |
| uart-init-001 | boot/uart.pdx | uart_out | sysreg |
| uart-putc-001 | boot/uart.pdx | uart_putc | sysreg |
| uart-puts-001 | boot/uart.pdx | uart_puts | sysreg |

## Phase-2+ growth

Each new `.pdx` file with an `unsafe { }` block adds a corresponding
audit entry in the same commit. The CI smoke (Phase-1 m1-014) will
eventually verify that every `unsafe { }` block in the source tree
has a matching audit entry.

## Phase-2 entries (1 unsafe block across 1 file)

| Audit ID | File | Function | Effects |
|----------|------|----------|---------|
| cap-dump-001 | src/kernel/core/cap/dump.pdx | (placeholder, Phase 3+) | rawmem |

The cap-dump-001 entry documents a deferred unsafe block for the cap_dump(handle)
diagnostic introspection utility. The real implementation is scheduled for Phase 3
when unsafe blocks gain structured control flow (if/else, loops) support.

## Phase-3 entries (1 safety review across 1 file)

| Audit ID | File | Function | Effects |
|----------|------|----------|---------|
| ipc-memory-ordering-001 | src/kernel/core/ipc/*.pdx | (all channel ops) | acq-rel ordering |

The ipc-memory-ordering-001 entry documents the acquire-release (acq-rel) memory ordering requirements
for the SPSC channel's head/tail indices. Per Lamport/Vyukov SPSC algorithm, all message writes must
happen-before head increment (producer release), and tail load must acquire message data (consumer acquire).
See `design/ipc/p3-deadlock-freedom.md` for the deadlock-freedom proof; `design/audit/entries/ipc-memory-ordering-001.md`
for the full ordering catalogue.

The Phase-3 IPC implementation includes unsafe pointer arithmetic in slots.pdx (ring buffer indexing)
and atomic operations in mpsc_lock.pdx (CAS-based spinlock). These are deferred to paideia-as Phase 7+
when the encoder supports these patterns.

## Phase 1 honest scope

All Phase-1 unsafe blocks are Phase-1 stubs (single-instruction or
single-port-write) gated on paideia-as encoder gaps (cf. paideia-as
issues #734, #736 for the open bugs). Real multi-instruction
unsafe blocks land when paideia-as Phase 6 ships jcc/cmp/call
encoders for the unsafe-block payload walker.

Phase-3 extends this to include unsafe pointer arithmetic (ring buffer indexing)
and atomic compare-and-swap (global MPSC lock), which remain stubs pending
encoder support for these patterns in paideia-as Phase 6+.

## Phase-4 entries (8 unsafe blocks across 8 scheduler files)

| Audit ID | File | Function | Effects |
|----------|------|----------|---------|
| switch-001 | src/kernel/core/sched/switch.pdx | stub_context_switch | sysreg (CR3, MSR gs-base), registers |
| gs-current-001 | src/kernel/core/sched/gs_current.pdx | stub_get/set_gs_base | sysreg (MSR 0xC0000102) |
| current-001 | src/kernel/core/sched/current.pdx | stub_sched_current | rawmem (GS:[0]) |
| idle-001 | src/kernel/core/sched/idle.pdx | stub_idle_hlt | sysreg (HLT instruction) |
| tsc-deadline-001 | src/kernel/core/sched/tsc_deadline.pdx | stub_tsc_deadline_set | sysreg (MSR 0x6E0) |
| timer-irq-001 | src/kernel/core/sched/timer_irq.pdx | stub_timer_irq_handler | sysreg (MSR ops), rawmem (queue manipulation) |
| timer-idt-001 | src/kernel/core/sched/timer_idt.pdx | stub_idt_set_timer_handler | sysreg (LIDT), rawmem (IDT writes) |

Phase-4 scheduler implementation includes:
- Context switch with register save/restore and GS-base MSR access
- Per-CPU current TCB via GS-base offset 0
- Idle thread with HLT instruction
- TSC-deadline timer programming via MSR
- Timer interrupt handler with scheduler integration
- IDT entry installation for timer vector
- 6 audit entries documenting unsafe block rationale and invariants
- 6 smoke tests (stubs) for validation once real implementation ships

## Phase-5 entries (3 unsafe blocks across 3 memory-management files)

| Audit ID | File | Function | Effects |
|----------|------|----------|---------|
| memory_map-001 | src/kernel/core/mm/memory_map.pdx | (data; parser) | rawmem (E820 table read) |
| aspace_activate-001 | src/kernel/core/mm/aspace_activate.pdx | p1_aspace_activate | sysreg (CR3 write) |
| pf_handler-001 | src/kernel/core/mm/pf_handler.pdx | stub_pf_handler | sysreg (CR2/CR3 read), rawmem (PT update) |

Phase-5 memory-management API includes:
- E820 memory-map parsing for bootloader-provided RAM/reserved regions
- Buddy allocator constants (4K–2M, 10 free lists)
- Per-CPU magazine cache for fast allocation
- Physical allocation/free API (p1_phys_alloc, p1_phys_free)
- Address-space lifecycle (create, activate, destroy)
- Page-table walk and mapping/unmapping (4K and 2M pages)
- Page-fault handler entry point
- PCID (Process-Context Identifier) support for TLB efficiency
- NUMA preparation (per-domain free lists, domain-aware refill)
- 3 audit entries documenting unsafe surfaces (bootloader table read, CR3 write, fault handler)
- 7 smoke tests (stubs) for validation once Phase-6 implementation ships

## Phase-6 entries (9 unsafe blocks across 15 core files)

| Audit ID | File | Function | Effects |
|----------|------|----------|---------|
| int-ist-stacks-001 | src/kernel/core/int/ist.pdx | stub_ist_init | sysreg, rawmem |
| apic-x2apic-001 | src/kernel/core/apic/x2apic.pdx | stub_enable_x2apic | sysreg |
| apic-ioapic-001 | src/kernel/core/apic/ioapic.pdx | stub_ioapic_set_redir | mmio |
| acpi-rsdp-001 | src/kernel/core/acpi/rsdp.pdx | stub_rsdp_find | rawmem |
| ipi-cross-cpu-001 | src/kernel/core/ipi/cross_cpu.pdx | stub_ipi_send | sysreg |

Phase-6 interrupts, APIC, and timer-wheel API includes:
- Interrupt Descriptor Table (IDT) in kernel .bss with 256 vectors
- IST (Interrupt Stack Table) stacks for DF/NMI/MC exception handling
- Exception handlers for UD, GP, PF, DF, MC, NMI vectors
- x2APIC enablement via IA32_APIC_BASE_MSR
- LAPIC timer configuration with TSC-deadline mode
- LAPIC EOI (End-of-Interrupt) helper
- I/O APIC redirect table programming for ISA IRQ routing
- MSI (Message Signaled Interrupt) support for PCIe devices
- IRQ-to-notification-capability routing table (224 vectors)
- ACPI RSDP discovery and RSDT/XSDT parsing
- MADT (Multiple APIC Description Table) walker for topology discovery
- Hierarchical 8-level timer wheel (64 buckets per level, O(1) insertion)
- timer_add() and timer_cancel() syscall APIs
- LAPIC timer ISR with deadline-based firing
- Cross-CPU IPI delivery (reschedule, TLB shootdown)
- TLB shootdown IPI handler
- Reschedule IPI handler
- 5 audit entries documenting unsafe surfaces (IST init, x2APIC MSR, IOAPIC MMIO, RSDP scan, IPI dispatch)
- 5 smoke tests (stubs) for validation once Phase-7 implementation ships
