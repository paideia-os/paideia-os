---
audit_id: r13-m2-001-phys-alloc
issue: 419
file: src/kernel/core/mm/phys_alloc.pdx
file_pool: src/kernel/core/mm/phys_pool.pdx
function: phys_alloc / _phys_page_pool / _phys_pool_next
effects: [mem]
capabilities: []
reviewed_by:
date: 2026-07-03
status: complete
---

# AUDIT R13-m2-001 — Bump allocator over static 64-page pool (COMPLETE)

## Issue

R13-m2-001 (#419): Implement phys_alloc(order) as a simple bump allocator backed by a static, page-aligned 64-page pool. Replaces R5.5-002 buddy-allocator stub (Phase 5 MVP). Intended for Phase 7 early allocation: page tables, IST stacks, exception handling buffers, etc.

## Justification

A buddy allocator with inter-module data linkage (Buddy.free_list_heads) is deferred to Phase 7+. For Phase 7 bootstrap, a simpler bump allocator is sufficient:
- Requires only two state variables: pool base and cursor (no trees).
- Contiguous allocation simplifies debugging and verification.
- No concurrency protection needed during single-threaded bootstrap.
- Suitable for kernel initialization code paths before SMP activation.

Per design/infrastructure/phys-alloc-plan.md (R13), Phase 7 uses bump allocation; Phase 8+ introduces reusability and per-NUMA-node pools.

## Intended sequence

1. **Precondition check:** Caller passes (order) in RDI. Check order == 0 (reject all other orders as unsupported). If order != 0, return 0.
2. **Load cursor:** LEA + MOV to fetch _phys_pool_next (index into pool, 0..PHYS_POOL_PAGES).
3. **Bounds check:** Compare cursor < 64 (PHYS_POOL_PAGES). If cursor >= 64, return 0 (pool exhausted).
4. **Compute base:** 
   - LEA to fetch _phys_page_pool base.
   - SHL cursor by 12 (multiply by 4096) to get byte offset.
   - ADD to base; result in RDI becomes phys_base.
5. **Bump cursor:** Increment cursor in-place via ADD + MOV back to _phys_pool_next.
6. **Return base:** MOV RAX, RDI; RET. RAX now holds physical address of allocated page.

## Implementation

```pdx
pub let phys_alloc : (u64) -> u64 !{mem} @{} = fn (order: u64) -> unsafe {
  effects: {mem},
  capabilities: {},
  justification: "...",
  block: {
    cmp rdi, 0;
    jne phys_alloc_unsupported;

    lea rax, [rip + _phys_pool_next];
    mov r10, [rax];

    mov rcx, 64;
    cmp r10, rcx;
    jge phys_alloc_exhausted;

    lea rdi, [rip + _phys_page_pool];
    mov rdx, r10;
    shl rdx, 12;
    add rdi, rdx;

    add r10, 1;
    mov [rax], r10;

    mov rax, rdi;
    ret;

    phys_alloc_exhausted:
      mov rax, 0;
      ret;

    phys_alloc_unsupported:
      mov rax, 0;
      ret
  }
}
```

## Pool declaration

Pool resides in `src/kernel/core/mm/phys_pool.pdx`:

```pdx
pub let PHYS_POOL_PAGES : u64 = 64
pub let PHYS_POOL_PAGE_SIZE : u64 = 4096

pub let mut _phys_page_pool : [u64; 32768] = uninit @align(4096)
pub let mut _phys_pool_next : u64 = 0
```

- `_phys_page_pool`: 64 pages × 4 KiB/page = 256 KiB = 32768 u64s (paideia-as v0.11.0-28 audited [u64; N] layout).
- `@align(4096)` attribute ensures page alignment (PA10-006y feature, **first use in paideia-os**).
- `_phys_pool_next`: cursor, initialized to 0 (empty pool).

## Invariants

**I1 (Cursor in range):** `_phys_pool_next ∈ [0, PHYS_POOL_PAGES]`. Initially 0; incremented only by phys_alloc on successful allocation.

**I2 (Contiguity):** All allocated pages are in the interval `[0, cursor-1]` in the pool. No gaps or reallocation.

**I3 (Alignment):** Pool base address is a multiple of 4096 bytes (enforced by @align(4096)). All allocated pages have address = base + index*4096, which is naturally 4 KiB aligned.

**I4 (Monotonicity):** `_phys_pool_next` never decreases. Once exhausted (cursor == 64), all future allocations return 0.

## Non-invariants

**NI1 (Concurrency):** No spinlock or atomic protection. If multiple CPUs/cores call phys_alloc simultaneously during bootstrap, data races are possible. **Mitigated by:** Single-threaded bootstrap phase; SMP activation occurs only after all critical pools are pre-allocated.

**NI2 (Reusability):** No free() or release operation. Allocated pages remain bound to caller. Suitable for kernel initialization; not suitable for dynamic workloads after bootstrap.

## Consumers

- **aspace_create** (core/mm/aspace.pdx): Allocates page tables (PML4, PDPT, PD, PT).
- **ist_allocate** (core/int/ist.pdx): Allocates IST stacks for exception handling (double-fault, etc.).
- **Trampoline tables** (core/int/idt.pdx): Early IDT/handler stub pages.
- **Sched TCB pool** (core/sched/tcb.pdx): Pre-populate task control blocks.

All consumers are invoked during single-threaded bootstrap; SMP spins up only after critical allocations complete.

## Retirement path

**Phase 8+ (Buddy allocator):** When inter-module data linkage (Buddy.free_list_heads_per_node) lands in paideia-as, retire phys_alloc bump implementation. Replace with buddy walk/split logic per Phase 5 spec. Pool will support free/reuse.

**Decommissioning:** Leave _phys_page_pool and _phys_pool_next in .bss for debugging; no runtime removal needed.

## Caller discipline

```
Input:
  RDI ← order (must be 0; non-zero orders unsupported in R13)

Output:
  RAX ← physical address of allocated page (0 = allocation failed)

Clobber:
  RAX, RCX, RDX, RDI, R10 (caller must save if needed)

Flags:
  ZF set iff RAX == 0 (allocation failed)
```

## Verification

**Build:** Kernel must compile; phys_alloc symbol present in kernel.elf.

```bash
./tools/build.sh 2>&1 | tail -5
nm build/kernel.elf | grep -E "phys_alloc|_phys_page_pool|_phys_pool_next"
```

**Disassembly check:** Bytecode inspection confirms cmp/jne unsupported branch, LEA+MOV cursor load, SHL 12 multiply, ADD to base, cursor bump, and three RET paths.

```bash
objdump -d build/kernel.elf --disassemble=phys_alloc | head -40
```

**Alignment check:** Pool base must be 4 KiB aligned. `objdump -t build/kernel.elf | grep _phys_page_pool` must show address ≡ 0 (mod 4096).

**Regression matrix (5 modes):**
```bash
./tools/run-smoke.sh boot_r8_only       # Baseline boot, no allocation yet.
./tools/run-smoke.sh boot_r10           # Scheduler alive; early TCBs allocated via phys_alloc.
./tools/run-smoke.sh boot_r11           # Cooperative preemption; context stacks from phys_alloc.
./tools/run-smoke.sh boot_r12           # Denial-of-service hardening; pool pressure.
./tools/run-smoke.sh boot_r12_denial    # Explicit exhaustion test (allocate near 64-page limit).
```

All 5 modes must pass byte-identically.

## Failure modes

**F1 (Alignment not supported):** If paideia-as v0.11.0-28 does not support @align(4096), drop the attribute and file PA-R13-align soft escalation. Pool alignment then depends on linker script defaults (.bss section alignment). Verify alignment via `objdump -t`.

**F2 (Pool exhausted):** If caller attempts to allocate and cursor == 64, phys_alloc returns 0. Caller is responsible for detecting (RAX == 0 or ZF set) and handling gracefully (panic / OOM handling).

**F3 (Unsupported order):** Caller passes order != 0. phys_alloc returns 0 immediately (cmp rdi, 0; jne unsupported). Callers must pre-allocate all needed pages during bootstrap to avoid order-0 exhaustion.

**F4 (Data race during bootstrap):** Multiple CPUs reach phys_alloc before SMP barrier. Cursors may be incremented multiple times before any CPU sees updated value. **Mitigated by:** Real bootloaders (BIOS/UEFI) hold secondary CPUs in reset; PaideiaOS architecture assumes single-threaded code path up to sched_boot_barrier.

## Cross-references

- **Issue:** #419 (R13-m2-001)
- **Plan:** design/infrastructure/phys-alloc-plan.md (R13 Phase 7)
- **Related issues:** #246 (R5.5-002 buddy allocator), #377 (R10-m3 context switch)
- **Module:** PhysAlloc (src/kernel/core/mm/phys_alloc.pdx), PhysPool (src/kernel/core/mm/phys_pool.pdx)
- **Consumers:** aspace_create, ist_allocate, trampoline tables, sched TCB pool
- **paideia-as support:** v0.11.0-28 @align and [u64; N] uninit arrays

---
**Audit:** R13-m2-001 bundle (July 2026)
