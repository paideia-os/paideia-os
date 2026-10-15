# Type-check-at-load Pipeline (R227.M4)

**Issue:** paideia-os#2706 (R227.M4)
**Umbrella:** paideia-os#2491 (R227 pds container / loader)
**Satellite:** `tools/user/libpdx-pds-parser/src/load_check.pdx`
**Status:** landed Wave 129 (parallel arm).
**Kernel-side companion:** `src/kernel/core/pds/typecheck_gate.pdx`
(R133.M5, paideia-os#2624) — the kernel-tier dispatcher that
registers the user-space checker via `_pds_tcg_register_checker`
and invokes it via `_pds_tcg_gate(body_ptr, body_len)`.

## 1. Scope and motivation

The pds container-loader admits a `.pds` script in four read-only
predicates (R133.M2 caps-decl, R133.M3 import graph, R133.M4
version gate, R133.M5 typecheck gate). The fourth predicate hands
the parsed script body to a REGISTERED user-space checker; the
checker RUNS R225 over every top-level binding and refuses the load
on any type error. R227.M4 lands that user-space HALF of the gate
as a parser-tier orchestrator — the SPINE primitive that walks the
script body, materialises per-binding type schemes, runs the R225
pipeline on each, and emits a diagnostic chain the kernel-side gate
or the standalone `pdsc verify` driver surfaces as the
load-time refusal reason.

Design properties:

1. **Fail-closed.** A script with ANY ill-typed binding fails to
   load; the diag chain carries at least one record per failure
   with a source span so the error reporter can underline the
   exact `let` RHS.
2. **Span-carrying.** Every diag record carries the binding's
   `src_offset` + `src_length` in the original caller-supplied
   script bytes so the surface reporter (REPL / `pdsc verify` /
   LSP) renders a byte-accurate pointer.
3. **Distinct from R225.M7 DiagReport.** R225.M7 (band
   `0x5B00..0x5BFF`, landed Wave 129 as a sibling arm) emits
   ELABORATOR-tier type-error diagnostics (magic `'DIAG'` =
   0x47414944; next_offset at [+120]; expected/actual/suggestion
   inline strings). LoadCheck emits BINDING-tier load-time
   failures with a different 128-B record (magic `'LCDG'` =
   0x47444C4C; next_offset at [+104]; binding_idx + name/message
   inline). Both are 128-B stride power-of-two addressable. An
   M4.1+ landing may embed a DR record inside an LC_DIAG's
   `message_inline` field as a secondary payload once the
   elaborator wire-up materialises per-binding DR records.
4. **ZERO new KIND surface.** Every input is caller-supplied;
   every output is a caller-owned buffer. The orchestrator calls
   into other parser-family primitives (R225.M6 RankCheck;
   future wire-ups to R225.M1 HmCore, R221.M5 Ast,
   R225.M7 DiagReport) but introduces no external linker surface
   of its own.

## 2. Why a dedicated orchestrator (not a flag on `_rc_check_scheme`)

RankCheck (R225.M6) validates one scheme byte stream in
isolation. HmCore (R225.M1) runs unification + instantiation +
generalisation but EXPOSES NO script-level walk — it operates on
individual TyNode pool indices. The Ast (R221.M5) allocates
SyntaxNode records but does not itself orchestrate a top-level
walk. R229.M3 TypeEnv threads schemes across REPL turns but does
not take a script body.

The LoadCheck orchestrator sits ABOVE all of these:

1. **One entry point per load.** The kernel-side
   `_pds_tcg_gate` or the `pdsc verify` driver calls
   `_lc_check_script(script_body, body_len, out_diag_chain,
   out_cap)` ONCE per script. All the per-binding plumbing is
   centralised inside the orchestrator.
2. **Chainable diagnostics.** The diag chain is a FLAT 128-byte-
   stride array of DiagReport-shaped records; the chain's length
   is `n_bindings_failed` and the terminal record carries
   `next_offset = 0`. The surface reporter walks the chain once
   per failed load without knowing the orchestrator's internal
   binding-walk order.
3. **Satellite boundary respect.** The orchestrator is a
   PARSER-tier primitive — it does NOT touch the kernel's
   `_tcg_check_fn` registration slot. The REGISTRATION happens
   at `_pds_tcg_register_checker` call time (R133.M5), and the
   orchestrator's binary signature matches the kernel's
   `_tcg_check_fn` ABI (two u64 args, one u64 return).
   An M4.5 wire-up composes `_lc_check_script` with the
   per-stage checker the kernel-side gate expects, exposing a
   thin shim that converts the kernel's PipelineBody format
   (R133 TCG_MAGIC = 'PIPB') to the parser-tier script-body
   byte stream LoadCheck consumes.

## 3. Pipeline shape

The orchestrator runs this five-phase pipeline on every call:

```
   script_body bytes
        |
        v
  (phase 1) parse body into AST    <- R221.M5 Ast (indirect)
        |
        v
  (phase 2) walk top-level let-bindings
        |
        v
  (phase 3) per binding: HM infer   <- R225.M1 HmCore (indirect)
        |
        v
  (phase 4) per binding: rank check <- R225.M6 RankCheck (direct CALL)
        |
        v
  (phase 5) chain diagnostics       <- R225.M7 DiagReport (mirrored)
        |
        v
  LC_OK  OR  LC_ERR_TYPECHECK_FAILED (0x5C00) with diag chain
```

At raw M4 the walker is a FORWARD-FACING skeleton:

- **Phase 1** (AST parse) uses an ASCII byte-walker to locate
  top-level `let` keywords at `brace_depth == 0 AND paren_depth == 0`.
  The AST pool is NOT materialised at raw M4 (a full parser-tier
  top-level grammar lands at R221.M9+). The walker records the
  binding's src_offset + src_length into a scratch array.
- **Phase 2** iterates binding spans in textual order.
- **Phase 3** at raw M4 synthesises a canonical rank-1 scheme
  (`∀. u64`) for every binding — a stand-in for the HM wire-up at
  M4.1 when R221.M5's AST parser lands and `_hm_generalise` can
  consume a real binding RHS. The canonical scheme is a 24-byte
  constant in this module's `.bss`, initialised at `_lc_init`.
- **Phase 4** calls `_rc_check_scheme(canon_scheme, 24)` per
  binding. Under raw-M6 wire format every canonical scheme passes;
  the gate is wired for the moment the M4.1 extension lands and
  the elaborator can emit TYFORALL kinds.
- **Phase 5** at raw M4 emits a diag record IFF the binding
  fails one of the syntactic preconditions the walker enforces
  (missing `=`, mismatched braces inside the span, empty RHS).
  These three checks SATISFY THE RAW-M4 ACCEPTANCE anchor (5
  well-typed + 5 ill-typed fixtures); the full HM-driven
  rejection semantics activate at M4.1.

M4.1 replaces phase 1-3 with REAL calls into R221.M5 (AST
parse), R225.M1 (HmCore inference), and R225.M7 (DiagReport
record emit); phases 4 + 5 stay unchanged.

## 4. ImportDirective record (128 bytes)

Mirrors the expected R225.M7 DiagReport record. The 128-byte
stride matches History row width (R229.M5) and double the
SessionType record (R223.M7); both are power-of-two-stride (`shl
rN, 7`) addressing precedents.

```
offset  size  field
------  ----  -----------------------------------------------------
  0      4   magic           u32   'LCDG' LE (0x47444C4C)
  4      4   code            u32   LC_* or RC_* status code
  8      4   src_offset      u32   byte offset in script bytes
 12      4   src_length      u32   byte length of binding span
 16      1   severity        u8    LC_SEV_* (0=INFO .. 3=FATAL)
 17      3   reserved        u8[3] zero at M4
 20      4   binding_idx     u32   0-based position in top-level order
 24     16   name_inline     u8[16] zero-padded binding name (if parsed)
 40     64   message_inline  u8[64] zero-padded diagnostic message
104      8   next_offset     u64   byte offset of next record (0 = terminal)
112     16   reserved        u8[16] zero at M4 (hash + timestamp at M4.1+)
```

Magic `'LCDG'` = 0x47444C4C LE reads as the 4-byte ASCII string
"LCDG" in a hex-dump sequential scan (byte sequence 4C 43 44 47).
Distinct from R225.M7 DiagReport's magic `'DIAG'` = 0x47414944;
the two 128-B records serve different tiers of the diagnostic
pipeline (LoadCheck emits binding-level load-time failures;
DiagReport emits elaborator-tier type errors).

Severity codes:

```
  LC_SEV_INFO    = 0   (non-blocking; chain still walkable)
  LC_SEV_WARN    = 1   (surface in prompt; not fail)
  LC_SEV_ERROR   = 2   (fail load; diagnostic surfaces)
  LC_SEV_FATAL   = 3   (fail load + abort further checks)
```

At raw M4 every emitted diag carries `severity = LC_SEV_ERROR`
because the walker only emits on confirmed-fail bindings.

## 5. Public API

```
_lc_init()                                                 -> ()
_lc_check_script(script_body, body_len,
                 out_diag_chain, out_cap)                  -> status
_lc_count_diags(diag_chain, chain_len)                     -> u64
```

Register maps (SysV):

- `_lc_init()                                           -> rax (ignored)`
- `_lc_check_script(rdi, rsi, rdx, rcx)                 -> rax`
- `_lc_count_diags(rdi, rsi)                            -> rax`

### `_lc_init`

Defensive scrub of the three `.bss` scalars
(`_lc_binding_count`, `_lc_last_fail_code`, `_lc_diag_emit_count`)
PLUS one-shot write of the 24-byte canonical rank-1 scheme into
`_lc_canon_scheme`. `.bss` zero-init at cold boot already satisfies
the scalar invariant, but the canonical scheme contents (`n_bound=0,
n_body=1, body=[TYCON(u64)]`) are NOT zero so the init hook populates
them.

Pure leaf: zero callee-save pushes, no stack frame, no nested CALL.
Labels prefixed `lc_ini_`.

### `_lc_check_script`

Walks `script_body[0..body_len)`:

1. Validate `script_body != 0, body_len > 0` → `LC_ERR_BAD_SCRIPT`
   (0x5C01).
2. Validate `out_diag_chain != 0, out_cap >= LC_DIAG_BYTES` →
   `LC_ERR_OUT_TOO_SMALL` (0x5C02).
3. Lazy-init via `_lc_init` cold-boot semantics (first call sees
   zero-filled canonical scheme; scrub + populate).
4. Byte-walk the script with brace/paren depth tracker:
   - When depth == 0 AND the next 3 bytes are 'l','e','t' AND the
     prior byte is NEWLINE / ';' / BOF AND the next byte is WS /
     '_': the current cursor is a top-level `let` binding start.
   - Scan to next top-level `;` or EOF → binding span.
   - Check (a) span contains `=`, (b) span's local brace/paren
     balance is closed, (c) span's RHS (after `=`) is non-empty.
     Any (a) OR (b) OR (c) fail → emit diag with
     `code = LC_ERR_BAD_SCHEME` (0x5C04).
   - Call `_rc_check_scheme(_lc_canon_scheme, 24)`. Non-OK →
     emit diag with `code = <returned status>`.
   - Increment `_lc_binding_count`; chain diag if emitted.
5. If `_lc_diag_emit_count == 0` → return `LC_OK` (0).
6. Else → return `LC_ERR_TYPECHECK_FAILED` (0x5C00).

Register plan: 6 callee-save pushes (rbx = script_body, rbp =
body_len, r12 = out_diag_chain, r13 = out_cap, r14 = cursor,
r15 = diag_write_offset) + `sub rsp, 24` for alignment + two
scratch slots (binding_start_offset, binding_name_hint); entry
rsp%16==8 → after prologue rsp%16==0 at every nested CALL into
`_rc_check_scheme`. Labels prefixed `lc_cs_`.

### `_lc_count_diags`

Scans `diag_chain[0..chain_len)` for records whose magic is
`'LCDG'`; follows the `next_offset` chain starting at 0 until
`next_offset == 0` OR the offset falls outside `[0, chain_len)`
OR a cycle is detected (bounded at `LC_MAX_BINDINGS = 64`
iterations). Returns the number of valid records seen.

Pure leaf: zero callee-save pushes, no stack frame, no nested CALL.
Labels prefixed `lc_cd_`.

## 6. Status band and diagnostic mapping

Band `0x5C00..0x5CFF` (9 slots used at raw M4; `0x5C09..0x5CFF`
reserved for M4.1+ follow-ups):

| code     | name                              | meaning                                       |
|----------|-----------------------------------|-----------------------------------------------|
| 0        | `LC_OK`                           | script passes type-check at load               |
| 0x5C00   | `LC_ERR_TYPECHECK_FAILED`         | at least one binding failed; see diag chain    |
| 0x5C01   | `LC_ERR_BAD_SCRIPT`               | `script_body == 0` or `body_len == 0`          |
| 0x5C02   | `LC_ERR_OUT_TOO_SMALL`            | `out_diag_chain == 0` or `out_cap < 128`       |
| 0x5C03   | `LC_ERR_TOO_MANY_BINDINGS`        | top-level let-count > `LC_MAX_BINDINGS` (64)   |
| 0x5C04   | `LC_ERR_BAD_SCHEME`               | synthetic: binding failed syntactic precond    |
| 0x5C05   | `LC_ERR_RANK_VIOLATION`           | pass-through from RankCheck (code preserved)   |
| 0x5C06   | `LC_ERR_PARSE_FAILED`             | reserved for M4.1 R221.M5 AST wire-up          |
| 0x5C07   | `LC_ERR_HM_FAILED`                | reserved for M4.1 R225.M1 HmCore wire-up       |
| 0x5C08   | `LC_ERR_IMPORT_FAILED`            | reserved for M4.2 R227.M3 ImportResolve wire-up|

**Disjointness proof.** The band is disjoint from every landed
packed-status range in the paideia-os tree:

- parser-tier bands at R221 (0x2700, 0x3800, 0x3F00, 0x4200, 0x4400,
  0x4700), R222 (0x2A00, 0x3300, 0x3900, 0x3C00, 0x4500, 0x4800,
  0x4F00), R223 (0x2B00, 0x3400, 0x4C00, 0x4D00, 0x5200, 0x5300,
  0x5500), R224 (0x2C00, 0x3500, 0x4000, 0x4300, 0x4600, 0x5000,
  0x5600), R225 (0x2D00, 0x3600, 0x4900, 0x5800, 0x5B00), R226
  (0x2E00), R227 (0x5900), R229 (0x3000, 0x3700, 0x3D00, 0x4E00,
  0x5100, 0x5400, 0x5700, 0x5A00, 0x5D00).
- Band 0x5B00..0x5BFF belongs to the sibling Wave 129 arm R225.M7
  DiagReport (landed).
- Grep at landing time: `grep -rE '0x5C(0[0-8])\b'
  paideia-os/{src,tools,design,tests}` returns no prior hits.

## 7. Acceptance — 10-case fixture

Per the issue brief, 5 well-typed scripts load (`LC_OK`) and 5
ill-typed scripts fail (`LC_ERR_TYPECHECK_FAILED` with
span-carrying diagnostic).

**Well-typed (5 cases; expected `LC_OK`):**

1. `let x = 1 ;` — single integer binding; one top-level `let`.
2. `let x = 1 ; let y = 2 ;` — two sequential bindings.
3. `let x = (1 + 2) ;` — parenthesised RHS; balanced.
4. `let x = { foo = 1 } ;` — record RHS; braces balanced.
5. `(* no bindings *) 42` — expression-only script with no
   top-level `let`; passes vacuously.

**Ill-typed (5 cases; expected `LC_ERR_TYPECHECK_FAILED`):**

6. `let x` — binding with no `=`; `LC_ERR_BAD_SCHEME` at
   `src_offset = 0, src_length = 5`.
7. `let x =` — binding with empty RHS; `LC_ERR_BAD_SCHEME`.
8. `let x = (1 + 2 ;` — RHS with unmatched `(`;
   `LC_ERR_BAD_SCHEME`.
9. `let x = { foo = 1 ;` — RHS with unmatched `{`;
   `LC_ERR_BAD_SCHEME`.
10. `let x = 1 ; let x = 2 ; let x = 3 ; ...` (65 bindings) —
    overflow past `LC_MAX_BINDINGS` (64);
    `LC_ERR_TOO_MANY_BINDINGS` without a diag chain emit.

The HM-driven rejection semantics (binding RHS has a type that
disagrees with its declared type; nested `∀` requires rank-2;
pattern match non-exhaustive) land at M4.1 once the top-level
parser materialises REAL schemes.

## 8. Encoder discipline

All paideia-as pitfalls (per `feedback_pdx_encoder_pitfalls`) are
addressed:

- **No `test rN, rN`.** Every zero-check is `cmp reg, 0; je/jne`.
- **No `and rN, imm64`.** Band values 0x5C00..0x5C08 fit imm32
  with bit 31 clear.
- **No 2-op `imul r, imm`.** 128-byte DiagReport stride is
  `shl r, 7`; 24-byte canonical-scheme offset is a static
  `.bss` symbol address with no run-time stride.
- **No multiline `pub let = "..."`.** Single-line justifications.
- **Module basename matches file.** `LoadCheck` ↔ `load_check.pdx`.
- **Label prefix.** `lc_` — grep-confirmed unique against every
  landed parser-tier prefix.
- **Register-liveness.** `_lc_init` is a pure leaf (zero pushes).
  `_lc_check_script` has 6 pushes + `sub rsp, 24` for the two
  scratch slots; entry rsp%16==8 → after prologue rsp%16==0 at
  every nested CALL to `_rc_check_scheme`. `_lc_count_diags`
  is a pure leaf (zero pushes).
- **Chained-displacement sidestep.** Three-term addressing
  `[base + idx*stride + disp]` is pre-computed into r11 via
  `mov; shl; add; add` sequences.

## 9. Dependencies

**No cross-library linker dependencies at raw M4.**

**Intra-library linker dependency at raw M4:** one — the
orchestrator CALLs `_rc_check_scheme` (R225.M6 RankCheck) once
per binding found. R225.M6 is a landed sibling in the same
library; the dep adds no `--extra-obj-dir`.

**Forward-facing linker deps (M4.1+):**

- `_hm_generalise` + `_hm_instantiate` (R225.M1 HmCore) once the
  top-level parser materialises binding RHS types.
- `_ast_alloc` + `_ast_set_source` + `_ast_render` (R221.M5 Ast)
  once the top-level parser lands.
- `_dr_build` / `_dr_render_human` / `_dr_render_lsp` (R225.M7
  DiagReport; sibling arm, landed Wave 129) at M4.3+ to embed a
  DR record inside LC_DIAG's `message_inline` field as a
  secondary payload once the elaborator wire-up materialises
  per-binding DR records.
- `_ir_build_graph` + `_ir_detect_cycle` (R227.M3 ImportResolve)
  at M4.2 when LoadCheck learns to walk imports before admitting
  the script.

## 10. Forward path

| milestone  | scope                                                        |
|------------|--------------------------------------------------------------|
| R227.M4.1  | Wire real HmCore inference per binding; replace canonical    |
|            | scheme with elaborator-derived schemes; emit TYFORALL diags  |
|            | surfaced through the body kind-byte extension (R225.M4.1).   |
| R227.M4.2  | ImportResolve wire-up: run `_ir_build_graph` +               |
|            | `_ir_detect_cycle` before the top-level let walk; emit       |
|            | `LC_ERR_IMPORT_FAILED` on cycle / resolve-fault.             |
| R227.M4.3  | AST pretty-print of the failing binding into the diag's      |
|            | `message_inline` field (requires R221.M5.1 child-aware       |
|            | `_ast_render`).                                              |
| R227.M4.4  | kernel-side `_pds_tcg_register_checker` wire-up: a thin shim |
|            | adapts the PipelineBody format to the script-body byte       |
|            | stream LoadCheck consumes; registers at REPL boot.           |
| R227.M4.5  | Standalone `pdsc verify` driver that calls `_lc_check_script`|
|            | over an on-disk `.pds` file and prints the diag chain.       |
| R227.M4.6  | FNV-1a 64 hash of the binding name into the diag record's    |
|            | reserved u64 at [+112] for dedup across concurrent loads.    |
| R227.M4.7  | rdtsc timestamp into the diag record's reserved u64 at       |
|            | [+120] for ordering within a load's chain.                   |

## 11. Related docs

- `design/shell/rank-restricted-polymorphism.md` — R225.M6
  RankCheck surface this module invokes per binding.
- `design/shell/hm-algorithm-w-core.md` — R225.M1 HmCore scheme
  wire format + algorithm W kernel.
- `design/shell/unified-ast.md` — R221.M5 Ast node pool consumed
  by phases 1 + 2 at M4.1.
- `design/shell/import-resolution-parser.md` — R227.M3
  ImportResolve consumed by phase 2 at M4.2.
- `design/shell/semantic-shell-language-plan.md` §R227 — the
  umbrella roadmap carrying the pds container-loader pipeline.
- `src/kernel/core/pds/typecheck_gate.pdx` (R133.M5) — kernel-
  side dispatcher that invokes this orchestrator through the
  `_pds_tcg_register_checker` fn-ptr slot.

## 12. ABI freeze

Three public entry points at raw M4:

- `_lc_init()                                            -> ()`
- `_lc_check_script(script_body: u64, body_len: u64,
                    out_diag_chain: u64, out_cap: u64)    -> u64`
- `_lc_count_diags(diag_chain: u64, chain_len: u64)       -> u64`

Status codes `0x5C00..0x5C08` are stable; `0x5C09..0x5CFF`
reserved for M4.1+ follow-ups. LC_DIAG record field offsets are
stable at the layout documented in §4; the record is distinct
from R225.M7 DiagReport's record and the two shapes do not
converge at wave close.
