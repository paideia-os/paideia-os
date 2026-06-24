---
audit_id: ipc-enqueue-001
issue: 343
file: src/kernel/core/ipc/enqueue.pdx
function: ipc_enqueue
effects: [mem]
capabilities: [ipc]
reviewed_by:
date: 2026-06-24
---

# AUDIT ipc-enqueue-001 — B6-002 Real ipc_enqueue with message copy

## Justification

The B6-002 milestone implements the producer side of the SPSC channel as a direct
assembly function that performs full-check, ring write, and cursor advance.

The `ipc_enqueue(msg: u64) -> u64` function:
1. Loads head and tail cursors from `channel_data`
2. Checks if `(head+1) & 0x3F == tail` (buffer full)
3. If not full: writes message to `ring[head & 0x3F]`, advances head, returns 1
4. If full: returns 0 without mutation

The unsafe operations include:
- Direct load of mutable cursors from `.bss`
- Ring buffer write at computed address `base + (index << 3)`
- Mutable store to head cursor in `.bss`
- Full-check arithmetic using unbounded u64 modulo 64

This is inherently unsafe because:
- No synchronization (SPSC discipline enforced only by caller)
- Full-check is racy under concurrent access (not hardened in B6)
- Memory write bypasses all type safety (7-byte message in 8-byte slot)
