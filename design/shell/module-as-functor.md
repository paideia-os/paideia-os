# Module as functor (R227.M5)

**Status:** parser-tier landing (R227.M5).
**Issue:** paideia-os#2707 (R227.M5).
**Umbrella:** paideia-os#2491 (R227 pds container / loader).
**Module:** `tools/user/libpdx-pds-parser/src/module_functor.pdx`
(`ModuleFunctor`).
**Error band:** `0x5F00..0x5FFF`.
**Siblings:** paideia-os#2705 (R227.M3 ImportResolve, parser-tier
`#import` directive parser), paideia-os#2706 (R227.M4 LoadCheck,
type-check-at-load pipeline).

## 1. Scope and motivation

A `.pds` script module is NOT a passive bag of top-level bindings. Each
script's semantics depend on a well-defined set of CAPABILITIES: the
`fs` capability for a script that reads the filesystem, `net` for one
that opens sockets, `exec` for one that spawns processes, and so on
(the ten CapRow primitive labels per R224.M4 Q-A2 substructural
lattice, plus future user-declared slots per M5.1). A script MUST
NOT run with latent authority — it must receive the SPECIFIC caps it
needs, named at the module boundary, so a reader of the source can
audit "this module requires `fs` + `net`" at a glance.

Paideia-shell therefore adopts the **module-as-functor** discipline
(ML / Haskell / Agda / Lean module systems; Harper 1994 *A type-theoretic
account of modularity* §2.1-2.3; Rossberg et al. 2010 *F-ing modules*
§3; Dreyer 2007 *A type system for recursive modules* §2):

> A `.pds` script elaborates to a FUNCTOR whose PARAMETERS are the
> capabilities the script declares via `#capability "<name>"` directives,
> and whose BODY is the packed set of `pub let`-bound exports. Importing
> a module APPLIES the functor: the importer hands the module its current
> `cap_env_mask`, the apply operation refuses with `E1200_MISSING_CAP`
> on a missing bit, and only on success does the exported-name table
> become addressable.

Design properties:

1. **Explicit capability binding.** Every capability a script needs is
   named at the module boundary via `#capability "<name>"`. A script
   that reads the filesystem but omits `#capability "fs"` fails to
   elaborate (the exported binding will fail its load-time check);
   a script that declares a cap but never uses it is a warn-level
   diagnostic (M5.8 forward-path linting).
2. **Fail-closed apply.** `_mf_apply` compares the module's declared
   `cap_param_mask` against the importer's `cap_env_mask`; a single
   missing bit refuses the whole import with the offending bit index
   packed in the high 32 bits of the return. The importer cannot
   acquire a reference to any export of a non-applied functor —
   the applied flag at offset 0x50 of the record is read by
   `_mf_lookup_export` as a precondition in M5.4.
3. **ZERO ambient authority.** The functor's cap_param_mask contains
   ONLY the capabilities named in `#capability` directives at parse
   time. There is no implicit cap set, no "default" FS access, no
   `#!/bin/sh`-style POSIX-era authority leak.
4. **Distinct from R222.M3 FunctorInstance.** R222.M3 lands
   per-COMMAND functors (abstracting over per-invocation args and
   flags for ONE command). R227.M5 lands per-MODULE functors
   (abstracting over capabilities for a MULTI-command script). The
   two layers compose: resolve `util.process_pdfs` through
   `_mf_lookup_export` to get a CommandSig ref, then invoke
   `_fi_instantiate` with that ref against the current argv/flags.

The parser is user-space (satellite library) because the shell runs in
user space; the kernel-side cap substrate (R107+) never touches
functor-elaboration bytes directly. The kernel-side R133.M3
ImportGraph consumes the adjacency ImportResolve emits (R227.M3); the
FUNCTOR APPLICATION this module performs happens entirely in user
space on a caller-supplied cap_env_mask snapshot.

## 2. Why a functor (not a flat capability declaration list)

