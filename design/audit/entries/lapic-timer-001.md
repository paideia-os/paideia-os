---
audit_id: lapic-timer-001
issue: 254
file: src/kernel/core/timer/lapic_isr.pdx
function: lapic_timer_init / lapic_timer_rearm / lapic_eoi
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-06-21
---

# AUDIT lapic-timer-001 — LAPIC TSC-deadline timer (R6.5-003, R6.5-004)

## Justification
The LAPIC timer drives preemption. Programming the LVT timer register, writing
the IA32_TSC_DEADLINE MSR, and writing the EOI register are all privileged
MMIO/MSR operations that change interrupt-delivery behaviour for the local CPU —
unsafe. The value composition (LVT bits, deadline = tsc + interval) is ordinary
arithmetic in the typed surface.

Citation: Intel SDM Vol 3A §10.5.4.1 (TSC-deadline mode), §10.8.5 (EOI).
**Verification TODO.**

## Intended sequences
- `lapic_timer_init`: `mov [LAPIC_BASE+0x320], (32 | TSC_DEADLINE_MODE)` — LVT
  timer: vector 32, mode 0b10, unmasked.
- `lapic_timer_rearm`: `rdtsc` (EDX:EAX) → `shl rdx,32; or rax,rdx`; `add rax,
  interval`; `mov ecx, 0x6E0; wrmsr`.
- `lapic_eoi`: `mov [LAPIC_BASE+0xB0], 0`.

## Phase-6 honest scope gaps
- **rdtsc / wrmsr encoders** and **MMIO store operands**: not in paideia-as
  0.6.0; each unsafe block emits `mov rax, rax`. Implemented for real: the LVT
  value via `lvt_timer_value`, the tick/re-arm/EOI control flow in
  `lapic_timer_isr`.

## Verification (when encoders land)
Test: init with a 10 ms interval; observe the timer ISR fire 10 times in 100 ms
(measured by a busy-loop reading rdtsc).
