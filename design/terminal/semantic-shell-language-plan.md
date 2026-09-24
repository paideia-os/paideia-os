# PaideiaOS — Semantic Shell: Language-Surface Materialization Plan

**Status:** Draft v0.1
**Date:** 2026-09-23
**Scope:** The language-surface half of a comprehensive plan to move
`design/terminal/semantic-shell.md` (the 12 SH-D decisions) from
specification into runnable reality. This document is paired with the
runtime-substrate half owned by `osarch` (pipeline serialization,
capability flow at the substrate, REPL process model, WASM jail,
rendering, Unicode substrate tables, cross-host transport). Where the
two halves meet, this doc names the seam and cross-references — it does
not re-plan the substrate.

**Hard inputs (do not relitigate):**
- `design/terminal/semantic-shell.md` — SH-D1..SH-D12.
- `design/terminal/datalog-spec.md`, `pds-format.md`, `command-registry.md`,
  `schema-registry.md`, `wire-format.md`, `editor-bindings.md`,
  `i18n-provider.md`, `d8-features.md`.
- `design/00-feature-inventory.md` — E12 (semantic shell), E13 (Unicode),
  E6 (typed name-resolution graph), D8 (advanced semantic-shell features).
- `design/01-foundational-decisions.md` — Pillar 8, Q13 (hybrid
  serialization), Q-A3 (algebraic effects), Q-A4 (elaborator reflection),
  Q-A7 (functors), Q-A2 (substructural lattice), Q9 (no POSIX; WASM jail).
- `design/toolchain/custom-assembler.md` — the elaborator surface we
  intend to *host* the shell parser+checker inside.
- `design/toolchain/macros-phase1.md` — the *restricted* phase-1 macro
  form (pattern-based, syntax-rules lineage). This IS the blocker on the
  hosting strategy for §3's R220.
- `design/paideia-as/v0.18-issue-999-command-dispatch-doc.md`,
  `v0.18-issue-1003-hash-dispatch.md` — how command-name→handler
  dispatch stands today (u64-key HashMap + fn-ptr indirect call;
  Str-keyed dispatch blocked on `#998b/c`).
- Current `src/user/shell.pdx` (373 LOC) + `src/user/dispatch.pdx`
  (1996 LOC) — the POSIX-shaped `/bin/sh` this plan replaces stage by
  stage.

---

## 1. Executive summary

The semantic shell is not one language — it is a *lexical composition*
of three (typed pipelines + embedded Datalog + HM-typed lambdas),
unified under one type checker, one elaborator, one AST. The design
document `semantic-shell.md` names 12 SH-D decisions but leaves the
implementation strategy open at exactly one place that dominates every
downstream cost: does the shell **host** its parser and type checker as
first-class extensions inside `paideia-as`'s elaborator (Q-A4 typed
reflection), or does it **hand-roll** a standalone compiler? The answer
this plan defends (§6 R220) is *host inside the elaborator*, with a
carefully scoped subset of Q-A4 landed as the first prerequisite round.
Hand-rolling produces an orphan compiler that duplicates the substructural
lattice, effect system, functor machinery, LSP, SARIF writer, and hygiene
algorithm the assembler already ships. Hosting turns the shell into a
paideia-as macro-and-DSL — one order of magnitude less code and one
type-system invariant tighter.

The plan sequences 10 rounds (R220..R229). R220 lands the paideia-as
prerequisites the hosting strategy requires — elaborator reflection
surface, Str::eq/Str::hash, generic HashMap, closure-typed value slot,
effect-row inference at call sites (paideia-as `#1356`). R221..R229
then materialize the shell subsystems in dependency order: Unicode-aware
lexer + AST + context machinery (R221) → command-module functor surface
+ registry (R222) → pipeline literal syntax (R223) → lambda surface
(R224) → **unified HM type checker across the three sub-languages**
(R225 — largest round) → Datalog evaluator with magic-set rewriting
(R226) → `.pds` script format + module loading (R227) → tab completion
(R228) → REPL evaluator loop with session-scoped bindings (R229). Each
round has a milestone table (§4), a concrete acceptance criterion (a
compile witness + a runnable example + a wire fingerprint once the
shell can emit one), and issue-count estimates that sum to ~345.

