---
audit_id: r13-m6-007-kind-reply
issue: 455
file: src/kernel/core/reply/reply.pdx
file: src/kernel/core/cap/kind_reply.pdx
file: src/kernel/core/cap/tags.pdx
file: src/kernel/core/cap/invoke.pdx
function: cap_handler_reply / _reply_pool
effects: [mem, sysreg]
capabilities: [cap]
reviewed_by:
date: 2026-07-03
status: complete
---

# AUDIT R13-m6-007 — KIND_REPLY handler (#455)

## Issue

R13-m6-007 (#455): Implement KIND_REPLY capability with real handler (~50 instructions) supporting two operations (REPLY, STATUS); static 64-slot reply pool in .bss; one-shot reply-cap semantics sufficient for m11 SIGCHLD wait path.

## Justification

Reply caps implement a minimal one-shot RPC reply model: a receiving thread waits for a reply cap and can invoke it exactly once to deliver a payload, after which the cap is exhausted. This is foundational for Phase 7+ synchronous IPC (thread::wait_for_reply + thread::reply) and m11 SIGCHLD wait where a parent process waits for a child to call reply with exit status.

The pool is static (64 slots) to match notification caps; dynamic allocation is deferred to post-R13. Slot recycle via revoke is also deferred. The consumed-flag + payload model is sufficient for R13; seL4's transfer-cap and reply-from-kernel semantics are simplified away.

## Intended Sequence: KIND_REPLY (OP_REPLY, OP_STATUS)

### Data Model

Static 64-slot reply pool in `.bss`, no init needed (zero-init is correct):
```
_reply_pool : [u64; 128]  // 64 slots × 16 bytes each, aligned 16
Slot layout:
  +0  consumed (u64)  // One-shot flag: 0=armed, 1=consumed
  +8  payload (u64)   // Delivered value from OP_REPLY (op_arg >> 8)
```

### Operations

**OP_REPLY (op_arg[7:0] = 0)**, RIGHT_INVOKE:
1. Check rights & 0x08 (RIGHT_INVOKE). Fail → INVOKE_DENIED.
2. Check reply_id (target_ptr) < 64. Fail → INVOKE_UNSUPPORTED.
3. Load consumed flag from pool[reply_id].consumed.
4. If consumed != 0 → already one-shot exhausted → return INVOKE_UNSUPPORTED.
5. Else: Set consumed = 1 (mark as exhausted).
6. Store op_arg >> 8 into pool[reply_id].payload.
7. Return 0.

**OP_STATUS (op_arg[7:0] = 1)**, RIGHT_READ:
1. Check rights & 0x01 (RIGHT_READ). Fail → INVOKE_DENIED.
2. Check reply_id < 64. Fail → INVOKE_UNSUPPORTED.
3. Load and return consumed flag non-mutating (0=armed, 1=consumed).

### Return Codes

- **OP_REPLY success:** 0.
- **OP_STATUS success:** Consumed flag value (0 or 1).
- **INVOKE_UNSUPPORTED (0xFFFFFFFFFFFFFFFC):** Unknown operation, reply_id ≥ 64, or OP_REPLY on already-consumed reply.
- **INVOKE_DENIED (0xFFFFFFFFFFFFFFFD):** Rights check failed.

## Implementation

### File: `src/kernel/core/reply/reply.pdx`

Defines REPLY_SLOT_BYTES, REPLY_POOL_SLOTS constants and _reply_pool symbol. Exactly mirrors notification.pdx structure.

### File: `src/kernel/core/cap/kind_reply.pdx`

Handler: `cap_handler_reply(rights, target_ptr, op_arg) -> u64`
- ~50 instructions (OP_REPLY path: 25 instr; OP_STATUS path: 16 instr).
- Prologue: save registers, emit "CAP INVOKE REPLY\n".
- Dispatch on op_arg[7:0].
- OP_REPLY: check consumed=0, set consumed=1, store payload, return 0.
- OP_STATUS: read and return consumed flag non-mutating.
- All paths: rights check, bounds check, error codes.

### File: `src/kernel/core/cap/tags.pdx`

Add message string:
- `cap_reply_msg : [u8; 18] = "CAP INVOKE REPLY\n\0"`

Update header comment to list 12 message symbols (was 11).

### File: `src/kernel/core/cap/invoke.pdx`

In `cap_invoke_dispatch`:
1. Add branch before fallthrough (in numeric order):
   ```asm
   cmp rcx, 13;  je call_kind_reply;
   ```
2. Add call label at end:
   ```asm
   call_kind_reply:
     call cap_handler_reply;
     ret;
   ```

## Invariants

**I1 (Pool Zero-Init):** `_reply_pool` is placed in `.bss` and zero-initialized at load time. No manual init code needed; consumed=0 for all slots at boot.

**I2 (Slot Layout):** All 64 slots are 16 bytes apart (offset = slot_id * 16). Consumed at +0, payload at +8, always valid.

**I3 (One-Shot Semantics):** Reply caps are exactly one-shot. After OP_REPLY succeeds (consumed transitions 0→1), all subsequent OP_REPLY invocations return INVOKE_UNSUPPORTED.

**I4 (Rights Enforcement):** OP_REPLY requires RIGHT_INVOKE (0x08); OP_STATUS requires RIGHT_READ (0x01). Mismatch → INVOKE_DENIED.

**I5 (reply_id Bounds):** Only slots 0–63 are valid. Indices ≥ 64 → INVOKE_UNSUPPORTED.

**I6 (Payload Liveness):** Payload is only meaningful after OP_REPLY succeeds. Caller (thread::wait_for_reply) must not read payload until consumed=1 confirmed.

## Non-Invariants

**NI1 (Concurrent Access):** Phase 7 assumes single-threaded OP_REPLY + OP_STATUS pairs. Two threads invoking the same reply cap is undefined (no atomic CAS on consumed flag).

**NI2 (Slot Recycle):** Consumed slots remain in pool indefinitely until revoke path is implemented post-R13. No defragmentation.

**NI3 (Transfer Cap):** seL4's "reply from kernel" (where kernel posts reply on behalf of sender) is not modeled. Callers must explicitly invoke OP_REPLY.

**NI4 (IPC Binding):** Reply caps are not auto-bound to IPC ports. Caller sets up reply cap slot manually via mint and passes to receiver.

## Cross-References

- **Issue #455:** Implement r13-m6-007 (KIND_REPLY handler).
- **Issue #454:** KIND_NOTIFICATION precedent (#454).
- **R13-preflight:** Design docs for Phase 6 capability kinds.
- **src/kernel/core/cap/invoke.pdx:** Dispatch table + handler ABI.
- **src/kernel/core/cap/tags.pdx:** Message symbol table.
- **design/audit/entries/r12-m1-002-dispatch-arch.md:** Handler ABI and kind dispatch rules.
- **R13-m5:** SIGCHLD wait path (future consumer, #492+).
- **Phase 7 IPC sync (#526):** Consumer of KIND_REPLY + thread::wait_for_reply.

## Verification

1. **Build succeeds:**
   ```bash
   ./tools/build.sh
   ```
   All four source files compile and link without errors.

2. **Smoke tests pass (5 regression modes):**
   - boot_r8_only
   - boot_r10
   - boot_r11
   - boot_r12
   - boot_r12_denial
   
   No output divergence from baseline.

3. **Handler size (objdump):**
   - `cap_handler_reply`: ~50 instructions (as intended).

4. **Symbol checks:**
   - `_reply_pool` is page-aligned and in `.bss`.
   - `cap_reply_msg` is in `.rodata`.
   - Handler resolves in symbol table.

5. **No emoji pollution:**
   ```bash
   grep -P '[^\x00-\x7F]' <files> || echo "CLEAN"
   ```

## Errata

None at this time.
