# PaideiaOS — paideia-as Diagnostic Catalog

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Code-allocation rules, machine-readable schema, addition/deprecation discipline, and the initial catalog of diagnostic codes emitted by paideia-as. Addresses AS4 (functor sharing-constraint diagnostics — specific entries) and AS10 (versioning policy) from `custom-assembler.md`.

**Hard inputs:**
- `custom-assembler.md` §11 — three-output diagnostic structure (human / SARIF / LSP), category enum, code identifier, structured payload, suggestions.
- `syntax-reference.md` §12 — initial lexer error codes E0001–E0018.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| DI-D1 | Stable identifier format: `Cxxxx` where `C` is a category letter and `xxxx` is a 4-digit decimal | Project convention; matches Rust `E0xxx` pattern at glance |
| DI-D2 | Codes are stable forever once issued; deprecated codes are marked but never reused | Compatibility; users may grep their build logs |
| DI-D3 | Code ranges allocated per category (see §2) | Avoids collisions across teams; signals category at a glance |
| DI-D4 | Adding a new code requires PR including: rule statement, accepting example, rejecting example, expected payload, suggested fix | Keeps the catalog disciplined |
| DI-D5 | Catalog source-of-truth: `src/toolchain/diagnostics/catalog.toml` in the assembler repo (paideia-as) | One file, machine-readable, single update site |
| DI-D6 | SARIF output is the project schema's serialization; human format derived | SARIF is OASIS-standard; tools consume it |
| DI-D7 | LSP `code` is `Cxxxx`; LSP `codeDescription.href` points to `https://paideia-os.org/diagnostics/Cxxxx` | Modern LSP convention |

---

## 1. Code format

A diagnostic code is `<Category><Severity><Number>`:

```
   E 0 001
   │ │ │
   │ │ └── 4-digit number, allocated per category
   │ └──── severity level: 0 = error, 1 = warning, 2 = note, 3 = hint, 4 = lint
   └────── category letter (see §2)
```

Examples:
- `E0001` — error in category E, code 001
- `L1042` — warning in category L (linter), code 042
- `T0301` — error in category T (type system), code 301
- `S0050` — error in category S (substructural), code 050

In running text, codes are written without padding (`E1` is acceptable shorthand for `E0001`); in machine output, the full 4-digit form is normative.

---

## 2. Category ranges

| Letter | Category | Range | Owner |
|---|---|---|---|
| `E` | Encoding, lexer | 0001–0099 | paideia-as parser team |
| `P` | Parser (grammar, syntax) | 0100–0299 | paideia-as parser team |
| `M` | Module system, imports, functors | 0300–0499 | paideia-as elaborator team |
| `T` | Type system (HM + dependent + record) | 0500–0899 | paideia-as elaborator team |
| `S` | Substructural lattice (linearity, drops) | 0900–1099 | paideia-as elaborator team |
| `F` | Effect system (rows, handlers, closures) | 1100–1299 | paideia-as elaborator team |
| `C` | Capability discipline (kinds, rights, derivation) | 1300–1499 | paideia-as + capabilities team |
| `O` | Optimization passes | 1500–1599 | paideia-as opt-pass team |
| `U` | Unsafe-block discipline | 1600–1699 | paideia-as + security team |
| `B` | Binary emission (ELF, PE/COFF, PAX) | 1700–1799 | paideia-as emitter team |
| `D` | DWARF / debug info | 1800–1899 | paideia-as emitter team |
| `L` | Linter / style | 2000–2999 | paideia-as linter team |
| `W` | Workspace, build-graph | 3000–3099 | paideia-as toolchain team |
| `R` | Runtime checks (LAM verification, capability runtime) | 3100–3199 | kernel team |
| `Z` | Catch-all / experimental | 9000–9099 | reserved |

Ranges that fill up may be extended into the next decade (E0001-E0099 → E0100-E0199) only by a versioning-RFC.

---

## 3. The catalog file format

`src/toolchain/diagnostics/catalog.toml`:

```toml
[diagnostic.E0001]
severity = "error"
category = "lexer"
title = "Source file is not valid UTF-8"
brief = "The source file's bytes cannot be decoded as UTF-8."
description = """
PaideiaOS source files must be UTF-8 encoded. This file's bytes do not
form valid UTF-8. The first invalid byte is at the position indicated.
"""
example_accept = "examples/E0001/accept.pdx"
example_reject = "examples/E0001/reject.pdx"
payload_schema = "schemas/E0001.json"
suggested_fix = "Re-encode the source file as UTF-8. Most editors offer a 'Save with Encoding' option."
since = "0.1.0"
deprecated = false
deprecation_note = ""

[diagnostic.T0501]
severity = "error"
category = "type"
title = "Type mismatch"
brief = "The type of an expression does not match the expected type."
description = """
The expression at the primary span has type `<actual>`, but the context
expects type `<expected>`. The two types could not be unified.
"""
example_accept = "examples/T0501/accept.pdx"
example_reject = "examples/T0501/reject.pdx"
payload_schema = "schemas/T0501.json"
suggested_fix = "Adjust the expression to produce the expected type, or change the context to accept the actual type."
since = "0.1.0"
deprecated = false
```

