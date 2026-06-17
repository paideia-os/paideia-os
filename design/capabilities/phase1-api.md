# PaideiaOS — Capabilities: Phase-1 Fallback API

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Minimal phase-1 capability operations. Addresses CAP-O12. Strict subset of the phase-2 capability system; code written against phase-1 carries forward.

**Hard inputs:**
- `linearity-and-tags.md` §13.2 — phase-1 vs phase-2 split.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| P1CAP-D1 | Phase 1: fixed-layout descriptor (no kind-tagged variant) | Simpler |
| P1CAP-D2 | Phase 1: hardware LAM only (no software fallback) — phase 1 uses dev hardware with LAM | Pragmatic |
| P1CAP-D3 | No derivation tree in phase 1; manual revocation via descriptor flag | Simpler |
| P1CAP-D4 | No sealing in phase 1 | Defer |
| P1CAP-D5 | No effect-bitmask mapping in phase 1 (type system not ready) | Defer |
| P1CAP-D6 | Phase 1 has just kernel-internal caps; no userspace cap exposure | Simpler |

---

## 1. Phase-1 capability descriptor

Fixed layout:

```nasm
struct phase1_capability {
   u32 kind;             // base kind
   u32 rights;           // 32-bit rights bitmask
   u64 target_ptr;       // pointer to the target object
   u32 generation;       // revocation epoch (8 bits used)
   u32 flags;
}
```

Total: 24 bytes. Fixed-size slab allocator.

---

## 2. Phase-1 operations

```nasm
; Allocate a capability descriptor.
; Inputs: RDI = kind, RSI = target_ptr, RDX = rights
; Output: RAX = capability handle (LAM-tagged pointer)
extern p1_cap_mint

; Verify a capability handle is valid.
; Input: RDI = handle
; Output: RAX = 1 if valid, 0 otherwise
extern p1_cap_verify

; Check that a capability has the required rights.
; Inputs: RDI = handle, RSI = required rights bits
; Output: RAX = 1 if all required bits set, 0 otherwise
extern p1_cap_has_rights

; Revoke a capability (bumps generation).
; Input: RDI = handle
; Output: RAX = 0 on success
extern p1_cap_revoke

; Destroy a capability (returns descriptor to slab).
; Input: RDI = handle
; Output: RAX = 0 on success
extern p1_cap_destroy
```

5 entry points. No derivation, no retype, no sealing.

---

## 3. Migration to phase 2

Phase 2 adds:
- Kind-tagged variant descriptors (replaces fixed-layout).
- Software-LAM fallback (replaces hardware-only assumption).
- Derivation tree + retype + subtree revocation.
- Sealing.
- Effect-bitmask mapping.
- Userspace capability operations.

Phase-1 callers continue to work via wrapper functions over the phase-2 API.

---

## 4. Use in phase 1

Phase-1 caps are used for:
- NVMe driver's request capability (read/write rights bits).
- Serial console capability.
- Audit log channel capability.
- Root task's spawning capability.

About a dozen distinct capabilities total in phase 1.

---

## 5. Open issues

| ID | Issue |
|---|---|
| P1CAP-O1 | Phase-1 capability for kernel-internal use only — no userspace exposure means the verification step is straightforward. |
| P1CAP-O2 | When to migrate each subsystem to phase-2 caps — coordinate with `milestones.md` §3.3. |

---

*End of document.*
