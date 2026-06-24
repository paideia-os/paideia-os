---
audit_id: b5-003-cap-verify
issue: 339
file: src/kernel/core/cap/verify.pdx
function: cap_verify, cap_verify_read
effects: [mem]
capabilities: [cap]
reviewed_by:
date: 2026-06-24
---

# AUDIT B5-003 — Capability Verification with Descriptor Read

## Justification

The capability verification operation reads a capability descriptor from the kernel's static cap_table and validates that the requested kind and rights match the stored descriptor fields. This is the canonical verification point for all capability operations in PaideiaOS Phase 2.

**Function signature (Phase-1 API):**
```
pub let cap_verify : (u64, u64, u64) -> u64 =
  fn (slot: u64) (kind: u64) (rights: u64) -> { ... }
```

Per `design/audit/entries/b5-003-cap-verify.md`, the operation takes three u64 parameters:
- **slot**: Descriptor table index (0-255)
- **kind**: Expected capability kind (KIND_NULL through KIND_RESERVED)
- **rights**: Required rights bitmask (read, write, execute, etc.)

**Verification flow:**
1. Bounds-check slot against [0, 256); if slot >= 256, return `CAP_VERIFY_RESULT_INVALID` (0).
2. Otherwise, call `cap_verify_read()` to fetch the descriptor and check kind + rights.
3. Return 1 (true) if descriptor.kind == kind AND (descriptor.rights & rights) == rights.
4. Return 0 (false) if either check fails.

**Descriptor read (cap_verify_read):**
The helper function reads two u64 fields from the descriptor at offset `slot * 24` and performs two comparisons:
1. Compare descriptor.kind (at offset 0) against the `kind` parameter; fail if unequal.
2. Mask descriptor.rights (at offset 8) with `rights` parameter and compare result against `rights`; fail if (descriptor.rights & rights) != rights.

The x86-64 calling convention (System V AMD64 ABI) uses arguments:
- RDI ← slot
- RSI ← kind
- RDX ← rights

Inline assembly computes the effective address: `rax = &cap_table + (slot * 24)` via:
```
mov rax, Table.cap_table     // Load base address
mov r8, rdi; shl r8, 3        // r8 = slot * 8
mov r9, rdi; shl r9, 4        // r9 = slot * 16
add r8, r9                     // r8 = slot * 24
add rax, r8                    // rax = &cap_table + (slot * 24)
// Check kind
mov rcx, [rax + 0]            // Load descriptor.kind
cmp rcx, rsi                   // Compare with expected kind
jne verify_fail                // Jump if unequal
// Check rights
mov rcx, [rax + 8]            // Load descriptor.rights
and rcx, rdx                   // Mask with required rights
cmp rcx, rdx                   // Compare masked rights with required rights
jne verify_fail                // Jump if (rights & required) != required
mov rax, 1                     // Return 1 (valid)
ret
verify_fail:
  xor rax, rax                 // Return 0 (invalid)
  ret
```

## Hardware and Design References

### Capability Descriptor Layout
Per `design/capabilities/phase1-api.md` §1 and `src/kernel/core/cap/table.pdx`:
- **kind** (u64 offset 0): 4-bit kind tag identifying the capability type
- **rights** (u64 offset 8): Bitmask of granted rights
- **target_ptr** (u64 offset 16): Pointer to the target object
- **generation** (u64 offset 24, deferred): Revocation epoch (not read by B5-003)
- **flags** (u32 offset 32, deferred): Sealed/revoked state (not read by B5-003)

### Rights Encoding
Per `design/capabilities/phase1-api.md` §3 and `src/kernel/core/cap/rights.pdx`:
- Rights are represented as a bitmask where each bit corresponds to a permitted operation.
- Verification checks that `(descriptor.rights & required_rights) == required_rights`, i.e., the descriptor grants all requested rights.
- A descriptor with rights=0 grants no operations (read-verify always fails unless required_rights=0).