Wall-clock (solo developer, per the toolchain-milestones-solo posture
in `design/toolchain/milestones.md`): R220 ~12 weeks (paideia-as-side,
gates everything else); R221..R224 in parallel-safe waves ~26 weeks;
R225 ~14 weeks (single biggest concentration of hard work — HM across
three sub-languages is the plan's principal technical risk); R226 ~10
weeks; R227..R229 ~14 weeks. Total ~76 weeks of language-surface work,
which runs *alongside* osarch's runtime-substrate half; the calendar
gate is R225's completion, after which R226..R229 are largely mechanical.
Two risks dominate: the elaborator-reflection scope creep (mitigated by
freezing a subset spec before R220 opens) and the HM-across-three-sub-
languages decidability (mitigated by rank restrictions + a fallback
"annotate the boundary" escape). Both are itemized in §6.

---

## 2. Prerequisite unblocks (paideia-as work R220 will land)

The hosting strategy requires the paideia-as substrate to expose
surfaces that today are either DEFERRED (typed elaborator reflection
per `macros-phase1.md` MP-D5) or LANDED as canary-only shapes
(u64-keyed HashMap; no Str-keyed variant). Each unblock is issued
against `paideia-as` and gates one or more shell rounds.

| # | Unblock | Existing / new issue | Gates |
|---|---|---|---|
| P1 | Typed elaborator reflection surface (Q-A4) — the `Syntax` type, `Elab` effect, quote/anti-quote (`` `(…) `` / `${…}`), expected-type/expected-effect access, syntax-tree walker | new; **paideia-as ~#1500–1512 range** (12 issues; supersedes MP-D5's phase-2 gate) | R221, R222, R225, R226, R227 |
| P2 | Str::eq (byte-equal, NFC-normalized) | existing paideia-as `#998b` (P0273 deferred) | R222 (command-name key), R228 (completion match) |
| P3 | Str::hash (BLAKE3-based per `schema-registry.md` §3 upgrade path; FNV-1a-64 interim) | existing paideia-as `#998c` (P0273 deferred) | R222 (dispatch), R226 (predicate name hashing) |
| P4 | Generic HashMap<K, V> — lifted from the per-fixture canary shape of `#1003` into a stdlib module with K/V type parameters | new; **paideia-as ~#1513–1518 range** (6 issues; supersedes `#996` successor placeholder) | R222, R227, R228, R229 |
| P5 | Closure-typed value slot in HashMap — 16-byte fat-pointer values, closure-in-map lookup | new; **paideia-as ~#1519–1521 range** (3 issues; blocked on P4) | R222 (heavy/light dispatch), R229 (session-scoped bindings) |
| P6 | Effect-row inference at call sites — the open half of `v0.25-session-functors` | existing paideia-as `#1356` (OPEN and blocking) | R224 (lambda effect polymorphism), R225 (HM effect unification) |
| P7 | `Syntax`-value hygiene algorithm (Ullrich 2020) exposed to reflected macros | new; **paideia-as ~#1522–1525 range** (4 issues) | R221 (context-switch lexer as reflected macro), R227 (import hygiene) |
| P8 | LSP-embed API — an in-process handle by which a hosted language can push its own diagnostics through the assembler's diagnostic router | new; **paideia-as ~#1526–1529 range** (4 issues) | R225 (shell type errors), R228 (completion) |
| P9 | Fingerprint-emission intrinsic (`@fingerprint` attribute or elaborator API) that a hosted DSL can use to stamp per-turn REPL fingerprints (the anti-fabrication witness pattern we already use kernel-side) | new; **paideia-as ~#1530–1531 range** (2 issues) | Every round's acceptance criterion once the REPL emits |
| P10 | Rank-restricted let-polymorphism — sound HM subset that keeps inference decidable across the three sub-languages (see risk R2 in §6) | new; **paideia-as ~#1532–1535 range** (4 issues, joint spec with R225) | R225 |

**R220 total:** ~50 issues on `paideia-as` (12+4+2+6+3+4+4+4+2+4=45,
plus 5 for CHANGELOG/tests/version-discipline scaffolding). None of
R221..R229's work can start on the shell side until P1–P7 have
CHANGELOG entries in `tools/paideia-as/CHANGELOG.md`. P8..P10 gate only
R225+; P1..P7 can be sequenced so that R221 begins ~week 6 of R220's
window.

**Deliberate NON-prerequisites** — the following are *deferred to R229
or later* and NOT gates on the plan opening:
- BLAKE3 intrinsic in paideia-as (paideia-as `#1341` follow-on). FNV-1a-64
  is fine for R220..R228 (`schema-registry.md` §3 blesses the interim);
  BLAKE3 upgrade rides the same release that upgrades the schema
  registry's fingerprint. R228 completion works under FNV.
- Full phase-3 self-hosted paideia-as (`paideia-as-native`). The shell
  targets the phase-2 Rust-hosted `paideia-as`; a phase-3 rehost is
  transparent to the shell because the reflection surface is the API.
- Persistence of the schema registry (`schema-registry.md` §12). R226's
  Datalog evaluator is fine reading the boot-empty registry; the shell's
  session process is the first-registrar for its own pipeline schemas.

---

## 3. Rounds R220..R229 — dependency arrows and briefs

```
   R220 (paideia-as prereq)
       │
       ├─────────────┬─────────────┬─────────────┐
       ▼             ▼             ▼             ▼
     R221          R222          R226          R227
    (lexer/AST)  (cmd-modules)  (Datalog     (.pds script
       │             │           evaluator)   format)
       │             │             │             │
       └──────┬──────┴──────┬──────┘             │
              ▼             ▼                    │
            R223          R224                   │
        (pipelines)     (lambdas)                │
              │             │                    │
              └──────┬──────┘                    │
                     ▼                           │
                   R225                          │
              (unified HM checker) ◄─────────────┘
                     │
              ┌──────┴──────┐
              ▼             ▼
            R228          R229
        (completion)     (REPL loop)
```

Dependency notes:
- R221 (lexer + AST) is the single node R222..R229 all read from.
- R226 (Datalog) needs R221 (AST) but does NOT need R223/R224 — it
  parses its own `datalog { … }` block via a reflected sub-parser. This
  lets it run in parallel with R223/R224.
- R227 (.pds files) needs only R221 for parse; type-check-at-load
  needs R225.
- R225 (HM checker) is the join point. It cannot start until R223 and
  R224 have both landed their sub-language AST + effect-row shapes, and
  R226 has landed its schema-driven predicate typing.
- R228 (completion) and R229 (REPL) both need R225.

### R220 — paideia-as substrate for hosted DSLs
Land elaborator reflection (P1), stdlib primitives (P2–P5), effect-row
inference (P6), hygiene (P7), LSP embed (P8), fingerprint intrinsic
(P9), rank-restricted HM spec (P10). This is the round the plan cannot
open without; its own milestones are in §4.

### R221 — Unicode-aware lexer, unified AST, context machinery (SH-D9, SH-D1)
Lexer as a reflected paideia-as macro that produces `Syntax` values.
Three context states (`Pipeline`, `Datalog`, `Lambda`) driven by
lexical delimiters (`datalog { … }`, `{ |args| body }`). NFC
normalization at input boundary, TR#29 grapheme clustering for cursor
math, TR#11 width for renderer. Unified AST is a single sum type over
all three sub-languages so R225's checker walks one tree.

### R222 — Command-module functor surface + registry client (SH-D5)
`SchemasSig` and `CommandSig` signature bodies in paideia-as functor
syntax; each command is `module Cmd(Schemas: SchemasSig)(...) :
CommandSig`. Name→functor-instance resolution at the REPL through the
supervisor's command registry (per `command-registry.md`). Light
commands elaborate in-process; heavy commands spawn as separate
processes. This round *replaces* the POSIX-shaped dispatch table in
`src/user/dispatch.pdx` — the migration is stage-by-stage, one command
family at a time, with the legacy shell staying live behind a
`legacy-sh` alias throughout R222..R229.

### R223 — Pipeline literal syntax (part of SH-D3)
The `|` piping operator with typed rows. Built-in operators
`where`/`filter`, `sort by`, `group by`, `reduce`, `select`, `project`,
`head`/`tail`, `count`. Each stage's output-schema is threaded through
R225 for downstream stages. `@hostname` annotations parse now; the
substrate half wires the actual cross-host transport.

### R224 — Lambda surface (part of SH-D2/D5)
HM-typed anonymous functions in `{ |args| body }` and `\args -> body`
form. Closure over pipeline-scope bindings. Effect polymorphism per
Q-A3 (function types carry an effect row that unifies at call site
per P6). Interaction with linear/affine values from the substructural
lattice (Q-A2) — lambdas that close over a linear value are themselves
linear.

### R225 — Unified HM type checker across three sub-languages (SH-D2)
The one round every other round depends on for compile-time safety.
Algorithm W or J core, extended with: pipeline-record types (rows of
named fields typed from source-command's output-schema); Datalog
predicate types (typed by schema registry); function types with effect
rows (per P6). Cross-context type flow: a Datalog `?var` escaping into
pipeline context inherits the predicate's argument type. Rank-restricted
polymorphism (per P10) keeps the composed system decidable — see risk
R2 in §6 for the theoretical hazard and its mitigation. LSP integration
via P8 makes type errors visible in the line editor (Rust-style
diagnostic with source spans + suggestions).

### R226 — Datalog evaluator (SH-D4)
Bottom-up semi-naive evaluation over the FS's typed name-resolution
graph. Magic-set rewriting for goal-directed queries (Beeri &
Ramakrishnan 1991). Stratified negation. Aggregation library (count,
sum, min, max, avg — DLG-O1 resolved here). Session-local EDB for
`assert`/`retract`. Predicate signatures are typed via the schema
registry (`schema-registry.md` §7), so every query is type-checked
before evaluation. Runs in the shell process; graph access via
`TypedGraph` effect (FS §7.2).

### R227 — `.pds` script format + module loading (SH-D10)
Header pragmas (`#capability`, `#requires-paideia`, `#import`,
`#schema`, `#ascii`). Script bodies use REPL syntax. Type-check-at-load
runs R225 on the whole script; failure aborts load. Imports are functor
applications; hygiene (per P7) prevents accidental capture. Cyclic-
import detection via the module dependency graph.

### R228 — Tab completion via schema registry + FS graph (SH-D7 sub)
Completion protocol modeled on LSP `textDocument/completion`. Sources:
command registry (names + arg/flag names + types), FS typed graph
(path completion), schema registry (field completion inside pipeline
records, predicate name completion inside `datalog { … }`), session
history (recently used values). Fuzzy matching. Latency budget: ≤50ms
per completion query (per `semantic-shell.md` §14).

### R229 — REPL evaluator loop + session-scoped bindings (SH-D7)
The `{parse → typecheck → elaborate → execute}` pipeline for one REPL
turn. Session-scoped bindings survive turns; the type environment is
threaded across turns. Job control (`&`, `bg`, `fg`, `jobs`). History
storage (CoW FS file per `history-storage.md`). Line editor with the
emacs + vi bindings from `editor-bindings.md`. Renderer switches
between Kitty and ANSI-256 via the substrate's capability-detection
seam (osarch owns detection; this round consumes the answer). Per-turn
wire fingerprint via P9 — the anti-fabrication witness that lets
`debugger` verify the REPL actually did what softarch claims.

---

## 4. Per-round milestone tables

Legend: **RC** = round code; **Acceptance** = compile clean + runnable
example + wire fingerprint where the REPL can emit; **Blocks** = list of
gates. Target repos default to `paideia-os/paideia-os` unless noted.

### R220 — paideia-as substrate for hosted DSLs (target repo: `paideia-as`)

| Milestone | Title | Task brief | Acceptance | Issues | Blocked by | Target |
|---|---|---|---|---|---|---|
| R220.M1 | Elaborator reflection surface: `Syntax` type + `Elab` effect | Land the type `Syntax`, quote/anti-quote parser support (`` `(…) `` and `${…}`), the `Elab` effect signature (get-expected-type, get-expected-effects, elab-error, elab-warn), and a walker API over the surface AST. Follow Christiansen & Brady 2016 for the shape. | `paideia-as check` accepts a hosted-macro fixture; canary fixture emits an ELF that returns the elaborated form's checksum as its exit code. | 4 | — | `paideia-as` |
| R220.M2 | Hygiene (Ullrich 2020) exposed to reflected macros | Wire the phase-1 alpha-rename pass through the reflected `Syntax` API so a hosted DSL cannot accidentally capture use-site names or leak macro-scope names. | Test corpus: 20 potential-capture forms elaborate hygienically; property test asserts no accidental capture over 10k random forms. | 4 | R220.M1 | `paideia-as` |
| R220.M3 | Reflected-parser attachment point | Provide the `@dsl_parser("<name>")` attribute a paideia-as module can carry to register its `parse` function as an elaborator plug-in. This is the seat the shell sits in. | Fixture: a trivial `numeric` DSL (`num { 1 + 2 * 3 }`) parses via a reflected plug-in and elaborates to a normal paideia-as `u64`. | 4 | R220.M1, R220.M2 | `paideia-as` |
| R220.M4 | Str::eq (byte, NFC-normalized) — `#998b` close-out | Land `Str::eq` on the stdlib `Str` type. NFC normalization at the eq boundary (per SH-D9). | 15 unit tests: identical bytes, distinct NFC-canonical-equal forms, case-different, empty, giant. Fingerprint per test. | 2 | R220.M1 | `paideia-as` |
| R220.M5 | Str::hash (FNV-1a-64 interim) — `#998c` close-out | Land `Str::hash` returning `u64` via FNV-1a-64 over the NFC-normalized bytes (matches `schema-registry.md` §3). BLAKE3 upgrade is a follow-up round when the intrinsic lands. | Vector tests vs `schema-registry.md` §3 constants; 100 collision-cluster property tests. | 2 | R220.M4 | `paideia-as` |
| R220.M6 | Generic `HashMap<K, V>` stdlib module | Lift the per-fixture u64→u64 canary of `#1003` into a real `HashMap<K, V>` where K: `Hash + Eq` and V: any 8- or 16-byte value. Bucket resize, linear probing, `Option<V>` returns. | Fixture: `HashMap<Str, u64>` with 100 puts + gets; fingerprint per bucket-fill percentile. | 6 | R220.M4, R220.M5 | `paideia-as` |
| R220.M7 | Closure-typed value slot in HashMap | Widen HashMap's value slot to hold a 16-byte closure fat-pointer; provide `HashMap<Str, |A|->R>` specialization. Needed for command-name → closure dispatch (the SH-D5 target shape). | Fixture: 30 named handlers keyed by `Str`, dispatch on one → exit code matches the chosen handler. | 3 | R220.M6 | `paideia-as` |
| R220.M8 | Effect-row inference at call sites — close `#1356` | The open half of `v0.25-session-functors`. At each call site, infer the callee's effect row and unify with the caller's declared row; propagate row-polymorphic variables. | 40-test corpus of caller/callee effect-row shapes; every case elaborates or emits the correct `E0410`-family diagnostic. | 3 | R220.M1 | `paideia-as` |
| R220.M9 | LSP-embed API for hosted DSLs | An in-process handle by which a reflected DSL pushes its own diagnostics through `paideia-lsp`'s router. Reuses the SARIF writer. | The `numeric` DSL fixture from M3 raises a hosted `E9001` diagnostic; the LSP client sees it as a normal LSP diagnostic with correct span. | 4 | R220.M1 | `paideia-as` |
| R220.M10 | `@fingerprint("<name>")` intrinsic | An elaborator API a hosted DSL uses to stamp a per-turn wire fingerprint (matching the anti-fabrication pattern kernel-side per `feedback_workerbee_verify_claims.md`). | Fixture calls `@fingerprint("test.turn.001")`; a byte-string appears on the serial log at run time; `debugger` recognizes the shape. | 2 | R220.M1 | `paideia-as` |
| R220.M11 | Rank-restricted let-polymorphism spec + implementation | Formalize the sound subset of HM that keeps inference decidable across shell/pipeline/Datalog/lambda composition; land the elaborator's restriction check. | Spec doc in `tools/paideia-as/design/toolchain/rank-restricted-hm.md`; 60-test corpus (accept + reject cases with diagnostic codes). | 4 | R220.M8 | `paideia-as` |
| R220.M12 | CHANGELOG + version + tag alignment | Per `feedback_paideia_as_version_discipline.md`: workspace.version bump + tag + CHANGELOG entry per unblock at round close. Cross-repo submodule bump to paideia-os. | `find-paideia-as.sh` strict check green; paideia-os submodule pointer updated. | 2 | all above | `paideia-as` + `paideia-os` |

**R220 total: ~40 issues on paideia-as, ~2 on paideia-os for submodule
bump = ~42 issues.** (The § 2 estimate of ~50 counts CHANGELOG scaffolding
per-milestone; §4's table names the load-bearing work.)

### R221 — Unicode-aware lexer, unified AST, context machinery (SH-D9, SH-D1)

| Milestone | Title | Task brief | Acceptance | Issues | Blocked by | Target |
|---|---|---|---|---|---|---|
| R221.M1 | UTF-8 decoder + NFC normalizer | Read UTF-8 input, normalize to NFC at the parse boundary (per SH-D9.4). Depend on stdlib `Str` (R220.M4). | Unicode TR#15 conformance vectors pass; fingerprint per test. | 4 | R220.M4 | `paideia-os` |
| R221.M2 | TR#29 grapheme cluster boundary iterator | Cursor-position math for the line editor; argument tokenization. Table-driven from a shipped Unicode Character Database subset. | TR#29 conformance vectors pass; 100 kg/s throughput on a synthetic corpus. | 6 | R221.M1 | `paideia-os` |
| R221.M3 | TR#11 width table for renderer | East-Asian width + combining-mark handling; drives cursor advance and column math. | TR#11 conformance vectors pass; visual test corpus of 50 mixed strings. | 4 | R221.M2 | `paideia-os` |
| R221.M4 | Context-tracking lexer (Pipeline / Datalog / Lambda) | State machine that switches contexts at `datalog { … }` and `{ |args| body }` delimiters. Nested contexts (a lambda inside Datalog inside a pipeline) tracked as a stack. | 40-example lexer fixture; every token stream matches the expected context-sequence. | 8 | R221.M2, R220.M3 | `paideia-os` |
| R221.M5 | Unified AST sum type + node constructors | One `SyntaxNode` enum spanning pipeline stages, Datalog atoms/goals/rules, lambda expressions, records, literals. Source spans on every node (per Q-A5 invariant). | Parser round-trip test: 100 sample inputs parse to AST and pretty-print to byte-identical output. | 10 | R221.M4 | `paideia-os` |
| R221.M6 | Source-span tracking through NFC normalization | Preserve mapping from post-NFC AST spans back to pre-NFC byte ranges — needed for LSP diagnostics on user's original bytes. | 20 NFC-transforming test inputs; every AST node's span round-trips to a valid original range. | 3 | R221.M1, R221.M5 | `paideia-os` |
| R221.M7 | Fuzz corpus for parser + Unicode | Malformed UTF-8, malformed NFC, adversarial delimiter nesting. Per `semantic-shell.md` §15.6 — parser must not crash. | 24-hour AFL run finds no crash; corpus checked in under `tests/shell/parser-fuzz/`. | 6 | R221.M5 | `paideia-os` |

**R221 total: ~41 issues.**

### R222 — Command-module functor surface + registry client (SH-D5)

| Milestone | Title | Task brief | Acceptance | Issues | Blocked by | Target |
|---|---|---|---|---|---|---|
| R222.M1 | `SchemasSig` signature body | ML signature naming the schemas a command may consume and produce; typed by `schema-registry.md` fingerprints. | Fixture: `SchemasSig` for `FileSchema`, `RawByteChunk@0.1` elaborates; canary emits its fingerprints. | 3 | R220.M1 | `paideia-os` |
| R222.M2 | `CommandSig` signature body | The functor-return signature: `name`, `input_schema`, `output_schema`, `arguments`, `flags`, `effects`, `required_capabilities`, `execute` op per `semantic-shell.md` §6.1. | Reference implementation: `Find : CommandSig` matches shape verbatim; type-checks. | 4 | R222.M1 | `paideia-os` |
| R222.M3 | Functor instantiation at REPL prompt | When the user types `find .`, resolve `find` to its functor, instantiate against the session's schemas, elaborate the arguments, invoke `execute`. | Runnable: `find .` returns the same file list as legacy `/bin/ls`, formatted as records. Fingerprint per invocation. | 4 | R222.M2, R220.M7 | `paideia-os` |
| R222.M4 | ArgSpec + FlagSpec typing | HM-typed argument and flag descriptors; positional vs `--named`; type-check user input against the ArgSpec at parse time. | 20-test corpus of well-typed and ill-typed arg lists; error diagnostics reference the ArgSpec source span. | 4 | R222.M2 | `paideia-os` |
| R222.M5 | Command registry client + supervisor RPC | Per `command-registry.md`: read `/system/shell/commands.toml`, per-user shadow at `/users/<u>/shell/commands.toml`. Load functor references. | Fixture: seed 5 commands, look up each by name in ≤50µs; user-shadow test. | 6 | R220.M7, R222.M2 | `paideia-os` |
| R222.M6 | Light vs heavy dispatch | Framework decides at load-time from declared resource needs; light commands elaborate in-process, heavy commands spawn a separate process using the substrate's process-model seam (owned by osarch). | 4-command test: `where`/`sort` land as light (in-process function call); `find`/`grep` land as heavy (process spawn). Fingerprint per dispatch decision. | 5 | R222.M5 | `paideia-os` |
| R222.M7 | Legacy `/bin/sh` shim + `legacy-sh` alias | Keep the current POSIX-shaped `src/user/shell.pdx` alive under the alias `legacy-sh` for the duration of R222..R229. New shell mounts at `/bin/sh` behind a `PDX_SHELL_MODE=semantic` env-var gate; flip default at R229 close. | Both shells bootable side by side; smoke test runs `PDX_SHELL_MODE=legacy /bin/sh -c 'ls'` and `PDX_SHELL_MODE=semantic /bin/sh -c 'ls'` — both succeed. | 3 | R222.M3 | `paideia-os` |
| R222.M8 | Command signature wire format for discovery | Serialize `CommandSig` to a queryable form so `describe find` or `commands operating on FileSchema` return typed answers (the "semantically queryable" feature applied to commands themselves per `semantic-shell.md` §6.4). | Fixture: 5 CommandSigs serialize + deserialize byte-identically; `describe find` returns the right ArgSpec set. | 3 | R222.M2 | `paideia-os` |

**R222 total: ~32 issues.**

### R223 — Pipeline literal syntax (part of SH-D3)

| Milestone | Title | Task brief | Acceptance | Issues | Blocked by | Target |
|---|---|---|---|---|---|---|
| R223.M1 | Parser for pipeline stages + `|` operator | Given a token stream from R221, produce a pipeline AST: sequence of stages, positional args, `--flags`, `@hostname` annotations. | 30-test parser corpus; every input round-trips to canonical form. | 5 | R221.M5 | `paideia-os` |
| R223.M2 | Record projection + `select` / `project` | Column-selection combinator with type-derived output schema; new schema registered on the fly if not present. | Runnable: `find . | select name, size` emits a 2-column record stream; fingerprint per row schema. | 3 | R223.M1, R222.M3 | `paideia-os` |
| R223.M3 | `where` / `filter` with lambda predicate | Filter combinator; predicate is a lambda from R224 (or `by size > 1.MB` shorthand). | 15-test filter corpus; each shows correct rows retained. | 3 | R223.M2, R224.M3 | `paideia-os` |
| R223.M4 | `sort by` + `group by` + `reduce` | Standard combinators. `sort by size desc`; `group by ext`; `reduce { |acc, r| acc + r.size } 0`. | 10-test corpus each; runtime perf ≥100 kg/s per `semantic-shell.md` §14. | 8 | R223.M2 | `paideia-os` |
| R223.M5 | Wire-format sink (Cap'n Proto) | Serialize records to `wire-format.md`'s Cap'n Proto schema at process/host boundaries. Substrate half (osarch) provides the transport. | Cross-process pipeline `find . | @remote sort by size` fingerprint-round-trips; wire bytes match schema. | 4 | R223.M2 | `paideia-os` |
| R223.M6 | `@hostname` annotation parse + type | Parse-only in this round; substrate half wires the actual encrypted transport. | 8-test corpus of `@host stage | local stage` variants parses and type-checks. | 3 | R223.M1 | `paideia-os` |
| R223.M7 | Session-typed edge protocol enforcement | Each pipeline edge has a session type derived from the producing stage's output schema; consumer's input session-type must be dual (per IPC doc §6.3). | Adversarial test: 10 pipelines with mismatched edge session-types all fail type-check with `E0710`-family diagnostic. | 3 | R223.M2, R225.M4 | `paideia-os` |
| R223.M8 | Backpressure integration with IPC slot-cap economy | Sink into IPC `wait-free-dataflow.md` §8 slot caps; substrate half owns the actual cap-return; shell drives producer pacing. | Load test: 10k-record pipeline under a slow consumer completes without OOM; producer pauses observed. | 3 | R223.M5 | `paideia-os` |
| R223.M9 | Per-stage fingerprint emission | Every pipeline stage stamps a `@fingerprint` at open + close via P9; adversarial-verification hook per memory. | 20-pipeline smoke test emits 2N fingerprints; debugger correlates them. | 3 | R220.M10 | `paideia-os` |

**R223 total: ~35 issues.**

### R224 — Lambda surface (part of SH-D2/D5)

| Milestone | Title | Task brief | Acceptance | Issues | Blocked by | Target |
|---|---|---|---|---|---|---|
| R224.M1 | Lambda literal grammar | Both `{ |args| body }` and `\args -> body` forms per `semantic-shell.md` §2.1. Argument patterns can destructure records. | 20-test parser corpus; both forms parse to same AST. | 3 | R221.M5 | `paideia-os` |
| R224.M2 | Closure over pipeline-scope bindings | Capture pipeline-scope bindings by reference (per Q13 in-process by-ref); capture across process boundary requires explicit `[binding]` capture list (which serializes). | 15-test corpus of intra- and cross-process closures. | 4 | R220.M7, R224.M1 | `paideia-os` |
| R224.M3 | Effect polymorphism per Q-A3 | Lambdas quantify over effect rows; effect-set inferred at call site via P6. | 15-test corpus; each lambda's inferred effect row matches expected. | 5 | R220.M8 | `paideia-os` |
| R224.M4 | Capability-row typing per pillar 6 | Lambdas carry a capability row (subset of Q-A2 substructural lattice); executing a lambda checks the environment holds the row. | Adversarial test: 8 lambdas asking for capabilities absent from env fail type-check with `E0820`-family diagnostic. | 5 | R220.M8 | `paideia-os` |
| R224.M5 | Nested lambda + let-in scoping | Standard HM shadowing; recursion via `let rec`. | 12-test corpus. | 3 | R224.M1 | `paideia-os` |
| R224.M6 | Lambda as first-class value in pipeline | A lambda flows through `|` like any other value; higher-order combinators (`filter`/`sort by` from R223) accept them. | End-to-end: `find . | filter { |f| f.size > 1.MB } | sort by { |f| f.size } desc` runs; fingerprint per turn. | 3 | R224.M2, R223.M4 | `paideia-os` |
| R224.M7 | Linear/affine interaction with substructural lattice | A lambda closing over a linear value is itself linear (Walker 2005 propagation rule). Verified at elaborator time. | 10-test corpus of linear-capture cases; each classifies correctly. | 4 | R224.M2 | `paideia-os` |

**R224 total: ~27 issues.**

### R225 — Unified HM type checker across three sub-languages (SH-D2)

| Milestone | Title | Task brief | Acceptance | Issues | Blocked by | Target |
|---|---|---|---|---|---|---|
| R225.M1 | HM algorithm W core | Standard Damas-Milner 1982 algorithm; unification with occurs-check; principal-type derivation for the pure lambda subset. | 100-test corpus of Damas-Milner examples; each produces the principal type. | 6 | R220.M11 | `paideia-os` |
| R225.M2 | Pipeline-record row types | Row polymorphism (Rémy-style) for records with named fields; row extension/restriction operators; record concatenation. | 40-test corpus; row-inference examples produce principal types. | 6 | R225.M1 | `paideia-os` |
| R225.M3 | Datalog predicate types via schema registry | Each predicate's arity+types come from the schema registry (`schema-registry.md`); logic-variable types unified across goals in one query. | 30-test corpus; ill-typed queries emit `E0900`-family diagnostic referencing the schema. | 5 | R225.M1, R226.M2 | `paideia-os` |
| R225.M4 | Effect-row unification | Row polymorphism extended to effect rows; unification with row variables and with rank-restricted quantifiers (per P10). | 30-test corpus; effect-row unification produces least effect satisfying constraints. | 5 | R225.M1, R220.M8 | `paideia-os` |
| R225.M5 | Cross-context type flow | A Datalog `?var` escaping to pipeline context takes the predicate's argument type; a pipeline record entering `datalog { … }` becomes a ground term of the record's row schema. | 25-test corpus of cross-context values; each type-checks with the derived type. | 8 | R225.M2, R225.M3 | `paideia-os` |
| R225.M6 | Rank-restricted let-polymorphism enforcement | Reject let-generalization sites that would require rank-2 or higher (per P10 spec). Diagnostic explains the workaround (explicit annotation at the boundary). | 20-test corpus of rank-boundary cases; each rejected with `E0980`-family diagnostic. | 5 | R220.M11 | `paideia-os` |
| R225.M7 | Error reporting with source spans + suggestions | Every type error carries primary + secondary spans, expected-vs-actual, and a suggestion when derivable. Emit via P8 LSP-embed. | 60-error test corpus; each diagnostic matches the golden expected form; LSP client renders correctly. | 5 | R220.M9 | `paideia-os` |
| R225.M8 | LSP hover integration | On hover in the line editor, show the inferred type + effect row + capability row for the token under cursor. | Interactive test: hover on 10 sample expressions returns the expected inference. | 3 | R220.M9 | `paideia-os` |
| R225.M9 | Property-based test corpus | Well-typed programs never fail; ill-typed programs always emit at least one error; effect rows compose correctly across stages. | 10k random-program corpus passes; 24-hour run finds no soundness violation. | 6 | R225.M6 | `paideia-os` |
| R225.M10 | Per-turn type-check fingerprint | Every REPL turn's checker run emits `@fingerprint("check.<turn-id>.<result>")` for adversarial verification. | 200-turn REPL session emits 200 fingerprints; debugger correlates. | 3 | R220.M10 | `paideia-os` |

**R225 total: ~52 issues.** (This is deliberately the largest round — HM
across three sub-languages is the plan's single hardest theoretical
piece, and understating it here would be a lie.)

### R226 — Datalog evaluator (SH-D4)

| Milestone | Title | Task brief | Acceptance | Issues | Blocked by | Target |
|---|---|---|---|---|---|---|
| R226.M1 | Datalog parser (facts, rules, queries) | Parse `datalog { … }` block per `datalog-spec.md`: atoms, goals, rules, `?var`, `$expr`, negation, aggregation. | 40-test parser corpus; every valid input round-trips; every invalid input fails with `E1000`-family. | 5 | R221.M4 | `paideia-os` |
| R226.M2 | Predicate-type resolution against schema registry | Look up each predicate's typed arity; register a predicate as user-defined if not in the schema; type-check argument positions. | 30-test corpus; correct type assignment for all predicates. | 4 | R220.M4, R225.M3 | `paideia-os` |
| R226.M3 | Bottom-up semi-naive evaluator | Fixpoint over deltas per standard Datalog literature. | Standard Datalog test suite (Abiteboul-Hull-Vianu chapter examples) all pass; perf ≥1M facts/sec selective. | 6 | R226.M2 | `paideia-os` |
| R226.M4 | Magic-set rewriting | Beeri & Ramakrishnan 1991. Goal-directed rewrite so only relevant tuples are computed. | 20-test corpus with 10x-100x speedup vs. naive fixpoint on goal-directed queries. | 5 | R226.M3 | `paideia-os` |
| R226.M5 | Stratified negation | Compute strata; refuse queries whose stratification would require negation-through-recursion. | 15-test corpus of stratifiable + non-stratifiable queries. | 3 | R226.M3 | `paideia-os` |
| R226.M6 | Aggregation library (count/sum/min/max/avg) | Closes `DLG-O1`. Aggregators pass through a stream of satisfying assignments. | 20-test corpus; each aggregate returns the correct value. | 5 | R226.M3 | `paideia-os` |
| R226.M7 | Graph-traversal via TypedGraph effect | Connect to FS `TypedGraph` effect (per FS §7.2). Query lifts to graph walks with typed-index use. | Fixture: `datalog { child_of(?a, "/etc") }` walks the FS graph and returns children. | 5 | R226.M3 | `paideia-os` |
| R226.M8 | Session-local EDB (assert/retract) | User-defined facts scoped to the session; survive across REPL turns; drop at session end. | 10-turn test asserting and querying user facts; retract removes them. | 3 | R226.M3 | `paideia-os` |
| R226.M9 | Query-time type-check + rejection | Untyped predicates or type-mismatched arguments produce diagnostics referencing the schema. | 15-test corpus of ill-typed queries; each caught with `E1020`-family. | 4 | R226.M2 | `paideia-os` |
| R226.M10 | Progress emission for long queries | Long-running queries emit partial results via the typed-stream output so the REPL renderer can show progress. | Test with 1M-fact query; partial-result stream observed at 100ms intervals. | 2 | R226.M3 | `paideia-os` |
| R226.M11 | Per-query fingerprint | Every query emits `@fingerprint("dlg.<query-id>.<result-count>")`. | Datalog smoke suite emits fingerprints; debugger correlates. | 2 | R220.M10 | `paideia-os` |

**R226 total: ~44 issues.**

### R227 — `.pds` script format + module loading (SH-D10)

| Milestone | Title | Task brief | Acceptance | Issues | Blocked by | Target |
|---|---|---|---|---|---|---|
| R227.M1 | Header pragma parser | Parse `#capability`, `#requires-paideia`, `#import`, `#schema`, `#ascii` per `pds-format.md`. | 15-header test corpus; each pragma normalizes correctly. | 4 | R221.M5 | `paideia-os` |
| R227.M2 | Capability-declaration checker | Verify declared caps are a subset of invoker's caps at load time; fail load if not. | 12-test corpus of superset and subset cases. | 3 | R227.M1 | `paideia-os` |
| R227.M3 | Import resolution + module graph | `#import "path" as name`; resolve against project + system paths; build dependency graph; detect cycles. | 20-test corpus; correct resolution, error on cycle with `E1100`-family. | 5 | R220.M7, R227.M1 | `paideia-os` |
| R227.M4 | Type-check-at-load pipeline | Run R225 on the whole script pre-execution; fail load on any type error. | Fixture: 5 well-typed scripts load; 5 ill-typed scripts fail with span-carrying diagnostic. | 4 | R225.M9 | `paideia-os` |
| R227.M5 | Functor-typed script modules | Scripts elaborate to a functor whose parameters are `#capability`-declared capabilities; imports apply the functor. | Fixture: `util.pds` exports `process_pdfs`; `caller.pds` imports and calls it. | 4 | R227.M3 | `paideia-os` |
| R227.M6 | Version pragma + resolution | `#requires-paideia >= X.Y` compared against the running system version. | 8-test corpus of matching + mismatching versions. | 2 | R227.M1 | `paideia-os` |
| R227.M7 | Script-body binary cache | Cache the elaborated script under `~/.paideia/script-cache/<hash>.pdc`; invalidate on source or dependency change. | Fixture: 1000-line script's second load is ≥10x faster than first. | 3 | R227.M4 | `paideia-os` |
| R227.M8 | Script load fingerprint | Emit `@fingerprint("pds.load.<script-hash>")` at each load. | 5-script load test emits 5 fingerprints. | 2 | R220.M10 | `paideia-os` |

**R227 total: ~27 issues.**

### R228 — Tab completion via schema registry + FS graph (SH-D7 sub)

| Milestone | Title | Task brief | Acceptance | Issues | Blocked by | Target |
|---|---|---|---|---|---|---|
| R228.M1 | Completion protocol (LSP-style) | In-process RPC between line editor and completion engine; request carries partial input + cursor position; response is candidate list with type info. | 30-test corpus; each request returns expected candidates. | 3 | R220.M9 | `paideia-os` |
| R228.M2 | Command-name completion source | Query the command registry for names matching prefix; include arg/flag signatures in the candidate's typed payload. | Fixture: type `fin<TAB>` → suggests `find`; `find --<TAB>` → suggests all flags with types. | 3 | R222.M5 | `paideia-os` |
| R228.M3 | Path completion via FS typed graph | Query FS graph for node names under the current directory; distinguish files/directories via typed edges. | Fixture: `ls /et<TAB>` suggests `/etc/`; `ls /etc/pas<TAB>` suggests `passwd`. Latency ≤50ms. | 4 | R222.M5 | `paideia-os` |
| R228.M4 | Record-field completion via schema registry | Inside a pipeline stage, complete field names against the incoming stream's schema. | Fixture: `find . | select nam<TAB>` → suggests `name`. | 4 | R222.M8, R223.M2 | `paideia-os` |
| R228.M5 | Datalog predicate completion | Inside `datalog { … }`, complete predicate names against schema registry + user-defined. | Fixture: `datalog { fi<TAB>` → suggests `file`, `filter`, etc. | 3 | R226.M2 | `paideia-os` |
| R228.M6 | Fuzzy matching | Non-prefix matching with a scoring function (fzf-like). | 20-fuzzy-input corpus; ranking is stable and matches golden. | 3 | R228.M1 | `paideia-os` |
| R228.M7 | Completion cache + eviction | LRU cache of recent completions keyed by (context, prefix); TTL 60s. | Fixture: same completion twice → second is ≥100x faster. | 3 | R228.M1 | `paideia-os` |
| R228.M8 | Latency budget verification | Bench 1000 completion queries; assert P99 ≤50ms per `semantic-shell.md` §14. | Bench asset stored under `bench/shell/completion/`; CI check green. | 2 | all above | `paideia-os` |

**R228 total: ~25 issues.**

### R229 — REPL evaluator loop + session-scoped bindings (SH-D7)

| Milestone | Title | Task brief | Acceptance | Issues | Blocked by | Target |
|---|---|---|---|---|---|---|
| R229.M1 | Session process + prompt loop | REPL process owns capability env, terminal channel, session-scoped state. Prompt shows cwd, cap-summary, active-jobs count. | Bootable: `PDX_SHELL_MODE=semantic /bin/sh` presents prompt; each turn logs a fingerprint. | 3 | R222.M7 | `paideia-os` |
| R229.M2 | Session-scoped bindings across turns | `let x = find . | count` at turn N persists to turn N+1; type environment threads across. | 20-turn test; every let-binding survives until session end or explicit unset. | 4 | R225.M1 | `paideia-os` |
| R229.M3 | Type environment threading | Session-scoped type schemes persist; monomorphized specializations reused for perf. | 15-turn test with polymorphic bindings; specializations correctly reused. | 4 | R225.M1 | `paideia-os` |
| R229.M4 | Job control (`&`, `bg`, `fg`, `jobs`) | Background commands run as separate scheduled threads; prompt shows count. | 10-job test; each transitions correctly through states; fingerprint per state transition. | 3 | R229.M1 | `paideia-os` |
| R229.M5 | History storage (CoW FS file per `history-storage.md`) | Per-user history file; records command, cap env, result summary; searchable. | 100-turn session persists to CoW file; `C-r` search finds turn 42. | 3 | R229.M1 | `paideia-os` |
| R229.M6 | Line editor: emacs mode bindings | All bindings from `editor-bindings.md` §1; multi-line editing with syntax highlighting. | Interactive test: every binding produces the expected edit. | 6 | R221.M2 | `paideia-os` |
| R229.M7 | Line editor: vi mode bindings | All bindings from `editor-bindings.md` §2; modal state; operators × motions. | Interactive test: standard vi motion set produces expected edits. | 6 | R229.M6 | `paideia-os` |
| R229.M8 | Multi-line input for incomplete expressions | If parser signals "incomplete" (unclosed `{`, `datalog {`, `\`), prompt continues on next line with a continuation marker. | 15-multi-line test corpus; each expression completes correctly. | 3 | R221.M4 | `paideia-os` |
| R229.M9 | Renderer integration (Kitty vs ANSI-256) | Consume the substrate's terminal-capability answer (osarch owns detection); route output through Kitty or ANSI-256 path per `semantic-shell.md` §9. | Test on Kitty + xterm-256color; both render tables correctly. | 3 | osarch's substrate half | `paideia-os` |
| R229.M10 | Per-turn wire fingerprint | Every REPL turn emits `@fingerprint("turn.<id>.<result-hash>")` per P9. This is the debugger's principal anti-fabrication hook. | 500-turn smoke session emits 500 fingerprints; debugger correlates each with its expected result. | 3 | R220.M10 | `paideia-os` |
| R229.M11 | Legacy shell retirement | Once R229.M10 is green, flip `/bin/sh` default from `legacy-sh` to the semantic shell. Keep `legacy-sh` alive as an alias for one release cycle. | Boot smoke: `/bin/sh` is semantic; `legacy-sh` still works. | 2 | R229.M10 | `paideia-os` |

**R229 total: ~40 issues.**

---

## 5. Cross-repo cascade shape

The plan is dominated by `paideia-os` work; `paideia-as` sees one large
wave at R220 and small follow-on landings when a hosted-DSL escape hatch
needs a new primitive.

```
   paideia-as                          paideia-os
   ──────────                          ──────────
   R220 (P1..P10)  ──── submodule ───▶ R221 opens
                     bump + tag         (lexer/AST)
   ┌───────────────────────────────┐
   │ backtrack cascade shape:      │
   │  paideia-os gap discovered    │
   │  during R221..R229 →          │
   │  file paideia-as issue,       │
   │  land fix, bump submodule,    │
   │  resume paideia-os round      │
   │  (per                          │
   │  feedback_cross_repo_escalation.md)
   └───────────────────────────────┘
```

Every round's acceptance criterion asks for a wire fingerprint (P9);
`debugger` uses these to adversarially verify softarch's diff summaries
per `feedback_workerbee_verify_claims.md` and the current
`feedback_paideia_os_loop_shape.md` (softarch → main build → debugger
each iteration).

Per-round CHANGELOG discipline: paideia-as uses parallel scratch
pattern (`feedback_paideia_as_parallel_changelog.md`); paideia-os uses
compact commit messages (`feedback_compact_commit_messages.md`); every
finalized design doc is committed and pushed
(`feedback_always_commit_push_docs.md`).

Cross-round backtracks are expected. Prime example: R225.M4 (effect-row
unification) may expose that P6's inference algorithm is insufficient
for the row-polymorphism the shell needs — in that case, file a
paideia-as follow-on issue, land, submodule-bump, resume R225 (this is
the classical cross-repo-escalation shape).

---

## 6. Risk register

| # | Risk | Likelihood × Impact | Mitigation |
|---|---|---|---|
| R1 | **Elaborator-reflection scope creep** (P1). Reflection is one of the two hardest features in `paideia-as` (Q-A4 was deferred to phase 2 per `macros-phase1.md` for reason). If R220 tries to land all of Idris-style reflection, it never closes. | High × High | Freeze the R220 reflection subset spec *before* R220 opens: `Syntax` value type, quote/anti-quote, `Elab` effect with 5 operations (get-expected-type, get-expected-effects, elab-error, elab-warn, elab-emit), hygiene, and the `@dsl_parser` attachment attribute. Everything else (macro-generated modules, macro-defined effects, macro-time file I/O) is out of scope until phase 3. Ship the freeze as `design/toolchain/elaborator-reflection-r220.md` before landing the first R220 issue. |
| R2 | **HM inference across three sub-languages may be undecidable in the general case.** Row polymorphism (records + effects) with impredicative polymorphism is known-undecidable (Wells 1999); adding predicate types over a mutable schema registry compounds the hazard. | High × High | Adopt rank-restricted let-polymorphism (P10) — inference is decidable and complete for rank-1 HM (Damas-Milner 1982). At each context transition (pipeline↔Datalog↔lambda), require an explicit annotation if the inferred type would be rank-2 or higher; the annotation is the escape hatch, and the emitted diagnostic `E0980` explains it verbatim. Publish a soundness sketch in R220.M11's spec doc — this is the "informal proof" posture per `01-foundational-decisions.md` §3 tension 1. Track the corpus of forms that require explicit annotation; if it grows past 10% of realistic scripts, revisit the rank bound. |
| R3 | **Bootstrap circularity.** The shell hosts inside the elaborator, so debugging the elaborator uses the shell, which uses the elaborator… If a bug in R220 corrupts the elaborator, R221..R229 cannot debug it. | Medium × High | Keep the legacy `/bin/sh` (`src/user/shell.pdx`) alive as `legacy-sh` for the full R221..R229 duration (R222.M7 explicit milestone). Every round's debug workflow uses `legacy-sh` when the semantic shell is regressed. Only at R229.M11 is `legacy-sh` demoted to an alias; kill it only one release cycle later. |
| R4 | **Substrate seam thrash with osarch.** The substrate half owns pipeline serialization, capability flow, renderer, WASM jail, cross-host transport. If osarch and this plan diverge on the seam, both halves stall. | Medium × High | Enumerate the seam in a single tracking doc (`design/terminal/language-substrate-seam.md`) written jointly with osarch before R221 opens. Every crossing point (Cap'n Proto wire format, capability-env RPC, renderer capability-detection, WASM-jail invocation, cross-host session-typed channel) named with a versioned interface contract. Interface changes require both halves' sign-off. |
| R5 | **Datalog perf over a 1M-node FS graph.** `semantic-shell.md` §14 budgets ≤100ms for selective queries. Bottom-up semi-naive over a live typed graph is a stretch without indices. | Medium × Medium | R226.M4 (magic-set rewriting) is the primary lever; R226.M7 uses FS §7.2's `lookup_by_tag` typed indices, not full scans. Ship perf gate in bench corpus (bench/shell/datalog/) — CI fails if a benchmarked query regresses >20%. If R226 misses the 100ms budget on a representative corpus, replan the round with an added index-hint syntax. |
| R6 | **Fingerprint noise floods serial log.** Every round asks for fingerprints; the current kernel serial log is already dense. | Medium × Low | Namespace fingerprints (`turn.*`, `check.*`, `dlg.*`, `pds.*`) so the debugger can filter. Ship a fingerprint-router config that lets a dev mute categories at boot. Ship a "quiet" mode that emits only turn-boundary fingerprints for production sessions. |
| R7 | **Command-registry Str-keyed dispatch depends on P3 (`#998c`) which is P0273-deferred.** If P3 slips, R222 slips. | Medium × Medium | R220.M5 (FNV-1a-64 Str::hash) is the interim answer that unblocks R222 today; BLAKE3 upgrade is a follow-on when the intrinsic lands. R222 must NOT wait for BLAKE3. |
| R8 | **Rank-restricted HM diagnostic noise.** If explicit-annotation requirements land on >10% of realistic scripts, users experience the shell as "type-annotation-heavy" (a Haskell complaint). | Low × Medium | Track the diagnostic-frequency in R225.M9's property corpus; if >10%, spec a "boundary inference" extension in R230+ that annotates cross-context transitions automatically. Not scoped to this plan; documented as a known follow-on. |

---

## 7. Total issue count + wall-clock estimate

| Round | Issues | Focus | Wall-clock (solo, weeks) |
|---|---|---|---|
| R220 | ~50 | paideia-as substrate | 12 |
| R221 | ~41 | Unicode lexer + AST | 6 |
| R222 | ~32 | Command modules + registry | 7 |
| R223 | ~35 | Pipeline literal syntax | 6 |
| R224 | ~27 | Lambda surface | 6 |
| R225 | ~52 | Unified HM checker | 14 |
| R226 | ~44 | Datalog evaluator | 10 |
| R227 | ~27 | `.pds` scripts | 5 |
| R228 | ~25 | Tab completion | 4 |
| R229 | ~40 | REPL evaluator loop | 6 |
| **Total** | **~373** | | **~76 weeks calendar** |

Note: R221..R224 can partially overlap because their dependency
frontier converges only at R225. In an optimistic parallel-safe wave,
R221→R222 sequential + (R223‖R224) parallel drops the R221..R224
window to ~19 weeks (from 25 sequential). R225 is the single serial
node that cannot parallelize.

The 76-week estimate is aligned with `design/toolchain/milestones.md`'s
solo-developer posture and its ~5-year horizon for the full custom-
assembler + userspace stack. The semantic shell language surface fits
inside that horizon; its critical-path wall-clock is dominated by R220
(paideia-as prereqs) and R225 (HM checker) — together ~26 weeks of
concentrated work, plus ~50 weeks of parallel-safe work in R221..R229.

Cross-half wall-clock: this plan and osarch's runtime-substrate half
share only the R229 renderer integration (R229.M9) and R223's wire
format seam (R223.M5). Both halves can proceed largely independently
after the seam doc lands.

---

## 8. What this plan explicitly does NOT cover

- **Runtime substrate.** Pipeline serialization at the byte level,
  capability minting/flow, REPL process spawn/exec model, WASM jail
  invocation, Kitty rendering pipeline, Unicode substrate tables in
  the kernel, cross-host transport, and the fd-inheritance bugs
  currently open (`#2469`, `#2470`). These belong to osarch's half.
- **Phase-3 self-hosted `paideia-as-native`.** The shell targets the
  Rust-hosted `paideia-as` (phase 2). A rehost is transparent to the
  shell because the API is the reflection surface, not the
  implementation.
- **D8 advanced features** (history-as-Datalog, semantic search across
  sessions, saved-query templates, visual program builder). These are
  a phase 3+ round (R230+) per `d8-features.md`; enumerated but not
  planned here.
- **Multi-session interactions** (`multi-session.md`), **mouse mode**
  (`mouse.md`), **cross-host authentication** (`cross-host-auth.md`),
  **perf baselines** (`perf-baselines.md`). Each is a small follow-on
  round; enumerate under R230+ once the core plan lands.

---

## 9. References

- `design/terminal/semantic-shell.md` — the specification this plan
  materializes.
- `design/toolchain/custom-assembler.md` — the elaborator surface we
  host inside.
- `design/toolchain/macros-phase1.md` — the restricted phase-1 macro
  form and the phase-2 gate this plan collapses via P1.
- `design/toolchain/milestones.md` — the solo-developer calendar this
  plan aligns to.
- `design/paideia-as/v0.18-issue-999-command-dispatch-doc.md` — the
  three landed dispatch shapes.
- `design/paideia-as/v0.18-issue-1003-hash-dispatch.md` — the u64-key
  HashMap canary pattern P4/P5 lift into a generic stdlib module.
- `feedback_workerbee_verify_claims.md`,
  `feedback_paideia_os_loop_shape.md`,
  `feedback_debugger_every_iteration.md`,
  `feedback_paideia_as_version_discipline.md`,
  `feedback_cross_repo_escalation.md`,
  `feedback_compact_commit_messages.md`,
  `feedback_always_commit_push_docs.md`,
  `feedback_no_background_builds.md`,
  `feedback_paideia_as_parallel_changelog.md` — process discipline
  memories this plan honors.

---

*End of document.*
