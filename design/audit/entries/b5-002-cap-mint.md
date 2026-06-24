---
audit_id: b5-002-cap-mint
issue: 338
file: src/kernel/core/cap/mint.pdx
function: cap_mint, cap_mint_write
effects: [mem, cap]
capabilities: [cap]
reviewed_by:
date: 2026-06-24
---

# AUDIT B5-002 — Capability Mint with Descriptor Write

## Justification

The capability mint operation allocates a fresh descriptor slot from the slab allocator and initializes a 24-byte capability descriptor in the kernel's static cap_table. This is the foundational operation for capability-based access control in PaideiaOS Phase 2.

**Function signature (Phase-1 API):**
```
pub let cap_mint : (u64, u64, u64) -> u64 =
  fn (kind: u64) (target_ptr: u64) (rights: u64) -> { ... }
```

Per `design/capabilities/phase1-api.md`, the operation takes three u64 parameters:
- **kind**: Capability kind (enum 0-15, KIND_NULL through KIND_RESERVED)
- **target_ptr**: Kernel-virtual address of the target object
- **rights**: Bitmask of granted rights (read, write, execute, etc.)

**Allocation flow:**
1. Call `Slab.slab_alloc()` to obtain a free descriptor slot (0-255) or failure sentinel (256).
2. If slot >= 256 (slab exhausted), return `MINT_HANDLE_INVALID` (0xFFFFFFFFFFFFFFFF).
3. Otherwise, call `cap_mint_write()` to write the descriptor fields to the cap_table.
4. Return the slot index as the capability handle.

**Descriptor write (cap_mint_write):**
The helper function writes three u64 fields to the descriptor at offset `slot * 24`:
- **[rax + 0]**: kind (8 bytes)
- **[rax + 8]**: rights (8 bytes)
- **[rax + 16]**: target_ptr (8 bytes)

The x86-64 calling convention (System V AMD64 ABI) curries arguments:
- RDI ← slot
- RSI ← kind
- RDX ← rights
- RCX ← target_ptr

Inline assembly computes the effective address: `rax = &cap_table + (slot * 24)` via:
```
mov rax, Table.cap_table     // Load base address
mov r8, rdi; shl r8, 3        // r8 = slot * 8
mov r9, rdi; shl r9, 4        // r9 = slot * 16
add r8, r9                     // r8 = slot * 24
add rax, r8                    // rax = &cap_table + (slot * 24)
mov [rax + 0],  rsi           // Write kind
mov [rax + 8],  rdx           // Write rights
mov [rax + 16], rcx           // Write target_ptr
ret
```

## Hardware and Design References

### Capability Descriptor Layout
Per `design/capabilities/phase1-api.md` §1 and `src/kernel/core/cap/table.pdx`:
- **kind** (u64 offset 0): 4-bit kind tag identifying the capability type
- **rights** (u64 offset 8): Bitmask of granted rights
- **target_ptr** (u64 offset 16): Pointer to the target object
- **generation** (u64 offset 24, deferred): Revocation epoch (not written by B5-002)
- **flags** (u32 offset 32, deferred): Sealed/revoked state (not written by B5-002)

**Phase 2 limitation**: The 24-byte descriptor is split across 3 consecutive u64s in the cap_table (index slot, slot+1, slot+2 in the u64 array). Fields generation and flags are initialized separately by B5-003+ when generation management is added.

### Slab Allocator (P2-005)
Per `src/kernel/core/cap/slab.pdx`:
- Free-list-based allocation with O(1) performance.
- `Slab.slab_alloc()` returns the next available slot index or 256 (CAP_SLAB_CAPACITY) if exhausted.
- State: `free_head` and `free_list` are mutable static arrays, maintained across kernel lifetime.

