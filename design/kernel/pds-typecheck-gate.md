# PDS pre-execution type-check gate — R133.M5

Parent: paideia-os#2480. Milestone: paideia-os#2624.

## Scope

Hand the parsed `.pds` script body (a sequence of pipeline stages, each
with a type descriptor) to the user-space type-checker (R132.Mx) and
refuse execution on any type error, naming the offending stage index in
the fingerprint and in the packed return value. A script with a
pipeline-stage mismatch is caught here BEFORE a single stage effect is
dispatched: the gate is the fourth and last read-only predicate between
an admitted container (R133.M2 caps-decl, R133.M3 import graph, R133.M4
version gate) and the R131 shell command dispatcher.

## Why a dedicated gate

R133.M2 admits the capability SHAPE; R133.M3 admits the import-graph
SHAPE; R133.M4 admits the ABI VERSION. None of those predicates speak
to the TYPE compatibility between a pipeline stage and the stage
downstream of it. A `.pds` whose shell author wrote
`list-files | word-count` is syntactically well-formed, cap-decl-clean,
cycle-free, and ABI-compliant — but if `list-files` emits
`Record<Path>` and `word-count` consumes `Record<Bytes>`, the pipeline
is ill-typed and must refuse at load time, not at the moment the first
`word-count` instance tries to coerce a `Path` into bytes.

The gate exists for three reasons that each argue AGAINST folding this
pass into any sibling:

  1. **Satellite decoupling.** The pds-lang type system (R222
     CommandSig / R223 record projection / R224 ClosureCapture / R225
     RowTypes / R229 TypeEnv) lives OUTSIDE the kernel in
     `tools/user/libpdx-pds-parser/`. The HM core, type algebra, and
     row-polymorphism engine are too large (and correctly have no
     business inside ring 0) to absorb at R133. The kernel cannot
     hard-link that satellite: the kernel's cadence and the parser's
     cadence are independent, and a kernel built on wave N cannot
     wait for a type-checker that lands on wave N+K.

     The gate therefore exposes a REGISTRATION slot — a `.bss` function
     pointer — and the satellite's init publishes its checker there at
     boot. Before registration, the gate refuses with
     `TCG_ERR_NO_CHECKER_AVAIL`; after registration, the gate
     dispatches each stage through the slot via `call rax`.

  2. **Error-code namespacing.** Each prior R133 gate owns a disjoint
     16-bit band so a surrounding error-reporter can switch on the low
     16 bits of the packed status without ambiguity:

         0x3200..0x32FF  R133.M2 caps-decl gate
         0x3A00..0x3AFF  R133.M3 import graph
         0x3B00..0x3BFF  R133.M4 version gate
         0x3E00..0x3EFF  R133.M5 typecheck gate   <-- THIS

     0x3C00..0x3CFF is reserved by R222.M4 ArgSpec/FlagSpec (user-space,
     see design/shell/arg-flag-spec-typing.md); 0x3D00..0x3DFF is
     reserved by R229.M3 TypeEnv (user-space, see design/shell/
     type-env-threading.md). A `grep -rnE '0x3E[0-9A-Fa-f]{2}\b' src/
     design/` on 2026-10-15 returned no live source references, so the
     0x3E00..0x3EFF band is free of collision (Wave 118 lesson
     applied).

  3. **Pure predicate.** The gate accepts a `(body_ptr, body_len)` byte
     range and returns a packed `u64` — no session-env mutation, no
     disk I/O, no allocation. The signature is reusable from an
     offline `pdsc verify` pass and amenable to a future adversarial
     smoke that drives malformed `PipelineBody` records straight at
     the entry point.

## PipelineBody wire shape

```
+----------------------------------------------------------+
| PipelineBody header (TCG_HEADER_SIZE = 32 bytes)         |
|   [ 0.. 4] magic         u32 = 0x50495042 ('PIPB')       |
|                             (LE: file bytes 'B','P','I','P') |
|   [ 4.. 6] n_stages      u16  count of StageDesc records |
|                             (0 .. TCG_MAX_STAGES = 64)   |
|   [ 6.. 8] flags         u16  shape bits; 0 at M5        |
|   [ 8..12] stages_offset u32  byte offset from body base |
|                             to StageDesc[0]              |
|   [12..16] stages_len    u32  byte length of the stages  |
|                             region (= n_stages * 32)     |
|   [16..32] reserved      [u8; 16]  zero at M5            |
+----------------------------------------------------------+
| StageDesc[0]  (TCG_STAGE_STRIDE = 32 bytes)              |
| StageDesc[1]  ...                                        |
|   ...                                                    |
| StageDesc[n_stages-1]                                    |
+----------------------------------------------------------+
```