A "flat" design — a `.pds` script carries a `caps = [fs, net]` list
with no apply semantic — would admit a different, worse model:

- The runtime grants EVERY cap in the list unconditionally at load
  time; a caller cannot reduce the set.
- There is no apply-time check — if the caller lacks a declared cap,
  the discrepancy surfaces as a syscall error much later (e.g. inside
  `_fi_instantiate` → kernel-side cap check), far from the import
  site. The error is RECOVERABLE but spans the user-space / kernel-
  space boundary.
- Capability-row typing (R224.M4 CapRow) cannot gate the IMPORT because
  the import doesn't participate in the typechecker's cap-row flow;
  all cap discipline sinks into the executor.

With module-as-functor, the import IS the type-level check. A caller
without the required caps CANNOT acquire a reference to any export at
all — the applied-flag at `[+80]` is read by every subsequent lookup
in M5.4+ as a precondition. The error is NON-RECOVERABLE at the
import site: a diagnostic reporter underlines the exact `#import`
line with `E1200_MISSING_CAP` + the missing cap name, and the user
knows precisely which cap to grant.

The precedent closest to this design: Rossberg 2015 *1ML — core and
modules united* §5 (phased module elaboration gated by witness
coherence); the ML module system (Milner / Harper / MacQueen 1985
*A type discipline for programming*) that paideia-shell builds on
reflexively treats "module" as "functor of its abstract types" — we
extend "abstract types" to "abstract capabilities".

## 3. ModuleFunctor record (128-byte header + 32 × 32-byte export table)

| offset | size | field                | note                                                 |
|-------:|-----:|----------------------|------------------------------------------------------|
|      0 |    4 | magic                | `'MFCT'` LE (0x5443464D)                             |
|      4 |    2 | n_exports            | 0..`MF_MAX_EXPORTS` (= 32)                           |
|      6 |    2 | n_cap_params         | 0..`MF_MAX_CAP_PARAMS` (= 8)                         |
|      8 |    8 | module_path_hash     | FNV-1a 64 of module path; 0 at raw M5 (M5.3 wire-up) |
|     16 |   16 | module_name_inline   | zero at raw M5 (M5.3 wire-up)                        |
|     32 |   32 | cap_param_mask       | 256-bit bitmap; low u64 meaningful at raw M5         |
|     64 |    8 | exports_offset       | = 128 at raw M5                                      |
|     72 |    8 | entries_offset       | = 128 + n_exports × 32 at raw M5                     |
|     80 |    1 | applied_flag         | 0 = unapplied; 1 = applied by `_mf_apply`            |
|     81 |    7 | reserved_81          | zero                                                 |
|     88 |    8 | applied_env_mask     | cap_env_mask snapshot from `_mf_apply`               |
|     96 |   32 | reserved_96          | zero at raw M5 (M5.1+ hash + rdtsc + diag ref)       |

Total header: 128 B (`MF_HEADER_BYTES`; power-of-two stride for
`shl rN, 7` addressing).

Export table entry (`MF_EXPORT_BYTES` = 32 B each):

| offset | size | field          | note                                               |
|-------:|-----:|----------------|----------------------------------------------------|
|      0 |    8 | name_hash      | FNV-1a 64 of the full export name bytes            |
|      8 |   16 | name_inline    | NUL-padded export name                             |
|     24 |    8 | cmd_sig_ref    | opaque u64 ref into the R222.M2 CommandSig pool    |

Total entry: 32 B (power-of-two stride for `shl rN, 5` addressing).
`cmd_sig_ref = 0` at raw M5 (M5.2 wire-up via R222.M5 CmdRegistry).

