---
audit_id: b5-004-cap-invoke
issue: 340
file: src/kernel/core/cap/invoke.pdx
function: cap_invoke, cap_invoke_dispatch
effects: [mem]
capabilities: [cap]
reviewed_by:
date: 2026-06-24
---

# AUDIT B5-004 — Capability Invoke with Descriptor Dispatch (MVP)

## Justification

The capability invoke operation reads a capability descriptor from the kernel's static cap_table and dispatches on the capability kind. The B5-004 MVP implementation reads the descriptor's target_ptr field and returns it as the result, deferring real per-kind dispatch (memory read, IPC enqueue, interrupt handling, etc.) to Phase 7+.

**Function signature (Phase-1 API):**
```
pub let cap_invoke : (u64, u64) -> u64 =
  fn (slot: u64) (op_arg: u64) -> { ... }
```

Per `design/audit/entries/b5-004-cap-invoke.md`, the operation takes two u64 parameters:
- **slot**: Descriptor table index (0-255)
- **op_arg**: Operation argument (unused in MVP; deferred to Phase 7+ for per-kind dispatch)

**Invoke flow (MVP):**
1. Bounds-check slot against [0, 256); if slot >= 256, return `INVOKE_RESULT_INVALID_HANDLE` (0xFFFFFFFFFFFFFFFE).
2. Otherwise, call `cap_invoke_dispatch()` to fetch the descriptor.
3. Read descriptor.target_ptr (at offset 16) and return it as the result.
4. Per-kind dispatch on descriptor.kind (at offset 0) is deferred to Phase 7+.

**Descriptor read (cap_invoke_dispatch):**
The helper function reads the target_ptr field from the descriptor at offset `slot * 24 + 16`:

The x86-64 calling convention (System V AMD64 ABI) uses arguments:
- RDI ← slot
- RSI ← op_arg

Inline assembly computes the effective address: `rax = &cap_table + (slot * 24) + 16` via:
```
mov rax, Table.cap_table     // Load base address
mov r8, rdi; shl r8, 3        // r8 = slot * 8
mov r9, rdi; shl r9, 4        // r9 = slot * 16
add r8, r9                     // r8 = slot * 24
add rax, r8                    // rax = &cap_table + (slot * 24)
mov rax, [rax + 16]           // Load descriptor.target_ptr
ret
```

## Hardware and Design References

### Capability Descriptor Layout
Per `design/capabilities/phase1-api.md` §1 and `src/kernel/core/cap/table.pdx`:
- **kind** (u64 offset 0): 4-bit kind tag identifying the capability type
- **rights** (u64 offset 8): Bitmask of granted rights
- **target_ptr** (u64 offset 16): Pointer to the target object (returned by MVP)
- **generation** (u64 offset 24, deferred): Revocation epoch (not read by B5-004 MVP)
- **flags** (u32 offset 32, deferred): Sealed/revoked state (not read by B5-004 MVP)

### Capability Kinds
Per `design/capabilities/phase1-api.md` §2 and `src/kernel/core/cap/kind.pdx`:
- **KIND_NULL** (0): Null/invalid capability
- **KIND_ENDPOINT** (1): IPC endpoint for message passing
- **KIND_THREAD** (2): Execution context / thread
- **KIND_NOTIFICATION** (3): Asynchronous notification object
- **KIND_PAGETABLE** (4): Virtual memory management object
- **KIND_CSPACE** (5): Capability space / CSpace container
- Additional kinds (6-15): Reserved for future use

Real per-kind dispatch (matching on descriptor.kind and calling kind-specific handler functions) is deferred to Phase 7+.

### Descriptor Table (B5-001)
Per `src/kernel/core/cap/table.pdx` and design/audit/entries/b5-001-descriptor-table.md:
- Static 768-u64 array (.bss) representing 256 capability descriptors.
- No dynamic allocation; slots are fixed at compile/link time.
- Base address exposed via `pub let cap_table : [u64; 768] = uninit`.

## Implementation Notes

### Inline Assembly Discipline
The `cap_invoke_dispatch` function uses inline unsafe assembly with:
- **effects**: `{mem}` — memory read from cap_table
- **capabilities**: `{cap}` — exercises capability authority
- **justification**: Audit entry reference (B5-004 MVP)

The assembly uses direct symbol reference `Table.cap_table` followed by arithmetic to compute the descriptor address.