Every diagnostic has:
- A unique code (the table key).
- A severity (error / warning / note / hint / lint).
- A category (informational; the letter prefix is the source of truth).
- A title (one-line summary for index views).
- A brief (≤ 80 characters; for terminal output).
- A description (Markdown; for documentation and LSP code-description).
- An example accept (a source file that the rule does *not* trigger on).
- An example reject (a source file that the rule *does* trigger on).
- A payload schema (JSON schema for the structured payload).
- A suggested fix (one or more lines).
- A `since` version (when the diagnostic was added).
- A `deprecated` flag (with optional `deprecation_note`).

---

## 4. Code allocation

### 4.1 Adding a new code

Process:
1. Identify the appropriate category and a free number in its range.
2. Add the entry to `catalog.toml`.
3. Add accepting and rejecting example files.
4. Define the structured-payload JSON schema.
5. Implement the diagnostic emission in the relevant assembler stage.
6. Add a regression test to `tests/diagnostics/`.
7. Open a PR with two reviewers (per category-owner table in §2).

### 4.2 Code retirement

A code may be deprecated (the catalog marks `deprecated = true` with a note) but **never reused**. A reused code would mean a build log's `T0501` could refer to two different things across versions — unacceptable.

### 4.3 Renumbering forbidden

Once a code is in the catalog and shipped, its identifier is immutable. Even if its semantics are slightly clarified in later versions, the code stays.

### 4.4 Title and description editing

Title and description may be edited freely (clarity, typo fixes, more detail). Brief should be kept stable for cross-version grep matching.

### 4.5 Severity changes

Changing a diagnostic's severity (e.g., warning → error) is a breaking change. Such changes require:
- Major version bump for the assembler.
- Migration guide.
- A compatibility flag (`--ignore-severity-changes`) for one minor version.

---

## 5. Structured payload (SARIF integration)

Every diagnostic carries a payload. The payload schema is per-code; common fields:

```json
{
  "code": "T0501",
  "severity": "error",
  "primary_span": {
    "file": "src/kernel/mm/page_table.pdx",
    "line": 142,
    "column": 17,
    "byte_offset": 4231,
    "length": 18
  },
  "secondary_spans": [
    {
      "file": "src/kernel/mm/page_table.pdx",
      "line": 89,
      "column": 7,
      "byte_offset": 2103,
      "length": 12,
      "label": "expected type defined here"
    }
  ],
  "payload": {
    "expected_type": "PageTableCap",
    "actual_type": "MemCap",
    "unification_path": ["arg 2 of map_page", "expected PageTableCap"]
  },
  "fixes": [
    {
      "description": "retype the memory cap to a PageTableCap first",
      "rewrite": { "before": "mem", "after": "retype(mem, PageTableCap)" }
    }
  ]
}
```

The SARIF v2.1.0 emitter wraps this in a `Result` object per the SARIF schema.

---

## 6. Initial catalog (illustrative)

The full catalog is in the assembler repo. The following are representative entries that downstream documents reference.

### 6.1 Lexer (`E`)

Already listed in `syntax-reference.md` §12: `E0001`–`E0018`.

### 6.2 Parser (`P`)

| Code | Brief |
|---|---|
| `P0100` | Unexpected token; expected one of: ... |
| `P0101` | Mismatched delimiter |
| `P0102` | Empty expression |
| `P0103` | Unterminated expression |
| `P0104` | Invalid module declaration |
| `P0105` | Invalid signature declaration |
| `P0106` | Invalid functor parameter |
| `P0107` | Invalid effect declaration |
| `P0108` | Invalid capability set |
| `P0109` | Reserved word used as identifier |
| `P0110` | Recursive type declaration without recursion marker |

### 6.3 Module (`M`)

| Code | Brief |
|---|---|
| `M0300` | Module not found |
| `M0301` | Circular module dependency |
| `M0302` | Signature mismatch in module ascription |
| `M0303` | Missing implementation in module body |
| `M0304` | Functor application argument mismatch |
| `M0305` | Sharing constraint violation in functor (per AS4) |
| `M0306` | Module redefinition |

### 6.4 Type system (`T`)

| Code | Brief |
|---|---|
| `T0500` | Cannot unify types |
| `T0501` | Type mismatch |
| `T0502` | Cannot resolve type variable |
| `T0503` | Recursive type constraint |
| `T0504` | Kind mismatch |
| `T0505` | Type alias loop |
| `T0506` | Cannot infer type for binding |

### 6.5 Substructural (`S`)

| Code | Brief |
|---|---|
| `S0900` | Linear value not consumed |
| `S0901` | Linear value consumed twice |
| `S0902` | Affine value consumed in linear context |
| `S0903` | Ordered value used out of order |
| `S0904` | Substructural class downgrade requires explicit conversion |
| `S0905` | Unrestricted value used as linear |
| `S0906` | Linearity violation in if-branch (one branch consumes, other does not) |
| `S0907` | Capture of linear value by non-linear closure |

