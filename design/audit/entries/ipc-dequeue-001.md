---
audit_id: ipc-dequeue-001
issue: 344
file: src/kernel/core/ipc/dequeue.pdx
function: ipc_dequeue
effects: [mem]
capabilities: [ipc]
reviewed_by:
date: 2026-06-24
---

# AUDIT ipc-dequeue-001 — B6-003 Real ipc_dequeue with message copy

## Justification

The B6-003 milestone implements the consumer side of the SPSC channel as a direct
assembly function that performs empty-check, ring read, and cursor advance.

The `ipc_dequeue() -> u64` function:
1. Loads head and tail cursors from `channel_data`
2. Checks if `head == tail` (buffer empty)
3. If not empty: reads message from `ring[tail & 0x3F]`, advances tail, returns message
4. If empty: returns 0

The unsafe operations include:
- Direct load of mutable cursors from `.bss`
- Ring buffer read at computed address `base + (index << 3)`
- Mutable store to tail cursor in `.bss`
- Empty-check arithmetic using unbounded u64 cursors

This is inherently unsafe because:
- No synchronization (SPSC discipline enforced only by caller)
- Empty-check is racy under concurrent access (not hardened in B6)
- Memory read bypasses all type safety (returns u64 from ring slot)
- Return value 0 is ambiguous (could be empty OR message was 0x0000000000000000)
