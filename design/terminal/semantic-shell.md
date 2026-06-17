# PaideiaOS — Semantic Queryable Shell

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Architectural specification of the PaideiaOS semantic queryable shell mandated by pillar 8 and E12. Covers the three-sub-language design (typed pipelines + embedded Datalog + lambda expressions), the unified type system across them, the Q13 hybrid serialization (in-process by-reference + boundary-serialized), the Datalog evaluator over the FS's typed name-resolution graph, functor-typed command modules, the interactive REPL, rich rendering via the Kitty graphics protocol with text fallback, native Unicode handling (E13), and foreign-command execution via the WASM jail (Q9).

**Hard inputs (do not relitigate):**
- `design/00-feature-inventory.md` — E12 (semantic shell + structured pipeline runtime), E13 (Unicode), E1 (root task), E6 (typed name-resolution graph); D8 (advanced semantic-shell capabilities).
- `design/01-foundational-decisions.md` — Pillar 8 (semantic queryable + Unicode), Q9 (no POSIX; WASM jail for foreign software), Q13 (hybrid pipeline serialization: in-process by-reference + boundary-serialized).
- `design/02-development-environment.md` — Unicode test corpus; the shell is itself fuzz-tested.
- `design/toolchain/custom-assembler.md` — algebraic effects (Q-A3), functor modules (Q-A7), substructural lattice (Q-A2), elaborator reflection (Q-A4).
- `design/ipc/wait-free-dataflow.md` — session-typed channels (Q-A6); in-process by-reference works through these.
- `design/capabilities/linearity-and-tags.md` — capability flow at the shell level.
- `design/filesystem/cow-design.md` — the typed name-resolution graph (FS §7); schema registry (FS §7.4).
- `design/network/stack.md` — typed channels for network commands.
- `design/runtime/wasm-vm-jail.md` (future) — foreign-command execution.

---

## 0. Decisions summary

### 0.1 Inherited (already binding)

| Source | Constraint |
|---|---|
| Pillar 8 | Commands are *semantically queryable*. Native Unicode throughout. |
| Q13 | Pipelines pass typed records by reference within a host; serialize only at host/trust boundaries. |
| Q9 | No POSIX; foreign software runs in the WASM/VM jail. |
| E12 / E13 | Semantic shell with structured pipeline runtime; native Unicode subsystem. |
| E6 | Names are resolved via the typed name-resolution graph (FS doc §7). |
| Q-A3 / Q-A7 | Algebraic effects with handlers; ML-style functors. |
| IPC primitive | Session-typed channels are the wire format between shell processes and commands. |
| FS doc | Schemas are first-class nodes in the graph; commands can declare schemas they consume and produce. |

### 0.2 New decisions in this document

| # | Choice | Source |
|---|---|---|
| SH-Q1 | Language family: **hybrid** — typed pipelines + embedded Datalog + lambda | User choice |
| SH-D1 | The three sub-languages compose lexically: a top-level expression is in *pipeline context*; `datalog { … }` enters Datalog context; `{ |args| body }` enters lambda context. Each context's syntax is internally consistent; transitions are explicit. | Taken — minimizes confusion |
| SH-D2 | Type system: unified Hindley-Milner-style inference across the three sub-languages; Datalog terms are typed by the graph schemas they query; pipeline records are typed by their source command's output schema; lambda expressions are HM-typed. | Taken — Q-A7 + Q-A4 lineage |
| SH-D3 | Pipeline runtime implements Q13 hybrid serialization: intra-process pipes pass records by capability (zero-copy memory cap transport); pipelines crossing process/host boundaries serialize via Cap'n Proto. | Taken — Q13 literal |
| SH-D4 | Datalog evaluator: bottom-up semi-naive evaluation with magic-set rewriting for goal-directed queries; runs in the shell process; can pull data from any service exposing a graph-schema channel (the FS being the primary one). | Taken — standard modern Datalog implementation |
| SH-D5 | Command modules: each command is a functor `module Cmd(Schemas: SchemasSig)(...) : CommandSig`; the supervisor's command-registry maps command names to functor instances; commands are processes (heavy commands) or in-process functor calls (light commands). | Taken — pillar 9 |
| SH-D6 | Capability flow: shell command execution receives a *capability environment* the user has granted; commands cannot access capabilities not in the environment; capability grants are explicit at the shell level (`run --grant fs.read.home some-command`). | Taken — pillar 6 |
| SH-D7 | REPL: a process per session; line editor with rich editing; multi-line input; tab completion using the schema registry and the FS graph; history per user. | Taken — standard with semantic-shell extensions |
| SH-D8 | Rendering: Kitty graphics protocol native for rich output (images, charts, structured tables, inline media); ANSI-256 + text fallback for terminals that don't support it; no VT100-only legacy support. | Taken — pillar 5 + forward-looking |
| SH-D9 | Unicode: every string is UTF-8; the shell's parser is grapheme-cluster-aware (per Unicode Annex #29); collation per Unicode Collation Algorithm (UCA); normalization to NFC at IPC boundaries. | Taken — pillar 5 / E13 |
| SH-D10 | Scripting: shell scripts are `.pds` (PaideiaOS Shell) files with the same syntax as the REPL; scripts can be saved, type-checked at load, and executed; functor-typed script modules can be imported. | Taken |
| SH-D11 | Foreign commands: a POSIX command (`ls`, `vim`, `curl`) runs in the WASM jail (Q9) with a generated typed wrapper that converts pipeline records to argv/stdin and stdout/stderr to typed records. | Taken — Q9 |
| SH-D12 | Cross-host pipelines: when a pipeline stage targets a remote PaideiaOS host, the IPC bridge (per `wait-free-dataflow.md` §15) serializes records via Cap'n Proto over a hybrid-KEM-encrypted channel. | Taken — Q13 + PQ doc |