Magic `'MFCT'` = 0x5443464D LE reads as the 4-byte ASCII string "MFCT"
in a hex-dump sequential scan (byte sequence 4D 46 43 54). Distinct
from R222.M3 FunctorInstance's magic `'FINS'` (0x534E4946), from
R227.M3 ImportResolve's magic `'IMPT'` (0x54504D49), from R227.M4
LoadCheck's magic `'LCDG'` (0x47444C4C), and from R222.M2 CommandSig's
magic `'CSIG'` (0x47495343) — the four FourCC codes serve different
tiers of the pds container / loader pipeline.

## 4. Grammar

```
Module       := (CapDirective | PubLet | Other)*
CapDirective := '#capability' WS+ '"' CapName '"' (WS* ';')?
PubLet       := 'pub' WS+ 'let' WS+ Name (WS | '=' | ';' | '(' | ...)
CapName      := [a-z] [a-z0-9_]*            byte length 1..12
Name         := [A-Za-z_] [A-Za-z0-9_]*     byte length 1..16
WS           := 0x20 | 0x09 | 0x0A | 0x0D
Other        := any byte sequence that is NOT a cap directive or
                  'pub let' prefix at the current cursor position;
                  the scanner advances by one byte and continues.
```

Raw M5 limitations (deferred to M5.6+):

- **Nested lambdas are not recognised as exports.** A top-level
  `pub let f = \x. ...` binding captures `f` as an export at raw M5.
  A nested `let g = ...` inside the lambda body does NOT.
- **Shadowed `pub let` entries pass through.** Two `pub let foo = ...`
  bindings in the same source both land in the export table; a
  downstream lookup returns the FIRST entry (lowest i). M5.7 adds
  the duplicate-name scan (analogous to R227.M3's intra-source
  duplicate check).
- **Only primitive caps.** `#capability "fs"` works. `#capability
  "my_custom_cap"` fails with `MF_ERR_UNKNOWN_CAP` at raw M5 because
  slots 10..31 of the CapRow label table are not consulted yet. M5.1
  wires in R224.M4 `_cr_label_lookup`.

## 5. Public API

```
_mf_init()                                                   -> ()
_mf_parse_module(script_body, body_len,
                 out, out_cap)                               -> packed_u64
_mf_apply(functor_record, cap_env_mask, out, out_cap)        -> packed_u64
_mf_lookup_export(functor_record, name_ptr, name_len,
                  out_cmd_sig_ref)                           -> status
```

Register maps (SysV):

- `_mf_init()                                           -> rax (ignored)`
- `_mf_parse_module(rdi, rsi, rdx, rcx)                 -> rax`
- `_mf_apply(rdi, rsi, rdx, rcx)                        -> rax`
- `_mf_lookup_export(rdi, rsi, rdx, rcx)                -> rax`

### `_mf_init`

Bare `ret`. ModuleFunctor holds NO `.bss` state at raw M5 (every
record is caller-owned on all operational paths). Pure leaf; zero
callee-save pushes; no stack frame; no nested CALL. Kept for
parallelism with the parser-family init-hook convention so a later
M5 landing that adds `.bss` (per-session functor instance interning
table, apply counter, diag-chain head) does not break the API.

### `_mf_parse_module`

Scans `script_body[0..body_len)` byte-by-byte, dispatching on `#`
(try-match `#capability "<name>"`) and `p` (try-match `pub let NAME`).
Populates the 128-byte header + 32 × 32-byte export table at `out`.

Phases:

1. **Validate args.** `script_body != 0`, `body_len` ∈ [1, 65536];
   `out != 0`, `out_cap ≥ MF_RECORD_MAX_BYTES` (1152).
2. **Zero-fill 1152 bytes** at `out` via 144 u64 stores (stride-by-8).
3. **Initialise running state.** `cursor = 0`, `n_exports = 0`,
   `n_cap_params = 0`, `cap_mask = 0`.
4. **Main scan loop.** Byte-by-byte advance; dispatch:
   - `'#'` (0x23) → `_mf_pm_cap_try`
   - `'p'` (0x70) → `_mf_pm_pub_try`
   - else → advance one byte.
