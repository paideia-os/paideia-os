# PaideiaOS — `paideia-as`: Custom Assembler Design

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Architectural specification of the custom in-house assembler (`paideia-as`) mandated by Q3 of `01-foundational-decisions.md`. Covers surface syntax, type system, effect system, macro/elaborator, IR pipeline, calling convention, module system, optimization policy, inline-asm escape policy, error reporting, object-file emission, and tooling.

**Hard inputs (do not relitigate):**
- `design/00-feature-inventory.md` — feature inventory.
- `design/01-foundational-decisions.md` — Q1 through Q15 are binding.
- `design/02-development-environment.md` — toolchain bootstrap (three-phase NASM → paideia-as), ABI versioning, DDC, build-time linearity check, DWARF requirement, ELF64 + PE/COFF emission requirement, LAM-aware capability tagging.

---

## 0. Decisions summary

### 0.1 Inherited (already binding)

| Source | Constraint |
|---|---|
| `01-foundational-decisions.md` Q3 | The assembler is a custom in-house project, not NASM or GAS. |
| `01-foundational-decisions.md` Q7 | Build-time static linearity check (E14) + LAM-backed runtime capability tags. |
| `01-foundational-decisions.md` Q11 | PQ-aware artifact signing pipeline integrates with the assembler. |
| `01-foundational-decisions.md` Q12 | 48-bit default address spaces; 57-bit opt-in per address space. |
| `02-development-environment.md` §3.1 | Must emit DWARF (`.debug_info`, `.debug_line`, ideally `.debug_frame`). |
| `02-development-environment.md` §5.1 | Must emit ELF64 (kernel image) and PE/COFF (UEFI loader). PAX format via separate linker (`paideia-link`). |
| `02-development-environment.md` §8.3 | Stages 0/1 in OCaml; stage 2 self-hosted. |
| `02-development-environment.md` §8.1–8.4 | Three-phase bootstrap (NASM → coexistence → paideia-as canonical), with cross-build smoke test in phase 2 and DDC. |
| `02-development-environment.md` §13.1 | The cross-decision tension list flagged this document as critical-path. |

### 0.2 New decisions in this document

| # | Question | Decision |
|---|---|---|
| Q-A1 | Surface syntax | Wholly novel concrete syntax designed around capability/effect notation. |
| Q-A2 | Type-system foundation | Full substructural lattice — ordered, linear, affine, unrestricted (Walker 2005). |
| Q-A3 | Effect-system model | Algebraic effects with handlers (Koka / Eff lineage). |
| Q-A4 | Macro / metaprogramming model | Typed elaborator reflection (Idris / Lean lineage). |
| Q-A5 | IR architecture | Typed multi-pass: elaborator → typed core → ANF → effect-handler-rewritten → emit. No register reallocation. |
| Q-A6 | Calling convention | Custom PaideiaOS-native convention; System V AMD64 bridge generated only at C-runtime boundaries (ACPICA bubble, WASM jail). Applications are primarily written in paideia-as, so the bridge is a niche path, not the common case. |
| Q-A7 | Module / namespace system | ML-style modules with functors and signatures. |
| Q-A8 | Inline-assembly escape | Strict `unsafe { effects; capabilities; justification }` blocks; CI-audited; declared effects/capabilities propagate to surrounding linearity and effect-closure checks. |
| Q-A9 | Optimizer policy | Elaborator evaluation as the base (constant folding, dead-branch elimination during elaboration); no machine-code rewriting by default. Additional optimization passes available as a catalog of *opt-in* annotations (`#[peephole]`, `#[schedule]`, etc.); each pass is documented and independently auditable. |
| Q-A10 | Error reporting | Structured (SARIF or project-schema JSON) + Rust-style human format + LSP server from day one. |

### 0.3 The meta-tension to acknowledge up front

The combination of decisions Q-A1–Q-A10 is *ambitious*. A wholly novel syntax, a full substructural lattice, algebraic effects with handlers, typed elaborator reflection, ML-style functors, an LSP server, and a catalog of optimization passes is significantly more than the "1–2 person-year prerequisite" estimate in `01-foundational-decisions.md` §3 implied. A realistic estimate is **3–5 person-years** for a small team to reach phase 3, with phase 2 (bootstrap drift acceptable) reached earlier.

This is recorded explicitly so future revisions can judge progress against intended scope. See §15 for the open questions this raises about milestone gating.

---

## 1. Architecture overview

```
                ┌─────────────────────────────────────────────────────────────┐
                │                          paideia-as                          │
                │                                                              │
   source .pdx ─┼─►  lexer ─►  parser ─►  surface AST                          │
                │                              │                               │
                │                              ▼                               │
                │                  ┌───────────────────────┐                   │
                │                  │  typed elaborator     │                   │
                │                  │  (Q-A4 reflection)    │                   │
                │                  │   — substructural      │                   │
                │                  │   — effect inference   │                   │
                │                  │   — functor resolve    │                   │
                │                  │   — macro expansion    │                   │
                │                  │   — const folding/DCE  │                   │
                │                  └──────────┬────────────┘                   │
                │                             ▼                                │
                │                       typed core IR                          │
                │                             │                                │
                │                             ▼                                │
                │                          ANF IR                              │
                │                             │                                │
                │                             ▼                                │
                │                  effect-handler-rewritten IR                 │
                │                             │                                │
                │           ┌─────────────────┼──────────────────┐             │
                │           ▼                 ▼                  ▼             │
                │  opt-in pass: #[peephole]  ...  #[schedule]  ...             │
                │           │                 │                  │             │
                │           └─────────────────┼──────────────────┘             │
                │                             ▼                                │
                │                      emitter (Intel bytes)                   │
                │                             │                                │
                │                ┌────────────┼────────────┐                   │
                │                ▼            ▼            ▼                   │
                │            ELF64       PE/COFF      relocatable              │
                │              │            │       fragments → paideia-link   │
                │              ▼            ▼                                  │
                │           DWARF        debug info                            │
                │           sidecar         sidecar                            │
                │              │            │                                  │
                └──────────────┼────────────┼──────────────────────────────────┘
                               │            │
                          .o.elf       .o.pecoff           ┌─────────────────┐
                               │            │              │  E14 linearity- │
                               │            │              │  regression     │
                               ▼            ▼              │  corpus runs    │
                          (linker)  (linker / paideia-link)│  against typed  │
                                                          │  core IR        │
                                                          └─────────────────┘
                                                                  ▲
       LSP server (Q-A10) ──────── reads typed core IR + spans ───┘
       Audit emitter (Q-A8) ─── emits unsafe-block catalog from elaborator
       SARIF writer (Q-A10) ─── reads diagnostics from every pass
```

