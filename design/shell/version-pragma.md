# Version pragma (R227.M6)

**Status:** parser-tier landing (R227.M6).
**Issue:** paideia-os#2708 (R227.M6).
**Umbrella:** paideia-os#2491 (R227 pds container / loader).
**Module:** `tools/user/libpdx-pds-parser/src/version_pragma.pdx`
(`VersionPragma`).
**Error band:** `0x6200..0x62FF`.
**Siblings:** paideia-os#2705 (R227.M3 ImportResolve, parser-tier
`#import` directive parser), paideia-os#2706 (R227.M4 LoadCheck,
type-check-at-load pipeline), paideia-os#2707 (R227.M5 ModuleFunctor,
functor-typed script modules).
**Mirror:** paideia-os#2623 (R133.M4 kernel-side VersionGate) --
grammar + comparison semantics identical; disjoint error-code spaces.

## 1. Scope and motivation

A `.pds` script pins the ABI contract its author wrote the script
against via the `#requires-paideia OP X.Y[.Z]` directive. The kernel's
command surface, effect taxonomy, and capability shapes evolve across
waves; a script compiled against `paideia 2.x` may legitimately refuse
to run on a `0.x` kernel that has not yet minted the effects /
capabilities the script's cap-decl references positionally. The
pragma is a **fail-closed** admission predicate: the loader refuses to
dispatch script bytes until the running-system version satisfies the
constraint.

The kernel-side R133.M4 `_vg_check` already implements the version
gate as a single-shot dispatcher (parse + compare against the kernel-
tier `KERNEL_VERSION_*` statics in one entry). R227.M6 lands the
PARSER-TIER half of the machinery: a split into a PARSE phase (emits
a reusable 32-byte VersionPragma record) and a CHECK phase (callable
against ANY running-triple -- not only the kernel-tier statics).

Reasons the parser-tier split exists:

1. **Offline reuse.** A hypothetical `pdsc verify` driver (R227.M4.5
   forward-path, standalone pds-verifier) needs to parse `#requires-
   paideia` directives outside the running kernel. The parser-tier
   module makes that reuse possible without re-invoking the kernel-
   tier dispatcher.
2. **Multi-shim checking.** The REPL may need to version-gate a
   script against the shell's own version (parser lib triple) OR
   against a federated-remote peer's version, not just the kernel's.
   `_vp_check` takes the running triple as explicit u64 arguments so
   the caller picks the compare target.
3. **Record reuse.** A load-time pds-loader walk may parse the pragma
   once, cache the record, and check against several candidate
   (running) triples (e.g. during federation negotiation). The 32-byte
   record is cheap to cache and pointer-pass.
4. **Grammar + semantics parity.** The two halves share grammar
   (`#requires-paideia OP X.Y[.Z]`) and comparison semantics (three-
   way lex compare on (major, minor, patch); op dispatch per the
   kernel-side table). A single mental model covers both tiers.

## 2. Why a dedicated parser-tier version-pragma primitive

A naive design would call the kernel-side `_vg_check` directly from
user space. Three forces push back against that:

- `_vg_check` compares against `KERNEL_VERSION_*` statics only; a
  caller that wants a non-kernel compare target cannot pivot it.
- `_vg_check` returns a packed u64 whose high bits encode the
  version mismatch's (req_major, have_major) tuple; a caller that
  wants to CACHE the parsed directive and run several compares
  against several targets must either re-parse each time or carry
  a shadow record format.
- `_vg_check` lives in the kernel-side packed-status band
  (0x3B00..0x3BFF). A standalone user-space tool that parses `.pds`
  pragmas for offline verification should NOT reach into kernel-tier
  error codes; the parser-tier band (0x6200..0x62FF) carves a
  disjoint slice for the parser-tier producer so a downstream
  compound-error dispatcher can discriminate "the record producer
  faulted" from "the kernel-tier dispatcher faulted".

