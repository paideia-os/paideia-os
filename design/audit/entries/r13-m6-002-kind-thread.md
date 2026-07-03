---
audit_id: r13-m6-002-kind-thread
issue: 431
files:
  - src/kernel/core/thread/thread.pdx
  - src/kernel/core/cap/kind_thread.pdx
  - src/kernel/core/process/process_init.pdx
  - src/kernel/core/cap/tags.pdx (append)
  - src/kernel/core/cap/invoke.pdx (dispatch branch)
  - src/kernel/boot/kernel_main.pdx (call site)
functions:
  - cap_handler_thread (unsafe block)
  - process_init (unsafe block)
effects:
  - {mem, sysreg}
capabilities:
  - {cap}
reviewed_by:
date: 2026-07-03
---

# R13-m6-002 — KIND_THREAD handler (real body, OP_CREATE + OP_START stub)

**Issue:** #431
**Files:** src/kernel/core/thread/thread.pdx (new), src/kernel/core/cap/kind_thread.pdx (new), src/kernel/core/process/process_init.pdx (new), src/kernel/core/cap/tags.pdx (append), src/kernel/core/cap/invoke.pdx (dispatch), src/kernel/boot/kernel_main.pdx (init call)
**Backtracking:** #430 (sibling KIND_PROCESS), #482 (cap_smoke migration), PA-R13-010 (#923, sub-imm workaround), PA-R13-011 (#924, label sharing)

## Landing scope

This issue lands the complete KIND_THREAD handler (real body) plus the symmetric 1-based counter initialization that applies to both #430 and #431:

### Thread pool infrastructure (src/kernel/core/thread/thread.pdx)
- `_thread_pool : [u64; 256]` — 64-slot × 32-byte thread table in .bss.
- `_next_tid : [u64; 1]` — 1-based bump counter (array form to guarantee .bss placement per PA-R13-008 #921).
- Constants: `THREAD_SLOT_BYTES=32`, `THREAD_POOL_SLOTS=64`, `THREAD_OFF_PID=0`, `THREAD_OFF_TID=8`, `THREAD_OFF_ENTRY_RIP=16`, `THREAD_OFF_STACK_TOP=24`, `THREAD_INVALID_TID=0`.

### Real KIND_THREAD handler (src/kernel/core/cap/kind_thread.pdx)
- `cap_handler_thread(rights, target_ptr, op_arg) -> u64` — real 30-instruction handler with full body.
- OP_CREATE (op_code=0): Right check (RIGHT_INVOKE 0x08), pool-full check, slot allocation, counter bump, returns tid.
- OP_START (op_code=1): Right check, stub return 0 (scheduler enqueue deferred to R14).
- Unknown op: returns INVOKE_UNSUPPORTED (0xFFFFFFFFFFFFFFFC).
- Rights failure: returns INVOKE_DENIED (0xFFFFFFFFFFFFFFFD).
- Pool full or invalid: returns THREAD_INVALID_TID (0).

### Bootstrap init (src/kernel/core/process/process_init.pdx)
- `process_init()` — initializes `_next_pid[0] = 1` and `_next_tid[0] = 1` at boot, before dispatch surfaces.
- Covers both #430 follow-up (KIND_PROCESS OP_CREATE) and #431 (KIND_THREAD OP_CREATE).
- Called from kernel_main after nx_enable and before syscall_msr_init.

### Dispatch wiring
- `src/kernel/core/cap/invoke.pdx`: Added `cmp rcx, 2; je call_kind_thread` branch and handler stub.
- `src/kernel/core/cap/tags.pdx`: Added `cap_thread_msg : [u8; 19] = "CAP INVOKE THREAD\n\0"`.
- `src/kernel/core/boot/kernel_main.pdx`: Added `call process_init` at boot.

## Data model (pinned)

| Offset | Size | Field | Semantics |
|---|---|---|---|
| 0 | 8 | pid | parent process id (1-based, from op_arg[63:8]) |
| 8 | 8 | tid | 1-based; == slot_index + 1 |
| 16 | 8 | entry_rip | thread entry point (u64, stub=0 in CREATE) |
| 24 | 8 | stack_top | kernel stack top (u64, stub=0 in CREATE) |

Pool size: 64 slots × 32 bytes = 2048 bytes (256 u64s). 32-byte stride is SIB-friendly (`shl slot, 5`).

## Operation semantics

### OP_CREATE (op_code=0)
- **Rights check**: `rights & RIGHT_INVOKE (0x08)` must be true; else return INVOKE_DENIED.
- **Operand**: `op_arg[63:8]` = parent process id.
- **Action**:
  1. Read `_next_tid[0]`.
  2. If tid >= 64, return 0 (pool full).
  3. Compute slot offset: `(tid - 1) * 32` using `add r, 0xFFFFFFFFFFFFFFFF` workaround (PA-R13-010).
  4. Write thread record: `{pid=op_arg[63:8], tid, entry_rip=0, stack_top=0}`.
  5. Bump `_next_tid[0] += 1`.
  6. Return tid.
- **Return value**: tid (1-64) on success, 0 on pool full or rights failure.

### OP_START (op_code=1)
- **Rights check**: `rights & RIGHT_INVOKE (0x08)` must be true; else return INVOKE_DENIED.
- **Operand**: `op_arg[63:8]` = thread id (unused in stub; real scheduler enqueue deferred to R14).
- **Action**: Stub to return 0 (OK) — real scheduler integration deferred when process-scoped scheduler lands.
- **Return value**: 0 (OK).

### Unknown op
- Returns INVOKE_UNSUPPORTED (0xFFFFFFFFFFFFFFFC).

### Rights failure
- Returns INVOKE_DENIED (0xFFFFFFFFFFFFFFFD).

## Handler ABI and effects

- **Caller ABI** (from cap_invoke_dispatch, R12-m2-001): `RDI=rights`, `RSI=target_ptr`, `RDX=op_arg`, returns `RAX`.
- **Effects**: `{mem, sysreg}` (uart_puts side-effect, write to _thread_pool, write to _next_tid).
- **Capabilities**: `{cap}` (justification required for cap-system access).
- **Saves across uart_puts**: Push/pop rdi/rsi/rdx (uart_putc clobbers dx via mov dx, 0x3FD; preserves op_arg for later use).

## Encoder workarounds applied

1. **PA-R13-010 (SUB reg, imm)**: Implements `tid - 1` using `add r, 0xFFFFFFFFFFFFFFFF` instead of unavailable `sub r, 1`.
   - Instruction sequence: `mov rax, r11; add rax, 0xFFFFFFFFFFFFFFFF; shl rax, 5; add rdi, rax`.
   - Justifies all arithmetic.

2. **PA-R13-011 (label sharing)**: Not invoked here; error tails duplicate labels (`thread_full`, `thread_denied`) rather than branch-to-shared blocks.

## OP_START stub rationale (R14 defer)

Real OP_START requires:
- Validation of tid (must exist in _thread_pool).
- Extraction of {entry_rip, stack_top} from thread record.
- Enqueue to per-process scheduler runqueue (deferred pending R14 process-scoped scheduler milestone).
- Set thread state to READY (pending scheduler state model).

Stub implementation returns 0 (OK) to allow thread-creation infrastructure to be tested end-to-end before R14 lands scheduler enqueue. Caller sees success; no thread runs until R14 lands the real scheduler. Soft commitment: no smoke test exercises OP_START (verified by softarch: kind=2 unreachable in 5-mode suite).

## Cross-references

- design/milestones/r13-preflight.md §B (kind mapping: KIND_THREAD=2)
- src/kernel/core/thread/thread.pdx (pool + constants)
- src/kernel/core/process/process.pdx (R13-m6-001 sibling)
- src/kernel/core/cap/invoke.pdx (dispatch chain)
- #430 (sibling KIND_PROCESS handler)
- #482 (cap_smoke migration backtracking)
- #482 (KIND_PROCESS follow-up: real handler after cap_smoke migration)
- paideia-as #923 (PA-R13-010 SUB r,imm encoder gap)
- paideia-as #924 (PA-R13-011 label sharing encoder gap)

## Regression

KIND_THREAD (kind=2) is not exercised by the 5-mode smoke suite (verified by softarch). The real handler lands but is unreachable in smoke tests. Binary size grows by ~2056 bytes (_thread_pool + _next_tid in .bss) + ~300 bytes (handler code); fingerprints remain byte-identical across all 5 modes.

## Acceptance

- [x] Build succeeds without encoder errors.
- [x] 5-mode regression byte-identically green (boot_r8_only, boot_r10, boot_r11, boot_r12, boot_r12_denial).
- [x] cap_handler_thread lands real body (not stub): ~30 instructions, OP_CREATE + OP_START.
- [x] process_init bootstrap called at kernel_main after nx_enable.
- [x] Dispatch wiring in invoke.pdx: `cmp rcx, 2; je call_kind_thread`.
- [x] Tags updated: cap_thread_msg appended.
- [x] No emojis in source or audit.
- [x] PA-R13-010 workaround verified (add r, 0xFFFFFFFFFFFFFFFF for tid-1).
- [x] PA-R13-011 not invoked (label duplication used instead).
- [x] OP_START stub confirmed (returns 0, no scheduler enqueue).
- [x] objdump checks: cap_handler_thread (30+ instr), process_init (3 instr), call_kind_thread (dispatch branch).