### 0.3 Three meta-positions

1. **Three sub-languages compose lexically, not semantically.** The shell parser switches contexts at lexical delimiters (`datalog { … }`, `{ |args| body }`); within each context, the syntax is the canonical syntax of that sub-language. Crucially, *values* flow between contexts seamlessly: a pipeline record entering a `datalog` block becomes a Datalog ground term; a logic variable bound by Datalog leaves as a pipeline value; a lambda's argument is a pipeline record. The unified type system ensures consistency across the transitions.

2. **The FS's typed name-resolution graph is the shell's substrate.** The Datalog evaluator queries the graph directly; the pipeline runtime resolves paths via the graph; the schema registry is the type oracle. A query like `find . | datalog { cited_by(?p, $it) }` works because (a) `find .` returns nodes in the graph, (b) `cited_by` is an edge label in the graph, (c) the Datalog evaluator walks the graph using the schema. Without the FS-provided typed graph, the semantic-query promise of pillar 8 is not realized.

3. **Capability flow is a first-class shell concept.** When a user runs a command, the shell does not pass *all* the user's capabilities — only the subset declared as needed. The default is least-privilege: a `find . -name '*.pdf'` gets file-read on the cwd only; a `curl https://example.com` gets network-connect to that domain only. This is a deliberate departure from POSIX shells where every process inherits the parent's full capability set. It is enforced by the shell's argument parser + the supervisor's capability minting.

---

## 1. Architectural overview

```
                  ┌────────────────────────────────────────────────────────────┐
                  │                  Shell session (process)                    │
                  │                                                              │
                  │  ┌────────────────────────────────────────────────────────┐ │
                  │  │  REPL                                                    │ │
                  │  │   - line editor with rich editing                       │ │
                  │  │   - history                                             │ │
                  │  │   - tab completion via schema registry + FS graph       │ │
                  │  └─────────────────┬──────────────────────────────────────┘ │
                  │                    │                                          │
                  │                    ▼                                          │
                  │  ┌────────────────────────────────────────────────────────┐ │
                  │  │  Parser (paideia-as elaborator-hosted)                  │ │
                  │  │   - lexical context tracking (pipeline/datalog/lambda) │ │
                  │  │   - unified AST                                          │ │
                  │  │   - source-span tracking                                │ │
                  │  └─────────────────┬──────────────────────────────────────┘ │
                  │                    │                                          │
                  │                    ▼                                          │
                  │  ┌────────────────────────────────────────────────────────┐ │
                  │  │  Type checker (HM + Datalog typing + effect inference) │ │
                  │  │   - pipeline-record type flow                            │ │
                  │  │   - Datalog predicate type checks against schemas       │ │
                  │  │   - lambda HM inference                                  │ │
                  │  │   - effect-row composition                               │ │
                  │  └─────────────────┬──────────────────────────────────────┘ │
                  │                    │                                          │
                  │                    ▼                                          │
                  │  ┌────────────────────────────────────────────────────────┐ │
                  │  │  Evaluator                                              │ │
                  │  │   ┌────────────────────────┐  ┌─────────────────────┐ │ │
                  │  │   │ Pipeline runtime       │  │ Datalog engine      │ │ │
                  │  │   │  - in-process by-ref   │  │  - bottom-up SN     │ │ │
                  │  │   │  - boundary Cap'n Proto │  │  - magic-set rewrite│ │ │
                  │  │   │  - session-typed chans │  │  - graph access     │ │ │
                  │  │   └────────────────────────┘  └─────────────────────┘ │ │
                  │  │   ┌────────────────────────┐                          │ │
                  │  │   │ Lambda evaluator       │                          │ │
                  │  │   │  - closure conversion  │                          │ │
                  │  │   │  - capability-checked   │                          │ │
                  │  │   └────────────────────────┘                          │ │
                  │  └─────────────────┬──────────────────────────────────────┘ │
                  │                    │                                          │
                  │                    ▼                                          │
                  │  ┌────────────────────────────────────────────────────────┐ │
                  │  │  Renderer                                                │ │
                  │  │   - Kitty graphics protocol for rich output             │ │
                  │  │   - ANSI-256 + text fallback                            │ │
                  │  │   - schema-driven formatting (tables, plots, trees)     │ │
                  │  └────────────────────────────────────────────────────────┘ │
                  └─────────────────────────────────────────────────────────────┘
                                       │
              ┌────────────────────────┼──────────────────────────────────┐
              │                        │                                   │
              ▼                        ▼                                   ▼
       ┌──────────────┐         ┌──────────────┐                  ┌──────────────┐
       │ Supervisor   │         │ FS server    │                  │ Command      │
       │ - cap minting│         │ - graph      │                  │ processes    │
       │ - registry   │         │ - schemas    │                  │ (one per     │
       └──────────────┘         └──────────────┘                  │ heavy cmd)   │
                                                                   └──────────────┘
```

