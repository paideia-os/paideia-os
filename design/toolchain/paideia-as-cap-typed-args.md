# paideia-as grammar extension: `@cap(…)` parameter sigil

**Status:** Spec (design-only, not yet implemented).
**Wave:** UMB-W14 (companion to `design/shell/capability-typed-arguments.md`).
**Target toolchain wave:** TBD — this document is the input brief when
the paideia-as team schedules the implementation.
**Depends on:** `design/shell/capability-typed-arguments.md` (R125.M6
contract); `design/toolchain/syntax-reference.md` (host grammar);
`design/toolchain/custom-assembler.md` §2.3 (capability-set notation
precedent).
**Blocks:** R125.M7 (runtime check emission).

---

## 1. Scope

This document is the paideia-as-side spec for the capability-typed
argument sigil defined in `design/shell/capability-typed-arguments.md`
(the *shell doc* from here on). It covers:

- lexer additions (new keyword, new multi-char token);
- grammar extension (EBNF delta against `syntax-reference.md` §8);
- elaborator obligations (origin tracking, rights-subset check);
- emitter obligations at M6 (none at runtime; static annotation only)
  and the hand-off shape to M7;
- interaction with the existing `@{…}` capability-set notation;
- diagnostic (E-code / D-code) catalogue;
- debug-info section layout for the `.debug_paideia.caps` extension
  (per `custom-assembler.md` §9.5).

Scope **excludes**:

- the runtime-check lowering recipe (M7);
- any paideia-as code; this doc is a brief for a future wave to
  implement.

---

## 2. Lexer additions

### 2.1 New reserved word

`cap` becomes a context-sensitive reserved word inside a type /
parameter position. Outside those positions, `cap` remains available
as an identifier (there is no project-wide `cap` keyword today, so no
collision; but existing `cap p : PortCap ⊣ pcie.bus0` style bindings
(`syntax-reference.md` §2.2 glyph table) already treat `cap` as a
binding introducer — see §2.3 below).

Decision: `cap` is **not** promoted to a top-level reserved word.
Instead, the parser recognises the two-token sequence `@` `cap` **only
when immediately followed by `(`** in a parameter position. This is a
one-token lookahead, well within paideia-as's parser capability.

Rationale: adding `cap` to §3.4's reserved-word list would break the
`cap p : …` idiom from `custom-assembler.md` §2.2. The contextual
recognition is safer.

### 2.2 Token stream

For the input `@cap(KIND_DEK, R_DEK_READ)`:

| Token | Byte range | Class |
|---|---|---|
| `@` | 0..1 | Operator (unchanged; `syntax-reference.md` §2.3) |
| `cap` | 1..4 | Identifier (lexed as any other identifier) |
| `(` | 4..5 | Punctuation |
| `KIND_DEK` | 5..13 | Identifier |
| `,` | 13..14 | Punctuation |
| ` ` | 14..15 | (whitespace, skipped) |
| `R_DEK_READ` | 15..25 | Identifier |
| `)` | 25..26 | Punctuation |

No new token class is needed. The lexer passes through unchanged; the
parser does the recognition work.

### 2.3 Interaction with `cap p : PortCap ⊣ pcie.bus0`

The binding form `cap p : …` lives at **statement scope** inside a
functor body or block scope; its `cap` is a leading keyword at
statement start.

The sigil form `@cap(…)` lives at **parameter position** inside a
function-type or lambda-param list; its `cap` is after `@` and inside
a parameter.

The parser can keep both working: the `cap` binding is recognised when
`cap` is the first token of a statement; the `@cap(…)` sigil is
recognised when `@` + `cap` + `(` appears in a parameter-position
context. The two never collide.

---

## 3. Grammar extension

### 3.1 Delta against `syntax-reference.md` §8

The host grammar's `LambdaParams` rule is:

```
LambdaParams ::= "(" Pattern ":" Type ")" ("(" Pattern ":" Type ")")*
```

(Curried paideia-as style — one parenthesised arg per fn-call-chain
position.)

The function-type rule in §8 is:

```
Type ::= TypeName ("(" Type ("," Type)* ")")?
       | "(" Type ")" "->" Type EffectSetOpt CapSetOpt
       | "(" Type ("," Type)* ")"
       | LinClass Type
       | EffectRowType
```

The delta:

```
Param        ::= CapSigil? Pattern ":" Type
LambdaParams ::= "(" Param ")" ("(" Param ")")*

TypeInArgList ::= CapSigil? Type

Type         ::= TypeName ("(" Type ("," Type)* ")")?
               | "(" TypeInArgList ")" "->" Type EffectSetOpt CapSetOpt
               | "(" TypeInArgList ("," TypeInArgList)* ")"
               | LinClass Type
               | EffectRowType

CapSigil     ::= "@" "cap" "(" CapKind "," CapRights ")"

CapKind      ::= PathIdent
CapRights    ::= RightsExpr

RightsExpr   ::= Primary ("|" Primary)*
Primary      ::= PathIdent | HexLit | DecLit

PathIdent    ::= Identifier ("." Identifier)*
HexLit       ::= "0x" HexDigit+
DecLit       ::= DecDigit+
```

Three touch-points:

1. `LambdaParams` grows the optional `CapSigil` prefix at each curried
   position.
2. The function-type arg list (both single-arg and tuple-arg) grows a
   `TypeInArgList` wrapper that lets the sigil precede the type at the
   signature level too.
3. The new rules `CapSigil`, `CapKind`, `CapRights`, `RightsExpr`,
   `Primary`, `PathIdent`, `HexLit`, `DecLit` are additions.

### 3.2 Where the sigil may appear

**Legal** positions:
- a function-type parameter (`(@cap(K, R) T) -> U`);
- a lambda parameter (`fn (@cap(K, R) x: u64) -> …`);
- a functor-signature parameter type.

**Illegal** at M6/M7:
- function return types (deferred — shell doc CTA-Q4);
- local `let` binding types (a cap is passed, not stored at a `let`;
  if cap-local-storage is wanted, add it at a future wave);
- field types inside a `struct` body (no cap-slot in a persisted struct
  at M6; the IPC-boundary cap-passing work makes this a later-wave
  question);
- type parameters of a generic (no `@cap` at kind-level in M6/M7).

The parser rejects out-of-position sigils with `E0904 (@cap in illegal
position)`.

### 3.3 Example signatures

Legal:

```paideia-as
pub let sys_dek_apply_body
    : (@cap(KIND_DEK, R_DEK_READ | R_DEK_SCRUB) u64, u64, u64, u64, u64) -> u64
      !{crypto, mem, sysreg} @{paideia.crypto, cap}
    = …
```

```paideia-as
pub let delegate_endpoint
    : (@cap(KIND_IPC_ENDPOINT, R_IPC_INVOKE) u64) -> u64
    = fn (@cap(KIND_IPC_ENDPOINT, R_IPC_INVOKE) ep: u64) -> …
```

```paideia-as
pub let dek_apply_slot
    : (@cap(KIND_DEK, R_DEK_SEAL | R_DEK_READ) u64) -> u64
    = fn (@cap(KIND_DEK, R_DEK_SEAL | R_DEK_READ) slot: u64) -> …
```

Illegal (rejected at parse time):

```paideia-as
let x : u64 = @cap(KIND_DEK, R_DEK_READ) y    // E0904: not a param position
```

```paideia-as
fn f() -> @cap(KIND_DEK, R_DEK_READ) u64      // E0904: not a return position
```

---

## 4. Elaborator obligations

The elaborator (`paideia-as`'s type/effect checker; the surface pass
between parser and lowering) grows a new pass **cap-origin tracking**.

### 4.1 Cap-origin tracking

For every value in a function body, the elaborator maintains an
`Option<(CapKind, CapRights)>` origin tag:

- A `let` binding of a value with origin `(K, R)` inherits `(K, R)`.
- A function argument annotated `@cap(K, R)` has origin `(K, R)`.
- A call to a function returning a value tagged `@cap(K, R)` has
  origin `(K, R)` (M7 scope; M6 does not model this because return-
  position `@cap` is illegal at M6).
- Any arithmetic operation (`+`, `-`, `*`, `/`, `%`, `<<`, `>>`, `&`,
  `|`, `^`) with at least one non-cap operand **erases** the origin.
  Both operands cap-typed: still erased (the result is not a cap).
- A load from memory without a cap-type annotation at the load site
  has `None` origin.
- A load from `cap_table[row*CAP_ROW_BYTES + 8]` (rights field read)
  has an origin bootstrapped from the row-table pass at load time.

### 4.2 Rights-subset check at call sites

At every call site, for each argument position whose formal parameter
is `@cap(K, R)`, the elaborator checks:

- The argument's origin is `Some((K', R'))` (not `None`).
- `K == K'`.
- `R ⊆ R'` (the formal's required rights are a subset of what the
  argument has).

Any failure emits a diagnostic (§6).

### 4.3 Delegation declaration

A function that **passes** a cap-typed argument further down the call
chain is implicitly declaring that it may delegate. M6 does not require
an explicit `@delegate` sigil; §4.1's origin tracking already captures
the information. M7 may add an explicit `@delegate` requirement if
revocation-tracking needs it.

