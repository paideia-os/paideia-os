# PaideiaOS — paideia-as Syntax Reference

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Normative reference for the paideia-as surface syntax: lexical structure, identifiers, literals, reserved words, glyph table with ASCII fallbacks, EBNF grammar, operator precedence, whitespace rules, and style conventions. Addresses AS2 from `custom-assembler.md`.

**Hard inputs:**
- `custom-assembler.md` §2 — surface syntax design (Q-A1 wholly novel syntax around capability/effect notation).
- `custom-assembler.md` §11 — error reporting (diagnostics referring to source positions in this syntax).
- Pillar 5 — no legacy carry-over unless best design; ASCII alone is legacy.
- Pillar 8 — native Unicode.
- E13 — native Unicode subsystem.

---

## 0. Decisions summary

| # | Choice | Source |
|---|---|---|
| SY-D1 | Source encoding: **UTF-8** | Pillar 5 / E13 |
| SY-D2 | Unicode and ASCII forms are both accepted on input; **Unicode is canonical** for the formatter output | §2.2 of custom-assembler.md + pillar 5/8 (taken) |
| SY-D3 | Block delimiters: **`{` `}`**; newline OR semicolon separates statements within a block | Implicit in §2.3 examples (taken) |
| SY-D4 | Comments: `//` line, `/* ... */` block, `///` doc | Standard Rust/C-like (taken) |
| SY-D5 | Identifier syntax: Unicode XID_Start + XID_Continue per UAX #31, plus ASCII digits and underscore | Modern language convention (taken) |
| SY-D6 | Number literals: decimal `123`, hex `0x1F`, binary `0b1010`, octal `0o17`; underscore separators allowed `1_000_000`; suffixes for size `42u32`, `42i64`, `42.0f64` | Rust-style (taken) |
| SY-D7 | String literals: `"..."` with `\n \t \r \\ \" \xNN \u{NNNN}` escapes; raw strings `r"..."` and `r#"..."#` | Rust-style (taken) |
| SY-D8 | Operator precedence and associativity follow the table in §7 | Standardized per §7 (taken) |
| SY-D9 | Reserved words are listed in §3.4 and cannot be used as identifiers | Mechanical (taken) |
| SY-D10 | Style conventions: 2-space indent; lines ≤ 100 cols; `paideia-fmt` enforces | Project policy (taken) |

---

## 1. Source files

### 1.1 File extension

- `.pdx` — paideia-as source files.
- `.pdi` — interface files (`module : <Signature>` declarations only).
- `.pds` — semantic-shell scripts (separate language, but the lexer is shared at the identifier/literal level).

### 1.2 Encoding

UTF-8 is mandatory. A leading BOM (`U+FEFF`) is permitted but stripped by the lexer. Other encodings cause lexer error `E0001 (encoding)`.

### 1.3 Line endings

`LF` (`U+000A`) is canonical. `CR LF` is accepted and normalized to `LF` by `paideia-fmt`. A lone `CR` causes `E0002 (line-ending)`.

### 1.4 Maximum source-file size

Up to 2 GiB per source file (informally; practical files are far smaller). The parser supports streaming for files up to this limit.

---

## 2. Lexical structure

### 2.1 Whitespace

| Codepoint | Meaning |
|---|---|
| `U+0009` (TAB) | Whitespace (formatter normalizes to spaces) |
| `U+000A` (LF) | Newline; statement separator within blocks |
| `U+000D` (CR) | Accepted only as part of CR LF |
| `U+0020` (SPACE) | Whitespace |
| `U+200B` (ZWSP) | Forbidden in source (error `E0003 (invisible)`) |

Whitespace separates tokens but is otherwise insignificant within a statement; newline ends a statement within a block.

### 2.2 Comments

```paideia-as
// Line comment to end of line
/* Block comment.  May span lines. */
/// Doc comment for the next item.
/** Block doc comment. */
```

Doc comments attach to the next declaration; they appear in generated documentation (per `paideia-as doc`).

### 2.3 Token classes

Tokens are classified as:

- **Keyword** (reserved word).
- **Identifier**.
- **Literal** (number, string, character).
- **Operator** (single- or multi-character).
- **Punctuation** (delimiters: `( )`, `{ }`, `[ ]`, `,`, `;`, `:`, `.`).
- **Effect/capability bracket**: `!{`, `@{`.
- **Substructural marker**: `↓` / `$` (linear consume), `~` (affine drop).

### 2.4 Lexer error recovery

The lexer attempts to continue past an error to surface multiple diagnostics in one pass. After 100 errors, it bails.

---