5. **Capability branch.** Match `capability` (10 bytes); skip WS+;
   match `"<cap_name>"`; linear-scan the primitive-cap table (10
   slots × 16 bytes); on hit set bit `slot_i` in `cap_mask`; on miss
   return `MF_ERR_UNKNOWN_CAP`. Increment `n_cap_params`; if the
   count exceeds 8 return `MF_ERR_TOO_MANY_CAP_PARAMS`.
6. **PubLet branch.** Match `ub` WS+ `let` WS+; scan `NAME` ident;
   validate n_exports < 32 (`MF_ERR_TOO_MANY_EXPORTS` on overflow);
   compute FNV-1a 64 of name bytes; emit entry at slot
   `out + 128 + n_exports * 32`:
   - `name_hash` u64 at [+0]
   - `name_inline` u8[16] at [+8..+24] (NUL-padded)
   - `cmd_sig_ref` u64 at [+24] (zero at raw M5).
7. **Emit phase.** Write magic `'MFCT'`, `n_exports`, `n_cap_params`,
   `cap_param_mask` low u64, `exports_offset = 128`,
   `entries_offset = 128 + n_exports * 32`.
8. **Pack return.** `(record_bytes << 32) | MF_OK`.

Register plan: 6 callee-save pushes (rbx = bytes_ptr, rbp = bytes_len,
r12 = out, r13 = cursor, r14 = n_exports, r15 = n_cap_params); pure
leaf (FNV + primitive table scan inlined; no nested CALL); r8 holds
the running cap_mask; r11/r9/r10 are three-term precompute scratch.
Labels prefixed `mf_pm_`.

### `_mf_apply`

Imports apply the functor: an importer hands the module a
`cap_env_mask` snapshot of the caller's held caps; apply either
accepts (copies the record with the applied flag set) or refuses
(returns the missing-bit index packed in high 32 of the return).

Phases:

1. Validate `functor_record != 0`, `out != 0`,
   `out_cap ≥ MF_RECORD_MAX_BYTES`.
2. Verify magic at [+0] equals `MF_RECORD_MAGIC` (`'MFCT'`).
3. Load `n_exports` u16 at [+4]; compute
   `record_bytes = 128 + n_exports × 32`.
4. Load `cap_param_mask` low u64 at [+32]; compute
   `missing = cap_param_mask AND NOT cap_env_mask`.
5. If `missing ≠ 0`, scan for lowest-set bit via TEST+SHR; return
   `(idx << 32) | E1200_MISSING_CAP` (0x5F10).
6. Byte-copy `record_bytes` from functor to `out` via u64-stride-8
   loop.
7. Set `applied_flag = 1` at [out+80]; `applied_env_mask = cap_env_mask`
   at [out+88].
8. Return `(record_bytes << 32) | MF_OK`.

Register plan: 5 callee-save pushes (rbx = functor_record, rbp =
cap_env_mask, r12 = out, r13 = out_cap, r14 = record_bytes); pure leaf;
no nested CALL. Labels prefixed `mf_ap_`.

### `_mf_lookup_export`

Resolves a name against the functor's export table. The usage pattern
at R229.M3 REPL dispatch is:

```
_mf_lookup_export(util_functor_ref, "process_pdfs", 12, &sig_ref);
_fi_instantiate(inv_bytes, inv_len, sig_ref, cs_len, out_ptr, out_cap);
```

Phases:

1. Validate `functor_record != 0`, `name_ptr != 0`, `name_len ∈ [1..16]`,
   `out_cmd_sig_ref != 0`.
2. Defensive write 0 to `*out_cmd_sig_ref`.
3. Verify magic at [+0] equals `MF_RECORD_MAGIC`.
4. Compute FNV-1a 64 of `name_ptr[0..name_len)` → `target_hash`.
5. Load `n_exports` u16 at [+4]; `exports_offset` u64 at [+64].
6. Linear-scan `n_exports` entries at stride 32; compare each entry's
   `name_hash` u64 against `target_hash`.