### 4.4 Interaction with the ambient `@{…}` set

A function with `@cap(K, R)` on a parameter does NOT need to include
`K`-named cap in its `@{…}` set. The per-arg sigil is self-contained;
the ambient set remains for ambient-env caps the function uses outside
its arg list.

Lint rule (future): warn if a function's `@{…}` set names a cap of the
same KIND as one of its `@cap` arguments. This is almost always a
redundancy or a copy-paste error.

---

## 5. Emitter obligations

### 5.1 At M6

**None.** The emitter passes the parsed `CapSigil` through to the
elaborator and discards it before lowering. The emitted machine code
is byte-identical to what the function would emit without the sigil.

The sigil's presence is recorded only in the `.debug_paideia.caps`
section (§7) so future-tool-chain `objdump`-equivalents and
`paideia-as lint` can audit the ELF.

### 5.2 At M7 (future)

Each cap-typed parameter grows a **per-call-site stub** at the function
body's prologue. The stub, in paideia-as asm sketch:

```
// Prologue addition for a @cap(K, R) parameter in rN:
//   1. Load the active cap-env slot: slot_hdl = rN
//   2. Lookup the row:              row_ptr  = cap_table_row(slot_hdl)
//   3. Read the KIND tag:           got_kind = [row_ptr + CAP_ROW_KIND_OFF]
//   4. Compare to K:                cmp got_kind, K; jne cap_check_fail
//   5. Read rights field:           got_rights = [row_ptr + CAP_ROW_RIGHTS_OFF]
//   6. Mask-subset:                 and got_rights, R; cmp got_rights, R; jne cap_check_fail
//   7. Fall through to body.
```

The stub cost is ~6-8 instructions per cap-typed parameter — well
within the "no cap-check hot-path hit" posture (M4 §Non-goals already
accepts ~15 instructions for the ambient check).

