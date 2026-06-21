---
audit_id: cap-dump-001
issue: 47
file: src/kernel/core/cap/dump.pdx
function: (placeholder, Phase 3+)
effects: [rawmem]
capabilities: []
reviewed_by:
date: 2026-06-21
---

# AUDIT cap-dump-001 — cap_dump (deferred)

## Justification

The cap_dump(handle) function performs kernel-internal diagnostic inspection
of a capability descriptor by:
1. Taking a capability handle (LAM-tagged pointer)
2. Extracting the underlying descriptor from the kernel's slab allocator
3. Reading the descriptor's fields (kind, rights, target, generation)
4. Returning a structured introspection result

This requires `rawmem` effect because:
- Direct slab-allocator memory access bypasses typed accessors
- Descriptor fields are read from kernel-privileged memory
- The operation is used for audit/debugging only, not normal execution

**Safety constraints:**
- cap_dump is kernel-internal only; no userspace exposure in Phase 1–3
- Access is gated by audit-subsystem authorization (cap_dump caps are issued
  by audit controller only)
- The function validates the LAM tag and generation before returning to catch
  use-after-free or forged handles

**Deferred to Phase 3:** The real implementation will appear in Phase 3
when unsafe blocks gain access to structured control flow (if/else, loops).
Phase 2 contains only the stub module with constants.