Key invariants of the pipeline:
- **No register reallocation.** Every register named in source survives unchanged through every pass into the emitted bytes. Opt-in passes (`#[schedule]`, peephole) may reorder or rewrite *instruction encodings* but never repurpose programmer-named registers.
- **Each pass has typed inputs and typed outputs.** A diagnostic can be raised at any pass; all are routed through the SARIF writer.
- **Source spans survive end-to-end.** Every emitted byte carries provenance back to a source span, enabling DWARF, the LSP, and the audit emitter.

---

## 2. Surface syntax (Q-A1)

### 2.1 Design goals

- Capability and effect annotations are first-class lexical citizens — not comments, not pragmas, not attribute soup.
- Linearity and consumption are visible at glance.
- Intel SDM mnemonics are *not* preserved verbatim, but a direct mapping is documented; the SDM remains the source of truth for instruction semantics.
- The syntax is parseable with a small hand-written recursive-descent parser (target: under 2000 LOC for the parser in OCaml).

### 2.2 Lexical conventions (proposal)

| Element | Glyph(s) | Meaning |
|---|---|---|
| Effect set delimiter | `!{ … }` | A bracketed set of effects, e.g., `!{io, msr_read}`. |
| Capability set delimiter | `@{ … }` | A bracketed set of required capabilities, e.g., `@{port_cap, log_cap}`. |
| Linear consumption marker | `↓` (U+2193) or ASCII `$` | Operator-prefix marking that the operand is consumed (linear). |
| Affine drop marker | `~` | Operator-prefix marking that the operand may be dropped. |
| Effect-handler installation | `with H handle E` | Install handler `H` for effect `E` over a block. |
| Functor application | `F(M)(N)` | Standard. |
| Signature ascription | `:<S>` | Module/value ascription against signature `S`. |
| Capability binding | `cap p : PortCap ⊣ pcie.bus0` | Bind a capability `p` derived from a parent. |
| Block | `{ … }` | Curly-brace block. |
| Lambda / anonymous handler | `λ args. body` or `fn args -> body` (ASCII) | Functional binding. |
| Type annotation | `v : T` | Standard. |
| Instruction call | `op operand…` inside an action block | An assembly instruction is *just* a function call into the ISA module. |

Unicode is native (pillar 5 + E13). ASCII fallbacks are provided for every non-ASCII glyph; both are accepted by the lexer; the formatter (§13.3) normalizes to project policy.

### 2.3 Grammar sketch (illustrative, not normative)

```paideia-as
// ── PaideiaOS NVMe driver, illustrative ────────────────────────────
module NvmeServer : NvmeServerSig = functor
  (Pci : PciCapSig)            // required capability: PCIe enumeration
  (Mmio : MmioCapSig)          // required capability: MMIO mapping
  (Irq : IrqCapSig)            // required capability: interrupt vector
  -> struct

  // an effectful operation: read a 32-bit MMIO register
  let read_reg
      : (bar: MmioRegion ↓) -> (off: u32)
        -> u32 !{mmio_read} @{Mmio.read_cap}
      = fn bar off ->
        action !{mmio_read} @{Mmio.read_cap} {
          mov rax, [bar.base + off]   // straight Intel mnemonic
          ret rax
        }

  // a function consuming a queue-pair linearly
  let submit_io
      : (q: QueuePair ↓) -> (cmd: Cmd ↓)
        -> Completion !{mmio_write, ipc_send} @{Mmio.write_cap, q.cap}
      = fn q cmd ->
        with default_handler handle ipc_send {
          // queue-pair is linear: after this call, `q` cannot be used
          let head : u16 = atomic_load q.tail_ptr
          ...
        }

  // an `unsafe` escape: hand-written MMIO fence
  let mmio_fence : unit !{mmio_fence} @{} =
    unsafe {
      effects: { mmio_fence }
      capabilities: {}
      justification: "sfence required before doorbell write; the elaborator
                     does not yet model fence semantics — track in toolchain
                     issue T-0042."
      block: { sfence }
    }

end
```

The example shows:
- Functor declaration with capability-signature parameters.
- Linear-consumption marker `↓` on parameters.
- Effect set `!{ … }` and capability set `@{ … }` on signatures and at action sites.
- `action` block for issuing Intel instructions inside an effect/capability context.
- `with … handle …` for installing an effect handler.
- `unsafe { … }` block with mandatory `effects`, `capabilities`, `justification`, and `block` fields.

### 2.4 What the parser produces

A surface AST whose nodes carry source spans, lexical-form metadata (UTF-8 byte ranges), and unparsed comments (for the formatter). No type or effect information yet — those are the elaborator's job.

---

## 3. Type system (Q-A2): full substructural lattice

### 3.1 The four classes

