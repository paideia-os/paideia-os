# PaideiaOS — Dev Env: Sanitizer Story for Assembly-Source Fuzzing

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Sanitizers for paideia-as-compiled code under fuzz. Addresses dev-env S7.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| SAN-D1 | AFL-style coverage instrumentation: trivial via paideia-as macros | Standard |
| SAN-D2 | ASan-equivalent: project-specific memory tracking | Phase 3+ |
| SAN-D3 | UBSan-equivalent: bounds checks via macros | Phase 2 |
| SAN-D4 | MSan-equivalent: deferred | Phase 4+ |

---

## 1. Coverage instrumentation

paideia-as emits AFL-compatible coverage maps when `#[fuzz_instrument]` annotation is present. The fuzzer (libFuzzer/AFL++) consumes these.

---

## 2. ASan-equivalent

For assembly-source code, a project-specific memory tracker:
- All allocations recorded in a shadow.
- All loads/stores checked against shadow.
- Use-after-free, double-free, out-of-bounds detected.

Phase 3+ work; requires building the shadow infrastructure.

---

## 3. UBSan-equivalent

Bounds checks for array/buffer access via macros that paideia-as expands. Lower cost than ASan-style shadow.

---

## 4. Open issues

| ID | Issue |
|---|---|
| SAN-O1 | The exact shadow-memory layout for ASan-equivalent. |

---

*End of document.*
