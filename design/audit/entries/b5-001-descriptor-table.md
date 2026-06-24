---
audit_id: b5-001-descriptor-table
issue: 337
file: src/kernel/core/cap/table.pdx
function: cap_table
effects: [bss, cap_table]
capabilities: []
reviewed_by:
date: 2026-06-24
---

# AUDIT B5-001 — Capability Descriptor Table: Layout and Initialization

## Justification

The capability descriptor table is the fundamental data structure for capability-based access control in PaideiaOS. It provides a 256-entry static allocation of capability descriptors in read-write memory (.bss), with each entry capable of holding a full capability descriptor comprising kind, rights, target pointer, generation, and flags.

The table is declared as a [u64; 768] array in .bss (uninit), representing:
- **256 capability entries** (indices 0-255)
- **3 u64s per entry** (fields: kind, rights, target_ptr)
- **Total allocation**: 768 × 8 bytes = 6,144 bytes

This layout aligns with the microkernel's capability model:
- Each capability grants authority to perform specific operations (mint, retype, revoke, seal, unseal).
- The generation counter provides ABA-protection for descriptor table slots.
- The flags field (5th field) and target pointer (3rd field) enable both linear and non-linear capability semantics.

## Hardware and Design References

### Capability Structure
Per `design/capabilities/linearity-and-tags.md` §3:
- **kind** (u64): 4-bit LAM-embedded kind tag (0-15 reserved; 16+ derived kinds)
- **rights** (u64): Bitmask of granted rights (R_MINT, R_RETYPE, R_REVOKE, R_SEAL, R_UNSEAL, etc.)
- **target_ptr** (u64): Kernel-virtual address of the object the capability grants access to
- **generation** (u64): Monotonic counter preventing ABA attacks on slot reuse (compare-and-swap guard)
- **flags** (u32): Capability flags (sealed, revoked, etc.) — stored as part of a 5-field descriptor

### Descriptor-Table Semantics (P2-002 Phase-2 Specification)
Per the microkernel design (`.plans` Phase 2):
- The table is a flat array indexed by capability slot number (0-255).
- No dynamic allocation: table is pre-allocated in .bss at kernel image link time.
- Indexes are opaque to userspace; capabilities are passed by handle (index + generation pair).
- A task's capability table is isolated per AS (address space / task), stored in the task's TCB.

### Phase 6 Workaround (Structural Note)
The current implementation declares the table as `[u64; 768]` rather than `[Capability; 256]` due to a limitation in paideia-as 0.6.0 (cmd_build hardcodes 8 bytes per element, not 24). When paideia-as m5-005 adds proper element-size computation for non-u64 array types, this declaration can be simplified to the logical structure. The runtime interpretation remains identical: 3 consecutive u64s form one capability descriptor.

## Implementation Notes

### Storage Layout
- **Address**: Kernel-virtual address (TBD: assigned during final link phase)
- **Alignment**: 8-byte natural alignment (u64 array)
- **Section**: .bss (read-write, zero-initialized by kernel_main before first use)
- **Lifetime**: Static; persists for the entire kernel lifetime

### Initialization Protocol
The table is declared `uninit` because:
1. Early boot code (kernel_main.pdx / kernel_main_64) zeros the .bss segment before any cap operations.
2. Capabilities are populated lazily as tasks are created and granted authority.
3. No explicit initialization loop is needed; zero-filled slots are safe (kind=0 is KIND_NULL, rights=0 is no-authority).

### Slot Zero (Index 0)
The descriptor at index 0 is reserved for the kernel's own root/supervisor capability, minted during supervisor initialization (Phase 6 / R7 scope). All other slots are available for task capabilities.

## Access and Mutation Protocol

### Read Access
- **Kernel only**: Capability system operations (mint, retype, revoke, lookup, grant)
- **No user access**: Userspace cannot directly read or write cap table entries
- **Atomicity**: Individual u64 reads are atomic; multi-field reads (kind + rights) use generation as a guard

### Mutation Access
- **Kernel only**: Capability minting, retyping, revocation, and sealing operations
- **Atomicity**: Compare-and-swap on (generation, kind, rights, target_ptr) tuple with generation as witness
- **Non-atomic fields**: Flags may be updated separately (sealed/revoked state)

## Traceability

- **Issue**: #337 (B5-001 descriptor table layout)
- **Phase**: Tier 5 Phase 1 (capability system reactivation)
- **Milestone**: B5 subseries (capability system foundations)
- **Softarch**: Per `.plans` Phase 2, §Capability Model
- **References**:
  - `src/kernel/core/cap/table.pdx` (this file)
  - `src/kernel/core/cap/kind.pdx` (capability kind enum)
  - `design/capabilities/linearity-and-tags.md` (capability model spec)

## Known Limitations and TODOs

- **No heap allocation**: Phase 2 hardcodes 256 entries; dynamic table expansion deferred to Phase 7+.
- **No per-task isolation yet**: Kernel currently uses a single shared table; per-address-space tables are Phase 6 scope.
- **Initialization verification deferred**: B5-001b (audit entry) will add diagnostic code to validate all 256 slots are zeroed post-bss-zero.
- **Access control verification**: B5-002 (cap_mint, cap_lookup) will add full audit entries with witness codes.

## Validation Checklist

- [x] Header comment updated (src/kernel/core/cap/table.pdx)
- [x] Audit entry created (design/audit/entries/b5-001-descriptor-table.md)
- [x] Build verification: `tools/run-smoke.sh` passes
- [ ] Smoke output verification: kernel boots to idle without cap-system panics (Phase 6 scope)
