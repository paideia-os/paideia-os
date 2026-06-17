# PaideiaOS — IPC: Multiparty Session Types

**Status:** Draft v0.1 (deferred — phase 3+)
**Date:** 2026-06-17
**Scope:** Sketch of the multiparty session-types extension. Phase 1–2: dataflow graph composition via merger/splitter nodes. Phase 3+: optional multiparty session types as a single primitive. Addresses IPC-O2.

**Hard inputs:**
- `wait-free-dataflow.md` §6.6 — multiparty deferred to phase 3+.
- Honda, Yoshida, Carbone, *Multiparty Asynchronous Session Types*, POPL 2008.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| MP-D1 | Multiparty session types are a phase-3+ extension | Scope realism |
| MP-D2 | Until then, multi-party patterns are composed via merger/splitter nodes | Pragmatic |
| MP-D3 | When implemented, follow the Honda/Yoshida/Carbone framework | Established lineage |

---

## 1. What multiparty would add

Multiparty session types describe a *global protocol* among N processes; each process's *local protocol* (a "projection") is derived. The global protocol may be:

```
P1 → P2 : ↑Req
P2 → P3 : ↑Process
P3 → P1 : ↑Result
```

P1 projects to: `↑Req(P2) . ↓Result(P3) . end`
P2 projects to: `↓Req(P1) . ↑Process(P3) . end`
P3 projects to: `↓Process(P2) . ↑Result(P1) . end`

The framework guarantees:
- Each pair of communicating parties has dual local types.
- The global protocol is *deadlock-free* if projections are well-defined.

---

## 2. Why deferred

- Compositional multiparty session types remain research-active; PaideiaOS would be an early adopter.
- The merger/splitter composition (per IPC-Q2) already covers most practical patterns.
- The added type-system machinery (global type inference, projection) is substantial.
- Phase 3+ scope.

---

## 3. Open issues

| ID | Issue |
|---|---|
| MP-O1 | Which multiparty session-type framework to adopt (Honda-Yoshida-Carbone, Scribble, or a newer one). |
| MP-O2 | How global protocols interact with the dataflow-graph topology check (`cycle_cap` etc.). |
| MP-O3 | Whether to make multiparty available even in phase 2 if scope permits. |

---

*End of document.*
