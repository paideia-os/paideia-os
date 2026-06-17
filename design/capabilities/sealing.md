# PaideiaOS — Capabilities: Sealing Details

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Detailed mechanics of capability sealing per CAP-Q9: seal/unseal pair management, the supervisor's grant policy, revocation interactions, and the use-case patterns. Addresses CAP-O8.

**Hard inputs:**
- `linearity-and-tags.md` §9 — high-level sealing design.
- CAP-Q9 binding: sealed bit in LAM tag + seal_cap required to seal.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| SEAL-D1 | Seal/unseal pair construction is via `request_seal_pair(domain) → (seal_cap, unseal_cap)` | Per linearity-and-tags.md §9.1 |
| SEAL-D2 | Both halves are kernel-allocated; the nonce is per-pair | Unforgeability |
| SEAL-D3 | A pair can be revoked independently (revoking seal_cap doesn't revoke unseal_cap, etc.) | Flexibility |
| SEAL-D4 | A sealed capability can be invoked (op succeeds) but not introspected (rights/derivation hidden) | The fundamental sealing property |
| SEAL-D5 | Sealing preserves the underlying capability's base kind for runtime backstop checking | Defense in depth |
| SEAL-D6 | Audit log records: pair construction, every seal operation, every unseal operation | Audit |

---

## 1. Pair construction

```paideia-as
fn request_seal_pair(domain : SealDomain, supervisor : SupervisorCap)
                    -> (SealCap, UnsealCap) !{seal_construct, audit_log}
```

The supervisor allocates a fresh 128-bit nonce; mints two capability descriptors:
- `SealCap`: kind = `seal-cap` (12); tail carries the nonce and the (paired) `unseal_cap` descriptor pointer.
- `UnsealCap`: kind = `unseal-cap` (13); tail carries the nonce and the (paired) `seal_cap` descriptor pointer.

The pair is registered in the supervisor's sealing-registry for audit.

---

## 2. Apply seal

```paideia-as
fn seal(target_cap : Cap, seal_cap : SealCap)
       -> SealedCap !{seal_apply, audit_log}
```

1. The kernel verifies `seal_cap` is valid and the caller holds it.
2. The kernel mints a new capability descriptor: same base kind as `target_cap`, but with:
   - The `sealed` LAM bit set.
   - The `seal_nonce` field in the descriptor tail set to the seal_cap's nonce.
3. The target_cap is consumed (its substructural class respected).
4. The new sealed cap is returned.

The new cap is type-compatible with the original (same base kind) but has reduced introspectability.

---

## 3. Unseal

```paideia-as
fn unseal(sealed_cap : SealedCap, unseal_cap : UnsealCap)
         -> Cap !{seal_unseal, audit_log}
```

1. The kernel verifies the sealed bit on `sealed_cap`.
2. The kernel reads the `seal_nonce` from `sealed_cap`'s descriptor.
3. The kernel reads the `unseal_cap`'s nonce.
4. If matched: mints a new capability descriptor without the sealed bit; returns it.
5. If not: returns error `C1304` (sealed cap, no matching unseal-cap).

The original sealed cap remains valid; this is unsealing, not destruction.

---

## 4. Inspection vs invocation

| Operation | Allowed on sealed cap? |
|---|---|
| Kind-specific operations (e.g., `mem_read` on memory; `ipc_send` on ipc-endpoint) | Yes |
| `inspect_rights` | No — requires unseal_cap |
| `inspect_derivation_tree` | No — requires unseal_cap |
| `query_kind` (base kind) | Yes — base kind is fundamentally public |
| `mint` / `retype` | Depends — if the operation requires understanding the cap's metadata, no |

The principle: sealing hides *metadata*, not *action*.

---

## 5. Revocation interactions

### 5.1 Revoke seal_cap

The seal_cap is destroyed. Existing sealed capabilities remain sealed; new ones cannot be sealed using this seal_cap. The matched unseal_cap is still valid (can unseal existing sealed caps).

### 5.2 Revoke unseal_cap

The unseal_cap is destroyed. Sealed capabilities created with the seal_cap are now *permanently sealed* — no party can unseal them. They can still be invoked.

### 5.3 Revoke both

Both halves destroyed. Sealed caps remain invocable but unconditionally hidden.

### 5.4 Revoke a sealed cap directly

The sealed cap's descriptor's epoch bumps. Any holder's handle becomes stale.

---

## 6. Supervisor policy

The supervisor's `request_seal_pair` is the entry point. Policy considerations:
- Which domains can request seal pairs? (Drivers and trusted servers; not arbitrary userspace.)
- How many pairs can a domain hold concurrently? (Rate-limited to prevent exhaustion.)
- Are unseal_caps allowed to escape the originating domain? (Per-domain policy.)

---

## 7. Use cases

### 7.1 Driver-client opacity

A driver hands clients sealed queue caps. Clients submit work via the queue but cannot enumerate the driver's internal state.

### 7.2 Bearer tokens

A short-lived sealed cap can serve as an unforgeable bearer token: anyone holding it can invoke; no one can introspect or modify.

### 7.3 Audit-private channels

A channel whose existence is audited but whose detail is not visible to audit readers without the unseal_cap.

---

## 8. Performance

| Operation | Budget |
|---|---|
| Request seal pair | ≤ 100 ns |
| Seal a cap | ≤ 200 ns |
| Unseal a cap | ≤ 200 ns |
| Invoke a sealed cap (vs unsealed) | identical (no per-op overhead) |

---

## 9. Open issues

| ID | Issue |
|---|---|
| SEAL-O1 | Whether sealed caps can be re-sealed (yes by default; nesting depth limit). |
| SEAL-O2 | The interaction with derived kinds — sealing a derived cap preserves the derived-kind type info? Currently: no, only base kind survives. |
| SEAL-O3 | The supervisor's seal-pair grant policy — concrete rules. |
| SEAL-O4 | Auditing patterns for sealed-cap usage (the cap is hidden but the *invocation* can be logged with the cap's identity hash). |

---

*End of document.*