The two halves agree on digit-cap discipline: each semver component
is capped at 9 digits (`cmp rcx, 9; ja vp_pa_bs`). The paideia-as
R133.M4 Wave 118 lesson showed a u32 component overflows at 10
digits ($2^{32} - 1 = 4\,294\,967\,295$, ten decimal places); cap at
9 keeps every component safely inside u32.

## 3. Directive grammar

```
VersionPragma := '#requires-paideia' WS+ OP WS+ SEMVER
OP            := '>=' | '<=' | '~=' | '>' | '<' | '='
SEMVER        := DIGITS '.' DIGITS [ '.' DIGITS ]
DIGITS        := [0-9]+                      1..9 digits per component
WS            := 0x20 | 0x09 | 0x0A | 0x0D
```

The parser scans greedily: `>=` matches before `>`, `<=` before `<`,
`~=` before any single-byte op. Trailing whitespace / newline after
the version is tolerated and left to the caller; `bytes_consumed`
(packed into the high 32 of the return) points at the first byte
AFTER the last parsed semver digit so the caller can advance.

`~=` is the "compatible with" op -- same major, equal-or-newer within
that major. Named `~=` because `^` is a bitxor token in pdx-lang
(parity with R133.M4 kernel-side).

## 4. VersionPragma record layout (32 bytes)

| Offset | Size | Field                 | Notes |
|-------:|-----:|-----------------------|-------|
| 0      | 4    | `magic`               | u32; `'RVPR'` LE (`0x52505652`). |
| 4      | 1    | `op`                  | u8; 0 EQ, 1 GE, 2 LE, 3 GT, 4 LT, 5 TILDE. |
| 5      | 1    | `flags`               | u8; bit 0 `VP_FLAG_PATCH_PRESENT`; bits 1..7 reserved. |
| 6      | 2    | `reserved_6`          | u16; zero at M6. |
| 8      | 4    | `major`               | u32; parsed major; 0..999_999_999. |
| 12     | 4    | `minor`               | u32; parsed minor; 0..999_999_999. |
| 16     | 4    | `patch`               | u32; parsed patch; zero when flag bit 0 clear. |
| 20     | 12   | `reserved_20`         | u8[12]; zero at M6. |

Rationale:

- **Stride 32** = `2^5` so a dispatcher indexing an array of
  VersionPragma records (future per-import pragma cache, M6.3)
  multiplies via `shl rN, 5` -- no 2-op `imul r, imm`.
- **Magic 'RVPR'** = `0x52505652` LE reads as the 4-byte ASCII string
  "RVPR" in a hex-dump sequential scan (byte sequence `52 56 50 52`).
  Distinct from every landed parser-tier magic (`FINS`, `IMPT`,
  `LCDG`, `MFCT`, `TFPR`, `CSIG`, `HREC`, `WSNK`, `HOST`, `DESC`,
  `SESS`, `DIAG`). Fits imm32 with bit 31 clear so direct `mov r9,
  0x52505652` + `mov_d [r12 + 0], r9` lands the magic without a
  MOVABS.
- **12-byte reserved tail** (`0x14..0x20`) carries no payload at raw
  M6; forward-path landings reserve it for an optional parsed-
  prerelease tag (M6.1), parsed-build-metadata tag (M6.2), and a
  two-u16 err-span pair (M6.4; `src_offset` + `src_length` on the
  directive line, for diagnostic span injection).

## 5. Comparison semantics

Three-way lex compare on `(major, minor, patch)`:

```
cmp3((hm,hn,hp), (rm,rn,rp)) =
    HI    if hm > rm, or (hm==rm and hn > rn),
                 or (hm==rm and hn==rn and hp > rp)
    EQ    if (hm,hn,hp) == (rm,rn,rp)
    LO    otherwise
```

Op dispatch (identical to R133.M4 kernel-side):