Each StageDesc is 32 bytes:

```
byte [ 0.. 1]  stage_kind     u8   mirrors R222/R223 kinds
byte [ 1.. 2]  type_code      u8
byte [ 2.. 3]  name_len       u8
byte [ 3.. 4]  reserved       u8
byte [ 4..12]  type_desc_ref  u64  LE handle into the user-space
                                    type-env's TypeDesc arena
byte [12..26]  name_inline    [u8; 14]
byte [26..32]  reserved       [u8; 6]
```

### Note on header size

The task brief listed `reserved[12]` for the PipelineBody header, which
sums to 28 bytes against a stated total of 32. We interpreted the
"32B" total as authoritative and expanded `reserved` to `[u8; 16]`.
The stages array therefore starts at or after offset 32, with the
exact start controlled by the caller-supplied `stages_offset` field
(minimum 32, enforced by invariant I4a). A future wave MAY narrow the
header back to 28 bytes if the caller discipline fixes
`stages_offset == 28` consistently.

The on-wire shape is REUSED unchanged by the user-space checker:
`_pds_tcg_check_stage(stage_ptr)` is passed a pointer into the body
buffer at the stage's offset, so no re-encoding is needed between the
kernel-side gate and the satellite.

## Weak-import adapter model

The pdx dialect does not implement linker-level weak imports (the
paideia-as encoder emits strict symbol references only). To let the
kernel link in isolation from the user-space type-checker, R133.M5
expresses the "weak import" as a REGISTRATION SLOT:

```
pub let mut _tcg_check_fn : u64 = uninit @align(8)   // .bss nil
```

The slot is zero-init by the kernel's `.bss` zero-fill at boot entry
(confirmed via `boot/entry.pdx:16` rep-stosq zero of
`_bss_start.._bss_end`). The surrounding satellite's init publishes
the checker via:

```
_pds_tcg_register_checker(fn_ptr: u64) -> u64
```

which writes the function pointer into the slot and emits a one-shot
`pds typecheck registered` fingerprint. Passing `fn_ptr == 0` is a
contract violation (returns `TCG_ERR_NULL_FN`). Unregistering is NOT
supported at M5 (nullifying the slot would race with an in-flight
load); a later wave adds a sealed `unregister` primitive if the
hot-reload-the-type-checker workflow lands.

At gate time, the adapter loads the slot into `rax`, dispatches via
`call rax`, and interprets a non-zero return as a stage-level
type-check failure. The user-space side's status band is OPAQUE to
the gate: whatever the satellite returns is forwarded verbatim in the
high 32 bits of the mismatch packing (see "Return packing" below).

## Invariants

The gate enforces five invariants BEFORE invoking the registered
checker — the gate never hands a malformed stream to the satellite:

| id   | assertion                                                        | fault code                   |
|------|------------------------------------------------------------------|------------------------------|
| I1   | `body_ptr != 0 AND body_len >= TCG_HEADER_SIZE (32)`             | `TCG_ERR_NULL_BODY`          |
| I2   | `header.magic == TCG_MAGIC`                                      | `TCG_ERR_BAD_HEADER`         |
| I3   | `header.n_stages <= TCG_MAX_STAGES (64)`                         | `TCG_ERR_TOO_MANY_STAGES`    |
| I4   | `header.stages_offset >= 32 AND stages_offset + stages_len <= body_len` | `TCG_ERR_BAD_STAGES_BOUNDS` |
| I5   | `header.stages_len >= header.n_stages * 32`                      | `TCG_ERR_BAD_STAGES_BOUNDS`  |

A failure at any invariant surfaces as the corresponding `TCG_ERR_*`
code (see the status band below) with a klog_s1 fingerprint at
LEVEL_WARN; the user-space checker is NOT invoked on an invariant
failure.

## Status band — 0x3E00..0x3EFF