## 3. Identifiers and reserved words

### 3.1 Identifier syntax

Following UAX #31 with extension to allow leading underscores:

```
identifier ::= (XID_Start | '_') (XID_Continue | '_')*
```

The Unicode XID properties allow most non-ASCII letters and digits used in human languages.

### 3.2 Conventions

- `snake_case` for values and functions.
- `PascalCase` for types, modules, signatures, effects.
- `SCREAMING_SNAKE_CASE` for compile-time constants.
- Leading underscore (`_foo`) for intentionally unused.
- Single underscore (`_`) is the wildcard / placeholder.

### 3.3 Raw identifiers

`` `keyword` `` (backtick-quoted) treats a keyword as an identifier. Use sparingly (interfacing with external code that uses a reserved word).

### 3.4 Reserved words

The reserved words are partitioned by role.

**Item declarations:**
```
let       fn        module    signature    structure    functor
effect    capability extern    import       export       pub
```

**Control flow:**
```
if        else      match     when         do           with
loop      while     for       break        continue     return
yield
```

**Type system:**
```
type      enum      struct    trait        where        forall
ordered   linear    affine    unrestricted
```

**Effect system:**
```
handle    perform   resume    finally
```

**Substructural / unsafe:**
```
unsafe    move      borrow    consume      drop         own
```

**Literals and constants:**
```
true      false     null      Self         self
```

**Memory and addressing:**
```
sizeof    alignof   offsetof  asm
```

**Module operations:**
```
in        as        use
```

**Future reservations (cannot be used as identifiers):**
```
abstract  async     await     coroutine    deriving     dyn
implicit  lemma     proof     reflect      virtual
```

All other words are valid identifiers.

---

## 4. Glyph table — Unicode primary with ASCII fallback (SY-D2)

`paideia-as` source may use either Unicode glyphs or ASCII sequences for the following constructs. `paideia-fmt` normalizes to Unicode.

| Construct | Unicode | ASCII fallback | Note |
|---|---|---|---|
| Effect set open | `!{` | `!{` | Both same; the `!` is ASCII |
| Effect set close | `}` | `}` | Same |
| Capability set open | `@{` | `@{` | Same |
| Capability set close | `}` | `}` | Same |
| Linear consume | `↓` (U+2193) | `$` | Prefix marker on operands |
| Affine drop | `~` (U+007E) | `~` | Same (ASCII is the canonical) |
| Function arrow | `→` (U+2192) | `->` | In function-type signatures |
| Right-arrow lambda | `↦` (U+21A6) | `=>` | In lambda return |
| Type ascription | `∷` (U+2237) | `::` | In type declarations |
| Module signature ascription | `⊢` (U+22A2) | `\|-` | Capability binding context |
| Parameterized capability | `⊣` (U+22A3) | `-\|` | Derived-from notation |
| Forall | `∀` (U+2200) | `forall` | Universal quantification |
| Exists | `∃` (U+2203) | `exists` | Existential quantification (rare in source) |
| Lambda | `λ` (U+03BB) | `fn` | Lambda introduction |
| Effect lookup | `Σ` (U+03A3) | `Sigma` | Sum / record (rare) |
| Subset | `⊆` (U+2286) | `<=` | In effect-row constraints |
| Element-of | `∈` (U+2208) | `in` | In substructural checking |
| Logical and | `∧` (U+2227) | `and` | In where-clauses |
| Logical or | `∨` (U+2228) | `or` | Same |
| Logical not | `¬` (U+00AC) | `not` | Same |
| Cdot multiplication | `·` (U+00B7) | `*` | In some macros (rare) |
| Empty / unit | `∅` (U+2205) | `()` | Empty effect row |
| Top type | `⊤` (U+22A4) | `Top` | Universal type (in macros) |
| Bottom type | `⊥` (U+22A5) | `Bot` | Empty type (diverging functions) |
| Bullet | `•` (U+2022) | `*` | List bullet in doc comments |
| Right double arrow | `⇒` (U+21D2) | `==>` | Reserved for future use |

`paideia-fmt --ascii` produces ASCII-only output for environments without Unicode rendering.

---

## 5. Literals

### 5.1 Number literals

```
123                  // decimal i32 by default
123u32               // explicit u32
123i64               // explicit i64
123u                 // platform usize
1_000_000            // underscore separators
0x1F                 // hexadecimal
0xff_aa              // hex with separators
0b1010               // binary
0b1010_1100          // binary with separators
0o17                 // octal (rarely used)
3.14                 // f32 by default
3.14f64              // explicit f64
3.14e10              // scientific
1_000.5              // separator in float
0x1.8p3              // hexadecimal float (rare)
```