### Descriptor Table (B5-001)
Per `src/kernel/core/cap/table.pdx` and design/audit/entries/b5-001-descriptor-table.md:
- Static 768-u64 array (.bss) representing 256 capability descriptors.
- No dynamic allocation; slots are fixed at compile/link time.
- Base address exposed via `pub let cap_table : [u64; 768] = uninit`.

## Implementation Notes

### Inline Assembly Discipline
The `cap_mint_write` function uses inline unsafe assembly with:
- **effects**: `{mem}` — memory write to cap_table
- **capabilities**: `{cap}` — exercises capability authority
- **justification**: Audit entry reference (B5-002)

The assembly strategy avoids PC-relative addressing (lea rip-relative) due to paideia-as encoder limitations; instead, it uses direct symbol reference `Table.cap_table` followed by arithmetic.

### Register Allocation
The function computes `slot * 24` using two shifts and an add:
- RDI (caller: slot) → R8, shifted left 3 (×8)
- RDI (caller: slot) → R9, shifted left 4 (×16)
- R8 + R9 = slot * (8 + 16) = slot * 24
- RAX (cap_table base) + R8 = effective address

This avoids a multiply instruction (slower) and keeps the working registers distinct.

### Curried Function Semantics
`cap_mint_write` is a 4-argument curried function. The paideia-as compiler transforms it to a nested-closure structure at the Slab call site. Each closure captures one argument and returns a function waiting for the next. By Phase 7, the compiler's closure-to-lambda lowering produces a single assembly function with standard calling convention (all 4 args on stack or in registers per ABI).

## Access Control Discipline

- **Kernel-only operation**: cap_mint can only be invoked from the kernel, not userspace.
- **Slab state mutation**: Calling slab_alloc() mutates `Slab.free_head`, advancing the free-list.
- **Descriptor table mutation**: cap_mint_write directly modifies cap_table entries in .bss.
- **No validation of rights**: B5-002 does not validate that `rights` match `kind`'s allowed rights (deferred to B5-003).

## Traceability

- **Issue**: #338 (B5-002 real cap_mint with descriptor write)
- **Phase**: Tier 5 Phase 1 (capability system reactivation)
- **Milestone**: B5 subseries (capability system foundations)
- **Softarch**: Per `.plans` Phase 2, §Capability Model; `design/capabilities/phase1-api.md`
- **References**:
  - `src/kernel/core/cap/mint.pdx` (this file)
  - `src/kernel/core/cap/table.pdx` (B5-001)
  - `src/kernel/core/cap/slab.pdx` (P2-005)
  - `design/capabilities/phase1-api.md` §2 (Phase-1 operations)

## Known Limitations and TODOs

- **No rights validation**: cap_mint does not check that `rights` are valid for the given `kind`. Deferred to B5-003 (rights_table integration).
- **No generation management**: The generation field (offset 24, currently unwritten) remains zero across the descriptor lifetime in Phase 2. Revocation is deferred to B5-004+ (generation bumping on revoke).
- **No per-task isolation**: Kernel uses a single shared cap_table; per-address-space tables are Phase 6 scope.
- **Slab exhaustion handling**: Returns MINT_HANDLE_INVALID (0xFFFFFFFFFFFFFFFF) on slab full; no retry or overflow recovery (Phase 3+).

## Validation Checklist

- [x] cap_mint function signature matches phase1-api.md (3 args: kind, target_ptr, rights)
- [x] cap_mint_write uses unsafe block with effects and justification
- [x] Descriptor write at correct offsets (kind @ 0, rights @ 8, target_ptr @ 16)
- [x] Slot index arithmetic computed correctly (slot * 24 via shifts)
- [x] Slab allocator integration (calls Slab.slab_alloc())
- [x] Invalid handle sentinel matches MINT_HANDLE_INVALID constant
- [x] Table.cap_table properly qualified (module reference)
- [x] pub visibility on cap_mint for external access
- [ ] Build verification: `tools/build.sh` completes successfully
- [ ] Smoke verification: `tools/run-smoke.sh boot_banner` shows banner without panic