Following Walker, *Substructural Type Systems* (in *Advanced Topics in Types and Programming Languages*, MIT Press, 2005):

| Class | Use rule | Drop rule | Reorder rule | Typical PaideiaOS use |
|---|---|---|---|---|
| **Ordered** | exactly once | no | no (must be used in declaration order) | IPC protocol sequence positions; some hardware register sequences. |
| **Linear** | exactly once | no | yes | Capability handles; ownership of memory regions awaiting consumption. |
| **Affine** | at most once | yes (drop allowed) | yes | Memory regions; throw-away results; logging contexts. |
| **Unrestricted** | any number | yes | yes | Immediates; constants; pure values; type-level expressions. |

The four classes form a lattice: ordered ≤ linear ≤ affine ≤ unrestricted (rules of a stricter class subsume rules of a less-strict class for purposes of *consumption*, in the standard Walker presentation).

### 3.2 Defaults and inference

- Type annotations declare the class explicitly via a kind annotation: `T : Linear`, `T : Affine`, etc.
- For local bindings, the elaborator *infers* the most permissive class consistent with all uses.
- Capability handle types are **declared linear** at the module signature level; consumers cannot weaken them.
- Inference reports the inferred class in diagnostics (the SARIF payload includes it).

### 3.3 Linearity check (E14)

The build-time linearity check from feature E14 is the public face of the substructural type system. It runs after elaboration on the typed core IR (§5.2). It exposes:
- Per-binding consumption count (expected, actual).
- The path through which the violation arose.
- The class annotation that imposed the constraint.

`tests/linearity-regression/` (per `02-development-environment.md` §9.6) targets this checker.

### 3.4 Interaction with LAM (Q7)

LAM-backed runtime tags (per Q7) are *not* part of the type system; they are a runtime-correctness backstop. The type system catches violations at compile time; LAM catches violations the type system missed (e.g., from `unsafe` blocks whose declarations lied). They are independent layers.

---

## 4. Effect system (Q-A3): algebraic effects with handlers

### 4.1 Effect declarations

Effects are declared as named signatures, each with one or more operations. Example:

```paideia-as
effect Io {
  op port_read  : (port: u16) -> u8
  op port_write : (port: u16, value: u8) -> unit
  op mmio_read  : (addr: u64) -> u64
  op mmio_write : (addr: u64, value: u64) -> unit
  op mmio_fence : unit
}

effect Ipc {
  op send : (cap: SendCap ↓, msg: Msg ↓) -> unit
  op recv : (cap: RecvCap ↓) -> Msg
}
```

An effect declaration introduces:
- The effect name (`Io`, `Ipc`).
- An operation set, each with its own substructural-typed signature.

### 4.2 Effect rows on function types

Function types carry an explicit effect set:

```
read_msr : (msr: u32) -> u64 !{Msr, percpu}
```

The set is row-polymorphic in the technical sense: a function may be quantified over an unknown remainder set, e.g., `forall e. (...) -> T !{Io | e}` (it performs `Io`, plus whatever `e` is, transparently).

### 4.3 Handlers

Handlers install interpretations of effects over a code region:

```paideia-as
with msr_handler handle Msr {
  let v = read_msr 0x1A0
  ...
}
```

`msr_handler` is a value of handler type — it provides implementations for each operation in the `Msr` effect signature. Inside the `with` block, calls into `Msr` operations dispatch to the handler.

### 4.4 Compilation

Algebraic effects compile to ANF in §6.4. The effect-handler-rewrite pass (§6.5) replaces each effect operation with an indirect call through the installed handler. The handler value lives in a thread-local handler stack rooted in the per-CPU area (consistent with C18 of the feature inventory and the calling convention in §8).

### 4.5 Why algebraic effects fit PaideiaOS

- **Verification-friendly (Q2).** Handler-as-interpreter lets us write a *proof handler* that records a trace; the linearity-regression corpus and IPC property-tests can run the same source code under instrumented handlers.
- **Capability-aligned.** Each effect operation takes its capability as a linear argument — the type system enforces capability presence, the handler enforces semantics.
- **Microkernel-aligned.** Userspace servers naturally provide handlers for the effects whose semantics they own (e.g., the storage server provides handlers for `Storage` effects).
- **Wait-free IPC-aligned (Q1).** IPC operations are just effects with the IPC primitive's handlers installed by the kernel at thread creation.

---

## 5. Macros & elaborator (Q-A4): typed elaborator reflection

### 5.1 The elaborator as the heart of the assembler

The elaborator is responsible for:
- Resolving names and functor applications.
- Performing substructural inference and checking.
- Performing effect inference and checking.
- Expanding macros (which are themselves typed programs).
- Constant folding and dead-branch elimination during elaboration (Q-A9 base behavior).
- Reporting diagnostics to the SARIF writer.

Inspired by Idris elaborator reflection (Christiansen & Brady, *Elaborator Reflection: Extending Idris in Idris*, ICFP 2016) and Lean 4 macro / elaboration framework (Ullrich & de Moura, *Beyond Notations: Hygienic Macro Expansion for Theorem Proving Languages*, IJCAR 2020).

### 5.2 Macros are typed programs in paideia-as

A macro is a function in the `Elab` effect that:
- Receives the syntactic form being expanded (as a typed `Syntax` value).
- Receives the *expected type* and *expected effect set* from context (read-only).
- Returns a new syntactic form, which the elaborator re-elaborates in the original context.

```paideia-as
macro do_block (s: Syntax) : Syntax !{Elab} =
  match s with
  | `(do { ${stmts} }) -> elab_do_stmts stmts
  | _ -> elab_error "do_block expects a do {...} form"