| Op   | Code | Satisfied when |
|------|-----:|----------------|
| `=`  | 0    | `cmp == EQ` |
| `>=` | 1    | `cmp in {HI, EQ}` |
| `<=` | 2    | `cmp in {LO, EQ}` |
| `>`  | 3    | `cmp == HI` |
| `<`  | 4    | `cmp == LO` |
| `~=` | 5    | `have.major == req.major AND cmp in {HI, EQ}` |

The internal three-way result is encoded as `rsi` in `{0 (LO), 1
(EQ), 2 (HI)}` so each dispatch arm uses an imm8-fit `cmp`.

`have` is the FIRST operand of each compare (the caller-supplied
running triple); `req` is the SECOND operand (loaded from the parsed
VersionPragma record).

## 6. Public API

### 6.1 `_vp_init() -> ()`

Bare `ret`. R227.M6 holds NO `.bss` state (every record is caller-
owned on all operational paths). Kept for parallelism with the
parser-family init-hook convention.

- Register map: `()`.
- Pure leaf; zero pushes; zero stack frame; zero nested CALL.
- Labels prefixed `vp_ini_`.

### 6.2 `_vp_parse(bytes, bytes_len, out, out_cap) -> packed_u64`

Parse one `#requires-paideia OP X.Y[.Z]` directive out of the leading
bytes of a source byte run. Writes one 32-byte VersionPragma record
at `out`. Returns `(bytes_consumed << 32) | status`.

- Register map: `(rdi, rsi, rdx, rcx) -> rax`.
- 6-push PURE LEAF (no nested CALL) with `rbx=bytes_ptr`,
  `rbp=bytes_len`, `r12=out`, `r13=cursor`, `r14=parsed_op`,
  `r15=patch_flag`.
- Labels prefixed `vp_pa_`.

Flow:

1. Validate `out != 0`, `out_cap >= VP_RECORD_BYTES` (32); fail →
   `VP_ERR_OUT_TOO_SMALL`.
2. Validate `bytes_len >= VP_MIN_SRC_LEN` (18 = prefix 17 + at least
   one trailing byte); fail → `VP_ERR_SRC_TOO_SHORT`.
3. Zero-fill the 32-byte record via four u64 stores.
4. memcmp `src[0..17]` vs `vp_prefix[0..17]`; mismatch →
   `VP_ERR_BAD_DIRECTIVE`.
5. Skip WS+ (required at least one); fail → `VP_ERR_BAD_DIRECTIVE`.
6. Parse op token (greedy 2-char first `{>=, <=, ~=}`, then 1-char
   `{>, <, =}`); fail → `VP_ERR_BAD_OP`. Stash op code (0..5) in r14.
7. Skip WS+ (required at least one); fail → `VP_ERR_BAD_SEMVER`.
8. Parse major digits (1..9) via `(acc<<3)+(acc<<1) = acc*10`; zero
   digits or > 9 digits → `VP_ERR_BAD_SEMVER`. Store u32 at `[out+8]`.
9. Expect `.`; mismatch → `VP_ERR_BAD_SEMVER`.
10. Parse minor digits (1..9); store u32 at `[out+12]`.
11. If next byte is `.`, parse patch digits (1..9); store u32 at
    `[out+16]`; set r15 = `VP_FLAG_PATCH_PRESENT`.
12. Emit magic u32 at `[out+0]`; op u8 at `[out+4]`; flags u8 at
    `[out+5]`. Reserved bytes stay zero from zero-fill.
13. Return packed `(bytes_consumed << 32) | VP_OK`.

### 6.3 `_vp_check(record_ref, running_major, running_minor, running_patch) -> status`

Compare a parsed VersionPragma record against a caller-supplied
running-system version triple. Returns `VP_OK` (0) iff the recorded
`(op, req_major, req_minor, req_patch)` is satisfied by the running
triple; `VP_ERR_VERSION_MISMATCH` (`0x6210`) iff the constraint fails;
`VP_ERR_BAD_RECORD` (`0x6204`) iff `record_ref == 0` OR the magic u32
at `[+0]` does not match `'RVPR'`.

