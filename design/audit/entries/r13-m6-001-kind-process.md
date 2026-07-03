---
audit_id: r13-m6-001-kind-process
issue: 430
file: src/kernel/core/cap/kind_process.pdx
function: cap_handler_process
effects: [mem, sysreg]
capabilities: [cap]
reviewed_by:
date: 2026-07-03
---

# R13-m6-001 — KIND_PROCESS handler (real landing backfill R14-m2-002)

**Issue:** #430 (R14-m2-002 backfill)
**Files:** src/kernel/core/cap/kind_process.pdx (new); src/kernel/core/cap/tags.pdx, src/kernel/core/cap/invoke.pdx, src/kernel/core/mm/aspace_create.pdx (modified)
**Unblocking:** #482 (cap_smoke migration), #431 (process_init _next_pid init), #421 (aspace_create), PA-R13-010 (sub-imm workaround), PA-R13-011 (label-alias workaround)

## Landing scope

R14-m2-002 lands the real KIND_PROCESS handler and wires it into the dispatch chain:

- **New:** `src/kernel/core/cap/kind_process.pdx` — `cap_handler_process(rights, target_ptr, op_arg)` with OP_CREATE (0) and OP_GET_ASPACE_ROOT (1).
- **Modified:** `src/kernel/core/cap/tags.pdx` — add `cap_proc_msg : [u8; 17] = "CAP INVOKE PROC\n\0"`.
- **Modified:** `src/kernel/core/cap/invoke.pdx` — add `cmp rcx, 1; je call_kind_process` and corresponding call label.
- **Modified:** `src/kernel/core/mm/aspace_create.pdx` — promote `aspace_create` from private to `pub` for handler visibility.

