# PaideiaOS — Runtime: AOT Compilation Pipeline

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Ahead-of-time WASM compilation for security-sensitive jails. Addresses JAIL-O7.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| AOT-D1 | AOT compiles WASM module to native PaideiaOS binary | Performance + security |
| AOT-D2 | Cranelift is the backend | Same as wasmtime JIT |
| AOT-D3 | AOT output is a signed PAX | Per PQ |
| AOT-D4 | AOT artifacts can be signed by the release-line key | Audit |

---

## 1. Pipeline

```
WASM module 
  → Cranelift AOT compile 
  → Native x86_64 code 
  → wrap in PAX format 
  → sign 
  → store in /aot-cache/
```

---

## 2. Cache invalidation

If WASM module changes (different hash), the AOT cache entry is invalidated.

---

## 3. Use cases

- Latency-sensitive WASM workloads (avoid JIT warmup).
- Security-sensitive jails (no JIT-generated code in process).

---

## 4. Open issues

| ID | Issue |
|---|---|
| AOT-O1 | When AOT is triggered — at install time? On first run? |
| AOT-O2 | Compatibility across wasmtime version updates. |

---

*End of document.*