- Register map: `(rdi, rsi, rdx, rcx) -> rax`.
- 4-push PURE LEAF (no nested CALL) with `rbx=record_ref`,
  `rbp=running_major`, `r12=running_minor`, `r13=running_patch`.
- Labels prefixed `vp_ck_`.

Flow:

1. Validate `record_ref != 0`; magic match; fail → `VP_ERR_BAD_RECORD`.
2. Load op u8, req_major u32, req_minor u32, req_patch u32.
3. Three-way compare `(running vs required)` into rsi in `{0, 1, 2}`.
4. Dispatch on op (`VP_OP_EQ`, `VP_OP_GE`, `VP_OP_LE`, `VP_OP_GT`,
   `VP_OP_LT`, `VP_OP_TILDE`); fail arm → `VP_ERR_VERSION_MISMATCH`;
   any op code outside `{0..5}` also → mismatch.

## 7. Acceptance corpus (8-fixture)

Deferred to R221.M9 parser-tier property-test harness; the raw M6
surface satisfies every fixture by the three-entry-point validation
flows.

| # | Directive                         | Running triple | Expected status |
|--:|-----------------------------------|---------------:|-----------------|
| 1 | `#requires-paideia >= 1.0`        | 1.2.0         | `VP_OK` |
| 2 | `#requires-paideia >= 2.0`        | 1.2.0         | `VP_ERR_VERSION_MISMATCH` |
| 3 | `#requires-paideia = 1.2`         | 1.2.0         | `VP_OK` (patch absent → treated as 0; running 1.2.0 EQ required 1.2.0) |
| 4 | `#requires-paideia = 1.2`         | 1.3.0         | `VP_ERR_VERSION_MISMATCH` |
| 5 | `#requires-paideia ~= 2.5`        | 2.9.0         | `VP_OK` (same major; running >= required) |
| 6 | `#requires-paideia ~= 2.5`        | 3.0.0         | `VP_ERR_VERSION_MISMATCH` (different major) |
| 7 | `#requires-paideia < 2.0`         | 1.9.9         | `VP_OK` |
| 8 | `#requires-paideia > 1.0`         | 1.0.0         | `VP_ERR_VERSION_MISMATCH` |

The eight fixtures cover: four matching + four mismatching; the six
op tokens (`=`, `>=`, `<=`, `>`, `<`, `~=`) each exercised at least
once across the pair; patch-present and patch-absent branches on
both parse and check; equality boundary (fixture 8 running == required
but op is `>`); same-major vs. different-major on `~=`.

Additional parse-only fixtures (deferred, M6.5): over-9-digit major
→ `VP_ERR_BAD_SEMVER`; missing `.` between major and minor →
`VP_ERR_BAD_SEMVER`; `#requires-paideia 1.0` (missing op) →
`VP_ERR_BAD_OP`; truncated prefix `#requires-pade 1.0` →
`VP_ERR_BAD_DIRECTIVE`; `out_cap = 16` → `VP_ERR_OUT_TOO_SMALL`;
`bytes_len = 10` → `VP_ERR_SRC_TOO_SHORT`; `record_ref = 0` on check
→ `VP_ERR_BAD_RECORD`; invalid-magic record on check →
`VP_ERR_BAD_RECORD`.

## 8. Status band

The eight VP_* status codes live in `0x6200..0x62FF`:

| Code                       | Value   | Surface |
|----------------------------|--------:|---------|
| `VP_OK`                    | 0       | `_vp_parse` (packed with bytes_consumed) / `_vp_check` satisfied |
| `VP_ERR_BAD_DIRECTIVE`     | 0x6200  | `_vp_parse` prefix mismatch / missing WS after prefix |
| `VP_ERR_BAD_OP`            | 0x6201  | `_vp_parse` op token not in `{=, >=, <=, ~=, >, <}` |
| `VP_ERR_BAD_SEMVER`        | 0x6202  | `_vp_parse` digit malform / missing `.` / > 9 digits |
| `VP_ERR_OUT_TOO_SMALL`     | 0x6203  | `_vp_parse` `out == 0` or `out_cap < 32` |
| `VP_ERR_BAD_RECORD`        | 0x6204  | `_vp_check` NULL record or magic mismatch |
| `VP_ERR_SRC_TOO_SHORT`     | 0x6205  | `_vp_parse` `bytes_len < 18` |
| `VP_ERR_VERSION_MISMATCH`  | 0x6210  | `_vp_check` constraint fails |

Slots `0x6206..0x620F` reserved for M6.1+ parse diagnostics;
`0x6211..0x62FF` reserved for M6.2+ check diagnostics.

Disjointness proof: grep `0x62(0[0-5]|10)\b` across
`paideia-os/{src,tools,design,tests}` returns no live hits outside
this file, `caps.decl`, `STATUS.md`, and `CHANGELOG.md`.

## 9. Encoder discipline (absolute)

Per `feedback_pdx_encoder_pitfalls`:

- `cmp rN, 0` never `test rN, rN`.
- `acc*10` via `(shl rN, 3) + (shl rM, 1) + (add rN, rM)` never 2-op
  `imul-imm` (precedent: kernel-side `version_gate.pdx` L507-514 and
  R229.M10 `turn_fingerprint` decimal rendering).
- `and rN, imm64` not needed; `VP_FLAG_PATCH_PRESENT` is a single
  imm8 (`mov r15, 1`).
- Single-line `pub let` -- one line per literal.
- Module basename `VersionPragma` matches `version_pragma.pdx`.
- Labels prefixed `vp_` with per-function suffix (`vp_ini_`, `vp_pa_`,
  `vp_ck_`). Grep-confirmed virgin inside
  `tools/user/libpdx-pds-parser/src/*.pdx`; disjoint from the
  kernel-side `vg_` (R133.M4 VersionGate) and `vp_submit` /
  `vp_await` (R128.G4.M1 vello_render_channel.pdx; GLOBAL linker
  symbols in a disjoint linker scope).
- Byte loads via `xor rN, rN; mov_b rN, [reg+reg*1]`.
- `cmp rN, imm8` on every byte-literal compare.
- Status codes `0x6200..0x6210` fit imm32 sign-ext safe (bit 31
  clear).
- No multiline `pub let`.
- No chained-displacement addressing with three terms.

## 10. Register-liveness per entry

### `_vp_init`
- 0 callee-save pushes; 0 stack frame; 0 nested CALL.

### `_vp_parse`
- 6 callee-save pushes (`rbx`, `rbp`, `r12`, `r13`, `r14`, `r15` = 48 B).
- Entry `rsp%16==8` + 6*8 push = 48, (8+48)%16=8 misaligned, but no
  nested CALL fires (pure leaf) so no `sub rsp, N` pad is needed.
- Live:
  - `rbx` = `bytes_ptr`
  - `rbp` = `bytes_len`
  - `r12` = `out`
  - `r13` = `cursor`
  - `r14` = `parsed_op`
  - `r15` = `patch_flag`
- Scratch: `rax`, `rcx`, `rdx`, `rsi`, `rdi`, `r8`, `r9`, `r10`, `r11`.

### `_vp_check`
- 4 callee-save pushes (`rbx`, `rbp`, `r12`, `r13` = 32 B).
- Entry `rsp%16==8` + 4*8 = 32, (8+32)%16=8 misaligned, but no nested
  CALL fires (pure leaf) so no pad.
- Live:
  - `rbx` = `record_ref`
  - `rbp` = `running_major`
  - `r12` = `running_minor`
  - `r13` = `running_patch`
- Scratch: `rax`, `rcx`, `rdx`, `rsi` (three-way result), `rdi`,
  `r8` (req_major), `r9` (req_minor), `r10` (req_patch), `r11`
  (op code), `r14`, `r15`.