7. On hit: write entry's `cmd_sig_ref` u64 to `*out_cmd_sig_ref`;
   return `MF_OK`.
8. On miss: `*out_cmd_sig_ref` stays zero; return
   `E1201_EXPORT_NOT_FOUND` (0x5F11).

Register plan: 6 callee-save pushes (rbx = functor_record, rbp =
name_ptr, r12 = name_len, r13 = out_cmd_sig_ref, r14 = target_hash,
r15 = loop idx); pure leaf (FNV inlined; no nested CALL). Labels
prefixed `mf_lk_`.

## 6. Status band and diagnostic mapping

Band `0x5F00..0x5FFF` (10 slots used at raw M5; `0x5F08..0x5F0F`
reserved for M5.1+ parse diagnostics; `0x5F12..0x5FFF` reserved for
M5.2+ apply / lookup diagnostics):

| code     | name                              | meaning                                        |
|----------|-----------------------------------|------------------------------------------------|
| 0        | `MF_OK`                           | operation succeeded                            |
| 0x5F00   | `MF_ERR_BAD_SCRIPT`               | `script_body == 0`, `body_len == 0`, or `body_len > 65536` |
| 0x5F01   | `MF_ERR_OUT_TOO_SMALL`            | `out == 0`, `out_cap` too small, or `out_cmd_sig_ref == 0` |
| 0x5F02   | `MF_ERR_BAD_RECORD`               | `functor_record == 0` or magic mismatch        |
| 0x5F03   | `MF_ERR_TOO_MANY_EXPORTS`         | n_exports > 32                                 |
| 0x5F04   | `MF_ERR_TOO_MANY_CAP_PARAMS`      | n_cap_params > 8                               |
| 0x5F05   | `MF_ERR_NAME_TOO_LONG`            | export name > 16 OR cap-param name > 12        |
| 0x5F06   | `MF_ERR_UNKNOWN_CAP`              | `#capability` name not among the ten primitives (raw M5) |
| 0x5F07   | `MF_ERR_SYNTAX`                   | unterminated string / bad byte / malformed `pub let` |
| 0x5F10   | `E1200_MISSING_CAP`               | `_mf_apply`: cap_env_mask lacks a required bit  |
| 0x5F11   | `E1201_EXPORT_NOT_FOUND`          | `_mf_lookup_export`: name not in export table   |

Diagnostic-family mapping (E12xx family):

- `E1200_MISSING_CAP` → `MF_ERR_MISSING_CAP` (0x5F10). The missing
  bit index (0..63 at raw M5) is packed in bits [63:32] of the
  packed return.
- `E1201_EXPORT_NOT_FOUND` → `MF_ERR_EXPORT_NOT_FOUND` (0x5F11).
  Low 32 of return; no high-32 payload at raw M5 (M5.3 adds the
  module path for the diagnostic reporter).

The `0x5F00..0x5FFF` carve-out skips the `0x5E00..0x5EFF` band
(parallel R225.M8 arm) and the `0x5D00..0x5DFF` R229.M9 Renderer
band. A downstream compound-error dispatcher discriminates "the
module-functor substrate faulted" from every other sibling satellite's
failure modes via `shr r, 8; cmp r, 0x5F`.

## 7. Fixture acceptance (paideia-os#2707)

Per the issue brief: `util.pds` exports `process_pdfs`; `caller.pds`
imports and calls it.

**`util.pds`** (source):
```
#capability "fs"

pub let process_pdfs = \path.
  // read PDFs from path; needs fs
  ...
```

**`caller.pds`** (source):
```
#import "util.pds" as util
#capability "fs"

let x = util.process_pdfs("/data")
```

**Expected flow:**

1. The pds-loader (R133.M2+) walks `caller.pds` and admits it through
   the four kernel-side predicates (caps-decl, import graph, version
   gate, typecheck gate).