### Descriptor Table (B5-001)
Per `src/kernel/core/cap/table.pdx` and design/audit/entries/b5-001-descriptor-table.md:
- Static 768-u64 array (.bss) representing 256 capability descriptors.
- No dynamic allocation; slots are fixed at compile/link time.
- Base address exposed via `pub let cap_table : [u64; 768] = uninit`.

## Implementation Notes

### Inline Assembly Discipline
The `cap_verify_read` function uses inline unsafe assembly with:
- **effects**: `{mem}` — memory read from cap_table
- **capabilities**: `{cap}` — exercises capability authority
- **justification**: Audit entry reference (B5-003)

The assembly uses direct symbol reference `Table.cap_table` followed by arithmetic to compute the descriptor address.

### Register Allocation
The function computes `slot * 24` using the same strategy as B5-002:
- RDI (caller: slot) → R8, shifted left 3 (×8)
- RDI (caller: slot) → R9, shifted left 4 (×16)
- R8 + R9 = slot * (8 + 16) = slot * 24
- RAX (cap_table base) + R8 = effective address

### Conditional Branch
The assembly uses `cmp` and `jne` (jump if not equal) to implement the two verification checks. The x86-64 `jne` instruction transfers control to the `verify_fail` label if the preceding comparison detects inequality.

### Return Value Encoding
- **1 (true/VALID)**: All checks passed; descriptor is live and grants required rights.
- **0 (false/INVALID)**: One or more checks failed; operation must not proceed.

## Access Control Discipline

- **Kernel-only operation**: cap_verify can only be invoked from the kernel, not userspace.
- **Descriptor table reads**: cap_verify_read performs read-only access to cap_table entries in .bss.
- **No mutation**: Unlike cap_mint, verification does not modify state (idempotent operation).
- **Rights bitmask check**: B5-003 validates that the descriptor grants at least the required rights via bitwise AND.

## Traceability

- **Issue**: #339 (B5-003 real cap_verify with descriptor read)
- **Phase**: Tier 5 Phase 1 (capability system reactivation)
- **Milestone**: B5 subseries (capability system foundations)
- **Softarch**: Per `.plans` Phase 2, §Capability Model; `design/capabilities/phase1-api.md`
- **References**:
  - `src/kernel/core/cap/verify.pdx` (this file)
  - `src/kernel/core/cap/table.pdx` (B5-001)
  - `src/kernel/core/cap/mint.pdx` (B5-002)
  - `design/capabilities/phase1-api.md` §2 (Phase-1 operations)

## Known Limitations and TODOs

- **No generation validation**: B5-003 does not check the generation field (offset 24) for revocation. Generation validation is deferred to B5-005+ (revocation audit entry).
- **No sealed-state checking**: B5-003 does not check the sealed flag (in flags at offset 32). Sealing is deferred to B5-006+ (sealing audit entry).
- **No per-task isolation**: Kernel uses a single shared cap_table; per-address-space tables are Phase 6 scope.
- **No logging on failure**: B5-003 returns a simple boolean (0/1); failure reasons are not logged to audit. Structured error reporting with audit log integration is Phase 7+ scope.

## Validation Checklist

- [x] cap_verify function signature matches phase1-api.md (3 args: slot, kind, rights)
- [x] cap_verify_read uses unsafe block with effects and justification
- [x] Descriptor read at correct offsets (kind @ 0, rights @ 8)
- [x] Slot index arithmetic computed correctly (slot * 24 via shifts)
- [x] Bounds check on slot (>= 256 returns INVALID)
- [x] Kind comparison using `cmp rsi` (expected kind in RSI)
- [x] Rights mask check using `and rcx, rdx; cmp rcx, rdx`
- [x] Return value 1 (valid) and 0 (invalid) correctly encoded
- [x] Table.cap_table properly qualified (module reference)
- [x] pub visibility on cap_verify for external access
- [x] Build verification: `tools/build.sh` completes successfully
- [x] Smoke verification: `tools/run-smoke.sh boot_banner` shows banner without panic