## 11. Lazy-init non-applicability

R227.M6 holds NO `.bss` state at this landing (parallel to R227.M5
ModuleFunctor, R229.M10 TurnFingerprint, R225.M8 LspHover, R225.M7
DiagReport, R225.M6 RankCheck, R223.M5 WireSink, R223.M6
HostnameAnnot, R223.M7 SessionType). `.bss` zero-init at cold boot
trivially satisfies the module's "no mutable state" invariant.
`_vp_init` is a bare `ret` kept for parallelism with the parser-
family init-hook convention; a future M6.x landing that adds `.bss`
(per-session pragma intern table, check counter, diag-chain head)
does not break the API.

## 12. Dependencies

ZERO intra-library linker-visible FUNCTION dep at raw M6. ZERO
external cross-library linker dep. ZERO intra-library DATA linker
reference. All three public entry points touch ONLY caller-supplied
pointer args + the module's own `.rodata` (`vp_prefix` 18-byte
prefix table).

Declared forward-path intra-library deps:

- **M6.3** → R227.M3 ImportResolve ImportDirective-adjacent pragma
  pointer field (per-import version pin).
- **M6.4** → R225.M7 DiagReport `_dr_emit` (err-span injection into
  the parse-error diagnostic chain).

## 13. Forward path

- **R227.M6.1** Prerelease tag parse (`-alpha.1`, `-rc.2` per SemVer
  2.0 §9) into the reserved tail; `VP_ERR_BAD_PRERELEASE` diagnostic
  in reserved slot `0x6206..0x620F`.
- **R227.M6.2** Build-metadata parse (`+build.1` per SemVer 2.0 §10)
  with `VP_FLAG_BUILD_PRESENT` bit.
- **R227.M6.3** Per-import version pin: ImportResolve carries a
  parsed VersionPragma pointer per ImportDirective; the loader cross-
  checks against the imported module's own `#requires-paideia` on
  resolve.
- **R227.M6.4** Diagnostic span: `src_offset` + `src_length` u16 pair
  in the reserved tail so a downstream reporter can render the exact
  directive bytes without re-reading the source line.
- **R227.M6.5** 8-fixture acceptance corpus
  (`tests/proptest_version_pragma.pdx`) landing alongside R221.M9
  parser-tier property-test harness.

## 14. ABI freeze

The 32-byte VersionPragma record layout is frozen at M6:

- Magic `0x52505652` at `[+0]`.
- Op code at `[+4]`.
- Flags byte at `[+5]`; bit 0 = `VP_FLAG_PATCH_PRESENT`; bits 1..7
  reserved zero and must stay zero at every M6.x landing.
- Reserved u16 at `[+6]` stays zero.
- `(major, minor, patch)` triple at `[+8..+20]`.
- Reserved tail `[+20..+32]` reserved for M6.1+ fields; any landing
  that writes to this tail bumps the magic to `'RVPx'` for `x` in a
  new codepoint lane so the two layouts never alias.

## 15. Related docs

- `src/kernel/core/pds/version_gate.pdx` -- kernel-side R133.M4
  dispatcher (paideia-os#2623). Grammar + comparison semantics
  identical; error codes disjoint.
- `design/shell/import-resolution-parser.md` -- R227.M3 ImportResolve.
  M6.3 wire-up composes `_vp_check` with `_ir_resolve_path`.
- `design/shell/typecheck-at-load.md` -- R227.M4 LoadCheck. The
  pds-loader pipeline runs the version gate BEFORE the typecheck
  gate.
- `design/shell/module-as-functor.md` -- R227.M5 ModuleFunctor. The
  functor-apply operation runs AFTER the version gate admits the
  module.
- `design/shell/diagnostic-reporting.md` -- R225.M7 DiagReport. M6.4
  wire-up injects an err-span into the DiagReport chain on parse
  failure.