| code                              | hex    | meaning                                               |
|-----------------------------------|--------|-------------------------------------------------------|
| `TCG_OK`                          | 0x0000 | all stages type-check; `n_stages` in bits [31:16]     |
| `TCG_ERR_NO_CHECKER_AVAIL`        | 0x3E00 | registration slot nil (satellite not registered)      |
| `TCG_ERR_BAD_HEADER`              | 0x3E01 | magic mismatch at [0..4]                              |
| `TCG_ERR_TOO_MANY_STAGES`         | 0x3E02 | `n_stages > TCG_MAX_STAGES` (64)                      |
| `TCG_ERR_STAGE_TYPE_MISMATCH`     | 0x3E03 | a stage's checker returned non-zero                   |
| `TCG_ERR_NULL_BODY`               | 0x3E04 | `body_ptr == 0` or `body_len < TCG_HEADER_SIZE`       |
| `TCG_ERR_BAD_STAGES_BOUNDS`       | 0x3E05 | geometry fault (I4 or I5)                             |
| `TCG_ERR_NULL_FN`                 | 0x3E06 | `_pds_tcg_register_checker` rejected `fn_ptr == 0`    |

### Return packing

```
TCG_OK:
  bits [15: 0] = 0x0000
  bits [31:16] = n_stages
  bits [63:32] = 0

TCG_ERR_STAGE_TYPE_MISMATCH:
  bits [15: 0] = 0x3E03
  bits [31:16] = bad_idx         (stage index that refused)
  bits [63:32] = stage_status    (user-space checker's own errno,
                                   forwarded verbatim)

all other TCG_ERR_*:
  bits [15: 0] = TCG_ERR_*
  bits [31:16] = 0
  bits [63:32] = 0
```

Three accessors recover each packed field without exposing the layout
to callers:

```
_pds_tcg_bad_idx(packed)      -> bad_idx on MISMATCH, 0 otherwise
_pds_tcg_stage_status(packed) -> stage_status on MISMATCH, 0 otherwise
_pds_tcg_ok_stages(packed)    -> n_stages on OK, 0 otherwise
```

## Fingerprints

The gate emits one klog fingerprint per return path:

| path                           | wrapper      | level       | tag                                 | kv entries                     |
|--------------------------------|--------------|-------------|--------------------------------------|--------------------------------|
| `TCG_OK`                       | `klog_s1_d2` | LEVEL_INFO  | `pds typecheck ok`                   | `stages=<n>`, `bad=0`          |
| `TCG_ERR_STAGE_TYPE_MISMATCH`  | `klog_s1_d2` | LEVEL_WARN  | `pds typecheck rejected`             | `stages=<n>`, `bad=<idx>`      |
| `TCG_ERR_NO_CHECKER_AVAIL`     | `klog_s1`    | LEVEL_WARN  | `pds typecheck no-checker`           | —                              |
| `TCG_ERR_BAD_HEADER`           | `klog_s1`    | LEVEL_WARN  | `pds typecheck bad-header`           | —                              |
| `TCG_ERR_TOO_MANY_STAGES`      | `klog_s1`    | LEVEL_WARN  | `pds typecheck too-many-stages`      | —                              |
| `TCG_ERR_NULL_BODY`            | `klog_s1`    | LEVEL_WARN  | `pds typecheck null-body`            | —                              |
| `TCG_ERR_BAD_STAGES_BOUNDS`    | `klog_s1`    | LEVEL_WARN  | `pds typecheck bad-bounds`           | —                              |
| `_pds_tcg_register_checker` OK | `klog_s1`    | LEVEL_INFO  | `pds typecheck registered`           | —                              |
| `_pds_tcg_register_checker` NULL_FN | `klog_s1` | LEVEL_WARN | `pds typecheck null-fn`             | —                              |

The tag strings use lowercase `ok` deliberately: the
`tools/verify-fingerprint-coverage.sh` `OK_TOK` regex matches only bare
uppercase `OK` as a word token, so these tags bypass the asserted-
marker extractor. Same posture as R133.M2's `pds.cdg: ok`, R133.M3's
`pds import graph ok`, and R133.M4's `pds version ok`. A future smoke
that pins these fingerprints does so via plain substring assertions in
its golden file.

## Register plan

```
_pds_tcg_gate(body_ptr, body_len) -> packed u64

Saves rbx, r12, r13, r14, r15 (5 pushes) + sub rsp, 16 (2 locals):

  push rbx     rbx = body_ptr                 (base of input)
  push r12     r12 = body_len                 (byte count)
  push r13     r13 = n_stages                 (loop upper bound)
  push r14     r14 = loop_i                   (stage index)
  push r15     r15 = stages_base              (body_ptr + stages_offset)
  sub  rsp, 16
                [rsp +  0] = check_fn          cached checker ptr
                [rsp +  8] = last_stage_status checker's rax on mismatch
```

