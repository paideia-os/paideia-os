# PaideiaOS — paideia-as Phase-1 Restricted Macro Form

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Specification of the *restricted* macro form available in phase-1 of the paideia-as project, before the full typed elaborator reflection (Q-A4) comes online in phase 2. Addresses AS9 from `custom-assembler.md`.

**Hard inputs:**
- `custom-assembler.md` Q-A4 — typed elaborator reflection (full Q-A4 power is phase-2+).
- `custom-assembler.md` §5 — macros are typed programs in paideia-as.
- `custom-assembler.md` §14.5 — phase-1 has restricted macros; phase 2 brings full reflection.
- `milestones.md` §2 — phase-1 deliverables.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| MP-D1 | Phase-1 macros are **pattern-based only** (Scheme syntax-rules lineage), not full typed elaborator reflection | §14.5 binding |
| MP-D2 | Pattern matching is the *only* macro mechanism in phase 1 | Simplest implementation |
| MP-D3 | Hygiene is preserved automatically (alpha-rename macro-introduced names) | Ullrich 2020 algorithm; pillar 6 |
| MP-D4 | Macros are *expanded before* type checking, not as part of elaboration | Order is simpler in phase 1 |
| MP-D5 | A macro that needs more than patterns must wait for phase 2 | Discipline; signal scope realistically |
| MP-D6 | Phase-1 macros are forward-compatible with phase-2 typed reflection — a phase-1 macro that the elaborator accepts is still acceptable in phase 2 | Migration insurance |

---

## 1. Pattern-based macros

### 1.1 Syntax

```paideia-as
macro <name>(<pattern>) => <template>
```

A macro maps a pattern to a template. Multiple patterns are allowed:

```paideia-as
macro my_macro
    ($x:expr) => { simple_form($x) }
    ($x:expr, $y:expr) => { complex_form($x, $y) }
    ($x:expr; $rest:expr*) => { iterated_form($x; $rest) }
```

### 1.2 Pattern types

| Type | Matches |
|---|---|
| `$x:expr` | Any expression |
| `$x:type` | Any type |
| `$x:ident` | Any identifier |
| `$x:literal` | Any literal |
| `$x:pat` | Any pattern (for use in match expressions) |
| `$x:stmt` | Any statement |
| `$x:block` | Any `{ ... }` block |
| `$x:tt` | Any token tree (most permissive) |
| `$x:expr*` | Zero or more expressions, separated by commas (configurable) |

The fragment types match Rust's `macro_rules!` and behave similarly.

### 1.3 Hygiene

Names introduced by a macro are alpha-renamed against the use site; names referenced from the use site are resolved at the use site. The algorithm follows Lean 4 / Ullrich 2020. A macro cannot accidentally shadow a variable in the user's scope.

### 1.4 Examples

#### Effect handler installation

```paideia-as
macro with_handler
    ($effect:type, $handler:expr, $body:block) => {
        let __old_env = r15
        r15 = install_handler(r15, $effect, $handler)
        let __result = $body
        r15 = __old_env
        __result
    }
```

Usage:
```paideia-as
with_handler(Io, io_handler, {
    perform Io.port_write(0x60, 0x01)
})
```

#### Linearity-disciplined dispatch

```paideia-as
macro consume_then
    ($cap:expr, $action:block) => {
        let __cap = $cap     // consume here (linear)
        $action
    }
```

#### Capability binding

```paideia-as
macro bind_cap
    ($var:ident : $kind:type ⊣ $parent:expr) => {
        let $var : $kind = derive_from($parent)
    }
```

---

## 2. What is *not* in phase-1 macros

The following are *deferred to phase-2 typed reflection* and produce error `M0307` (macro feature not in phase 1):

