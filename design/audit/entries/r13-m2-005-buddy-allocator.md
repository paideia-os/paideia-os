---
audit_id: r13-m2-005-buddy-allocator
issue: 444
date: 2026-07-03
retires: "R12 fragmentation risk"
---

# R13-m2-005: Buddy Allocator Interface Parking

## Justification

Option A: Grow the bump pool to 1024 pages (4 MiB) while preserving order-0 fast path,
and publish the buddy allocator interface (buddy_alloc, buddy_free) as stubs that return
BUDDY_NULL for orders 1-10, deferring full buddy body implementation to R14.

Rationale:
- Early kernel initialization requires more physical memory than the original 64-page (256 KiB) pool.
- Bump allocator remains the fast path for single-page allocations (order 0).
- Buddy interface is published for caller convenience; bodies activate in R14 when the
  bitmap-based free-list and coalescing logic lands.
- This parking strategy satisfies R13 memory requirements without rushing R14 implementation.

## Intended Sequence

1. Grow _phys_page_pool to [u64; 524288] (1024 pages × 512 u64s/page).
2. Set PHYS_POOL_PAGES constant to 1024.
3. Update phys_alloc bounds check: mov rcx, 1024 (was 64).
4. Publish phys_free(page, order) -> u64:
   - Order 0: return 0 (no-op; bump discards frees).
   - Orders 1-10: return -1 (PHYS_FREE_INVALID; not yet supported).
5. Publish buddy_alloc(order) -> u64:
   - Order 0: call phys_alloc (bump delegation).
   - Orders 1-10: return BUDDY_NULL (0).
6. Publish buddy_free(page, order) -> u64:
   - Delegate to phys_free (body activates in R14).

## Invariants (I1-I4)

**I1: Pool Capacity**
- _phys_page_pool spans 1024 pages (4 MiB).
- Initial cursor _phys_pool_next = 0.
- Cursor only increments; reaches 1024 on exhaustion.

**I2: Order-0 Bump Path**
- phys_alloc(0) reads cursor, compares against 1024, increments cursor, returns base.
- All order-0 allocations are contiguous in _phys_page_pool.
- No fragmentation for order-0; pool exhaustion returns 0.

**I3: Order-1..10 Stubs**
- buddy_alloc(1..10) returns BUDDY_NULL (0); no pages are allocated.
- phys_free(*, 1..10) returns PHYS_FREE_INVALID (-1); no pages are freed.
- Bodies activate in R14 when bitmap and coalesce logic land.

**I4: Caller Discipline**
- Callers must not assume freed frames return to pool until R14.
- Callers may invoke buddy_alloc(0) or buddy_free(*); order-0 is no-op for free.
- Callers must check for BUDDY_NULL (0) on buddy_alloc failure.

## Non-Invariants

**NI1: Concurrency**
- phys_alloc, phys_free, buddy_alloc, buddy_free are not atomic.
- No spinlocks or memory barriers.
- Safe only if single-threaded or external synchronization guaranteed.

**NI2: Reuse Until R14**
- Freed pages (phys_free order-0) do not return to pool.
- Bump cursor never decrements.
- Memory pressure possible if alloc/free cycles occur before R14.

**NI3: Buddy Body Deferred**
- Orders 1-10 allocation/free logic lives entirely in R14.
- R13-m2-005 is interface only; no bitmap, no coalescing, no free lists.

## Consumers

- Early kernel initialization (page tables, stacks, IRQ vectors).
- Capability system bootstrap (R8+).
- LAPIC/IOAPIC setup (R10-R12).
- ISR/exception handler frames (R11).

## Retirement Path

**R14 Activation:**
- Replace phys_free order-0 no-op with bitmap release + coalesce.
- Replace buddy_alloc orders 1-10 stub with free-list walk + split.
- Replace buddy_free with bitmap update + buddy coalesce.
- Interface signature remains stable; callers unaffected.

## Caller Discipline

1. Allocate with buddy_alloc(order); check result != BUDDY_NULL.
2. For order 0: always succeeds until pool exhausted (returns 0).
3. For orders 1-10: currently always fails (returns BUDDY_NULL).
4. Free only order-0 pages with buddy_free(page, 0).
5. Do not re-free or double-free; phys_free no-op for order-0 discards redundant frees.
6. Do not expect freed order-0 pages to be reusable until R14 lands.

## Verification

Post-build checks:
- Pool size: _phys_page_pool is 4 MiB (0x400000 bytes).
- Bounds: objdump phys_alloc shows "cmp rcx, 1024" (immediate 0x400).
- Symbols exported: nm kernel.elf | grep -E "BUDDY_NULL|buddy_alloc|buddy_free|phys_free".
- Smoke tests: boot_r8_only, boot_r10, boot_r11, boot_r12, boot_r12_denial all green.
- No emojis in source.

## Failure Modes

**F1: Unsupported Order**
- Caller: buddy_alloc(5).
- Behavior: returns BUDDY_NULL (0).
- Recovery: allocator must handle null or fall back to order-0 strip-mining.

**F2: Free Ignored**
- Caller: buddy_free(page, 0).
- Behavior: returns 0 (PHYS_FREE_OK) but page is not reused.
- Impact: memory pressure if alloc/free cycles occur; resolved in R14.

**F3: Pool Exhaustion**
- Caller: bump cursor reaches 1024.
- Behavior: phys_alloc(0) returns 0 (PHYS_ALLOC_NULL).
- Recovery: kernel panic or graceful shutdown; no fallback allocation.

## Cross-References

- Issue: #444 (r13-m2-005: buddy allocator interface parking).
- Precursor: r13-m2-001 (#419 phys_alloc bump).
- Successor: r14-m1+ (buddy body + bitmap + coalesce).
- Design: design/infrastructure/memory-allocators.md (pool, bump, buddy architecture).
- Audit trail: design/audit/entries/r13-m2-001-phys-alloc.md (bump baseline).
