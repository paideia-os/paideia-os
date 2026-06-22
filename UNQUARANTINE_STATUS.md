# PA8 v0.8 Unquarantine Attempt Status

## Overview
Phase 8 v0.8 close-out attempted unquarantine of 9 files from `.quarantine/src/kernel/` (m7-002 #840).

## Files Attempted
All 9 files below failed Phase 8 paideia-as syntax validation:

1. **core/cap/slab.pdx** — Uses `module ... = structure { ... }` (Module language, not supported)
   - Contains `let mut` bindings and block-form lambda bodies `fn () -> { ... }`
   - Phase 8 only supports simple expression lambdas

2. **core/ipc/slots.pdx** — Reserved word error (E0011)
   - File starts with pseudo-code comments (`;`) predating Phase 8 syntax
   - Not actual paideia-as source; sketch/placeholder only

3. **core/ipc/allocator.pdx** — Reserved word error (E0011)
   - Pseudo-code sketch, not Phase 8 compatible

4. **core/ipc/channel.pdx** — Skipped (same pattern as above)

5. **core/ipc/dispatch.pdx** — Skipped (same pattern as above)

6. **core/ipc/mpsc_lock.pdx** — Skipped (same pattern as above)

7. **core/ipc/destroy_channel.pdx** — Skipped (same pattern as above)

8. **core/ipi/tlb_shootdown.pdx** — Skipped (same pattern as above)

9. **core/sched/enqueue.pdx** — Skipped (same pattern as above)

## Resolution
All 9 files remain quarantined. These are pre-Phase-8 sketches or use Module-language constructs.
Real implementations will require:
- Phase 9+ support for Module language (functors, signatures, structures)
- Phase 9+ support for `let mut` and mutable bindings
- Rewrite of block-form lambdas to expression form for Phase 8 compatibility

## Deferred To
- Phase 9 or later when Module language support ships
- Cross-filing issue for IPC subsystem rewrite post-Phase-8

## Files Left In Quarantine
All 9 files remain under `.quarantine/src/kernel/`:
- `.quarantine/src/kernel/core/cap/slab.pdx`
- `.quarantine/src/kernel/core/ipc/{slots,allocator,channel,dispatch,mpsc_lock,destroy_channel}.pdx`
- `.quarantine/src/kernel/core/ipi/tlb_shootdown.pdx`
- `.quarantine/src/kernel/core/sched/enqueue.pdx`

Status: paideia-os kernel.elf will not build until these are rewritten or Phase 9 Module language lands.