### 6.6 Effects (`F`)

| Code | Brief |
|---|---|
| `F1100` | Effect not handled |
| `F1101` | Effect handler type mismatch |
| `F1102` | Handler installation order invalid |
| `F1103` | Effect leaks across function boundary |
| `F1104` | Resume with mismatched type |
| `F1105` | Effect row unification failure |
| `F1106` | Forbidden effect in pure context |

### 6.7 Capability (`C`)

| Code | Brief |
|---|---|
| `C1300` | Required capability not held |
| `C1301` | Capability kind mismatch |
| `C1302` | Capability LAM tag mismatch |
| `C1303` | Capability revoked |
| `C1304` | Capability sealed (no unseal-cap) |
| `C1305` | Capability not present in derivation tree |

### 6.8 Optimization (`O`)

| Code | Brief |
|---|---|
| `O1500` | Optimization pass annotation conflicts with code structure |
| `O1501` | Pass disabled due to unsupported feature |
| `O1502` | Unsupported instruction for chosen pass |
| `O1503` | Pass produces semantically different code (regression) |

### 6.9 Unsafe (`U`)

| Code | Brief |
|---|---|
| `U1600` | `unsafe` block missing required field (effects, capabilities, justification, or block) |
| `U1601` | `unsafe` justification too short (< 20 chars) |
| `U1602` | `unsafe` declared capability not in caller's set |
| `U1603` | `unsafe` block touches register not in declared effect set |
| `U1604` | `unsafe` block contains forbidden instruction (e.g., `int 0x80`) |
| `U1605` | `unsafe` block uses a System V calling convention without bridge |

### 6.10 Binary emission (`B`)

| Code | Brief |
|---|---|
| `B1700` | Target architecture mismatch |
| `B1701` | Section overlap |
| `B1702` | Relocation overflow |
| `B1703` | Missing symbol |
| `B1704` | Duplicate symbol |
| `B1705` | PAX manifest construction failure |

### 6.11 DWARF (`D`)

| Code | Brief |
|---|---|
| `D1800` | DWARF emission failed |
| `D1801` | Source location not mapped |
| `D1802` | Vendor extension not supported (informational) |

### 6.12 Linter (`L`)

| Code | Brief |
|---|---|
| `L2000` | Unused binding (warning) |
| `L2001` | Identifier name does not match convention (warning) |
| `L2002` | Function too long (warning, > 100 lines) |
| `L2003` | Cyclomatic complexity too high (warning) |
| `L2004` | TODO comment in production code (warning) |
| `L2005` | Doc comment missing on public item (lint) |
| `L2006` | Line exceeds 100 columns (lint) |

### 6.13 Workspace (`W`)

| Code | Brief |
|---|---|
| `W3000` | Workspace member not found |
| `W3001` | Dependency cycle |
| `W3002` | Pinned version conflict |
| `W3003` | Toolchain version mismatch |

---

## 7. LSP integration

Per `custom-assembler.md` §11.3, the LSP server emits diagnostics with:

```json
{
  "code": "T0501",
  "codeDescription": {
    "href": "https://paideia-os.org/diagnostics/T0501"
  },
  "severity": 1,                    // 1=error, 2=warning, 3=info, 4=hint
  "message": "Type mismatch: expected PageTableCap, found MemCap",
  "source": "paideia-as",
  "range": { ... },
  "relatedInformation": [ ... ]
}
```

The `data` field carries the structured payload for client-side tooling (code-action templates).

---

## 8. Versioning

### 8.1 Catalog version

The catalog has a version number, tracked in `catalog.toml` header:

```toml
[catalog]
version = "0.1.0"
last_updated = "2026-06-17"
```

The catalog version is bumped per the assembler repo's semver:
- Patch: typo / wording edits to existing entries.
- Minor: new entries added.
- Major: severity changes, deprecations (rare).

### 8.2 Compatibility

A diagnostic emitted by version `0.x.y` of the assembler is valid in any future version `≥ 0.x.y`. Older versions may not know the diagnostic exists; that's an acceptable forward-compatibility property.

### 8.3 Deprecation

Marking a diagnostic deprecated:
- Sets `deprecated = true`.
- Adds a `deprecation_note` explaining why.
- Keeps the code in the catalog forever (no reuse).

The assembler continues emitting deprecated diagnostics until removal (usually one major version after deprecation). Removal means the assembler no longer emits the code; the catalog entry remains as historical record.

---

## 9. Open issues

| ID | Issue |
|---|---|
| DI-O1 | The `https://paideia-os.org/diagnostics/Cxxxx` URL scheme — when is the website live? Until then, LSP uses local file paths. |
| DI-O2 | Translations of human-format messages — locale support? Phase 3+. |
| DI-O3 | The relationship between diagnostic codes and the audit log — is a build-error-emission auditable? Phase 2+ design. |
| DI-O4 | Whether deprecated codes are surfaced in LSP completions for code references (currently: yes; user-configurable later). |
| DI-O5 | The R-category (runtime) is partially listed here but really belongs to kernel/runtime work — clarify ownership in the next revision. |

---

*End of document.*