Type suffixes: `u8`, `u16`, `u32`, `u64`, `u128`, `usize`, `i8`, `i16`, `i32`, `i64`, `i128`, `isize`, `f32`, `f64`.

### 5.2 Character literals

```
'a'                  // ASCII character (Char)
'\n'                 // newline
'\t'                 // tab
'\r'                 // CR
'\\'                 // backslash
'\''                 // single quote
'\xNN'               // byte (in 0..127)
'\u{NNNN}'           // Unicode codepoint
'家'                 // Direct Unicode character
```

A character literal is one Unicode codepoint, type `Char` (32 bits).

### 5.3 String literals

```
"hello"
"hello\nworld"
"unicode: \u{1F600}"
""                   // empty string
r"raw, no escapes"   // raw string
r#"raw with " in it"#
r##"raw with "# in it"##
```

Strings are UTF-8 encoded. The `r` prefix disables escape interpretation; `r##"..."##` allows embedded quotes by using more hashes.

### 5.4 Byte and byte-string literals

```
b'A'                 // u8
b"hello"             // [u8; 5]
br"raw bytes"        // raw bytes
```

### 5.5 Boolean literals

`true`, `false`.

### 5.6 Unit literal

`()` (empty tuple); type `Unit`.

---

## 6. Punctuation

| Token | Use |
|---|---|
| `(` `)` | Grouping; function call; tuple |
| `{` `}` | Block; struct/enum body |
| `[` `]` | Indexing; array literal; capability-set inner |
| `,` | Separator (function args, struct fields, tuple, list) |
| `;` | Statement separator within a block (alternative to newline) |
| `:` | Type ascription; module ascription |
| `::` | Path separator (`Module::Item`); type-ascription (Unicode `∷`) |
| `.` | Field access; method call |
| `..` | Range; rest pattern; struct update |
| `...` | Variadic (rare; in macros) |
| `?` | Try operator; optional |
| `!` | Effect-set introducer (`!{...}`); macro invocation (`name!`); negation in patterns |
| `@` | Capability-set introducer (`@{...}`); pattern binding (`name @ pat`) |
| `&` | Reference; bitwise AND |
| `\|` | Pipe; bitwise OR; lambda parameter list |
| `\|>` | Pipeline operator (shell-style; in lambda body); not for assembly source |
| `=` | Assignment; let-binding |
| `==`, `!=`, `<`, `<=`, `>`, `>=` | Comparison |
| `+`, `-`, `*`, `/`, `%` | Arithmetic |
| `+=`, `-=`, `*=`, `/=`, `%=` | Compound assignment |
| `&&`, `\|\|` | Logical AND, OR |
| `<<`, `>>` | Bit shifts |
| `^` | Bitwise XOR |
| `~` | Bitwise NOT (also affine drop, by context) |
| `->` | Function arrow (`→`) |
| `=>` | Match-arm arrow (`↦`) |
| `→`, `↦` | Unicode forms |

---

## 7. Operator precedence

From tightest to loosest binding. All operators left-associative except where noted.

| Tier | Operators | Associativity | Note |
|---|---|---|---|
| 1 | `::` `.` `(...)` `[...]` `?` | left | Postfix / member access |
| 2 | `!` (unary) `~` (unary) `-` (unary) `&` (unary) `*` (unary deref) | right | Prefix |
| 3 | `*` `/` `%` | left | Multiplicative |
| 4 | `+` `-` | left | Additive |
| 5 | `<<` `>>` | left | Shifts |
| 6 | `&` (binary) | left | Bit AND |
| 7 | `^` | left | Bit XOR |
| 8 | `\|` (binary) | left | Bit OR |
| 9 | `==` `!=` `<` `<=` `>` `>=` | left | Comparison |
| 10 | `&&` `∧` | left | Logical AND |
| 11 | `\|\|` `∨` | left | Logical OR |
| 12 | `..` `..=` | none | Range |
| 13 | `=` `+=` `-=` `*=` `/=` `%=` `&=` `\|=` `^=` `<<=` `>>=` | right | Assignment |
| 14 | `,` | left | Tuple / argument list |

The pipeline operator `|>` (used in `.pds` semantic-shell only, not in assembly source) binds tighter than assignment, looser than comparison.

---

## 8. Grammar (EBNF, abridged)

The following EBNF is the *normative* grammar at the top level; the full grammar is generated mechanically from the parser source and lives at `src/toolchain/asm/grammar.ebnf` (future).

