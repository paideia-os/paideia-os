---
audit_id: r13-m6-001-kind-process
issue: 430
file: src/kernel/core/process/process.pdx
function: (data-only; no handler wired)
effects: []
capabilities: []
reviewed_by:
date: 2026-07-03
---

# R13-m6-001 — KIND_PROCESS handler (structural stub; real handler deferred)

**Issue:** #430
**Files:** src/kernel/core/process/process.pdx (new)
**Backtracking:** #482 (cap_smoke migration), PA-R13-010 (#923, sub-imm), PA-R13-011 (#924, label sharing)

## Landing scope

This issue lands only the process-pool infrastructure:

- `_process_pool : [u64; 256]` — 64-slot × 32-byte process table in .bss.
- `_next_pid : [u64; 1]` — 1-based bump counter (array form to guarantee .bss placement per PA-R13-008 #921).
- Constants for slot layout: `PROCESS_SLOT_BYTES=32`, `PROCESS_POOL_SLOTS=64`, `PROCESS_OFF_ASPACE_ROOT=0`, `PROCESS_OFF_PID=8`, `PROCESS_OFF_PARENT_PID=16`, `PROCESS_OFF_STATE=24`.
- State constants: `PROCESS_STATE_RUNNING=0`, `PROCESS_STATE_ZOMBIE=1`, `PROCESS_INVALID_PID=0`.

The real `cap_handler_process` (OP_CREATE / OP_GET_ASPACE_ROOT), the dispatch table entry in `invoke.pdx`, the `cap_proc_msg` tag, and the `pub` promotion of `aspace_create` are all **not** landed here. They are deferred to a follow-up landing after the blockers below are resolved.

## Deferral rationale (three concrete blockers)

1. **cap_smoke path collision.** `src/kernel/core/cap/smoke.pdx` mints slot 0 with kind=1, target_ptr=0xCAFE, rights=0xF and invokes it via `cap_invoke_dispatch`; the R8 fingerprint asserts the result equals 0xCAFE. This depends on `invoke.pdx`'s current fallthrough (`mov rax, rsi; ret`). A real KIND_PROCESS handler returns a fresh pid (not target_ptr), which breaks cap_smoke's expectation and the 5-mode fingerprint. Migration tracked in #482.

2. **paideia-as encoder gaps.** The real handler needs `sub reg, imm` (for `pid - 1` slot arithmetic) — PA-R13-010 (#923). It also wants back-to-back-label aliasing for the shared `proc_full`/`proc_bad_pid` error tail — PA-R13-011 (#924). Both have workarounds (`add r, 0xFF...FF` and duplicate-block, respectively), so encoder blocks are soft.

3. **`_next_pid` initialization.** `uninit` in `.bss` zero-inits at boot, colliding with `PROCESS_INVALID_PID=0`. Real OP_CREATE would return pid=0 on first call, which every downstream check treats as "invalid." Needs an explicit `_next_pid[0] = 1` boot hook (or a designer-blessed non-zero initializer once PA-R13-008 lands the .data section discipline).

## Data model (pinned for the eventual real handler)

| Offset | Size | Field | Semantics |
|---|---|---|---|
| 0 | 8 | aspace_root | PML4 phys base from `aspace_create`; 0 = slot free |
| 8 | 8 | pid | 1-based; == slot_index + 1 |
| 16 | 8 | parent_pid | 0 = root process |
| 24 | 8 | state | 0=RUNNING, 1=ZOMBIE (reserve 2..7 for m11 signals) |

Pool size 64 slots × 32 bytes = 2048 bytes (256 u64s). 32-byte stride is SIB-friendly (`shl slot, 5`).

## Ops (deferred implementation reference)

- **OP_CREATE (0)**: rights & RIGHT_INVOKE (0x08). Reads `_next_pid`, checks pool-full (>64). Calls `aspace_create(&pml4)` (kernel PML4 sourced from boot_stub.S `.global pml4` — identity-mapped low half so VA==PA). Writes {aspace_root, pid, parent_pid=0, state=RUNNING} at slot (pid-1)*32. Bumps `_next_pid`. Returns pid. 0 on OOM or pool full.
- **OP_GET_ASPACE_ROOT (1)**: rights & RIGHT_READ (0x01). Extracts pid from `op_arg[63:8]`. Returns `_process_pool[pid-1].aspace_root` or 0 on invalid pid (0 or >64).
- Unknown op: `INVOKE_UNSUPPORTED (0xFFFFFFFFFFFFFFFC)`.
- Rights failure: `INVOKE_DENIED (0xFFFFFFFFFFFFFFFD)`.

Handler ABI: `(rdi=rights, rsi=target_ptr, rdx=op_arg) -> rax`. Effects `{mem, sysreg}`, capabilities `{cap}`.

## Regression

Structural-only landing: no code path in the 5-mode smoke suite reaches the new symbols. `.bss` grows by 2056 bytes but the initialized code is unchanged. Fingerprints byte-identical.

## Follow-up landing plan

When #482 lands (cap_smoke migration) and PA-R13-008 provides the `_next_pid` init discipline, this issue's follow-up will:

1. Add `src/kernel/core/cap/kind_process.pdx` with the real 100-line handler.
2. Add `cap_proc_msg` to `src/kernel/core/cap/tags.pdx`.
3. Add `cmp rcx, 1; je call_kind_process` branch to `src/kernel/core/cap/invoke.pdx`.
4. Promote `aspace_create` in `src/kernel/core/mm/aspace_create.pdx` to `pub`.
5. Add a boot-time `_next_pid[0] = 1` initializer (in `kernel_main.pdx` or a dedicated `process_init`).

## Cross-references

- design/milestones/r13-preflight.md §B (kind mapping: KIND_PROCESS=1)
- src/kernel/core/mm/aspace_create.pdx (aspace_create landed as #421)
- src/kernel/core/cap/invoke.pdx (dispatch chain)
- src/kernel/core/cap/smoke.pdx (R8 fingerprint anchor)
- #482 (cap_smoke migration backtracking)
- paideia-as #923 (PA-R13-010 SUB r,imm)
- paideia-as #924 (PA-R13-011 label sharing)

## Acceptance

- [x] Build succeeds.
- [x] 5-mode regression byte-identically green.
- [x] Pool + counter declared in .bss.
- [x] No wiring changes to invoke.pdx / tags.pdx / aspace_create.pdx.
- [x] Backtracking issues filed (#482, PA-R13-010, PA-R13-011).