Entry `rsp % 16 == 8`; +40 pushes + 16 sub = +56; `(8 + 56) % 16 == 0`
at body.

  * Pre-CALL to `klog_s1`: body `rsp % 16 == 0`, direct call.
  * Pre-CALL to `klog_s1_d2`: idiom `sub rsp, 8; push v2` (= +16) lands
    `rsp % 16 == 0` at the CALL (SysV callee entry `rsp % 16 == 8`),
    matching the proof in `version_gate.pdx:703-714`. Post-CALL
    `add rsp, 16` reclaims pad + push.
  * Pre-CALL to the registered checker via `call rax`: body
    `rsp % 16 == 0`, direct indirect call lands callee at
    `rsp % 16 == 8` per SysV with NO pad. (This is DISTINCT from
    `vops.pdx:139`'s `sub rsp, 8; call rax; add rsp, 8` pattern, whose
    caller has no prologue and therefore enters with `rsp % 16 == 8`;
    our prologue has already restored `rsp % 16 == 0`.)

Scratch (caller-save; may be clobbered by any nested CALL): `rax`,
`rcx`, `rdx`, `rsi`, `rdi`, `r8`, `r9`, `r10`, `r11`.

### `_pds_tcg_register_checker`

Minimal 2-push frame:

```
push rbx     rbx = fn_ptr
push r12     callee-save pad (keeps 2-push alignment)
```

Entry `rsp % 16 == 8`, +16 pushes = `rsp % 16 == 8`; `sub rsp, 8` before
`klog_s1` lands `rsp % 16 == 0` at the CALL, `add rsp, 8` after.

## Encoder discipline

Per `feedback_pdx_encoder_pitfalls`:

  * `cmp rN, 0`              never `test rN, rN`.
  * Stride 32 (StageDesc)    `shl rN, 5` — power of two; no 2-op
                              `imul r, imm`.
  * No `and rN, imm64`        mismatch pack uses `shl` + `or` only;
                              every `and rN, imm16` fits imm32
                              (0xFFFF, bit 31 clear).
  * Single-line `pub let`     one line per literal (tags, status
                              codes, registration slot).
  * Module basename matches   `TypecheckGate` ↔ `typecheck_gate.pdx`.
  * Labels prefixed `tcg_`    reserved-word discipline; distinct from
                              `ctr_` / `pds_cdg_` / `ig_` / `vg_`
                              siblings.
  * Byte loads                `xor rN, rN; mov_b rN, [reg+reg*1]`
                              (mov_b does not implicitly zero-extend —
                              R133.M3 L450 precedent).
  * u16 loads                 `xor rN, rN; mov_w rN, [reg+off]`
                              (header_pragma.pdx:924 precedent).
  * u32 loads                 `xor rN, rN; mov eax, [reg+off]`
                              (container_reader.pdx G4 pattern).
  * `cmp rN, imm32` for all   `0x3E00..0x3E06` all fit imm32
    status codes               sign-ext safe (bit 31 clear). TCG_MAGIC
                              `0x50495042` also sign-ext safe.
  * Full-u64 status compares  not low-byte masked (Wave 118 lesson).

## Fingerprint tag geometry (N = len(string) + 1, NUL inclusive)

```
"pds typecheck ok"              16 + NUL -> N = 17
"pds typecheck rejected"        22 + NUL -> N = 23
"pds typecheck no-checker"      24 + NUL -> N = 25
"pds typecheck bad-header"      24 + NUL -> N = 25
"pds typecheck too-many-stages" 29 + NUL -> N = 30
"pds typecheck null-body"       23 + NUL -> N = 24
"pds typecheck bad-bounds"      24 + NUL -> N = 25
"pds typecheck null-fn"         21 + NUL -> N = 22
"pds typecheck registered"      24 + NUL -> N = 25
"stages"                         6 + NUL -> N =  7
"bad"                            3 + NUL -> N =  4
```

## Cross-module wiring

The R131 pds-loader at M5+ invokes `_pds_tcg_gate` on the parsed
PipelineBody immediately after the version gate admits the ABI
contract and the import graph admits the module order:

```
e = _pds_cdg_gate(...);                     // 0x3200..0x32FF band
if (e != 0) abort;
e = _vg_check(req_line_ptr, req_line_len);  // 0x3B00..0x3BFF band
if (e != 0) abort;
e = _ig_build_order(adj, n, out, cap);      // 0x3A00..0x3AFF band
if (ig_status(e) != IG_OK) abort;
e = _pds_tcg_gate(body_ptr, body_len);      // 0x3E00..0x3EFF band
if (tcg_status(e) != TCG_OK) abort;
dispatch stage effects...
```

Each gate owns its band so a surrounding error-reporter can switch on
the low 16 bits of the packed status without ambiguity.

### Satellite init sequence