```ebnf
SourceFile ::= ItemDecl*

ItemDecl ::= ModuleDecl
           | SignatureDecl
           | LetDecl
           | EffectDecl
           | CapabilityDecl
           | StructDecl
           | EnumDecl
           | UnsafeBlock

ModuleDecl ::= "module" Identifier (":" SignatureRef)? "=" ModuleBody
ModuleBody ::= Structure | Functor

Structure ::= "struct" "{" ItemDecl* "}"
Functor ::= "functor" "(" FunctorParam ")"+ "->" "struct" "{" ItemDecl* "}"

LetDecl ::= "let" Identifier (":" Type)? "=" Expr

EffectDecl ::= "effect" Identifier "{" OpSig+ "}"
OpSig ::= "op" Identifier ":" Type ("!" "{" EffectSet "}")?

Expr ::= LambdaExpr
       | ActionBlock
       | WithHandlerExpr
       | UnsafeExpr
       | InfixExpr
       | PrefixExpr
       | PostfixExpr
       | LiteralExpr
       | IdentifierExpr
       | CallExpr
       | BlockExpr
       | MatchExpr
       | IfExpr
       | LoopExpr

LambdaExpr ::= ("fn" | "λ") LambdaParams "->" Expr
             | "|" Identifier ("," Identifier)* "|" Expr

LambdaParams ::= "(" Pattern ":" Type ")" ("(" Pattern ":" Type ")")*

ActionBlock ::= "action" ("!" "{" EffectSet "}")? ("@" "{" CapSet "}")? "{" Stmt+ "}"

WithHandlerExpr ::= "with" Expr "handle" Identifier BlockExpr

UnsafeExpr ::= "unsafe" "{" UnsafeFields "}"
UnsafeFields ::= "effects" ":" "{" EffectSet "}" 
              "capabilities" ":" "{" CapSet "}"
              "justification" ":" StringLit
              "block" ":" "{" Stmt+ "}"

Stmt ::= LetStmt
       | ExprStmt
       | InstructionStmt
       | ReturnStmt

InstructionStmt ::= Mnemonic Operand ("," Operand)*

Operand ::= Register
          | ImmediateExpr
          | MemoryRef

MemoryRef ::= "[" AddrExpr "]"
AddrExpr ::= BaseReg ("+" IndexReg ("*" Scale)? ("+" Disp)?)?

Type ::= TypeName ("(" Type ("," Type)* ")")?
       | "(" Type ")" "->" Type EffectSetOpt CapSetOpt
       | "(" Type ("," Type)* ")"
       | LinClass Type
       | EffectRowType

LinClass ::= "ordered" | "linear" | "affine" | "unrestricted" | "↓" | "~"

EffectSet ::= Identifier ("," Identifier)* "|" Identifier
            | "ε"
CapSet ::= Identifier ("," Identifier)*
```

This is illustrative; the canonical grammar lives in the toolchain source.

---

## 9. Whitespace and newline handling

### 9.1 Within a block

Statements within a `{...}` block are separated by:
- A newline (`LF`), or
- A semicolon (`;`), or
- Both.

### 9.2 Continuation lines

A statement may continue across lines if the line ends with an open paren, brace, bracket, infix operator, or comma. The lexer's continuation rule:

```
A newline does NOT terminate the statement if:
  - The preceding token is in:
    { ( [ , : -> => + - * / % == != < <= > >= && || | & ^ << >> = }
  - There is an unclosed paren/brace/bracket pair.
```

### 9.3 Statement boundary

A statement ends when:
- The lexer encounters `}` (closes the enclosing block), or
- A `;` not in a literal, or
- A `LF` that does not satisfy the continuation rule.

### 9.4 Indentation

Indentation is *style*, not significant. `paideia-fmt` enforces 2-space indent.

---

## 10. Style conventions

### 10.1 General

- 2-space indent; never tabs in source files (formatter rejects).
- Lines ≤ 100 columns (formatter wraps at boundaries).
- One blank line between top-level items; never two or more.
- Trailing whitespace forbidden.
- File ends with a single `LF`.

### 10.2 Naming

- Modules and signatures: `PascalCase`.
- Functions, values, fields: `snake_case`.
- Constants: `SCREAMING_SNAKE_CASE`.
- Type parameters: single uppercase letters (`T`, `U`, `E`, `S`) for short scopes; descriptive PascalCase for long scopes.

### 10.3 Effect and capability notation

- Effect sets always written `!{...}` (Unicode curly braces; ASCII curly braces are the canonical form regardless).
- Capability sets always written `@{...}`.
- Inside the brackets, identifiers comma-separated.
- Empty set: `!{}` or `@{}`.