```

Because the macro body has type `Syntax !{Elab}`, the same substructural and effect discipline applies inside macros. A macro cannot accidentally consume a linear capability twice.

### 5.3 Macro hygiene

Hygiene is automatic. Names introduced by a macro are alpha-renamed against the use site; names referenced from the use site are resolved at the use site. The model follows Lean 4's hygiene algorithm (Ullrich 2020).

### 5.4 What macros are used for in PaideiaOS

- Monad / functor / applicative scaffolds (the FP pillar named in `01-foundational-decisions.md` Q3).
- Capability-passing boilerplate around servers (the `with`-handler installation pattern).
- Generating ABI marshalling thunks for the System V bridge (§8.6).
- The `unsafe`-block audit emitter (§11.4).
- Domain-specific DSLs (e.g., a `ports` DSL for declaring port-mapped I/O servers).

### 5.5 What macros are NOT used for

- Implementing the ISA itself (instructions are first-class, not macro-expanded).
- Implementing the type system (the type system is the elaborator's primary concern, not a macro library).
- Replacing the parser (no reader macros in the Lisp sense; the parser is fixed).

---

## 6. IR pipeline (Q-A5)

### 6.1 Typed core IR

A small core calculus capturing:
- The full substructural lattice (each binding annotated with its class).
- Effect rows on every function.
- Module/functor structure as first-class values (in the style of System F-omega with applicative functors).
- Source spans on every node.

The typed core is the substrate for:
- The E14 linearity-regression corpus.
- Future formal-verification hooks (D4 of the inventory).
- The LSP server (it reads typed-core IR via a stable API).

### 6.2 ANF (administrative normal form)

A standard restructuring: every nontrivial sub-expression is bound to a name. Makes evaluation order explicit and is the canonical form for effect-handler rewrite. (Flanagan et al., *The Essence of Compiling with Continuations*, PLDI 1993, contemporary follow-ups.)

### 6.3 Effect-handler-rewritten IR

Each effect operation is replaced with an indirect call through the installed handler. The handler value is looked up via the handler stack rooted in the per-CPU area (§8). After this pass, the IR contains no `!{…}` annotations — they have been compiled away.

### 6.4 Opt-in optimization passes (Q-A9)

Each optimization is an independent module consuming and producing the effect-handler-rewritten IR. The catalog is extensible. Initial planned passes:

| Pass | Annotation | Effect |
|---|---|---|
| **Peephole** | `#[peephole]` | Conservative idiomatic rewrites: `mov reg, 0` → `xor reg, reg`; `add reg, 1` → `inc reg`; `cmp reg, 0` → `test reg, reg`; etc. Documented catalog. |
| **Instruction scheduling** | `#[schedule(latency)]` | Reorder instructions within a basic block to hide latency (e.g., separate dependent ops by independent ones). Does not change register choices; only reorders independent ops. |
| **Dead-store elimination** | `#[dse]` | Elide stores to memory immediately overwritten without intervening read. Scope: basic block. |
| **Macro-fusion-aware emission** | `#[macro-fusion]` | When emitting comparison-then-branch sequences, ensure the pair is fusable per Intel SDM Vol. 3, Optimization Reference Manual chapter on macro-fusion. |
| **REX/EVEX prefix tightening** | `#[encode-tight]` | Choose the smallest legal encoding when multiple encodings exist (e.g., short-form ADD vs. modrm-form). |
| **Loop unrolling** | `#[unroll(n)]` | Unroll the annotated loop by factor `n`. Explicit count, no heuristics. |
| **Branch reordering** | `#[branch-hint(likely)]` / `#[branch-hint(unlikely)]` | Layout the basic block to make the hinted branch the fall-through path. |
| **Cache-line alignment** | `#[align(64)]` | Align the function entry or loop head to a cache line. |
| **Constant table pooling** | `#[pool-constants]` | Lift repeated large immediates into a read-only data section. |
| **Tail-call elimination** | `#[tailcall]` | Replace a final `call`+`ret` pair with a `jmp` when ABI permits. |

Each pass:
- Operates only on the function or block where its annotation is present.
- Is documented in `design/toolchain/optimization-passes.md` (future) with the exact catalog of rewrites it performs.
- Has its own regression-test corpus.
- Reports its actions in the diagnostic stream so a programmer can see exactly which rewrites fired.

The default is *no optimization*. Adding a new pass to the catalog is a discrete PR with kernel-reviewer + toolchain-reviewer signatures.

### 6.5 Emitter

The final emitter consumes the (possibly optimized) effect-handler-rewritten IR and produces:
- Intel bytes in the order specified.
- DWARF debug info (`.debug_info`, `.debug_line`, `.debug_frame`).
- Relocation tables.
- Source-span sidecar for the LSP server (§13).

Three output backends share the emitter: ELF64, PE/COFF, and a relocatable-fragment format consumed by `paideia-link` for PAX binaries (E2).

---

## 7. Module system (Q-A7): ML modules with functors

### 7.1 Structures, signatures, functors

Following Standard ML / OCaml:
- A **signature** is a set of declarations (types, values, sub-signatures) with kinds, types, and effect rows.
- A **structure** is a value matching a signature.
- A **functor** is a structure parameterized by structures matching other signatures.

### 7.2 Why functors

A PaideiaOS userspace server (driver, FS, network server) is defined by:
- The capabilities it receives.
- The signatures of services it provides.

A functor expresses both natively: parameters are the received capabilities (each typed by a capability-signature); return is a structure matching a service-signature. Capability passing maps onto functor application at link time.

### 7.3 Functor flavor

Applicative functors (Leroy 1995, in the SML/OCaml lineage) rather than generative. Two applications of the same functor to the same argument yield structurally equal types; this matters because the linearity-regression corpus needs to reason about identity of capability-typed paths.

### 7.4 Sharing constraints