2. ImportResolve (R227.M3) parses `#import "util.pds" as util` into
   an ImportDirective; resolves the path; computes the import edge.
3. For every resolved import, the loader elaborates the target via
   `_mf_parse_module` (THIS module) over the target's script bytes.
   `util.pds` yields a ModuleFunctor with:
   - `n_exports = 1`, `n_cap_params = 1`
   - `cap_param_mask[0..8] = 0x0000000000000010` (bit 4 = CapRow slot
     "fs"; the ten primitive slots are 0=read, 1=write, 2=exec, 3=net,
     4=fs, 5=cap_mint, 6=cap_grant, 7=kalloc, 8=ipc, 9=trap)
   - export[0] = (hash("process_pdfs"), "process_pdfs"+NULs,
     `cmd_sig_ref = 0`).
4. The loader calls `_mf_apply(util_functor, caller_cap_env_mask,
   applied_record, applied_cap)` with
   `caller_cap_env_mask = 0x10` (caller holds `fs`).
   - `missing = 0x10 & ~0x10 = 0` → OK.
   - `applied_record` carries the full functor header + export table
     with `applied_flag = 1` and `applied_env_mask = 0x10` at offset
     [+88].
5. The REPL dispatcher resolves `util.process_pdfs` via
   `_mf_lookup_export(applied_record, "process_pdfs", 12, &sig_ref)`:
   - FNV-1a 64 hash of `"process_pdfs"` → `target_hash`.
   - Scan `n_exports = 1` entry; match on hash.
   - `*sig_ref = 0` (raw M5 placeholder); return `MF_OK`.
6. M5.2 wire-up resolves the `cmd_sig_ref` through R222.M5
   CmdRegistry so the subsequent `_fi_instantiate` call lands with
   a non-zero sig_ref.

**Fail-closed probe:** if `caller.pds` omitted `#capability "fs"`,
`caller_cap_env_mask = 0`, and `_mf_apply` would return
`(4 << 32) | 0x5F10 = 0x0000000400005F10` — the index 4 identifies
"fs" (CapRow slot 4), and the diagnostic reporter renders
`E1200_MISSING_CAP: util.pds requires 'fs' but caller lacks it`.

**Fixture tally (10 cases, M5 acceptance anchor):**

| # | source                                       | call                                                  | expected                            |
|---|----------------------------------------------|-------------------------------------------------------|-------------------------------------|
| 1 | `#capability "fs"\npub let f = ...`          | `_mf_parse_module → _mf_apply(mask=0x10)`             | OK: applied; n_exports=1            |
| 2 | `#capability "fs"\npub let f = ...`          | `_mf_apply(mask=0x00)`                                | E1200: idx=4                        |
| 3 | `pub let f = ...`                            | `_mf_apply(mask=0x00)`                                | OK: n_cap_params=0                  |
| 4 | `#capability "fs"\n#capability "net"\nlet g` | `_mf_parse_module → _mf_apply(mask=0x18)`             | OK: cap_param_mask=0x18             |
| 5 | `#capability "fs"\npub let f = ...`          | `_mf_lookup_export(applied, "f", 1)`                  | OK: *sig_ref=0                      |
| 6 | `#capability "fs"\npub let f = ...`          | `_mf_lookup_export(applied, "g", 1)`                  | E1201_EXPORT_NOT_FOUND              |
| 7 | `#capability "custom_cap"\npub let f = ...`  | `_mf_parse_module`                                    | MF_ERR_UNKNOWN_CAP                  |
| 8 | 33× `pub let fN = ...`                       | `_mf_parse_module`                                    | MF_ERR_TOO_MANY_EXPORTS             |
| 9 | 9× `#capability "fs"`                        | `_mf_parse_module`                                    | MF_ERR_TOO_MANY_CAP_PARAMS          |
|10 | `#capability "verylongcapname"\n`            | `_mf_parse_module`                                    | MF_ERR_NAME_TOO_LONG                |