- **Type-driven macros**: macros that inspect the type of their arguments and generate different code based on type. Phase 1 macros are purely syntactic.
- **Reflection on AST**: macros cannot inspect the AST as a typed value; pattern matching is the only mechanism.
- **Effect-aware macros**: macros that pattern-match on effect rows. The pattern types `$x:type` or `$x:expr` capture but do not destructure effect rows.
- **Procedural macros**: full programs that consume tokens and produce tokens. Phase 1 has only declarative pattern macros.
- **Quoting beyond template**: phase-1 templates are quasi-quoted (the `$var` interpolations); deep AST manipulation is not supported.
- **Eval-at-macro-expansion**: the phase-1 macro expander does not evaluate Rust functions; phase 2's reflection enables this.

---

## 3. Hygiene details

### 3.1 Capture-by-introduction

Names introduced by the macro template:

```paideia-as
macro foo($x:expr) => {
    let temp = $x;     // 'temp' is hygienic
    temp + 1
}
```

If the user calls `foo(temp)` (where `temp` is a user-visible variable), the user's `temp` and the macro's `temp` do not conflict; the macro's is rewritten internally.

### 3.2 Capture-by-reference

Names referenced from the use site are resolved at the use site:

```paideia-as
macro bar($x:expr) => {
    println("debug:", $x);   // 'println' resolved at use site
}
```

If the user's scope doesn't have `println`, the error is reported at the use site, not at the macro definition.

### 3.3 Marker-based identity

Internally, each name carries a "macro id" tag. Identifiers introduced at expansion site M are tagged with M; renaming compares tags to detect collisions.

---

## 4. Macro expansion phase

In phase 1:
1. Parser produces an AST.
2. Macro expansion pass walks the AST, replacing macro invocations with their expansions.
3. Type checking runs on the post-expansion AST.

In phase 2:
- Macro expansion *interleaves* with type checking (typed elaborator reflection).
- A macro can ask the elaborator for type info during expansion.
- Phase-1 macros work identically in phase 2 (forward compatibility).

---

## 5. Forward compatibility

A phase-1 macro:
- Accepts pattern arguments.
- Produces a template.
- Does not depend on type information.

This is a strict subset of what phase-2 macros can do. When phase 2 ships, every phase-1 macro continues to work without modification. Phase-2-only macros must wait for phase 2; the toolchain rejects them in phase 1 with `M0307`.

This is the migration insurance: code written in phase 1 carries forward.

---

## 6. Diagnostics

Macro-related diagnostic codes (per `diagnostics.md` §6):

- `M0307` — macro feature not in phase 1 (used when a phase-1 macro tries to do something phase-2 only).
- `M0308` — macro pattern does not match any rule.
- `M0309` — macro template references undefined pattern variable.
- `M0310` — macro hygiene violation (rare; usually a toolchain bug).
- `M0311` — macro expansion exceeded maximum depth (default: 100).
- `M0312` — macro recursive expansion does not terminate.

---

## 7. Examples used throughout PaideiaOS

The phase-1 macro language is used in the kernel for:

- **Atomic-section markers**: macros emit the enter/exit boilerplate (CLI/STI or equivalent).
- **Effect-handler installation**: `with_handler` pattern from §1.4.
- **Capability-derivation boilerplate**: `bind_cap` pattern.
- **Per-CPU access**: macros that compute GS-base-relative offsets.
- **Audit-log emission**: macros that wrap operations with audit-record construction.

These are the macros that enable the phase-1 PaideiaOS kernel to be written without the full Q-A4 typed reflection.

---

## 8. Open issues

| ID | Issue |
|---|---|
| MP-O1 | The exact pattern syntax for `$x:expr*` separators — comma is default; what about semicolon? |
| MP-O2 | The maximum macro expansion depth — default 100, may need tuning for deeply nested code. |
| MP-O3 | Cross-file macros — a macro defined in module A used in module B. Currently: requires explicit `use A::macro_name`. |
| MP-O4 | Macros that take type arguments — the `$x:type` fragment matches types syntactically; cannot inspect them. Phase 2 problem. |
| MP-O5 | Documentation generation for macros — what does `paideia-as doc` produce for macro signatures? Phase 2+. |
| MP-O6 | Test corpus for phase-1 macros — pattern-matching edge cases. Phase 1 deliverable. |

---

*End of document.*