Sharing constraints are supported and explicit: `MakeNvme(Pci)(Mmio) sharing (Pci.bus_id = Mmio.bus_id)`. Diagnostics for sharing violations must be among the highest quality the assembler emits — the SML/OCaml record of bad sharing-mismatch errors is a cautionary tale.

### 7.5 First-class modules

Modules are first-class values, packageable as `pack M : S`. Needed for IPC: a server can receive a capability-bundle structure as an IPC argument.

### 7.6 File / module mapping

One source file (`.pdx`) maps to one structure or one functor (a contributor cannot put both in the same file). The structure's name is the file's basename, capitalized. Cross-file references go through `import` statements that resolve via the build graph.

---

## 8. Calling convention (Q-A6): PaideiaOS-native

### 8.1 Posture

Applications, drivers, and userspace servers are *all* written in paideia-as. The System V AMD64 ABI is not the lingua franca of PaideiaOS — it is a foreign protocol used only at three locations:

1. The ACPICA bubble (per Q5 of foundational decisions).
2. The WASM/VM jail (per Q9).
3. Any future legacy-interop process running under the WASM jail's VM mode.

Therefore the convention is optimized for native-to-native calls; System V interop is implemented via generated thunks (§8.6) at the boundary, not as a default mode.

### 8.2 Register file partitioning

The 16 GPRs are partitioned into four bands. The partition is a property of the convention; the elaborator validates compliance.

| Band | Registers | Discipline | Purpose |
|---|---|---|---|
| **General** | RAX, RBX, R8–R11 | unrestricted | Scratch / general computation. |
| **Capability** | R12, R13 | linear; carry LAM-tagged capability handles (Q7) | Passing capability handles in/out of functions. |
| **Effect** | R14, R15 | affine; hold the active handler stack pointer and per-CPU handler-environment pointer | Effect-handler installation and lookup. |
| **Reserved** | RSP, RBP, RIP | reserved | Stack pointer, frame pointer, instruction pointer (architectural). |
| **Argument** | RDI, RSI, RDX, RCX | unrestricted, but used for argument passing per §8.3 | Standard arg-passing slots. |

The XMM/YMM/ZMM register file is partitioned similarly:
- ZMM0–ZMM15: scratch / general SIMD.
- ZMM16–ZMM31: reserved for vectorized PQ crypto state (E8) — a calling function preserves them across non-PQ calls but a PQ kernel may use them freely. Documented per-function in the signature.

### 8.3 Argument passing

- First 4 integer/pointer args: RDI, RSI, RDX, RCX.
- Capability args: R12, R13, then the stack with a capability-tagged stack-slot annotation.
- First 4 floating-point/vector args: ZMM0–ZMM3.
- Additional args: stack, in declaration order; the stack pointer is 64-byte aligned at call boundaries (versus System V's 16-byte) to accommodate ZMM saves.
- Return values: RAX (integer), R12 (capability), ZMM0 (floating-point/vector).

### 8.4 Effect-environment pointer

R15 carries the active effect-handler environment pointer. Calling a function with a different effect signature than the caller's switches R15 to a new environment by saving and restoring. This is cheaper than walking a stack and lets effect operations dispatch in 2–3 instructions (load handler table, indirect call).

### 8.5 Callee-saved vs caller-saved

| Class | Convention |
|---|---|
| Caller-saved | RAX, RCX, RDX, RSI, RDI, R8–R11, ZMM0–ZMM15. |
| Callee-saved | RBX, RBP, R12, R13, R14, R15, RSP, ZMM16–ZMM31. |

The callee-saved set is larger than System V's; this is a deliberate cost paid to make capability passing in R12/R13 efficient (the caller doesn't have to save them every call).

### 8.6 System V bridge

A thunk generator (a macro in the macro library) wraps a System V-ABI function in a paideia-as-callable signature, or vice versa. The thunk:
- Marshals capability handles: a capability in R12 enters the bridge; the bridge consumes it linearly and produces a system-call descriptor (e.g., an `int fd`) that the C side understands.
- Saves the caller's effect environment (R15) on a side stack and clears R15 (C code has no concept of effect handlers).
- Realigns the stack to 16 bytes for the System V call.
- On return, restores R15 and the capability environment.

The thunk's generated code is itself paideia-as code, audited per `unsafe`-block rules because it touches the ABI boundary.

### 8.7 Stack discipline