Process-pool infrastructure landed in R13-m6-001 stub still stands (`_process_pool`, `_next_pid`, slot constants from `process.pdx`). `_next_pid[0] = 1` bootstrap handled by `process_init` (#431).

## Unblocking resolution

All three precondition blockers resolved as of commit 1f195e6:

1. **cap_smoke migration (#482).** `smoke.pdx` migrated from kind=1 → kind=15; cap_smoke no longer collides with real KIND_PROCESS handler. Fingerprint tests remain byte-identical to prior smoke-only baseline.

2. **Encoder workarounds available.** PA-R13-010 (paideia-as #923): `sub rax, 1` not yet in encoder; workaround: `add rax, 0xFFFFFFFFFFFFFFFF` (2s complement decrement). PA-R13-011 (paideia-as #924): back-to-back labels not allowed; workaround: emit duplicate label+body blocks (e.g., `proc_full_create:` and `proc_bad_pid_get:` both return 0 via distinct code paths). Both workarounds encoded in `kind_process.pdx`.

3. **`_next_pid` bootstrap (#431).** `process_init()` called from `kernel_main` before capability dispatch surfaces; sets `_next_pid[0] = 1` before first OP_CREATE invocation.

## Data model (pinned for the eventual real handler)

| Offset | Size | Field | Semantics |
|---|---|---|---|
| 0 | 8 | aspace_root | PML4 phys base from `aspace_create`; 0 = slot free |
| 8 | 8 | pid | 1-based; == slot_index + 1 |
| 16 | 8 | parent_pid | 0 = root process |
| 24 | 8 | state | 0=RUNNING, 1=ZOMBIE (reserve 2..7 for m11 signals) |

Pool size 64 slots × 32 bytes = 2048 bytes (256 u64s). 32-byte stride is SIB-friendly (`shl slot, 5`).

## Ops (real implementation)

- **OP_CREATE (0)**: Requires RIGHT_INVOKE (0x08); rights check via `and rax, 0x08; cmp rax, 0x08`. Reads `_next_pid`, checks pool-full (≥64). Calls `aspace_create(&pml4)` with kernel PML4 from boot_stub.S `.global pml4` (identity-mapped in low half, VA==PA). Checks aspace_create return for OOM (0xFFFFFFFF). Writes {aspace_root, pid, parent_pid=0, state=RUNNING} at slot (pid-1)*32; slot offset computed via `shl slot, 5` per SIB encoding. Bumps `_next_pid`. Returns pid (r11 moved to rax). Returns 0 on pool-full or OOM.
- **OP_GET_ASPACE_ROOT (1)**: Requires RIGHT_READ (0x01); rights check via `and rax, 0x01; cmp rax, 0x01`. Extracts pid from `op_arg[63:8]` via `shr rdx, 8`. Checks pid in range (1..64). Returns `_process_pool[pid-1].aspace_root` at offset 0 in slot. Returns 0 on invalid pid (0, >64).
- **Unknown op**: Returns INVOKE_UNSUPPORTED (0xFFFFFFFFFFFFFFFC).
- **Rights failure**: Emits `cap_denied_msg` on COM1 and returns INVOKE_DENIED (0xFFFFFFFFFFFFFFFD).

Handler ABI: `(rdi=rights, rsi=target_ptr, rdx=op_arg) -> rax`. Effects `{mem, sysreg}`, capabilities `{cap}`.

Encoder workarounds applied:
- **PA-R13-010**: `sub rax, 1` → `add rax, 0xFFFFFFFFFFFFFFFF` (slot arithmetic for (pid-1)*32). Appears twice: once for OP_CREATE slot offset, once for OP_GET_ASPACE_ROOT slot offset.
- **PA-R13-011**: Separate labels for `proc_full_create` and `proc_bad_pid_get` error tails; both return 0 via distinct `mov rax, 0; ret` blocks to avoid back-to-back-label collision.

## Regression

Real landing with dispatcher wiring: cap_smoke tests (5 modes) remain byte-identical fingerprint. Reason: `smoke.pdx` migrated to kind=15 (not kind=1); cap_invoke_dispatch no longer routes smoke invocations to `cap_handler_process`. Smoke test invokes kind=15 → fallthrough `mov rax, rsi; ret` path → 0xCAFE returned unchanged. Process handler not exercised by smoke suite; process pool remains empty (no OP_CREATE calls).

Handlers added to ROM: ~110 instructions in `kind_process.pdx`. Code path reachable only via explicit cap_invoke with kind=1 capability (no such capability minted in R14-m2-002; full process creation deferred to R14-m3+).

## Cross-references

- design/milestones/r13-preflight.md §B (kind mapping: KIND_PROCESS=1)
- design/milestones/r14-m2.md (R14-m2-002 backfill landing)
- src/kernel/core/cap/kind_process.pdx (this landing; OP_CREATE / OP_GET_ASPACE_ROOT handlers)
- src/kernel/core/cap/tags.pdx (cap_proc_msg "CAP INVOKE PROC\n")
- src/kernel/core/cap/invoke.pdx (dispatch branch for kind=1)
- src/kernel/core/mm/aspace_create.pdx (pub promotion; PML4 factory for OP_CREATE)
- src/kernel/core/process/process.pdx (#430 stub infrastructure: _process_pool, _next_pid, constants)
- src/kernel/core/process/process_init.pdx (#431: _next_pid[0] = 1 bootstrap called from kernel_main)
- src/kernel/core/cap/smoke.pdx (#482: cap_smoke migration kind=1 → kind=15, unblocks this real landing)
- paideia-as #923 (PA-R13-010: add r,0xFF...FF workaround for sub r,1)
- paideia-as #924 (PA-R13-011: duplicate label blocks for back-to-back-label avoidance)

## Acceptance

- [x] Build succeeds.
- [x] 5-mode regression byte-identically green (smoke.pdx on kind=15, not kind=1).
- [x] Handler wired into dispatch (invoke.pdx cmp rcx,1 → call_kind_process).
- [x] cap_proc_msg tag added to tags.pdx.
- [x] aspace_create promoted to pub.
- [x] PA-R13-010 workaround applied (add r,0xFF...FF × 2 for slot offset arithmetic).
- [x] PA-R13-011 workaround applied (separate proc_full_create + proc_bad_pid_get labels).
- [x] Preconditions met: #482 (cap_smoke migration), #431 (process_init), #421 (aspace_create).
