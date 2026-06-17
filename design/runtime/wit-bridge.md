# PaideiaOS — Runtime: WIT-Typed Component-Model Bridge

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Conversion between PaideiaOS records and WASI Preview 2 WIT types. Addresses JAIL-O3.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| WIT-D1 | Type-direct conversion: no string round-trip | Performance |
| WIT-D2 | WIT primitive types map to PaideiaOS primitives | Standard |
| WIT-D3 | WIT records/variants map to schema-typed records | Type system integration |
| WIT-D4 | WIT resources map to capability handles | Cap discipline |

---

## 1. Type mapping

| WIT type | PaideiaOS type |
|---|---|
| u8, u16, u32, u64 | u8, u16, u32, u64 |
| s8, s16, s32, s64 | i8, i16, i32, i64 |
| f32, f64 | f32, f64 |
| bool | bool |
| char | u32 (Unicode codepoint) |
| string | String (UTF-8) |
| list<T> | List<T> |
| record { ... } | struct { ... } (mapped per schema) |
| variant { ... } | enum { ... } |
| resource | Capability handle |

---

## 2. Bidirectional conversion

For each direction (PaideiaOS → WIT, WIT → PaideiaOS), the bridge translates fields. Failures (type mismatches) return errors per WASI conventions.

---

## 3. Open issues

| ID | Issue |
|---|---|
| WIT-O1 | Complex WIT types (recursive variants). |
| WIT-O2 | Resource lifetime semantics across the bridge. |

---

*End of document.*
