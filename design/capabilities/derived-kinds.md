# PaideiaOS — Capabilities: Derived-Kind Safety Discipline

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Design specification for derived capability kinds (per CAP-Q3 two-tier) and the safety review process for the derived-kind safety holes (per CAP-O6).

**Hard inputs:**
- `linearity-and-tags.md` §3.4 — derived-kind limitation: no runtime discriminator.
- CAP-Q3 — two-tier hierarchy.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| DRV-D1 | Derived kinds carry no runtime discriminator; safety is static-only | CAP-Q3 binding |
| DRV-D2 | Derived-kind definitions are functor-typed; the type system tracks them | CAP-Q3 binding |
| DRV-D3 | A derived-kind definition is a userspace concern; the kernel sees only base kinds | Microkernel-pure |
| DRV-D4 | `unsafe` blocks that mint derived caps incorrectly are caught by audit, not by the kernel | The static safety hole |
| DRV-D5 | Every derived-kind definition is audited at registration time | Mitigation |

---

## 1. The fundamental limitation

The CAP-Q3 two-tier hierarchy specifies:
- 16 closed base kinds (kernel-defined).
- Unlimited derived kinds via the type system (userspace-defined).

Because the kernel descriptor only records the base kind, an *incorrectly-minted* derived capability (via an `unsafe` block that lied about its declared kind) is indistinguishable from a correctly-minted one at runtime. The substructural type system catches the lie at compile time *for well-typed code*; for code inside `unsafe` blocks, the catch is at code review.

This is the safety hole. It is acknowledged in `linearity-and-tags.md` §3.4 and discharged via process here.

---

## 2. Derived-kind definition

A derived-kind definition consists of:

```paideia-as
signature MyDerivedCapSig = derived BaseCapKind with
  schema : ProtocolSchema
  rights : EffectRow
  invariant : Property        // optional precondition
end

module MyDerivedCap : MyDerivedCapSig = derive(BaseCapKind, MyDerivedSchema)
```

Concretely: `NvmeQueueCap = derived IpcEndpointCap with NvmeSchema, !{nvme_submit, nvme_complete}`.

---

## 3. The audit process

### 3.1 Registration

When a derived-kind definition is added to the codebase:
1. The definition is in a `.pdx` file under `src/.../derived-kinds/`.
2. A PR is opened.
3. The PR is reviewed by a security-reviewer + the relevant subsystem owner (per `02-development-environment.md` §12.2).
4. Reviewers check:
   - The derived kind's invariant is satisfiable.
   - No `unsafe` block mints this derived kind with weaker conditions than declared.
   - The schema's session-type protocol is reasonable.

### 3.2 Catalog

All derived-kind definitions are listed in `design/capabilities/derived-kind-catalog.md` (future). When derived kinds proliferate, the catalog is the single review surface.

### 3.3 Periodic review

Every quarter, the existing derived-kind catalog is reviewed:
- Are all kinds still in use?
- Are their invariants still valid?
- Have new `unsafe` blocks been introduced that mint these kinds without the discipline?

---

## 4. Recommended patterns for derived-kind use

### 4.1 Restricting rights, not adding

A derived kind should *restrict* the parent kind's rights, not *add* rights the parent doesn't have:

```paideia-as
// Good: NvmeQueueCap restricts IpcEndpointCap to a specific schema
module NvmeQueueCap = derive(IpcEndpointCap, NvmeSchema)
  with effects = !{nvme_submit, nvme_complete}  // subset of ipc-endpoint's

// Bad: trying to add a new effect not in the parent
module BadCap = derive(IpcEndpointCap, ...)
  with effects = !{ipc_send, kernel_panic}  // !!! kernel_panic not in parent's effects
```

The type system catches the bad case at definition time.

### 4.2 Distinguishing by schema

A derived kind is most useful when the *schema* (session type) is what makes it different, not the rights bits.

### 4.3 Naming convention

`<Subsystem><Function>Cap` is conventional: `NvmeQueueCap`, `FsInodeCap`, `GpuBufferCap`, `AudioStreamCap`.

---

## 5. The runtime fallback

Even though derived-kind safety is static-only, the *base kind* check at runtime catches several classes of attack:

- An `unsafe` block claiming to mint `NvmeQueueCap` but actually pointing to a `MemCap` descriptor: the kernel-side LAM kind-hint check fails on the next operation (mismatch between expected base kind and actual descriptor kind).

This is the runtime backstop. It doesn't catch derived-kind-mismatch (claiming NvmeQueueCap but providing GpuBufferCap), but it does catch base-kind-mismatch.

---

## 6. Phase 2+ enhancement

Phase 2: derived kinds exist; safety is static + audit.
Phase 3+: investigate runtime tagging of derived kinds (would require additional descriptor metadata; possibly via a per-process kind registry).

---

## 7. Open issues

| ID | Issue |
|---|---|
| DRV-O1 | The exact security-reviewer / subsystem-owner pairings for derived-kind PRs. |
| DRV-O2 | The catalog format for derived-kind-catalog.md. |
| DRV-O3 | When (if ever) to invest in runtime tagging for derived kinds — phase 3+ analysis. |
| DRV-O4 | The interaction with sealed capabilities — sealing a derived cap; what's preserved? |

---

*End of document.*