### 10.4 Substructural markers

- `↓` (Unicode) preferred; `$` (ASCII) accepted; formatter normalizes to `↓` unless the file declares `#pragma ascii` (rare).

### 10.5 Imports

- Imports at the top of the file, grouped: standard library, third-party (if any), local modules.
- Sorted alphabetically within each group.
- One import per line.

---

## 11. ASCII-only mode

`paideia-as` accepts an `--ascii-only` flag and a per-file `#pragma ascii` directive. In ASCII mode:
- Unicode glyphs in operators (`→`, `↦`, `↓`, etc.) cause `E0010 (unicode-not-allowed)`.
- Unicode identifiers (XID_Start non-ASCII) are still allowed (this is identifier policy, separate from operator policy).
- The formatter outputs ASCII fallbacks only.

The default mode is *Unicode-allowed*; ASCII mode is opt-in for environments where the editor or terminal cannot render Unicode operator glyphs.

---

## 12. Errors emitted by the lexer

Per `custom-assembler.md` §11.4 diagnostic-catalog discipline. Each lexer error has a stable code:

| Code | Description |
|---|---|
| `E0001` | encoding error (not UTF-8) |
| `E0002` | line-ending error (lone CR) |
| `E0003` | invisible character forbidden (ZWSP, etc.) |
| `E0004` | unterminated string literal |
| `E0005` | unterminated block comment |
| `E0006` | invalid number literal (bad digits, out of range) |
| `E0007` | invalid character literal (more than one codepoint, bad escape) |
| `E0008` | invalid escape in string literal |
| `E0009` | invalid raw-string delimiter |
| `E0010` | unicode operator used in ASCII-only mode |
| `E0011` | reserved-word used as identifier |
| `E0012` | identifier starts with a digit or other invalid character |
| `E0013` | maximum file size exceeded |
| `E0014` | maximum nesting depth exceeded |
| `E0015` | invalid byte literal (out of `0..255`) |
| `E0016` | invalid Unicode escape (out of `0..0x10FFFF`) |
| `E0017` | surrogate codepoint in Unicode escape |
| `E0018` | source file empty or whitespace-only |

---

## 13. Examples

A complete (small) source file:

```paideia-as
//! Driver for the example device.
//!
//! Demonstrates linear capabilities, algebraic effects, and an unsafe escape.

module ExampleDriver : ExampleDriverSig = functor
  (Pci : PciCapSig)
  (Mmio : MmioCapSig)
  -> struct

  effect Example {
    op read_reg  : (off: u32) -> u32 !{mmio_read} @{Mmio.read_cap}
    op write_reg : (off: u32, value: u32) -> unit !{mmio_write} @{Mmio.write_cap}
  }

  let read_status_register
      : unit -> u32 !{mmio_read} @{Mmio.read_cap}
      = fn _ ->
        perform Example.read_reg(0x00)

  let configure_device
      : (config : DeviceConfig ↓) -> unit !{mmio_write} @{Mmio.write_cap}
      = fn config ->
        let regs = config.register_values
        for (off, val) in regs do
          perform Example.write_reg(off, val)

  // Hand-written MMIO fence is unrepresentable in the typed surface;
  // an unsafe block makes the escape explicit.
  let mmio_fence : unit !{mmio_fence} @{} =
    unsafe {
      effects: { mmio_fence }
      capabilities: {}
      justification: "Required before doorbell write; the elaborator does not
                      yet model fence semantics — track in toolchain issue T-0042."
      block: { sfence }
    }

end
```

---

## 14. Open issues

| ID | Issue |
|---|---|
| SY-O1 | The Unicode operator `↦` (right-arrow lambda) and ASCII `=>` both work for match arms; the lambda body uses `→`/`->`. Confirm the distinction holds; consider unifying. |
| SY-O2 | The full canonical grammar (in `.ebnf` form) — phase-1 deliverable from the parser implementation. |
| SY-O3 | The macro-expansion syntax (`macro_rules!`-equivalent) — referenced in the AST grammar but not yet specified in detail. |
| SY-O4 | The `Σ` (sum / row) and `∅` (empty) usage in macros — rare but should be specified. |
| SY-O5 | A formal-language-theory description of the grammar's ambiguity classes — phase-2 work. |
| SY-O6 | The pragma syntax (`#pragma ascii`, `#pragma optimize(...)`, etc.) — concrete spec. |
| SY-O7 | The doc-comment markup language — Markdown subset? Reuse the semantic-shell's rendering? |

---

*End of document.*
