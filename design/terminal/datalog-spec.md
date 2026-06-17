# PaideiaOS — Terminal: Datalog Dialect Specification

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Concrete syntax for the embedded Datalog sub-language in the semantic shell. Addresses SH-O1.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| DLG-D1 | Embedded inside `datalog { ... }` blocks (per shell doc §2.1) | Lexical context |
| DLG-D2 | Datalog with stratified negation and aggregation | Standard practical extensions |
| DLG-D3 | Predicates typed via FS schema registry | Type-safety |
| DLG-D4 | Recursion supported | Standard |
| DLG-D5 | Logic variables prefixed `?` | Distinguishes from pipeline values |
| DLG-D6 | Pipeline values interpolated with `$` | Cross-context flow |

---

## 1. Atoms

```
predicate(?x, ?y, $z)
```

- `predicate` is a predicate name resolved against the schema registry.
- `?x`, `?y` are logic variables (scoped to the query).
- `$z` is a pipeline value (resolved at query construction).

---

## 2. Goals

A query is a conjunction of atoms, comma-separated:

```
?- file(?f), 
   ext(?f, "pdf"), 
   modified(?f, ?t), 
   ?t > now() - days(7)
```

---

## 3. Rules

```
ancestor(?x, ?y) :- parent(?x, ?y).
ancestor(?x, ?y) :- parent(?x, ?z), ancestor(?z, ?y).
```

Rules define new predicates from existing ones; supports recursion.

---

## 4. Negation (stratified)

```
?- file(?f), not deleted(?f)
```

Negation-as-failure. Stratified: a predicate cannot recursively depend on its own negation.

---

## 5. Aggregation

```
?- count(file(?f), ?n)
?- sum(?size, file(?f), size(?f, ?size), ?total)
```

Aggregates over the satisfying assignments.

---

## 6. Output

A query's output is a stream of records — one per satisfying assignment. The free variables become record fields.

---

## 7. Type checking

Each predicate's argument types are looked up in the schema registry; type mismatches are caught at compile time.

---

## 8. Open issues

| ID | Issue |
|---|---|
| DLG-O1 | The exact aggregation function library — count, sum, min, max, avg, etc. |
| DLG-O2 | Magic-set rewriting heuristics. |
| DLG-O3 | User-defined predicates — how are they registered? |

---

*End of document.*
