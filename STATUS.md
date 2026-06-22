# PaideiaOS Implementation Status

## R2.5 (Cap System Reactivation) — IN PROGRESS

### Issues Implemented

- **R2.5-001** (cap_mint real body): ✓ Partial (PA7 match dispatch on kind, placeholder descriptor init)
- **R2.5-002** (slab_alloc/slab_free): ✓ Complete (free-list with LIFO discipline)
- **R2.5-003** (cap_verify real body): ✓ Partial (decode + bounds check, TODO: descriptor table access)
- **R2.5-004** (cap_revoke real body): ✓ Partial (decode + bounds check, TODO: generation bump + free)
- **R2.5-005** (handle layout + design doc): ✓ Complete (LAM-tag encoding, PA7-006 helper fns)
- **R2.5-006** (cap_invoke dispatcher): ✓ Partial (nested match on kind×op, placeholder implementations)
- **R2.5-007** (rights catalog): ✓ Complete (rights_table.pdx constants + audit entry)
- **R2.5-008** (E2E fixture + closure): ✓ Partial (stub fixture created, closure pending)

**Summary:** R2.5 cap subsystem scaffolding complete with PA7 surface syntax. Runtime gates on Phase 8+ unsafe-mem descriptor table access and inter-module calling stabilization.

---

## R3.5 (IPC Reactivation) — IN PROGRESS

### Issues Implemented

- **R3.5-001** (Channel struct): ✓ Complete (Message + Channel + pool arrays)
- **R3.5-002** (ipc_enqueue real body): ✓ Partial (PA7 size checks, TODO: memcpy + head increment)
- **R3.5-003** (ipc_dequeue real body): ✓ Partial (PA7 empty checks, TODO: memcpy + tail increment)
- **R3.5-004** (channel_create): ✓ Partial (pool allocation scaffold, TODO: cap_mint calls)
- **R3.5-005** (deadlock-freedom): ✓ Complete (design doc + producer/consumer tracking in Channel)
- **R3.5-006** (NUMA-local allocation): ✓ Complete (design doc + allocator structure)
- **R3.5-007** (E2E fixture + closure): ✓ Partial (stub fixture created, closure pending)

**Summary:** R3.5 IPC subsystem scaffolding complete with PA7 surface syntax. Runtime gates on Phase 8+ unsafe-mem descriptor access and scheduler context extraction (R4.5+).

---

## Build Status

- **Paideia-as PA7 surface:** Stable (examples in tools/paideia-as/tests/corpus/)
- **Phase 2.5 .pdx syntax:** Fully supported (match, if/else, while, let mut, multi-arg calls, unsafe blocks)
- **Module-level calling:** Partial (PA7-002 inter-fn calls working; module-let still single-return)

---

## Audit Trail

### Phase 2.5 Megabatch (topic/r2-r3-batch)

- Commits pending (15 total: 8 cap + 7 IPC)
- Audit entries: rights-001.md (R2.5-007), handle-layout.md (R2.5-005)
- Design updates: handle-layout.md new document per Pillar 1

---

## Next Steps

1. Implement R3.5-001..007 (IPC subsystem).
2. Build + link verification (tools/build.sh).
3. QEMU smoke test (cap + IPC integration).
4. Merge to main; open R4.5 (scheduler) branch.