Satisfied by the raw-M5 surface; the ten-fixture property-test
driver is deferred to the broader parser-tier harness (R221.M9 fuzz
corpus landing).

## 8. Encoder discipline

Standard parser-tier pdx dialect encoder rules (per
`feedback_pdx_encoder_pitfalls`):

- No `test rN, rN` — every zero-check uses `cmp reg, 0; je/jne`.
- No `and rN, imm64` — cap-mask covering check uses register-register
  `and r11, r10` (precedent cap_row.pdx L1208) + one-op `not r10`
  (precedent battery_monitor.pdx L454) + imm8 OR for setting single
  bits (`or r8, r9` where `r9 = 1 << slot_i` via `shl r9, cl`).
- No 2-op `imul rN, imm` — header stride 128 via `shl rN, 7`; export
  stride 32 via `shl rN, 5`; primitive-cap-table stride 16 via
  `shl rN, 4`. The FNV-1a 64 multiply uses one-op `mul rcx`.
- FNV constants 0xCBF29CE484222325 (offset basis) and 0x100000001B3
  (prime) load via MOVABS. Magic `'MFCT'` (0x5443464D) fits in imm32
  with bit 31 clear.
- No multiline `pub let = "..."` — single-line justifications.
- Module basename `ModuleFunctor` matches `module_functor.pdx`.
- Labels prefixed `mf_` with per-function suffix (`mf_ini_` init,
  `mf_pm_` parse-module, `mf_ap_` apply, `mf_lk_` lookup-export).
  Grep-confirmed disjoint from every landed parser-tier label prefix.
- All `cmp reg, imm` immediates fit imm32 with bit 31 clear so direct
  cmp-imm32 is sign-extension-safe.
- Byte loads via `xor rN, rN; mov_b rN, [base + idx * 1]`.
- Byte stores via `mov_b [dst + disp], reg` or precomputed
  `mov r9, base; add r9, idx; mov_b [r9 + 0], reg`.
- u16 stores via `mov_w [dst + disp], reg`; u16 loads via
  `xor rax, rax; mov_w rax, [base + disp]`.
- u32 stores via `mov_d [dst + disp], reg`.
- u64 stores via plain `mov [dst + disp], reg`.
- No chained-displacement addressing with three terms; all
  `[base + off + idx]` expressions precomputed via `add` first.

## 9. Dependencies

**Raw M5 intra-library deps:** NONE. Every entry point is a pure
leaf; no CALL fires from this module at raw M5. The primitive-cap
name table (`_mf_primitive_init : [u8; 160]`) is byte-identical to
R224.M4 CapRow's `_cr_primitive_init` so M5.1's switch to
`_cr_label_lookup` is a semantics-preserving refactor; the two tables
occupy disjoint `.rodata` labels.

**Declared forward-path intra-library deps (declared in `caps.decl`
for the M5.1+ landings):**

- **R227.M3 ImportResolve** (`_ir_resolve_path`, `_ir_build_graph`):
  M5.4 wires the import-resolve → mf-apply bridge so every
  ImportResolve edge triggers a functor application.
- **R224.M4 CapRow** (`_cr_label_lookup`): M5.1 replaces the inline
  10-slot primitive-cap table with a direct call to CapRow's lookup,
  widening recognition to the full 32-slot label table (primitive
  + user-declared).
- **R222.M5 CmdRegistry** (`_cmdreg_lookup`): M5.2 wires `pub let`
  export elaboration to the registered CommandSig records so each
  export is bound to its `cmd_sig_ref` at elaboration time.
- **R222.M3 FunctorInstance** (`_fi_instantiate`): M5.4 wires the
  dispatch pipeline so a lookup-export → fi-instantiate call chain
  resolves a module.name reference to a materialisation record.