Emission is behind a per-function opt-out knob (`#pragma no-cap-check`)
for kernel-origin / pre-userspace paths that cannot afford the stub
(M4 §Non-goals 3's "hard-failing kernel-origin syscalls" discipline).

### 5.3 Hand-off from M6 to M7

The emitter's M6 posture leaves a **TODO breadcrumb** in the debug-info
section: every cap-typed parameter records a `check_level = 0` byte in
its `.debug_paideia.caps` row. M7's wave flips every row to
`check_level = 1` as its emitter lands the stub.

A row's `check_level` is itself audit-visible: an ELF carrying
`check_level = 0` rows after M7 ships is a toolchain bug — the linter
refuses the image.

---

## 6. Diagnostic catalogue

Codes allocated to the cap-typed-arg surface:

| Code | Class | Meaning |
|---|---|---|
| `E0900` | parse | `@cap(…)` body is malformed (bad kind path, bad rights expr). |
| `E0901` | elab  | Non-cap-origin value passed to a `@cap(K, R)` parameter. |
| `E0902` | elab  | Rights-subset check fails: argument has rights `R'`, formal requires `R`, and `R ⊄ R'`. |
| `D0902` | diag  | Rights-subset check deferred to runtime (M7); argument's rights are not statically known. |
| `E0903` | elab  | Cap-rights widening attempted (narrower argument origin into wider formal). |
| `E0904` | parse | `@cap(…)` in an illegal position (return type, let type, struct field, etc.). |
| `E0905` | elab  | KIND mismatch: argument origin is `(K', R')` but formal requires `(K, R)` with `K != K'`. |
| `E0906` | elab  | `@cap(…)` kind path does not resolve to a `u64` compile-time constant. |
| `E0907` | elab  | `@cap(…)` rights expression does not resolve to a `u64` compile-time constant. |
| `W0908` | lint  | Ambient `@{K-cap}` redundant with `@cap(K, R)` parameter on same function. |

E-codes are hard errors; D-codes are informational (compile continues);
W-codes are lint warnings (compile continues, formatter notes).

---

## 7. Debug-info extension

### 7.1 Section layout

The existing `.debug_paideia.caps` section (per
`custom-assembler.md` §9.5 — "DWARF extension declaring capability
handle types and their substructural class") grows a new record type
**ParamCap** for M6:

```
struct ParamCap_row {
    u32  fn_debug_ref;    // offset into .debug_info to this function's DIE
    u32  param_index;     // 0-based param position (SysV register-order)
    u64  kind;            // KIND_* constant value
    u64  rights;          // required-rights mask
    u8   check_level;     // 0 = M6 static-only; 1 = M7 runtime-stub-emitted
    u8   reserved[7];     // pad to 32 bytes
}
```

Fixed-size 32-byte rows, counted by a §-header `row_count: u32`.

### 7.2 Consumer

`scripts/gdb/paideia.py` (per `custom-assembler.md` §9.5) grows a new
command `info cap-params <fn>` that lists every cap-typed parameter of
a function. Backward-compatible with existing `.debug_paideia.caps`
reads (new row-type is behind a tag byte in the section header).

### 7.3 ABI version bump

`.debug_paideia.caps` bumps its ABI version byte (minor) from whatever
it is today to one higher. The reader rejects older ABI versions with a
clear "please rebuild with M6-or-later paideia-as" diagnostic.

---

## 8. `caps.decl` cross-check

The M3 `.caps.decl` section (`design/shell/elf-caps-decl.md`) carries
the manifest a program is willing to accept at execve-time. M6 adds a
**cross-check** step at `paideia-as lint` time:

For every exported function with `@cap(K, R)` on at least one parameter,
the linter verifies that the program's `caps.decl` either:
- declares a cap of KIND `K` (so the caller can be expected to hold
  it), or
- marks the function as receiving its cap-arg from a derived source
  (via `svc.cap-minter` within the program).

A missing cross-check emits `W0909 (cap-arg references undeclared KIND in caps.decl)`.

This is a lint only, not a hard error — a library crate exporting
cap-typed signatures does not itself declare a `caps.decl` manifest
(binaries do).

---

## 9. Formatter

`paideia-fmt` is updated to:

- Preserve `@cap(…)` sigils exactly where the author wrote them (no
  reflow across the sigil-param boundary).
- Normalize whitespace inside the parens to a single space after each
  comma (`@cap(KIND_DEK, R_DEK_READ)` — not `@cap(KIND_DEK,R_DEK_READ)`
  nor `@cap( KIND_DEK , R_DEK_READ )`).
- Emit a canonical column break after the sigil if the full parameter
  overruns 100 columns (`syntax-reference.md` §10.1 wrap posture).

---

## 10. Grammar impact summary

The paideia-as grammar grows:

- 1 new parser rule family (`CapSigil`, `CapKind`, `CapRights`,
  `RightsExpr`).
- 1 modified rule (`LambdaParams` → `(Param)+`).
- 1 modified rule (`Type` arg list grows `TypeInArgList` wrapper).
- 1 contextual recognition rule in the lexer-parser interface
  (`@` + `cap` + `(`).
- 1 new section-header byte in `.debug_paideia.caps`.
- 1 ABI version bump on `.debug_paideia.caps`.
- 10 new diagnostic codes (`E0900`-`E0907`, `D0902`, `W0908`, `W0909`).

**No existing surface construct changes meaning.** The grammar
extension is strictly additive. Pre-M6 source files continue to parse
and compile with identical semantics.

---

## 11. Implementation discipline notes for the paideia-as wave

Flagging the paideia-as encoder pitfalls that would bite a careless
implementer of this spec:

- **Keyword table.** Do NOT add `cap` to the global reserved-word
  table. The contextual-recognition rule in §2.3 preserves the
  `cap p : …` idiom from `custom-assembler.md` §2.2.
- **One-token lookahead.** The `@` `cap` `(` recognition is a
  three-token lookahead at a parameter-position cursor. Verify the
  existing parser already distinguishes "parameter-position" from
  "expression-position" so §3.3 ("illegal in let type") can reject.
- **`PathIdent` resolution.** `KIND_DEK` lives in
  `src/kernel/core/cap/kind_dek.pdx` as a `pub let`. The elaborator
  must resolve such paths against the full module tree at the
  function's declaration site — not against the function's local
  scope.
- **Rights mask bitwise OR.** `R_DEK_READ | R_DEK_SCRUB` is a
  compile-time constant expression. The elaborator folds it at
  elaboration time; the emitter sees a single `u64`.
- **Debug-info row size.** 32 bytes exactly (§7.1). Rows after the
  §-header are back-to-back without padding; a reader does
  `header.row_count * 32` to find the end-of-section.
- **Module basename.** Grammar extensions in paideia-as source files
  must respect the module-basename-matches-file-name rule
  (`feedback_pdx_encoder_pitfalls`).

---

## 12. One-line summary

`@cap(KIND, RIGHTS)` is a parse-time additive parameter sigil that
tags a `u64` as a cap-slot handle; the elaborator checks origin and
rights-subset; the M7 emitter will lower each sigil to a 6-8-instruction
per-call-site prologue stub.
