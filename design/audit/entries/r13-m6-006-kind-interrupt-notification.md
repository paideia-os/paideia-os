---
audit_id: r13-m6-006-kind-interrupt-notification
issue: 454
file: src/kernel/core/notification/notification.pdx
file: src/kernel/core/cap/kind_notification.pdx
file: src/kernel/core/cap/kind_interrupt.pdx
file: src/kernel/core/cap/tags.pdx
file: src/kernel/core/cap/invoke.pdx
function: cap_handler_notification / cap_handler_interrupt / _notification_pool
effects: [mem, sysreg]
capabilities: [cap]
reviewed_by:
date: 2026-07-03
status: complete
---

# AUDIT R13-m6-006 — KIND_NOTIFICATION real + KIND_INTERRUPT stub (#454)

## Issue

R13-m6-006 (#454): Implement KIND_NOTIFICATION capability with real handler (~60 instructions) supporting three operations (SIGNAL, WAIT, POLL); implement KIND_INTERRUPT as a structural stub (~10 instructions) pending R14 IRQ->notification bridge work.

## Justification

Notifications implement a counting semaphore + last-write-wins (LWW) payload model, matching seL4's notification-badge semantics at the capability-invocation level. This layer is foundational for Phase-7+ asynchronous event delivery (interrupt routing via notifications + IPC port integration).

KIND_INTERRUPT defers real implementation to R14 because the handler requires:
1. `_irq_notification_map[256]` index table (vector → notif_id mapping, not yet designed)
2. ISR-side notification post inside `src/kernel/core/int/` (requires synchronization and ISR context awareness)
3. Userspace-visible EOI path (R9 ISRs already EOI inline; a second path via capability invocation duplicates state without a consumer in Phase 7)

KIND_NOTIFICATION is usable immediately by system threads for synchronization once scheduler + thread creation (#483–#485) are complete.

## Intended Sequence: KIND_NOTIFICATION (OP_SIGNAL, OP_WAIT, OP_POLL)

### Data Model

Static 64-slot notification pool in `.bss`, no init needed (zero-init is correct):
```
_notification_pool : [u64; 128]  // 64 slots × 16 bytes each, aligned 16
Slot layout:
  +0  pending_count (u64)  // Incremented on SIGNAL; decremented on WAIT (counting semaphore)
  +8  payload (u64)        // Last-written value; LWW semantics on repeated SIGNAL
```

### Operations

**OP_SIGNAL (op_arg[7:0] = 0)**, RIGHT_INVOKE:
1. Check rights & 0x08 (RIGHT_INVOKE). Fail → INVOKE_DENIED.
2. Check notif_id (target_ptr) < 64. Fail → INVOKE_UNSUPPORTED.
3. Load pending_count from pool[notif_id].pending.
4. Store old count in RAX (return value).
5. Increment pending_count and write back (add rax, 1; mov pool[notif_id].pending, rax).
6. Store op_arg >> 8 into pool[notif_id].payload (LWW: new value overwrites old).
7. Return old count.

**OP_WAIT (op_arg[7:0] = 1)**, RIGHT_READ:
1. Check rights & 0x01 (RIGHT_READ). Fail → INVOKE_DENIED.
2. Check notif_id < 64. Fail → INVOKE_UNSUPPORTED.
3. Load pending_count from pool[notif_id].pending.
4. If pending_count == 0 → return INVOKE_WOULD_BLOCK (0xFFFFFFFFFFFFFFFB).
5. Else: Decrement pending_count using PA-R13-010 workaround: `add rax, 0xFFFFFFFFFFFFFFFF` (subtract 1).
6. Write decremented value back.
7. Load payload from pool[notif_id].payload and return it in RAX.

**OP_POLL (op_arg[7:0] = 2)**, RIGHT_READ:
1. Check rights & 0x01 (RIGHT_READ). Fail → INVOKE_DENIED.
2. Check notif_id < 64. Fail → INVOKE_UNSUPPORTED.
3. Load and return pending_count without modification (non-mutating).

### Return Codes

- **OP_SIGNAL success:** Old pending_count (≥0).
- **OP_WAIT success:** Payload value from the signaled slot.
- **OP_POLL success:** Current pending_count.
- **INVOKE_UNSUPPORTED (0xFFFFFFFFFFFFFFFC):** Unknown operation, or notif_id ≥ 64.
- **INVOKE_WOULD_BLOCK (0xFFFFFFFFFFFFFFFB):** WAIT on zero pending_count.
- **INVOKE_DENIED (0xFFFFFFFFFFFFFFFD):** Rights check failed.

## Intended Sequence: KIND_INTERRUPT (Stub)

### Operations (Reserved, Stubbed)

- **OP_REGISTER (op_arg[7:0] = 0):** Reserved, returns INVOKE_UNSUPPORTED.
- **OP_UNREGISTER (op_arg[7:0] = 1):** Reserved, returns INVOKE_UNSUPPORTED.
- **OP_ACK (op_arg[7:0] = 2):** Reserved, returns INVOKE_UNSUPPORTED.

All other ops → INVOKE_UNSUPPORTED.

### Behavior

1. Emit "CAP INVOKE INT\n" to COM1 (via uart_puts).
2. Always return INVOKE_UNSUPPORTED (0xFFFFFFFFFFFFFFFC).

Real implementation deferred to R14 with design of:
- _irq_notification_map[256] (vector → notif_id indexing)
- ISR-side cap_signal_notification(notif_id) call
- Possibly userspace EOI via OP_ACK (deferred; R9 EOI already inline)

## Implementation

### File: `src/kernel/core/notification/notification.pdx`

Defines NOTIF_SLOT_BYTES, NOTIF_POOL_SLOTS constants and _notification_pool symbol.

### File: `src/kernel/core/cap/kind_notification.pdx`

Handler: `cap_handler_notification(rights, target_ptr, op_arg) -> u64`
- ~60 instructions (OP_SIGNAL path: 25 instr; OP_WAIT path: 22 instr; OP_POLL path: 14 instr).
- Prologue: save registers, emit "CAP INVOKE NOTIF\n".
- Dispatch on op_arg[7:0].
- OP_SIGNAL: increment, store payload, return old count.
- OP_WAIT: check pending, decrement (PA-R13-010), return payload.
- OP_POLL: return pending count non-mutating.
- All paths: rights check, bounds check, error codes.

### File: `src/kernel/core/cap/kind_interrupt.pdx`

Handler: `cap_handler_interrupt(rights, target_ptr, op_arg) -> u64`
- ~10 instructions (prologue + emit + return).
- Emit "CAP INVOKE INT\n" to COM1.
- Always return INVOKE_UNSUPPORTED.

### File: `src/kernel/core/cap/tags.pdx`

Add two message strings:
- `cap_notif_msg : [u8; 18] = "CAP INVOKE NOTIF\n\0"`
- `cap_int_msg : [u8; 16] = "CAP INVOKE INT\n\0"`

Update header comment table to list all 11 message symbols (was 9).

### File: `src/kernel/core/cap/invoke.pdx`

In `cap_invoke_dispatch`:
1. Add branches before fallthrough (in numeric order):
   ```asm
   cmp rcx, 9;   je call_kind_interrupt;
   cmp rcx, 12;  je call_kind_notification;
   ```
2. Add call labels at end:
   ```asm
   call_kind_interrupt:
     call cap_handler_interrupt;
     ret;
   call_kind_notification:
     call cap_handler_notification;
     ret;
   ```

## Invariants

**I1 (Pool Zero-Init):** `_notification_pool` is placed in `.bss` and zero-initialized at load time. No manual init code needed; pending_count=0 for all slots at boot.

**I2 (Slot Layout):** All 64 slots are 16 bytes apart (offset = slot_id * 16). Pending at +0, payload at +8, always valid.

**I3 (Counting Semantics):** Pending_count is a u64 counter; multiple SIGNALs without WAIT increment the counter. WAIT decrements exactly once per invocation. seL4 model: counting semaphore + payload badge (LWW).

**I4 (Rights Enforcement):** OP_SIGNAL requires RIGHT_INVOKE (0x08); OP_WAIT and OP_POLL require RIGHT_READ (0x01). Mismatch → INVOKE_DENIED.

**I5 (notif_id Bounds):** Only slots 0–63 are valid. Indices ≥ 64 → INVOKE_UNSUPPORTED.

**I6 (Stub Behavior):** KIND_INTERRUPT handler always returns INVOKE_UNSUPPORTED for all ops, with no state mutation.

## Non-Invariants

**NI1 (Concurrent Access):** Phase 7 assumes single-threaded WAIT/SIGNAL chains (thread A waits, thread B signals). Phase 8+ CAS-based atomic ops on pending_count are deferred.

**NI2 (IRQ Integration):** ISR-side notification posting is R14 work. KIND_INTERRUPT cap invocation is stubbed; the real bridge (ISR → _irq_notification_map → cap_signal_notification) is not implemented.

**NI3 (userspace EOI):** KIND_INTERRUPT.OP_ACK is reserved but stubbed. Userspace EOI deferred to R14 or later depending on ISR architecture.

## Cross-References

- **Issue #454:** Implement r13-m6-006 (KIND_NOTIFICATION real + KIND_INTERRUPT stub).
- **Issue #452:** Port-pattern capability (foundation for SIGNAL delivery into ports).
- **R13-preflight:** Design docs for Phase 6 capability kinds.
- **PA-R13-010:** SUB workaround (add rax, 0xFFFFFFFFFFFFFFFF).
- **src/kernel/core/cap/invoke.pdx:** Dispatch table + handler ABI.
- **src/kernel/core/cap/tags.pdx:** Message symbol table.
- **design/audit/entries/r12-m1-002-dispatch-arch.md:** Handler ABI and kind dispatch rules.
- **Phase 7 scheduler + thread (#483–#485):** Consumers of KIND_NOTIFICATION.

## Verification

1. **Build succeeds:**
   ```bash
   ./tools/build.sh
   ```
   All five source files compile and link without errors.

2. **Smoke tests pass (5 regression modes):**
   - boot_r8_only
   - boot_r10
   - boot_r11
   - boot_r12
   - boot_r12_denial
   
   No output divergence from baseline.

3. **Handler sizes (objdump):**
   - `cap_handler_notification`: ~60 instructions (as intended).
   - `cap_handler_interrupt`: ~10 instructions (stub).

4. **Symbol checks:**
   - `_notification_pool` is page-aligned and in `.bss`.
   - `cap_notif_msg` and `cap_int_msg` are in `.rodata`.
   - Both handlers resolve in symbol table.

5. **No emoji pollution:**
   ```bash
   grep -P '[^\x00-\x7F]' <files> || echo "CLEAN"
   ```

## Errata

None at this time.