- **R227.M4 LoadCheck** (`_lc_check_script`): the load-time gate
  runs BEFORE `_mf_parse_module`; a script that fails typecheck
  never gets its functor elaborated. Composable without a linker
  dep (both are called from the dispatcher one after the other).

**NO external cross-library linker dependencies at any landing.** The
module operates purely over caller-supplied byte buffers and its own
`.rodata` + (future) `.bss`.

## 10. Forward path

- **M5.1** Switch primitive-cap table to R224.M4 CapRow
  `_cr_label_lookup`; widens to slots 10..31 user-declared caps.
- **M5.2** Wire `pub let` export elaboration to R222.M5 CmdRegistry
  `_cmdreg_lookup`; cmd_sig_ref no longer zero.
- **M5.3** Module path hash + name inline populated from the
  enclosing ImportDirective's `path_hash` + `name_inline` fields
  (R227.M3).
- **M5.4** Import-time apply dispatch: `_ir_resolve_path` composes
  with `_mf_apply` at resolve time so the caller's cap_env_mask gates
  every imported export.
- **M5.5** 256-bit cap mask: widen `cap_env_mask` argument to a
  32-byte pointer; apply dispatch cross-walks all four u64 words.
- **M5.6** Nested lambda / let-rec exports via R224.M5 LetScope-aware
  walker.
- **M5.7** Intra-module duplicate-export scan (analogous to R227.M3's
  intra-source duplicate-name scan via `_ir_build_graph`).
- **M5.8** Unused-cap-param lint (warn-level diagnostic when a
  `#capability` is declared but no export references it; needs
  R224.M4 CapRow row-flow pass).

## 11. ABI freeze

The following surfaces are FROZEN at R227.M5 and will not change
through M5.8:

- `_mf_init()`, `_mf_parse_module`, `_mf_apply`, `_mf_lookup_export`
  symbol names + register-argument plans.
- 128-byte ModuleFunctor header stride; `'MFCT'` magic; the eight
  named-field offsets (magic, n_exports, n_cap_params, module_path_hash,
  module_name_inline, cap_param_mask, exports_offset, entries_offset)
  + the `applied_flag` and `applied_env_mask` reserved-slot
  positions.
- 32-byte export table entry stride; `name_hash` / `name_inline` /
  `cmd_sig_ref` offsets.
- Error band `0x5F00..0x5FFF`; the ten active status codes with
  their current numeric values.

The following surfaces are UNFROZEN pending the M5.1+ wire-ups:

- The semantics of `cmd_sig_ref` (zero at raw M5; a resolved
  CommandSig body ref at M5.2+).
- The `module_path_hash` and `module_name_inline` fields (zero at raw
  M5; populated by `_mf_apply` or by the import-resolve bridge at
  M5.3).
- The high 24 bytes of `cap_param_mask` (zero at raw M5; populated at
  M5.5 when 256-bit masks arrive).
- The reserved tail at [+96..+128] (zero at raw M5; M5.1+ auxiliary
  fields: name-hash + rdtsc + diag chain ref).

## 12. Related docs

- `design/shell/import-resolution-parser.md` — R227.M3 ImportResolve.
- `design/shell/typecheck-at-load.md` — R227.M4 LoadCheck.
- `design/shell/pds-container-format.md` — the `.pds` container shape.
- `design/shell/pds-caps-decl-gate.md` — the kernel-side cap-decl
  gate (R133.M2) upstream of this module.
- `design/shell/pds-header-pragmas.md` — the `#capability` / `#import`
  / `#version` directive family at the container level.
- `design/shell/cmd-functor-command-sig.md` — R222.M2 CommandSig
  (where `cmd_sig_ref` points).
- `design/shell/command-registry-client.md` — R222.M5 CmdRegistry
  (M5.2 wire-up).
- `design/shell/capability-row-typing.md` — R224.M4 CapRow (M5.1
  wire-up).
- `design/shell/functor-instantiation.md` — R222.M3 FunctorInstance
  (M5.4 wire-up).
