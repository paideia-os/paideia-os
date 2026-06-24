---
audit_id: ipc-channel-pool-001
issue: 342
file: src/kernel/core/ipc/channel.pdx
function: channel_data (global mutable array)
effects: [mem]
capabilities: [ipc]
reviewed_by:
date: 2026-06-24
---

# AUDIT ipc-channel-pool-001 — B6-001 Channel pool placement and cursor mutability

## Justification

The B6-001 milestone establishes the persistent storage for IPC channels as a unified array
in kernel `.bss` memory. The design uses a single global `channel_data` array containing:

- Ring buffer slots 0-63 (8 bytes each, offsets 0-504)
- Head cursor at offset 512 (index 64)
- Tail cursor at offset 520 (index 65)

This unified approach simplifies B6's MVP while maintaining byte-compatibility with the
Phase-1 API design (design/ipc/phase1-api.md §1).

The unsafe operations include:
- Direct memory writes to mutable cursors (head, tail)
- Ring buffer indexing via bit-masking (head & 0x3F, tail & 0x3F)
- Loading and storing unbounded u64 cursors in `.bss` memory

This is inherently unsafe because:
- Cursor mutations are not guarded by lock (SPSC discipline deferred to B7)
- Ring full/empty checks depend on cursor invariants (head - tail arithmetic)
- Memory layout is tightly coupled to offset arithmetic (512, 520 bytes)