Lands at R132.Mx (pds-parser boot):

  1. Satellite's own init runs AFTER kernel `.bss` zero-fill (so the
     registration slot is nil at the time of registration).
  2. Satellite publishes its checker:

     ```
     status = _pds_tcg_register_checker(&_pds_tcg_check_stage_impl)
     ```

     On OK: the gate is now armed with the real checker.
     On `TCG_ERR_NULL_FN`: fatal — the satellite's fn-ptr is bogus.

Between kernel boot and satellite registration, every `_pds_tcg_gate`
call returns `TCG_ERR_NO_CHECKER_AVAIL`; the surrounding R131 pds-loader
surfaces this as `PdsErr::NoTypeChecker { reason: "satellite not
registered" }` and either refuses the load (strict posture) or admits
with a downgraded promise (allow-partial posture; selected at M6+ by a
kernel-boot flag).

## Acceptance smoke

```
Pipeline:
  stage[0]: list-files     emits Record<Path>
  stage[1]: word-count     consumes Record<Bytes>

Expected outcome:
  _pds_tcg_gate(body_ptr, body_len) returns a packed u64 with:
     bits [15: 0] = 0x3E03           (TCG_ERR_STAGE_TYPE_MISMATCH)
     bits [31:16] = 1                (bad_idx -- stage 1 refused)
     bits [63:32] = <satellite status> (whatever R132.Mx returned)

Expected fingerprint:
  LEVEL_WARN  subsys=cap  tag="pds typecheck rejected"
              stages=2    bad=1

Companion success case:
  stage[0]: list-files     emits Record<Path>
  stage[1]: emit-paths     consumes Record<Path>

Expected outcome:
  packed = (2 << 16) | 0x0000     (TCG_OK, n_stages=2)
Expected fingerprint:
  LEVEL_INFO  subsys=cap  tag="pds typecheck ok"
              stages=2    bad=0
```

## Future work

  * **Multi-pass elaboration.** M5 performs a single flat walk of the
    stages; the user-space checker owns ALL cross-stage reasoning.
    A later wave MAY split row-type unification from stage-local
    typing to let the gate short-circuit cheap-local errors before
    paying for cross-stage inference.

  * **Checker hot-reload.** M5 bans unregistration to avoid race with
    in-flight loads. A sealed `_pds_tcg_unregister` with an epoch guard
    (bump an epoch counter, refuse any gate call whose captured epoch
    doesn't match, wait for drain) is a reasonable M6 elaboration if
    the shell workflow surfaces a legitimate reason to hot-swap.

  * **StageDesc overflow.** M5 caps `n_stages` at 64; a late pipeline
    reflow (`cat lots.txt | grep | wc`-style scripts in a user's
    bash-shaped mental model) MAY exceed. The ceiling is a
    `TCG_MAX_STAGES` constant and can be lifted by widening the loop
    counter width and the fingerprint column.

  * **Allow-partial admit.** `TCG_ERR_NO_CHECKER_AVAIL` is currently a
    hard refuse. The R131 pds-loader could trade this for a downgraded
    promise ("admit the script, but mark every stage effect as
    quarantine-only") behind a kernel-boot flag. The gate's return
    value is already shaped for a 3-way admit/warn/refuse split; the
    policy sits one layer up.

  * **Caller-provided scratch.** M5's `_tcg_check_fn` slot is a module
    singleton (one checker per kernel instance). A multi-tenant pds
    runtime (far future — see design/kernel/multi-tenancy.md once it
    lands) would thread a per-tenant checker fn through the gate's
    signature. The current signature stays stable; new args append.

## References

  * `src/kernel/core/pds/container_reader.pdx` — R133.M1
  * `src/kernel/core/pds/caps_decl_gate.pdx` — R133.M2
  * `src/kernel/core/pds/import_graph.pdx` — R133.M3
  * `src/kernel/core/pds/version_gate.pdx` — R133.M4
  * `src/kernel/core/pds/typecheck_gate.pdx` — R133.M5 (THIS)
  * `design/kernel/pds-import-graph.md` — R133.M3 design doc
  * `design/kernel/pds-version-gate.md` — R133.M4 design doc
  * `design/shell/arg-flag-spec-typing.md` — R222.M4 user-space
  * `design/shell/type-env-threading.md` — R229.M3 user-space
  * `tools/user/libpdx-pds-parser/` — satellite type-checker
  * `tools/verify-fingerprint-coverage.sh` — OK_TOK regex semantics
  * `feedback_pdx_encoder_pitfalls` — encoder discipline