---

## 2. The three sub-languages

### 2.1 Lexical contexts

The parser is in one of three contexts at any point:

| Context | Entered by | Syntax | Exit |
|---|---|---|---|
| **Pipeline** (top level) | Default at REPL or top of script | Stages separated by `|`; arguments space-separated; values are typed records | Newline or `;` |
| **Datalog** | `datalog { … }` | Comma-separated atoms; `?var` is a logic variable; `$expr` interpolates a pipeline value | Closing `}` |
| **Lambda** | `{ |args| body }` or `\args -> body` | HM-typed expression; can call pipeline commands, embed Datalog, do arithmetic | Closing `}` (lambda body is a single expression) |

### 2.2 Examples

#### Pipeline context (top level)

```
find . | where ext == "pdf" | sort by size desc | head 10
```

Each stage is a command; `|` is pipe; arguments to a command (e.g., `find`'s `.`) are positional; flags use `--name` syntax.

#### Embedded Datalog

```
files
  | datalog {
      tagged(?f, "research"),
      modified(?f, ?t),
      ?t > sub(now, days(30))
    }
  | sort by modified desc
```

The Datalog block produces a stream of `?f` bindings; each becomes a pipeline record. Other logic variables (`?t`) bound in the query but not consumed downstream are existentially quantified.

#### Embedded lambda

```
find .
  | filter { |f| size f > 1.MB and modified f > now - 7.days }
  | each { |f| 
      let processed = transform_pdf f
      processed
    }
  | sort by { |f| f.size } desc
```

Lambdas can:
- Take pipeline-record arguments.
- Compute with full functional power (Hindley-Milner typed).
- Embed Datalog queries via `datalog { … }`.
- Call other commands via pipeline notation.

### 2.3 Cross-context value flow

A value passes through context transitions seamlessly:

```
find .
  | datalog { cited_by(?paper, $it), author(?paper, "Knuth") }
  | filter { |f| f.size > 1.MB }
  | sort by size desc
```

- `$it` in the Datalog block refers to the current pipeline record (a file).
- `?paper` is a Datalog logic variable, scoped to the block.
- The block's output is a stream of files for which the query was satisfied.
- The filter's lambda receives each file `f` as an HM-typed value.
- The sort's `by size desc` is shorthand for `by { |f| f.size } desc`.

### 2.4 Why three contexts, not one

Each sub-language is *optimal for its domain*:

| Domain | Sub-language | Why |
|---|---|---|
| Command composition / data-stream filtering | Typed pipelines | Linear flow matches user mental model; tab-completion is straightforward; the dominant case |
| Cross-cutting graph queries with joins, recursion, negation | Datalog | Datalog is the canonical query language for this class of problem (Datalog evaluates joins efficiently; recursion is native; negation-as-failure is well-defined) |
| Aggregations, computations, predicates | Lambda | Higher-order functions over collections; HM inference; matches pillar 10 |

A single language trying to do all three (Datalog-first, FP-first, pipeline-first) sacrifices ergonomics in two of the three to optimize one. The hybrid is more code at the parser level but better at every level above.

---

## 3. Unified type system (SH-D2)

### 3.1 The type universe

The shell's type system is Hindley-Milner with extensions:
- **Pipeline-record types**: a record with named fields and types; the type is determined by the producing command's output schema.
- **Datalog predicate types**: a predicate has a typed arity `(T1, T2, ..., Tn)`; types come from the FS schema registry.
- **Function types**: HM functions with effect rows (per Q-A3).
- **Stream types**: a stream of records of a given type, with a session-type for protocol flow (per IPC primitive).
- **Capability types**: linear; declared in command signatures.

### 3.2 Inference

The type-checker runs at command line entry (before execution starts) and during interactive editing (to provide tab completion).

For pipelines: each stage's input type must match the previous stage's output type. Mismatch produces a type error referencing both stages.

For Datalog: each predicate's argument types are checked against the schema registry; logic-variable types are unified across goals.

For lambdas: standard HM inference.

For cross-context: a Datalog variable's escape into pipeline context produces a pipeline-record type derived from the predicate's argument type.

### 3.3 Effect rows

A pipeline stage's effects (e.g., `!{fs_read}`) propagate to the pipeline's overall effect set. Stages requiring effects not present in the shell session's capability environment fail type-check.

This is the type-system-level mechanism enforcing capability flow (per SH-D6): the shell knows at type-check time which capabilities each command will use.

### 3.4 Display

Type errors are presented in Rust-style with source spans, expected vs. actual types, and suggestions. The LSP protocol from the assembler (Q-A10) is reused here — the shell embeds the same LSP server for live type checking in the REPL.

---

## 4. Pipeline runtime (SH-D3, Q13)

### 4.1 In-process by-reference

When a pipeline runs entirely within one shell-session process, records pass by *capability reference*:
- Each record is a `MemCap` to an in-AS structure.
- The next stage receives the capability via a function call (intra-process).
- No serialization; no copy.

This is the fast path; suitable for the common case (a few stages, all in one shell).

### 4.2 Cross-process serialization

When a pipeline stage runs in a separate process (heavy command, foreign WASM-jail command, remote host):
- The record is serialized to Cap'n Proto.
- The bytes flow through the IPC primitive's session-typed channel.
- The receiving process deserializes back into its own typed records.

The boundary is *explicit*: the pipeline runtime knows which stages are local vs. remote and switches transports automatically.

### 4.3 Session-type discipline

Each pipeline edge has a session type derived from the schema:

```paideia-as
signature PipelineEdgeSchema =
  protocol = μX. (↑Record T | ↑Done) . X
  record_type = T
  effects = !{pipeline_send, pipeline_recv}
```

The producer sends records until done; the consumer receives until done. The session-type duality (per IPC doc §6.3) ensures producer and consumer agree on the record type.

### 4.4 Backpressure

The slot-cap economy (per IPC §8) provides natural backpressure: a slow consumer doesn't drown in records; a fast producer is paced by the consumer's drainage. Pipelines therefore handle large data streams gracefully — the shell doesn't have to implement backpressure.

### 4.5 Parallelism

A pipeline `stage1 | stage2 | stage3` runs all three stages concurrently. Each gets its own scheduling context. When stage1 produces a record, stage2 consumes; meanwhile stage1 can produce the next. This is wait-free dataflow at its best.

### 4.6 Cross-host pipelines

A pipeline crossing host boundaries:
- The pipeline runtime detects a `@hostname` annotation on a stage.
- It connects to the remote host via a hybrid-KEM-encrypted channel.
- The IPC bridge (per `wait-free-dataflow.md` §15) serializes records.
- The remote shell session runs the stage; results stream back.

Example:

```
@remote.host find . | where size > 1.GB | sort by size desc
```

The `find .` runs on `remote.host`; the `where` and `sort` run locally (or could be remote too with another annotation).

---

## 5. Datalog evaluator (SH-D4)

### 5.1 Algorithm

The evaluator implements:
- **Bottom-up semi-naive evaluation**: standard Datalog evaluation; fixpoint computation over deltas.
- **Magic-set rewriting**: for goal-directed queries (where only some bindings of the query matter), magic-set rewriting transforms the rules to compute only what's needed. Standard technique from Beeri & Ramakrishnan (1991).
- **Stratified negation**: negation-as-failure for non-recursive negation.

### 5.2 Data source

The evaluator pulls facts from:
- The FS's typed name-resolution graph (via the `TypedGraph` effect per FS §7.2).
- The current pipeline (pipeline records become Datalog tuples).
- User-defined `assert` and `retract` operations on a session-local extensional database.

### 5.3 Schema-driven type checking

Each Datalog predicate's argument types are known from the schema registry. The evaluator type-checks queries before evaluation. Untyped predicates are rejected.

### 5.4 Recursion

The evaluator supports recursive predicates:

```
datalog {
  ancestor(?x, ?y) :- parent(?x, ?y).
  ancestor(?x, ?y) :- parent(?x, ?z), ancestor(?z, ?y).
  ancestor("Knuth", ?descendant).
}
```

The fixpoint computation terminates if the underlying graph is finite (which it always is — the FS has finite nodes).

### 5.5 Performance

The evaluator's hot path is over the FS graph. The FS exposes typed indices (per FS §7.2 `lookup_by_tag`, etc.) which the evaluator uses. A query over a million-node graph with selective predicates typically completes in milliseconds.

For very large queries, the evaluator emits progress via the typed-stream output; the REPL can display partial results.

---

## 6. Command modules (SH-D5)

### 6.1 Commands as functors

Each command is a functor parameterized by the schemas and services it consumes:

```paideia-as
signature CommandSig =
  name : String
  input_schema : Option<Schema>
  output_schema : Option<Schema>
  arguments : List<ArgSpec>
  flags : List<FlagSpec>
  effects : EffectRow
  required_capabilities : CapSpec

  op execute : (input : Stream<InputRecord>,
                args : ArgValues,
                env : CapabilityEnvironment)
              -> Stream<OutputRecord>
              !{effects_declared_above}
```

Concrete commands:

```paideia-as
module Find : CommandSig = functor (Fs : FsSchemaSig) -> struct
  let name = "find"
  let input_schema = None
  let output_schema = Some FileSchema
  let arguments = [PathArg]
  let flags = [NameFlag, TypeFlag, SizeFlag, ...]
  let effects = !{fs_read, fs_enumerate}
  let required_capabilities = { fs_read_under_path }

  let execute(input, args, env) =
    let path = args.path
    Fs.enumerate_path(path, args.flags.recursive)
      |> filter args.predicates
end
```

### 6.2 Light vs heavy commands

- **Light commands**: small, fast, no major state — execute as in-process function calls. Examples: `where`, `sort`, `head`, `each`, `count`.
- **Heavy commands**: separate processes — `find` (consumes FS server), `grep` (potentially long-running, large memory), `compile`, `vim`, etc.

The framework decides at command-load time based on the command's declared resource needs.

### 6.3 Command registry

The supervisor's command registry maps name to functor instance. At shell startup, the registry is loaded; new commands installed at runtime register via a typed registration message.

Versioned: a command may have multiple versions; the user can select.

### 6.4 Command discovery

The shell's tab completion queries the registry for available commands. Each command's signature is the discovery surface:
- Command name
- Argument names + types
- Flag names + types
- Required capabilities
- Help text

This is the "semantically queryable" feature applied to commands themselves — the user can ask the shell "what commands operate on PDFs?" and get a typed answer.

---

## 7. Capability flow (SH-D6)

### 7.1 The capability environment

A shell session has a *capability environment*: the set of capabilities the user has granted to the session at login. By default:
- Read access to the user's home and a few standard paths.
- No network access.
- No write access to system locations.
- No driver capabilities.
- No supervisor capabilities.

### 7.2 Per-command capability subset

When a command runs, it receives only the subset of capabilities it declared as needed in its signature. Even if the user has broader capabilities, the command sees only its needs.

This is enforced by:
1. Type-check: the command's `required_capabilities` must be a subset of the session environment.
2. Mint: the supervisor mints child capabilities for the command, with rights bounded by the command's declaration.
3. Pass: the capabilities are passed to the command at its start.

### 7.3 Explicit grants

A user can grant additional capabilities to a command at the shell level:

```
run --grant fs.write.home/projects --grant net.connect.example.com:443 some-command
```

The grant is logged; the command receives the additional caps. The grant lasts only for that command invocation.

### 7.4 Capability-typed arguments

Some command arguments are *themselves* capabilities. Example:

```
copy <source-file> <dest-dir>
```

`copy` requires `fs_read_on_source` and `fs_write_on_dest_dir`; these are minted from the user's capabilities when the source and destination paths are resolved.

### 7.5 Why this departs from POSIX

POSIX shells inherit all parent capabilities to child processes. A common attack: a malicious tool reads the user's SSH key. PaideiaOS makes this attack impossible by construction — the tool simply does not have the capability unless the user granted it explicitly. The default-deny posture is the security model at the shell level.

---

## 8. REPL (SH-D7)

### 8.1 The REPL session

A REPL session is a process providing:
- Prompt with shell-state indicators (current directory, capability set summary, active jobs).
- Line editing with cursor movement, history, completion.
- Multi-line input for incomplete expressions.
- Output rendering (per §9).

### 8.2 Line editor

Capabilities:
- Vi-mode and Emacs-mode bindings (user choice).
- Multi-line editing with syntax highlighting.
- Inline type errors (red squiggles) as the user types, via the embedded LSP.
- Suggestions via tab.
- History via Ctrl-R search.

### 8.3 Tab completion

Tab completion uses three sources:
1. The command registry (for command names and arguments).
2. The FS's typed graph (for paths).
3. The schema registry (for record fields, Datalog predicates).

A query like `find . | where ext == "<TAB>"` would suggest known extensions from the FS schema's enumeration of file types.

### 8.4 History

History per user, stored as a CoW FS file. Searchable. The shell records:
- The command executed.
- The capability environment at execution.
- The result (success/failure, duration, output schema).

### 8.5 Job control

Background commands run as separate scheduled threads with their own pipelines. The shell tracks active jobs and presents them in the prompt.

```
find . | sort by size desc | head &
[1] running
```

### 8.6 The session as a process

The session is a process holding:
- The user's capability environment.
- A handle on the supervisor for granting/revoking.
- IPC channels to commonly-used services (FS, supervisor, audit).
- The terminal device (or terminal-emulator channel) for rendering.

Multiple sessions for the same user are independent processes; they share the user's capability set but have separate environments.

---

## 9. Rendering (SH-D8)

### 9.1 Kitty graphics protocol

The Kitty graphics protocol (developed by the Kitty terminal emulator) allows inline display of:
- Raster images (PNG, JPEG, raw RGBA).
- Vector graphics (rendered to raster at display resolution).
- Animation frames.
- Inline plots (with appropriate libraries).

PaideiaOS's renderer emits Kitty protocol sequences when the terminal supports them. Detection: query the terminal's capability via the standard XTerm `xtgettcap` extension.

### 9.2 ANSI-256 text fallback

For terminals not supporting Kitty graphics:
- 256-color ANSI tables for tabular data.
- Box-drawing Unicode characters for layout.
- Inline plot rendering as text (sparklines, ASCII charts).

### 9.3 Schema-driven formatting

The renderer uses the output's record schema to choose presentation:
- A stream of `File` records → table with columns matching the schema.
- A stream of `Image` records → inline thumbnail strip.
- A stream of `MetricPoint` records → time-series plot.
- Plain text or "unstructured" record → printed as-is.

User can override per-command:

```
find . | as table
find . | as chart by size
find . | as plain
```

### 9.4 No VT100

PaideiaOS does not include VT100-specific support. Modern terminals (xterm-256color, alacritty, kitty, wezterm) are the target. Legacy serial-console workflows where VT100 is the only option run in the WASM jail with a translation shim.

### 9.5 Unicode display

The renderer is grapheme-cluster-aware: a width calculation accounts for variation selectors, ZWJ sequences, combining marks per Unicode TR#11. Emoji and CJK display correctly without column miscounting.

---

## 10. Unicode (SH-D9, E13)

### 10.1 UTF-8 everywhere

All strings in PaideiaOS are UTF-8. The shell's parser handles UTF-8 input; the renderer handles UTF-8 output.

### 10.2 Grapheme cluster awareness

The parser uses Unicode TR#29 grapheme clustering for:
- Cursor positioning in the line editor.
- Argument tokenization.
- String length and indexing operations.

A user typing `家族` (two CJK characters, 2 grapheme clusters) sees the cursor advance two cells; the shell treats it as a 2-grapheme string.

### 10.3 UCA collation

String comparison (in `sort by`, `where x < y`) uses the Unicode Collation Algorithm with the user's locale. Default locale is `und` (no language-specific tailoring) for compatibility; user can override.

### 10.4 NFC normalization

At IPC boundaries (record send/receive), strings are normalized to NFC. This prevents "looks identical, compares unequal" bugs.

### 10.5 Bidi

The renderer handles bidirectional text (Hebrew, Arabic) per Unicode TR#9. The line editor respects logical-vs-visual order.

### 10.6 Locale and i18n

Per U16 (locale and i18n services), the shell consumes a locale capability:
- Date/time formatting.
- Number formatting.
- Currency.
- Translated command help (when translations are installed).

---

## 11. Scripting (SH-D10)

### 11.1 Shell scripts

A script is a `.pds` file (PaideiaOS Shell) with the same syntax as REPL input. Comments are `#`; pragmas allow declaring required capabilities and effect rows.

Example:

```
#! /bin/paideia-sh
#capability fs.read.home, fs.write.home/backup

find ~ 
  | where modified > now - 1.day
  | each { |f|
      copy $f.path to ~/backup/$(basename $f.path)
    }
```

### 11.2 Script type-checking

When a script is loaded:
- The parser validates syntax.
- The type checker validates types and effects.
- The capability checker verifies declared capabilities are a subset of the invoker's.
- Failures abort load.

Scripts that pass loading run with the declared capabilities only.

### 11.3 Imports

A script can import another script as a module:

```
#import "lib/util.pds" as util
util.process_pdfs(find . | where ext == "pdf")
```

Imports are functor applications under the hood; modules are first-class.

### 11.4 Versioning

Scripts can declare a minimum PaideiaOS version:

```
#requires-paideia >= 0.5
```

Mismatches produce errors before execution.

---

## 12. Foreign commands (SH-D11, Q9)

### 12.1 The WASM jail bridge

Commands written in POSIX-foreign languages (anything compiled to WASM or running in a VM jail) execute via the WASM jail (per `runtime/wasm-vm-jail.md`, future).

The bridge between PaideiaOS shell and a WASM jail command:
1. The shell type-checks the foreign command's declared schemas.
2. The shell converts input pipeline records to a foreign-language-friendly form:
   - For a POSIX `ls`: arguments are positional CLI args; input on stdin is line-separated text.
   - For a WASI command: pipeline records are serialized to the WASI WIT-typed interface.
3. The foreign command runs in the jail with the granted capability subset.
4. The bridge converts the foreign output back to typed pipeline records.

### 12.2 Example: running `curl`

```
curl https://example.com/api.json | from json | where status == "ok"
```

- `curl` is a foreign command in the WASM jail; the shell knows its output schema (string).
- `from json` parses; output is typed records.
- `where` filters using the typed structure.

The bridge handles the impedance mismatch transparently.

### 12.3 Schema annotation for foreign commands

Foreign commands are registered with schema annotations:

```toml
[command.curl]
input = "none"
output = "string"
foreign = "wasm-jail"
binary = "/jail/curl/curl.wasm"
```

The annotations make foreign commands first-class in the type system; without them, foreign commands appear as opaque text producers/consumers.

---

## 13. paideia-as implementation

### 13.1 Module layout

```
src/userspace/shell/
├── repl/
│   ├── session.s         # main REPL loop
│   ├── editor.s          # line editor
│   ├── completion.s      # tab completion
│   ├── history.s         # history management
│   └── jobs.s            # background jobs
├── parser/
│   ├── lexer.s           # context-aware lexer
│   ├── pipeline.s        # pipeline-context parser
│   ├── datalog.s         # Datalog-context parser
│   ├── lambda.s          # lambda-context parser
│   └── ast.s             # unified AST
├── typecheck/
│   ├── hm.s              # Hindley-Milner inference
│   ├── records.s         # pipeline-record typing
│   ├── datalog_types.s   # Datalog predicate typing
│   ├── effects.s         # effect-row inference
│   └── lsp.s             # LSP server wrapping the type checker
├── evaluator/
│   ├── pipeline_rt.s     # pipeline runtime
│   ├── datalog_eng.s     # Datalog evaluator
│   ├── lambda_eval.s     # lambda evaluator
│   └── boundary.s        # serialization at boundaries
├── commands/
│   ├── builtin/          # light commands as functor instances
│   └── registry.s        # command registry client
├── renderer/
│   ├── kitty.s           # Kitty graphics protocol
│   ├── ansi.s            # ANSI-256 fallback
│   ├── schema_fmt.s      # schema-driven formatting
│   └── unicode_disp.s    # Unicode display width / bidi
├── unicode/
│   ├── normalize.s       # NFC/NFD/NFKC/NFKD
│   ├── grapheme.s        # TR#29 cluster boundaries
│   ├── collate.s         # UCA collation
│   └── width.s           # TR#11 width
└── foreign/
    └── wasm_bridge.s     # foreign-command bridge (calls WASM jail)
```

### 13.2 Phase-1 vs phase-2

Phase 1 (NASM bootstrap):
- A minimal shell: pipelines, lambdas (simple), no Datalog.
- ANSI text only; no Kitty graphics.
- No tab completion; minimal history.
- A small set of built-in commands (`cd`, `ls`, `cat`, `echo`).
- ASCII-only input acceptable (for early bring-up).

Phase 2 (paideia-as coexistence):
- Full three-sub-language shell.
- Datalog evaluator.
- Kitty graphics protocol.
- Tab completion with schema registry.
- Rich command registry.
- Native Unicode (E13).
- Foreign command bridge.

Phase 3+:
- D8 advanced features (saved query templates, history-as-Datalog, semantic-search across past sessions).
- Cross-host pipelines.
- Visual program builder (drag-and-drop pipeline construction).

### 13.3 Calling convention

The shell's session process uses the standard PaideiaOS calling convention. R12 carries capabilities; R15 carries the effect environment with handlers for `Pipeline`, `Datalog`, `Lambda`, `Render`.

---

## 14. Performance considerations

| Metric | Budget | Substrate |
|---|---|---|
| REPL command-line startup latency | ≤ 20 ms | bare-metal |
| Type-check of a typical 5-stage pipeline | ≤ 10 ms | bare-metal |
| Pipeline record passing, in-process | ≤ 200 ns per record | bare-metal |
| Pipeline record passing, cross-process | ≤ 1 µs per record | bare-metal |
| Datalog query over 1M facts, selective | ≤ 100 ms | bare-metal |
| Tab completion lookup | ≤ 50 ms | bare-metal |
| Kitty graphics image emit | ≤ 50 ms per image | bare-metal |
| Unicode normalization (NFC) | ≥ 100 MB/s | bare-metal AVX-512 |

Aspirational; baselines come from `design/terminal/perf-baselines.md` (future).

---

## 15. Verification

### 15.1 Parser conformance

A test corpus of pipeline + Datalog + lambda inputs; the parser must accept valid inputs and reject invalid ones with the correct error code.

### 15.2 Type-checker correctness

Property-based tests:
- Type-checking a well-typed program produces no errors.
- Type-checking an ill-typed program produces an error referencing the actual mismatch.
- Effect rows compose correctly across stages.

### 15.3 Datalog evaluator correctness

Standard Datalog test suites; evaluator vs. spec.

### 15.4 Unicode test coverage

Per Unicode TR#41, the shell passes the standard Unicode test suite for normalization, grapheme clustering, collation, width.

### 15.5 Capability-flow tests

Adversarial tests: a script that attempts to use a capability not in its declared set must fail at load.

### 15.6 Fuzz testing

The parser is fuzz-tested per dev-env §9.5. Malformed input may produce errors but never crashes.

---

## 16. Open issues

| ID | Issue | Resolution |
|---|---|---|
| SH-O1 | The Datalog dialect — concrete syntax for negation, recursion, aggregation. | `design/terminal/datalog-spec.md` (future) |
| SH-O2 | The pipeline record's wire format — Cap'n Proto schema details. | `design/terminal/wire-format.md` (future) |
| SH-O3 | The Kitty graphics protocol's exact dialect — which extensions does PaideiaOS use? | `design/terminal/kitty-dialect.md` (future) |
| SH-O4 | Command registry storage and update — how do new commands install? | `design/terminal/command-registry.md` (future) |
| SH-O5 | The line-editor exact bindings — vi-mode and emacs-mode specs. | `design/terminal/editor-bindings.md` (future) |
| SH-O6 | History storage size and retention — per-session, per-user, global. | `design/terminal/history-storage.md` (future) |
| SH-O7 | The script `.pds` file format — header, capability declaration syntax. | `design/terminal/pds-format.md` (future) |
| SH-O8 | The semantic-search-history (D8) — phase 3+ extension. | `design/terminal/d8-features.md` (future) |
| SH-O9 | Multi-session interaction — when two sessions modify the same FS file. | `design/terminal/multi-session.md` (future) |
| SH-O10 | Mouse interaction in the REPL — supported? In which mode? | `design/terminal/mouse.md` (future) |
| SH-O11 | The locale/i18n provider — what locale data is shipped; what is downloadable. | `design/terminal/i18n-provider.md` (future) |
| SH-O12 | Performance baselines — first measurements drive `perf-baselines.md`. | `design/terminal/perf-baselines.md` (future) |
| SH-O13 | The Cross-host pipeline authentication — how does the remote shell authenticate the local user? | `design/terminal/cross-host-auth.md` (future) |

---

## 17. References

### 17.1 Modern shells

- Nushell: https://www.nushell.sh — typed pipelines lineage.
- PowerShell — typed object pipelines lineage.
- scsh (Scheme Shell) — FP-shell lineage.
- Fish — interactive ergonomics.

### 17.2 Datalog

- Beeri, C., Ramakrishnan, R. *On the Power of Magic*. PODS 1987 / J. Logic Programming 1991.
- Abiteboul, S., Hull, R., Vianu, V. *Foundations of Databases*. Addison-Wesley, 1995.
- Datomic, LogicBlox, Soufflé — production Datalog systems.

### 17.3 Type systems

- Damas, L., Milner, R. *Principal Type Schemes for Functional Programs*. POPL 1982.
- Pierce, B. *Types and Programming Languages*. MIT Press, 2002.

### 17.4 Unicode

- Unicode Standard, current version (16.x at time of writing).
- UAX #9 (Bidi), #11 (Width), #14 (Line Breaking), #15 (Normalization), #29 (Grapheme Clusters), #41 (Common References).
- Unicode Collation Algorithm (UTS #10).

### 17.5 Terminal protocols

- Kitty graphics protocol documentation.
- xterm capability documentation.
- VT-series and ECMA-48 (for historical context).

### 17.6 Pipeline architectures

- Mashey, J. *The Pipeline*. Bell Labs Technical Memoir, 1976 (historical Unix pipes).
- Naiad and Timely Dataflow (modern dataflow systems).

---

*End of document.*