- The stack is 64-byte aligned at every call boundary in PaideiaOS-native calls (ZMM-sized).
- The red zone is **not** used (in contrast to System V's 128-byte red zone) because exception/interrupt entry would otherwise corrupt it on PaideiaOS-native frames.
- Frame pointers (RBP) are mandatory in debug builds and optional in release builds; the choice is per-function annotated.

### 8.8 What this convention enables

- Capability-typed registers (R12/R13) get LAM-tagged loads/stores natively. A capability load into R12 carries the tag bits the hardware enforces (Q7).
- Effect handlers dispatch in two instructions: `mov rax, [r15 + offset]; call rax`.
- Cross-domain calls (kernel ↔ userspace) reuse the convention with one additional invariant: the effect environment pointer is swapped to a domain-appropriate one at the kernel boundary.

---

## 9. Inline-assembly escape (Q-A8)

### 9.1 Syntax

```paideia-as
unsafe {
  effects: { <effect-name>, ... }
  capabilities: { <cap-name>, ... }
  justification: "<free-form text; ≥ 1 sentence>"
  block: {
    <raw Intel instructions, with paideia-as operand syntax>
  }
}
```

All four fields are mandatory. The parser rejects an `unsafe` block missing any of them.

### 9.2 Semantics

- The `effects` and `capabilities` sets are *declarations*: the surrounding type system treats the block as if it performed those effects and consumed those capabilities. They are *not checked* against the block contents (the whole point of `unsafe` is that the contents are outside the elaborator's reach).
- The `justification` text is recorded verbatim in the audit catalog.
- The `block` is the only place inside paideia-as that raw Intel instructions appear without the typed surface in between.

### 9.3 Audit trail

The elaborator emits, for every `unsafe` block, an entry into `target/audit/unsafe-blocks.json` containing:
- Source span (file, line range, byte range).
- Declared effects and capabilities.
- Justification text.
- The git commit SHA-3-256 at build time.
- The byte hash (BLAKE3) of the block's contents.

CI mirrors this catalog to `audit/unsafe-blocks-history.md` on every `main` merge; the catalog's growth rate is itself a tracked metric (a sudden spike triggers review).

### 9.4 Effect-handler-rewrite interaction

`unsafe` blocks do not participate in the effect-handler-rewrite pass (§6.3); their declared effects are taken as performed-and-handled-already. This means an `unsafe` block cannot raise an effect for the surrounding handler to catch — if you need that, write the operation through the typed surface.

### 9.5 The trust contract

An `unsafe` block whose declarations lie (e.g., it secretly consumes a capability without declaring it) subverts the type system locally. The audit catalog and the CI review process are the project's defense; they substitute for a verified type system at these specific points. The honesty of every `unsafe` block declaration is therefore a project-wide trust assumption.

---

## 10. Optimization catalog discipline (Q-A9, expanded)

The base behavior is elaborator-only evaluation; the catalog of opt-in passes is governed by the rules below.

### 10.1 Adding a pass

A new pass requires:
1. A design note under `design/toolchain/optimization-passes.md` describing the rewrites it performs.
2. Implementation in `src/toolchain/asm/opt-passes/<name>/`.
3. A regression-test corpus in `tests/opt-regression/<name>/` containing accept-and-expect-rewrite inputs.
4. Two reviewer signatures: kernel-reviewer + toolchain-reviewer.

### 10.2 Removing or modifying a pass

Once a pass is in the catalog, modifying its rewrite rules requires the same review burden as adding a new pass. Removing a pass is a major-version event for paideia-as (per §16 versioning).

### 10.3 Pass interactions

Multiple passes annotated on the same function compose in catalog order (documented). The diagnostic stream reports each rewrite each pass fires; a contributor can read the cumulative effect.

### 10.4 No implicit "release build" toggle

There is no global flag that turns on the optimization catalog. Every optimization is per-block opt-in. A "release build" therefore is *not* the same code as "debug build with `-O0`" — they are literally the same code, modulo `assert`-equivalent unsafe-checks the elaborator may elide. This is a deliberate choice for predictability.

---

## 11. Error reporting (Q-A10)

### 11.1 Diagnostic structure

Each diagnostic has:
- **Primary span** — the location where the problem manifests.
- **Secondary spans** — locations contributing context (the binding site of a violated linearity constraint; the handler site for an effect that escaped).
- **Category** — one of `parse`, `elaborator`, `substructural`, `effect`, `module`, `optimizer`, `emitter`, `unsafe-audit`, `lint`.
- **Code** — a stable identifier (`E0301` for "linearity violation: linear value consumed twice"). The code catalog lives at `design/toolchain/diagnostics.md`.
- **Human message** — a Rust-style multi-line message with span highlights and a suggestion when possible.
- **Structured payload** — a category-specific JSON object (the linear value's name and type; the effect mismatch's expected vs. found rows).
- **Notes / suggestions** — zero or more secondary messages.

### 11.2 Output formats

The same diagnostic is emitted in three forms simultaneously by the diagnostic router:

1. **Human (terminal).** Multi-line, ANSI-coloured by default, optionally plain. Source lines with carets under spans; secondary spans labelled.
2. **SARIF** (Static Analysis Results Interchange Format; OASIS). Emitted to a `*.sarif.json` sidecar per source file. Consumed by code-review tools, security tooling, and CI.
3. **LSP diagnostics.** Pushed over the LSP protocol to whatever editor is attached. The diagnostic code becomes the LSP code; the structured payload powers code-action suggestions.

### 11.3 The LSP server

Lives in `src/toolchain/lsp/`. Wraps the elaborator behind the LSP protocol. Supported requests (initial):
- `textDocument/diagnostics` — push errors as they happen.
- `textDocument/hover` — show the inferred substructural class, effect row, and capability set for the symbol under the cursor.
- `textDocument/definition` — jump to declaration.
- `textDocument/references` — find all uses.
- `textDocument/codeAction` — quick fixes (e.g., "drop this affine binding"; "add this to the effect signature").
- `workspace/symbol` — module/functor search.
- `textDocument/formatting` — invoke the formatter (§13.3).

The LSP server is part of phase-1 deliverables, not deferred. Working in a typed-elaborator + substructural-types + effects language without an LSP is impractical.

### 11.4 Diagnostic catalog discipline

`design/toolchain/diagnostics.md` is the canonical catalog. Adding a new error code is a discrete PR including:
- The code (`Exxxx`).
- The category.
- The conditions under which it fires.
- An example input that triggers it.
- The suggested fix.
- The structured-payload schema.

The catalog is the LSP's source of truth for code-action templates.

---

## 12. Object-file emission

### 12.1 ELF64

The standard kernel and userspace-server output. Layout follows System V x86_64 ABI conventions (Section header table, symbol tables, relocation tables) so that GDB and objdump work. PaideiaOS-specific sections:

| Section | Purpose |
|---|---|
| `.paideia.caps` | Capability-handle binding sites; consumed by `paideia-link` to populate the PAX manifest. |
| `.paideia.effects` | Function-level effect-row annotations; consumed by the LSP and the audit tooling. |
| `.paideia.unsafe` | The audit catalog of `unsafe` blocks in this object. |
| `.paideia.opt-passes` | A record of which optimization passes ran and where; consumed by the diagnostic tooling. |
| `.paideia.lin` | Linearity-check witness data; consumed by E14. |

### 12.2 PE/COFF

For `paideia-loader.efi` (UEFI loader) only. The emitter shares its core with the ELF backend; the differences are header layout, relocation type encoding, and section naming (`.text` → `.text`, but COFF-specific characteristics).

### 12.3 Relocatable fragments → `paideia-link`

A third backend emits a project-specific relocatable format consumed by `paideia-link` to produce PAX binaries (E2). The format carries:
- Code bytes.
- Capability-binding sites (richer than ELF can express).
- Functor closure information (the structures the functor expects at link time).
- Effect-signature annotations on exports.

`paideia-link` is a sibling tool, not part of paideia-as. Its design is `design/toolchain/paideia-link.md` (future).

### 12.4 DWARF

`.debug_info`, `.debug_line`, `.debug_frame`, and `.debug_loc` are emitted at all optimization levels. Debug info correlates back to source spans preserved through every IR pass (§1 invariant).

PaideiaOS extensions:
- `.debug_paideia.caps` — DWARF extension declaring capability handle types and their substructural class. Consumed by `scripts/gdb/paideia.py`.
- `.debug_paideia.effects` — DWARF extension declaring effect rows on functions.

The DWARF extensions use the vendor-specific encoding space per DWARF 5 §7.4.

---

## 13. Tooling

### 13.1 `paideia-as` CLI

```
paideia-as [GLOBAL OPTIONS] SUBCOMMAND [SUBCOMMAND OPTIONS]

Subcommands:
  build    compile one or more .pdx files to object files
  check    type-check without emitting object files
  lint     run linearity check, effect check, opt-pass audit
  emit     emit a specific format (elf64 | pecoff | pax-frag)
  audit    print the unsafe-block catalog for the given inputs
  doc      generate reference documentation from inline annotations
```

Per `02-development-environment.md` §7.4, the only sanctioned invocation paths route through `./tools/dev/build` and `./tools/dev/test`, which in turn call `paideia-as`.

### 13.2 LSP server

`paideia-lsp` is a separate binary that links the elaborator as a library. Communicates over stdio per LSP convention. Editor integrations (VS Code, Helix, Emacs lsp-mode, Vim coc) ship configuration recipes in `tools/editor/`.

### 13.3 Formatter

`paideia-fmt` normalizes whitespace, glyph rendering (ASCII vs. Unicode lattice glyphs), and operator spacing per a project-wide style. The formatter is run by CI on every PR; deviations block.

The formatter does *not* rearrange code, rename, or otherwise affect semantics. Its output is purely lexical normalization.

### 13.4 REPL?

A REPL is not in scope for phase 1. Possible in phase 3 once the elaborator stabilizes; it would be a thin wrapper that elaborates and emits to a JIT page. Not yet committed.

### 13.5 Documentation generator

`paideia-as doc` walks signature declarations and emits Markdown reference documentation. Functor signatures are the natural unit of documented API. This feeds `design/<area>/` documents automatically.

---

## 14. Bootstrap path (recap and assembler-specific detail)

Per `02-development-environment.md` §8, the bootstrap is three-phase. This document refines the phases with paideia-as-specific milestones.

### 14.1 Phase 1 (NASM + macro simulation)

Built in NASM with hand-written macros that simulate (but do not check) the substructural lattice and effect-set notation. Tracks:
- Boot path (C1).
- Early physical memory (C2).
- Exception handlers (C8).
- Per-CPU IPI primitives (C18).
- Atomic ABI prototype (C14).

`paideia-as` itself is begun in OCaml during phase 1. First milestone: parser + surface AST + a "smoke check" that the elaborator can elaborate a trivial source file.

### 14.2 Phase 2 (NASM + early paideia-as coexistence)

`paideia-as` enters the build graph subsystem-by-subsystem. The order of migration follows the dependency on the typed surface:

1. **Capability system (C4)** — first, because linearity is most needed here.
2. **IPC primitive (C7)** — second, because effects and capabilities both apply.
3. **Scheduler (C6)** — third, because the per-CPU effect environment lives here.
4. Subsequent subsystems migrate as their need for substructural / effect discipline arises.

The phase-2 cross-build smoke test (`02-development-environment.md` §8.2) compares NASM-built and paideia-as-built versions of migrating modules.

### 14.3 Phase 3 (paideia-as canonical + self-hosting)

Stage 2 of paideia-as is built by stage 1; thereafter the build is self-hosted. NASM is retained only in `nix/legacy/` for DDC and forensic purposes.

### 14.4 OCaml dependency removal

Stages 0 and 1 are in OCaml; stage 2 is in paideia-as. Once stage 2 self-builds, the production build no longer depends on OCaml. The OCaml stages remain in the repo for DDC.

### 14.5 The elaborator-bootstrap concern

The typed elaborator is the most complex piece. Strategy:
- Phase-1 elaborator (OCaml) implements the substructural lattice and effect rows in a closed (non-reflective) form. Macros use a pattern-based fallback, not full typed reflection.
- Phase-2 elaborator (OCaml) adds typed reflection.
- Phase-3 elaborator (paideia-as, self-hosted) reaches feature parity and then exceeds the OCaml elaborator in performance.

The reflection capability is therefore *deferred* from phase 1 to phase 2. Code written in phase 1 uses a restricted macro form; phase-2 enables the full reflection API. This is a documented temporary restriction.

---

## 15. Open issues

| ID | Issue | Where it lives |
|---|---|---|
| AS1 | Scope realism. The Q-A1–Q-A10 combination is more than the §3-tension "1–2 person-year" estimate. A milestone plan in `design/toolchain/milestones.md` should commit to which subset is mandatory for phase 2 vs. phase 3. | `design/toolchain/milestones.md` (to write) |
| AS2 | ASCII fallbacks for Unicode glyphs (§2.2). Required for editor compatibility but bloats the lexer. Decide the canonical set. | `design/toolchain/syntax-reference.md` (to write) |
| AS3 | The effect-environment pointer in R15 (§8.4) conflicts with the System V ABI assumption that R15 is callee-saved. The thunk-bridge logic (§8.6) must save R15 on entry to C and restore on exit. Verify this against any compiler that may inline-expand a System V call (none currently planned, but worth noting). | `design/toolchain/calling-convention.md` (to write) |
| AS4 | Functor sharing-constraint diagnostics (§7.4). Need a worked example catalog before phase-2 functor migration begins. | `design/toolchain/diagnostics.md` |
| AS5 | The optimization-pass catalog (§6.4 / §10) is illustrative. Phase 1 ships zero passes; phase 2 adds peephole + scheduling. The order of subsequent passes is open. | `design/toolchain/optimization-passes.md` (to write) |
| AS6 | The LSP server (§13.2) is committed for phase 1 but the editor integrations (VS Code, Helix, Emacs, Vim) are not committed. Decide minimum viable editor support per phase. | `design/toolchain/editor-support.md` (to write) |
| AS7 | DWARF vendor extensions (§12.4) need a vendor identifier registration (DWARF 5 §7.4). Pick one and document. | `design/toolchain/debug-info.md` (to write) |
| AS8 | The PAX-fragment object format (§12.3) is referenced but undesigned. Must be specified before phase 2's userspace migrations begin. | `design/toolchain/paideia-link.md` (to write) |
| AS9 | Phase-1 elaborator's restricted macro form (§14.5) — exactly what subset of typed reflection is available. | `design/toolchain/macros-phase1.md` (to write) |
| AS10 | Versioning policy for the diagnostic catalog (`Exxxx`) — when do codes get retired vs. renumbered? | `design/toolchain/diagnostics.md` |

---

## 16. Versioning

Per `02-development-environment.md` §8.5: post-phase-3, paideia-as follows semantic versioning. Pre-phase-3, the assembler is internally versioned but treated as a moving target; ABI changes are coordinated via the `ABI_VERSION` in the phase-2 cross-build smoke test.

---

## 17. References

### 17.1 Type systems and effects

- Walker, D. *Substructural Type Systems*. In B. Pierce (ed.), *Advanced Topics in Types and Programming Languages*, MIT Press, 2005.
- Plotkin, G. and Power, J. *Algebraic Operations and Generic Effects*. Applied Categorical Structures, 11(1), 2003.
- Plotkin, G. and Pretnar, M. *Handlers of Algebraic Effects*. ESOP 2009.
- Leijen, D. *Koka: Programming with Row Polymorphic Effect Types*. MSFP 2014.
- Hillerström, D. and Lindley, S. *Liberating Effects with Rows and Handlers*. Tyde 2016.
- Bauer, A. and Pretnar, M. *Programming with Algebraic Effects and Handlers*. JLAMP 84(1), 2015.
- Brady, E. *Idris 2: Quantitative Type Theory in Practice*. ECOOP 2021.

### 17.2 Elaborator reflection / metaprogramming

- Christiansen, D. and Brady, E. *Elaborator Reflection: Extending Idris in Idris*. ICFP 2016.
- Ullrich, S. and de Moura, L. *Beyond Notations: Hygienic Macro Expansion for Theorem Proving Languages*. IJCAR 2020.
- Ebner, G., Ullrich, S., Roesch, J., Avigad, J., de Moura, L. *A Metaprogramming Framework for Formal Verification*. ICFP 2017.
- Flatt, M. *Composable and Compilable Macros: You Want it When?* ICFP 2002.

### 17.3 Module systems and functors

- MacQueen, D. *Modules for Standard ML*. LFP 1984.
- Leroy, X. *Applicative Functors and Fully Transparent Higher-Order Modules*. POPL 1995.
- Dreyer, D., Crary, K., Harper, R. *A Type System for Higher-Order Modules*. POPL 2003.
- Rossberg, A., Russo, C., Dreyer, D. *F-ing Modules*. JFP 24(5), 2014.

### 17.4 IR / compilation

- Flanagan, C., Sabry, A., Duba, B., Felleisen, M. *The Essence of Compiling with Continuations*. PLDI 1993.
- Kennedy, A. *Compiling with Continuations, Continued*. ICFP 2007.
- Leijen, D. *Type Directed Compilation of Row-Typed Algebraic Effects*. POPL 2017.

### 17.5 Standards and references

- DWARF Debugging Information Format, Version 5. DWARF Standards Committee, 2017.
- SARIF v2.1.0. OASIS Static Analysis Results Interchange Format Technical Committee.
- Language Server Protocol Specification 3.17. Microsoft.
- System V Application Binary Interface — AMD64 Architecture Processor Supplement. Current revision.
- Intel® 64 and IA-32 Architectures Software Developer's Manual, Vols. 1–4, current revision.
- Intel® 64 and IA-32 Architectures Optimization Reference Manual (for the macro-fusion catalog), current revision.

### 17.6 Prior-art assemblers and metaprogramming systems

- NASM Manual. Intel-syntax assembler.
- GNU as / binutils — for the AT&T-syntax baseline.
- Rust `macro_rules!` / procedural macros — for the macro-tier lesson.
- Lean 4 elaboration framework — for the typed elaborator pattern.
- Coq's Mtac / Ltac2 — alternate typed-tactic lineages worth study.

---

*End of document.*
