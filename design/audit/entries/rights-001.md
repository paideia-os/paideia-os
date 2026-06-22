# Audit Entry: Rights Catalog Enforcement (R2.5-007)

**Capability:** R2.5-007 (cap: rights catalog enforcement)  
**Audit Phase:** Phase 2.5  
**Date:** 2026-06-21  
**Author:** osarch + workerbee  

## Summary

R2.5-007 implements runtime enforcement of the capability rights catalog at mint-time and invoke-time. Each capability kind is associated with an allowed-rights bitmask; operations that attempt to mint or invoke with rights outside the allowed set are rejected.

## Affected Files

- `src/kernel/core/cap/rights_table.pdx`: kind-to-rights-bitmask table (16 const u64 values).
- `src/kernel/core/cap/mint.pdx`: add rights-validation check before descriptor initialization.
- `src/kernel/core/cap/invoke.pdx`: add per-operation rights-check before dispatch.

## Justification

Per Pillar 10 (functional discipline: capabilities are linear/affine, monadic effect-typed), the kernel must enforce a closed-world set of allowed rights per kind. This prevents userspace from forging capabilities with rights they have no authority to claim.

**Reference:** seL4 capability rights catalogue (NICTA TR-2009 §4.3, "Capability Object Derivation"). See `design/capabilities/rights-catalog.md` for the Phase 2 catalog design.

## Verification TODO

- Formal proof that the rights bitmask table (16 constants) is exhaustive and non-overlapping in its type-to-rights mapping.
- Runtime test: mint(KIND_THREAD, ptr, 0xFFFFFFFF) should fail with ERR_INVALID_RIGHTS (since KIND_2_ALLOWED_RIGHTS ≠ 0xFFFFFFFF).

## Implementation Status

**Phase 2.5:** Partial.
- `rights_table.pdx` constants defined and compiled.
- `cap_mint` checks rights before descriptor initialization (PA7-003 if-test on (kind_rights & requested_rights) == requested_rights).
- `cap_invoke` checks per-operation rights before dispatch.
- **Placeholder bytes:** Rights checking uses inline masking; real descriptor table write gates on Phase 8+ unsafe-mem work.

## Escalation Notes

None. The rights catalog is static per Phase 2 design.

## Audit Trail

- **Author:** R2.5-007 implementation.
- **Reviewed:** osarch + workerbee (Phase 2.5 megabatch).
- **Approved:** pending hwman review of LAM bit-usage impact (R2.5-005 escalation).
