---
audit_id: ipc-smoke-001
issue: 345
file: src/kernel/core/ipc/smoke.pdx
function: ipc_smoke
effects: [sysreg, mem]
capabilities: [ipc]
reviewed_by:
date: 2026-06-24
---

# AUDIT ipc-smoke-001 — B6-004 Producer-consumer smoke fixture

## Justification

The B6-004 milestone establishes a smoke test that exercises the full SPSC channel
lifecycle: two messages enqueued in order, then dequeued and verified in FIFO order.

The `ipc_smoke() -> ()` function:
1. Enqueues 0xDEAD
2. Enqueues 0xBEEF
3. Dequeues and asserts 0xDEAD
4. Dequeues and asserts 0xBEEF
5. Prints "IPC OK\n" to COM1 UART if all assertions pass

The unsafe operations include:
- Direct assembly calls to `ipc_enqueue` and `ipc_dequeue`
- Conditional branches on return values
- Call to `uart_puts` for output (effects: sysreg, mem)

This is inherently unsafe because:
- Fixture assumes no concurrent access (single-threaded boot context)
- Assertions use `je` conditional jumps (silent failure on mismatch)
- Hard-coded message values prevent reusability (MVP simplification)