### Register Allocation
The function computes `slot * 24` using the same strategy as B5-002 and B5-003:
- RDI (caller: slot) → R8, shifted left 3 (×8)
- RDI (caller: slot) → R9, shifted left 4 (×16)
- R8 + R9 = slot * (8 + 16) = slot * 24
- RAX (cap_table base) + R8 = effective address
- Final load from [RAX + 16] fetches descriptor.target_ptr
- RAX is returned as-is (no further processing in MVP)

### Target Pointer Return Value
The MVP returns descriptor.target_ptr directly to the caller. This allows:
- **Phase 7+ dispatch**: The result can be used as an opaque object pointer to pass to per-kind handlers.
- **Testing**: Callers can verify correct descriptor reads by checking the returned pointer.
- **Deferred interpretation**: The meaning of the return value depends on descriptor.kind, which is not examined by the MVP.

## Access Control Discipline

- **Kernel-only operation**: cap_invoke can only be invoked from the kernel, not userspace.
- **Descriptor table reads**: cap_invoke_dispatch performs read-only access to cap_table entries in .bss.
- **No mutation**: Unlike cap_mint, invocation does not modify state (read-only operation).
- **No rights checking**: B5-004 MVP does not validate RIGHT_INVOKE in the descriptor's rights field. Rights checking is deferred to Phase 7+ per-kind handlers.
- **No operation dispatch**: The op_arg parameter is accepted but unused in MVP. Per-kind operation dispatch (matching on op_arg and calling kind-specific handler functions) is Phase 7+ scope.

## Traceability

- **Issue**: #340 (B5-004 real cap_invoke dispatcher MVP)
- **Phase**: Tier 5 Phase 1 (capability system reactivation)
- **Milestone**: B5 subseries (capability system foundations)
- **Softarch**: Per `.plans` Phase 2, §Capability Model; `design/capabilities/phase1-api.md`
- **References**:
  - `src/kernel/core/cap/invoke.pdx` (this file)
  - `src/kernel/core/cap/table.pdx` (B5-001)
  - `src/kernel/core/cap/mint.pdx` (B5-002)
  - `src/kernel/core/cap/verify.pdx` (B5-003)
  - `src/kernel/core/cap/kind.pdx` (kind enumeration)
  - `design/capabilities/phase1-api.md` §2 (Phase-1 operations)

## Known Limitations and TODOs

- **MVP: no per-kind dispatch**: B5-004 returns target_ptr directly without examining descriptor.kind. Real per-kind dispatch (KIND_THREAD, KIND_ENDPOINT, KIND_NOTIFICATION, KIND_PAGETABLE, etc.) is Phase 7+ scope.
- **MVP: no operation dispatch**: The op_arg parameter is accepted but unused. Matching op_arg against kind-specific operation codes (INVOKE_OP_READ, INVOKE_OP_WRITE, INVOKE_OP_EXEC, etc.) and calling corresponding handlers is Phase 7+ scope.
- **No rights checking**: B5-004 MVP does not validate RIGHT_INVOKE in descriptor.rights. Rights validation is deferred to Phase 7+ per-kind handlers.
- **No generation validation**: B5-004 MVP does not check the generation field (offset 24) for revocation. Generation validation is deferred to B5-005+ (revocation audit entry).
- **No verification call**: B5-004 MVP does not call cap_verify before invoking. Verification of kind + rights prior to dispatch is Phase 7+ scope.
- **No error reporting**: Returning INVOKE_RESULT_INVALID_HANDLE (0xFFFFFFFFFFFFFFFE) on bounds-check failure is the only error signal in MVP. Structured error reporting with audit log integration is Phase 7+ scope.
- **No per-task isolation**: Kernel uses a single shared cap_table; per-address-space tables are Phase 6 scope.

## Validation Checklist

- [x] cap_invoke function signature matches phase1-api.md (2 args: slot, op_arg)
- [x] cap_invoke_dispatch uses unsafe block with effects and justification
- [x] Descriptor read at correct offset (target_ptr @ 16)
- [x] Slot index arithmetic computed correctly (slot * 24 via shifts)
- [x] Bounds check on slot (>= 256 returns INVOKE_RESULT_INVALID_HANDLE)
- [x] Return value is descriptor.target_ptr (no further processing in MVP)
- [x] Table.cap_table properly qualified (module reference)
- [x] pub visibility on cap_invoke for external access
- [x] Build verification: `tools/build.sh` completes successfully
- [x] Smoke verification: `tools/run-smoke.sh boot_banner` shows banner without panic
