# Per-turn type-check fingerprint (R225.M10)

Issue:    paideia-os#2691
Umbrella: paideia-os#2489 (R225 typechecker)
Wave:     133
Lands:    2026-10-15

## 1 Why this exists

The paideia-os project invariants
(`design/foundations/project-invariants.md` P9) commit every REPL turn
to a verifiable anti-fabrication anchor. R229.M10 TurnFingerprint
(parser-tier `_tf_emit` → `@fingerprint("turn.<id>.<result-hash>")`)
lands the RESULT-side half of that anchor: a 64-byte record carrying
magic 'TFPR' + turn_id + FNV-1a 64 hash of the actual emitted result
bytes + rdtsc timestamp + rendered ASCII tag.

R225.M10 lands the TYPECHECK-side half. Every REPL turn runs the HM
elaborator (R225.M1 HmCore) + the per-binding RankCheck
(R225.M6 RankCheck) + the per-script LoadCheck orchestrator
(R227.M4 LoadCheck) over the turn's typed-AST before dispatch. The
checker's PASS/FAIL outcome is itself an adversarial-verifiable claim:
a sub-agent (or the shell driver) that reports "type-check OK" or
"type-check failed with N diagnostics" must be anchorable to a
fingerprint the debugger can correlate against the actual checker
run. R225.M10 provides that anchor.

The checker's outcome has two shapes:

* **OK** -- the elaborator pass completed without emitting any
  R225.M7 DiagReport / R227.M4 LoadCheck diagnostic. The result bytes
  the fingerprint hashes are the literal ASCII string `"ok"` (2 bytes:
  `0x6F 0x6B`).
* **FAIL-N** -- the elaborator pass emitted N diagnostics (N > 0, from
  `_lc_count_diags` R227.M4). The result bytes the fingerprint hashes
  are the literal ASCII string `"fail-<N>"` where `<N>` is the
  variable-width decimal rendering of N (e.g. `"fail-3"`, `"fail-42"`).

The rendered tag the module emits externally is
`@fingerprint("check.<turn-id>.<result>")` where `<result>` is `ok` or
`fail-<N>` for exact-byte parallelism with the hash input. The
debugger (both the sub-agent debugger and the smoke-mode correlation
harness) treats the tag as the ground truth for every turn's claimed
checker outcome.

The 200-turn REPL session acceptance (per the issue) is: `_cf_emit`
fires 200 times in sequence (one per REPL turn), each turn producing a
64-byte record whose `_cf_render_tag` output can be fed back through
`_cf_correlate` with the expected tag and get `CF_OK` on every one of
200 iterations.

## 2 Position in the substrate

```
TTY ISR -> _rl_tick (R229.M1) -> state := EVALUATE
     -> parser builds AST (R221.M5)
     -> _lc_check_script(script_body, body_len, out_diag_chain, out_cap)
            -> LC_OK OR LC_ERR_TYPECHECK_FAILED + diag chain
     -> _lc_count_diags(diag_chain, chain_len) -> N
     -> _cf_emit(turn_id, lc_result_status, N, out, 64)  (THIS module)
            -> 64-byte CheckFingerprint record on caller scratch
     -> _cf_render_tag(record, out, out_cap)             (THIS module)
            -> `@fingerprint("check.<id>.<ok|fail-N>")` ASCII string
     -> klog emission + stdout emission
     -> IFF status == LC_OK: evaluator dispatch
     -> state := WRITING (R229.M9 Renderer dispatches the write)
     -> _tf_emit(turn_id, result_bytes, result_len, out, 64)  (R229.M10)
            -> `@fingerprint("turn.<id>.<result-hash>")`
     -> state := READING -> _rl_emit_prompt
```

Companion module on the debugger side:

```
<external claimed check-tag>  +  <record the shell emitted>
     -> _cf_correlate(expected_tag, expected_len, actual_record, 64)
            -> CF_OK (match) or CF_ERR_MISMATCH (lie)
```

R225.M10 is the sibling of R229.M10. The two per-turn fingerprint
emitters produce records with matched 64-byte stride, matched FNV-1a
64 hash family, and matched `@fingerprint("…")` wrapper. A
cross-boundary correlator comparing a `check.<id>.<result>` tag
against a `turn.<id>.<hash-hex>` tag discriminates "typecheck
emission" from "result emission" via the `check` vs `turn` prefix in
the rendered inner.

## 3 CheckFingerprint record -- 64 bytes

Record stride 64 = 2^6 so a future per-session multi-check ring (one
row per turn, up to a bounded horizon) can index via `shl idx, 6`
with no 2-op `imul r, imm` dance (precedent: R229.M10 TurnFingerprint
power-of-two record stride).

| Offset | Width | Field          | Meaning |
| ------ | ----- | -------------- | ------- |
| 0x00   | u32   | `magic`        | 'CFPR' (0x52504643 LE) -- bytes C,F,P,R |
| 0x04   | u32   | `turn_id`      | 1-based turn counter from R229.M1 state |
| 0x08   | u64   | `result_hash`  | FNV-1a 64 of result bytes `"ok"` or `"fail-<N>"` |
| 0x10   | u64   | `timestamp_us` | rdtsc sample at emit time (raw TSC) |
| 0x18   | u8[32]| `rendered_tag` | `check.<id>.<ok\|fail-N>` ASCII, NUL-padded |
| 0x38   | u64   | reserved       | zero at M10; reserved for M10.1+ |

The `rendered_tag` field format: `check.` (6 bytes) + variable-width
decimal `turn_id` (1..10 bytes; no leading zeros) + `.` (1 byte) +
either the 2-byte string `"ok"` OR `"fail-"` (5 bytes) +
variable-width decimal N (1..10 bytes; no leading zeros for N > 0;
single `0` for N == 0 iff the FAIL branch fires with N == 0 as a
defensive emission; the FAIL branch normally fires only with N >= 1
since `_lc_count_diags` returns 0 iff LC_OK).

Max rendered width:

```
"check."           = 6
decimal(2^32 - 1)  = 10        -> turn_id ceiling
"."                = 1
"fail-"            = 5
decimal(2^32 - 1)  = 10        -> n_diags ceiling
                   ---
                   = 32 bytes exactly
```

The 32-byte field fits the ceiling case exactly. The field is
NUL-padded past the live tail. A reader walks from offset 0 until the
first NUL or offset 32, whichever first.

Why 64 bytes exactly:
* Power of two (`shl idx, 6` addressing for a future multi-check ring).
* Fits the four fixed fields (magic / turn_id / hash / timestamp = 24 B)
  + the rendered_tag (32 B) + one reserved u64 for M10.1+ growth.
* Below the common x86_64 L1 cache line (64 B is one line exactly); a
  cold-cache read of a single turn's record pulls exactly one line.
* Matches the R229.M10 TurnFingerprint 64-byte record stride exactly;
  the two per-turn records are symmetric data-shape-wise.

Why FNV-1a 64:
* Byte-for-byte identical to the parser-tier FNV family
  (`_cmd_sig_fnv1a64` R222.M2, `_fi_fnv1a64` R222.M3,
  `_cmdreg_fnv1a64` R222.M5, `_ws_schema_hash` R223.M5, the inlined
  FNV in `_h_append` R229.M5, the inlined FNV in `_tf_emit`
  R229.M10). Hashing the checker's outcome bytes with the SAME
  algorithm as every other parser-tier hash site means a cross-tool
  correlator comparing hashes gets numerical equality.
* Pure-leaf implementation (no state, no SIMD, no lookup table) so
  the hash call-site is cheap on every turn.
* 64-bit output gives 16 hex characters (not emitted on the rendered
  tag, which carries the human-readable `ok`/`fail-N` form; the raw
  hash lives in the `result_hash` u64 field for machine comparison).

Why raw TSC (not microseconds):
* Byte-for-byte reproducible across tools (same rationale as
  R229.M10 TurnFingerprint).
* The REPL driver (R229.M1) owns the TSC-to-microseconds conversion
  (R20.M3 calibration result); this module stores the raw sample.

Why the rendered tag carries `ok`/`fail-N` rather than the raw hash:
* The checker's outcome is an EYEBALL claim ("I ran the HM elaborator
  and got N diagnostics"); the human-readable form on the rendered
  tag lets a hand-reviewer validate the fingerprint without a hash
  lookup table.
* The `result_hash` u64 field still carries the FNV digest so a
  machine correlator (the debugger's `_cf_correlate` or an M10.3-tier
  strict-mode comparator) can compare bitwise. The rendered form and
  the hash form are redundant by design: a tampered rendered form
  that keeps the hash field intact fails `_cf_correlate` because the
  function byte-compares the rendered inner, not the hash field.
* Distinction from R229.M10 TurnFingerprint, whose rendered tag
  carries the raw hash hex because a result's bytes are opaque to
  the eyeball; a checker outcome is semantic ("ok" / "fail-N") and
  benefits from the human-readable form.

## 4 Public API

### 4.1 `_cf_init() -> ()`

Bare `ret`. M10 holds NO .bss state. Entry exists for parallelism
with the parser-family init-hook convention (`_tf_init` R229.M10,
`_rd_init` R229.M9, `_ha_init` R223.M6, `_ws_init` R223.M5,
`_ds_init` R222.M8, `_dm_init` R222.M6, `_cmdreg_init` R222.M5,
`_st_init` R223.M7) so a later M10.1+ landing that adds .bss
(e.g. a per-session check-counter cache) does not break the API.

### 4.2 `_cf_emit(turn_id, lc_result_status, n_diags, out, out_cap) -> status`

Register map:

| Reg | Role |
| --- | ---- |
| rdi | `turn_id` (1-based; must fit u32) |
| rsi | `lc_result_status` (0 = LC_OK, non-zero = checker failed) |
| rdx | `n_diags` (count from `_lc_count_diags`; must fit u32) |
| rcx | `out` (ptr to caller-owned 64-byte scratch) |
| r8  | `out_cap` (must be >= 64) |
| rax | `CF_OK` or `CF_ERR_*` |

Guards (in order):

1. `out != 0` else `CF_ERR_BAD_OUT` (0x6300).
2. `out_cap >= 64` else `CF_ERR_OUT_TOO_SMALL` (0x6301).
3. `turn_id` upper 32 bits != 0 → `CF_ERR_BAD_TURN_ID` (0x6302).
4. `n_diags` upper 32 bits != 0 → `CF_ERR_BAD_N_DIAGS` (0x6303).

The upper-32-bits turn_id and n_diags checks stage `0xFFFFFFFF` via
MOVABS into a scratch register and compare register-to-register
(direct `cmp reg, imm32` with bit 31 set is sign-extension-unsafe
per the Wave 125 pdx-encoder-pitfalls lesson).

Side effects on success (writes 64 bytes to `out`):

| Offset | Store |
| ------ | ----- |
| +0  | `mov_d [out+0], 0x52504643` (magic 'CFPR') |
| +4  | `mov_d [out+4], turn_id_low32` |
| +8  | `mov [out+8], result_hash` |
| +16 | `mov [out+16], rdtsc_combined` |
| +24..+56 | zero-fill then ASCII render of `check.<id>.<ok\|fail-N>` |
| +56 | `mov [out+56], 0` (reserved u64) |

The ASCII render pass:

1. Zero-fill 32 bytes at [out+24..+56] via four u64 stores.
2. Byte-store `check.` (6 B) at [out+24..+30] via six `mov_b` writes.
3. Decimal-render `turn_id` starting at [out+30] via greedy-subtract
   over the shared `_cf_pow10` LUT with an `emit_flag` to suppress
   leading zeros. Edge case: `turn_id == 0` emits a single `0`.
4. Byte-store `.` at the running cursor.
5. Branch on `lc_result_status`:
   * `lc_result_status == 0`: byte-store `ok` (2 B) at the cursor;
     advance cursor by 2.
   * Else: byte-store `fail-` (5 B); advance cursor by 5; decimal-
     render `n_diags` with emit_flag suppression (edge case n_diags
     == 0 emits a single `0`); advance cursor by the digit count.
6. FNV-1a 64 hash the result-string bytes written in step 5
   (NOT including the `check.<id>.` prefix) and store the digest at
   [out+8]. The hash is computed INLINE while step 5 runs by
   maintaining the accumulator across each byte emit (standard FNV
   loop state in a dedicated register pair).
7. `rdtsc; shl rdx, 32; or rax, rdx; mov [out+16], rax`.

Frame shape: 6 callee-save push (rbx=turn_id, rbp=lc_result_status,
r12=n_diags, r13=out, r14=out_cap, r15=hash). NO nested CALL (FNV
inlined; decimal rendering unrolled) so no sub-rsp alignment pad is
required (precedent: R229.M5 `_h_append`, R229.M10 `_tf_emit`).

### 4.3 `_cf_render_tag(record, out, out_cap) -> packed_u64`

Register map:

| Reg | Role |
| --- | ---- |
| rdi | `record` (ptr to 64-byte CheckFingerprint record) |
| rsi | `out` (ptr to caller-owned output buffer) |
| rdx | `out_cap` (must be >= `16 + inner_len`) |
| rax | `(bytes_written << 32) \| status` |

Guards (in order):

1. `record != 0` else `CF_ERR_BAD_RECORD` (0x6304).
2. `out != 0` else `CF_ERR_BAD_OUT` (0x6300).
3. `u32 at [record+0] == 0x52504643` else `CF_ERR_BAD_MAGIC` (0x6305).
4. `out_cap >= 16 + inner_len` else `CF_ERR_OUT_TOO_SMALL` (0x6301).

Flow:

1. Scan `record[+24..+56]` for the first NUL byte; `inner_len` ∈
   [0..32] is the live tag length.
2. Emit the 14-byte prefix `@fingerprint("` from `_cf_prefix` in
   .rodata.
3. Byte-copy `inner_len` bytes from `record[+24..+24+inner_len]` to
   `out[+14..+14+inner_len]`.
4. Emit the 2-byte suffix `")` at `out[+14+inner_len..+16+inner_len]`.
5. Return `((16 + inner_len) << 32) | CF_OK`.

Pure leaf; zero callee-save pushes; no stack frame; no nested CALL.

### 4.4 `_cf_correlate(expected_tag, expected_len, actual_record, record_len) -> status`

Register map:

| Reg | Role |
| --- | ---- |
| rdi | `expected_tag` (ptr to expected `@fingerprint("...")` ASCII) |
| rsi | `expected_len` (byte length; must be >= 16) |
| rdx | `actual_record` (ptr to 64-byte CheckFingerprint record) |
| rcx | `record_len` (= 64; defensive guard) |
| rax | `CF_OK` iff rendering would produce byte-identical output |

Guards (in order):

1. `record_len == 64` else `CF_ERR_BAD_LEN` (0x6307).
2. `actual_record != 0` else `CF_ERR_BAD_RECORD` (0x6304).
3. `expected_tag != 0` else `CF_ERR_BAD_EXPECTED` (0x6308).
4. `expected_len >= 16` else `CF_ERR_BAD_LEN`.
5. `u32 at [record+0] == 0x52504643` else `CF_ERR_BAD_MAGIC` (0x6305).

Flow (NO scratch stack buffer; the function compares in-place):

1. Verify `expected_tag[0..14]` matches `_cf_prefix[0..14]`
   (`@fingerprint("`). Mismatch → `CF_ERR_BAD_LEN` (missing wrapper).
2. Verify `expected_tag[expected_len - 2] == '"'` and
   `expected_tag[expected_len - 1] == ')'`. Mismatch →
   `CF_ERR_BAD_LEN`.
3. `inner_len = expected_len - 16`. Guard `inner_len <= 32` else
   `CF_ERR_MISMATCH` (0x6306) -- the record's field only holds 32
   bytes.
4. Byte-compare `expected_tag[14..14+inner_len]` against
   `actual_record[24..24+inner_len]`. Any mismatch →
   `CF_ERR_MISMATCH`.
5. If `inner_len < 32`: verify `actual_record[24+inner_len] == 0` so
   the record's live tag is not LONGER than the expected inner.
6. Return `CF_OK`.

Pure leaf; zero callee-save pushes; no stack frame; no nested CALL.

## 5 Status-code namespace -- 0x6300..0x63FF

Nine slots used at R225.M10:

| Code | Name | Meaning |
| ---- | ---- | ------- |
| 0 | `CF_OK` | success |
| 0x6300 | `CF_ERR_BAD_OUT` | `out == 0` on any entry |
| 0x6301 | `CF_ERR_OUT_TOO_SMALL` | `out_cap` below required width |
| 0x6302 | `CF_ERR_BAD_TURN_ID` | `turn_id` upper 32 bits set |
| 0x6303 | `CF_ERR_BAD_N_DIAGS` | `n_diags` upper 32 bits set |
| 0x6304 | `CF_ERR_BAD_RECORD` | `record == 0` on render/correlate |
| 0x6305 | `CF_ERR_BAD_MAGIC` | magic at `record[+0]` != 'CFPR' LE |
| 0x6306 | `CF_ERR_MISMATCH` | correlate: tag != record's rendered form |
| 0x6307 | `CF_ERR_BAD_LEN` | correlate: bad record_len / expected_len |
| 0x6308 | `CF_ERR_BAD_EXPECTED` | correlate: `expected_tag == 0` |

Slots 0x6309..0x63FF reserved for M10.1+ follow-ups:

* `CF_ERR_BAD_ENV_MASK` (M10.1 env-mask field validator for cap-row
  delta between CHECK and READ phases).
* `CF_ERR_HASH_MISMATCH` (M10.3 strict-mode hash-only correlator
  that recomputes FNV from the result-string bytes).
* `CF_ERR_TIMESTAMP_SKEW` (M10.4 rdtsc-skew sanity bound).
* `CF_ERR_LC_RESULT_UNKNOWN` (M10.5 orchestrator-tier adapter that
  accepts a 4-category outcome: LC_OK / RANK_FAIL / HM_FAIL / IMPORT_FAIL).

### 5.1 Disjointness proof

Band 0x6300..0x63FF is disjoint from every landed parser-tier band:

```
0x3C00..0x3CFF  R222.M4 arg_flag_spec
0x3F00..0x3FFF  R221.M3 width_pass
0x4100..0x41FF  R222.M3 functor_instance
0x4500..0x45FF  R222.M5 cmd_registry
0x4800..0x48FF  R222.M6 dispatch_mode
0x4A00..0x4AFF  R229.M2 session_env
0x4B00..0x4BFF  R229.M3 type_env
0x4C00..0x4CFF  R222.M8 describe_sig legacy
0x4E00..0x4EFF  R229.M4 job_control
0x4F00..0x4FFF  R222.M8 describe_sig
0x5000..0x50FF  R224.M6 pipeline_lambda
0x5100..0x51FF  R229.M5 history
0x5200..0x52FF  R223.M5 wire_sink
0x5300..0x53FF  R223.M6 hostname_annot
0x5400..0x54FF  R229.M6 line_editor
0x5500..0x55FF  R223.M7 session_type
0x5600..0x56FF  R224.M7 linear_propagate
0x5700..0x57FF  R229.M7 vi_mode
0x5800..0x58FF  R225.M6 rank_check
0x5900..0x59FF  R227.M3 import_resolve
0x5A00..0x5AFF  R229.M8 multi_line
0x5B00..0x5BFF  R225.M7 diag_report
0x5C00..0x5CFF  R227.M4 load_check
0x5D00..0x5DFF  R229.M9 renderer
0x5E00..0x5EFF  R225.M8 lsp_hover
0x5F00..0x5FFF  R227.M5 module_functor
0x6000..0x60FF  R229.M10 turn_fingerprint
0x6100..0x61FF  R225.M9 proptest_hm
0x6200..0x62FF  R227.M6 version_pragma
0x6300..0x63FF  R225.M10 CheckFingerprint   (THIS landing)
```

R225.M10 sits directly above the R227.M6 VersionPragma band
(0x6200..0x62FF) with no held reservations between them.

A downstream compound-error dispatcher can discriminate
"check-fingerprint faulted" from every other sibling satellite's
failure modes by `shr r, 8; cmp r, 0x63`.

## 6 Encoder discipline (absolute)

Standard parser-tier discipline (grep-confirmed clean against the
pdx-encoder-pitfalls memory):

* No `test rN, rN` -- every zero-check uses `cmp reg, 0; je/jne`.
* No `and rN, imm64` -- every mask is imm8 (0xFF, 15) or imm32.
* No 2-op `imul r, imm` -- the FNV multiply uses the one-op
  `mul rcx` form (unsigned 64x64; distinct from the pitfall).
* No multiline `pub let = "..."` -- every justification is a single
  line.
* Module basename `CheckFingerprint` matches `check_fingerprint.pdx`.
* Labels prefixed `cf_` with per-function suffix (`cf_ini_`,
  `cf_em_`, `cf_rt_`, `cf_co_`). Grep-disjoint from every landed
  parser-tier prefix (u8n_, gi_, wp_, cl_, ast_, sm_, fh_,
  sch_sig_, cmd_sig_, fi_, afs_, cmdreg_, dm_, ds_, pl_, pl_lam_,
  rp_, fo_, sgr_, ws_, ha_, st_, ll_, cc_, er_, cr_, ls_, lp_,
  hm_, rt_, eu_, dl_, se_, te_, jc_, h_, le_, vi_, ml_, ir_,
  rc_, rd_, dr_, lc_, lh_, tf_, mf_, vp_, pth_). The `cf_` prefix
  is also disjoint from the paideia-as reserved-keyword set (loop,
  if, let, fn, ret, done).
* `cmp` immediates all fit imm32 with bit 31 clear EXCEPT
  `0xFFFFFFFF` (turn_id / n_diags upper-32 bound) which stages via
  MOVABS into a scratch register and compares register-to-register.
* Byte loads via `xor rax, rax; mov_b rax, [base + idx * 1]`
  (FNV-family precedent).
* u32 stores via `mov_d [dst + disp], reg`.
* u64 stores via plain `mov [dst + disp], reg`.
* Byte stores at a reg + reg address compute the destination into a
  caller-save scratch first (`mov r?, dst_base; add r?, idx;
  mov_b [r? + 0], byte`) to sidestep the
  `mov_b [reg + reg + off], reg` encoder gap (precedent:
  history.pdx line 663, turn_fingerprint.pdx throughout).
* `_cf_init`, `_cf_render_tag`, `_cf_correlate` are PURE LEAVES with
  zero callee-save pushes. r11 is used freely.
* `_cf_emit` is a 6-callee-save-push frame with ZERO nested CALL;
  no sub-rsp alignment pad required.

## 7 Register plans

### 7.1 `_cf_emit` -- 6-push frame

| Reg | Role after prologue |
| --- | ------------------- |
| rbx | `turn_id` (saved input; low 32 are the record's turn_id field) |
| rbp | `lc_result_status` (saved input; 0 → OK branch, else FAIL) |
| r12 | `n_diags` (saved input; low 32 are the FAIL branch's N) |
| r13 | `out` (saved input; destination base for every store) |
| r14 | `out_cap` (saved input; guard reference) |
| r15 | `result_hash` (populated inline during rendering) |

Decimal-render scratch budget: rdi (working dividend), r8 (pow
index 0..9), rcx (pow value), r9 (digit), r10 (emit_flag), rdx
(cursor), r11 (per-emission scratch), rsi (dst-address scratch).

FNV-inline hash accumulator: rax (hash), rcx (prime; held after
decimal render), rdx (mul high half, clobbered each byte).

### 7.2 `_cf_render_tag` -- pure leaf

Pre-loop and scan: r8 (`&record[24]`), r9 (`inner_len`), r10
(`needed`), r11 (per-byte scratch), rax (i).

Prefix emit: rcx (`&_cf_prefix`), rax (i), r11 (byte), r8
(dst-address scratch).

Inner copy: r8 (`&record[24]`), rcx (`&out[14]`), rax (i),
r11 (byte), rdi (dst-address scratch).

Suffix emit: rcx (`&out[14+inner_len]`), rax (byte).

### 7.3 `_cf_correlate` -- pure leaf

Same shape as `_tf_correlate` (R229.M10). Prefix verify: r8
(`&_cf_prefix`), r9 (expected_tag), rax (i), r10 (expected byte),
r11 (prefix byte). Suffix verify: r8 (`expected_len - 2`), r9
(`&expected_tag[len-2]`), r10 (byte). Inner compare: r8
(inner_len), r9 (`&expected_tag[14]`), r10 (`&actual_record[24]`),
rax (i), r11 (expected byte), rcx (actual byte). Trailing-NUL
check: r11 (byte at `&record[24 + inner_len]`).

## 8 Acceptance

The 200-turn smoke session (per the issue):

1. Simulated REPL driver pushes 200 synthetic (lc_result_status,
   n_diags) pairs through `_cf_emit(id, status, N, scratch, 64)`
   for id = 1..200. Mix: 100 OK (status=0, N=0), 100 FAIL
   (status=1, N ∈ {1..64}).
2. Each iteration also calls `_cf_render_tag(scratch, tag_out, 64)`
   and verifies the returned high-32 is `16 + inner_len` for the
   computed inner_len = 6 + decimal_digits(id) + 1 +
   (2 iff OK else 5 + decimal_digits(N)).
3. Each iteration then feeds (tag_out, len, scratch, 64) into
   `_cf_correlate` and asserts `CF_OK`.
4. An extra iteration perturbs scratch (flips one bit in the
   rendered_tag) and asserts `CF_ERR_MISMATCH`.

Fixture tier at raw M10 (nine negative cases + three positive):

| # | Fixture | Expected rax |
| - | ------- | ------------ |
| 1 | emit(1, 0, 0, out, 64) | CF_OK; magic 'CFPR', turn_id=1, hash=FNV("ok"), tag="check.1.ok" |
| 2 | emit(42, 1, 3, out, 64) | CF_OK; hash=FNV("fail-3"), tag="check.42.fail-3" |
| 3 | emit(4294967295, 1, 4294967295, out, 64) | CF_OK (ceiling: 32-byte rendered_tag exactly) |
| 4 | emit(1, 0, 0, 0, 64) | CF_ERR_BAD_OUT |
| 5 | emit(1, 0, 0, out, 63) | CF_ERR_OUT_TOO_SMALL |
| 6 | emit(0x1_0000_0000, 0, 0, out, 64) | CF_ERR_BAD_TURN_ID |
| 7 | emit(1, 0, 0x1_0000_0000, out, 64) | CF_ERR_BAD_N_DIAGS |
| 8 | render_tag(0, out, 64) | CF_ERR_BAD_RECORD |
| 9 | render_tag(record_with_wrong_magic, out, 64) | CF_ERR_BAD_MAGIC |
| 10 | correlate(expected_matching, len, record, 64) | CF_OK |
| 11 | correlate(expected_bit_flipped, len, record, 64) | CF_ERR_MISMATCH |
| 12 | correlate(0, 16, record, 64) | CF_ERR_BAD_EXPECTED |

The full 200-turn golden corpus lands at M10.5 under
`smoke/check-fingerprint-m10.golden.txt` with one line per turn
carrying the full `@fingerprint("...")` tag; the smoke harness
`tools/verify-check-fingerprint-coverage.sh` iterates the golden
and asserts `_cf_correlate` passes for every row.

## 9 Consumer pattern

The REPL driver (R229.M1, kernel-side) wires the check-fingerprint
path as:

```
// Per-turn check-anchor hot path (pseudocode).
let diag_chain = alloca 8192;
let lc_status  = _lc_check_script(script, script_len, diag_chain, 8192);
let n_diags    = _lc_count_diags(diag_chain, 8192);

let rec    = alloca 64;
let tag    = alloca 64;
let status = _cf_emit(turn_id, lc_status, n_diags, rec, 64);
if status != CF_OK { klog_fault(status); next_turn; }

let packed = _cf_render_tag(rec, tag, 64);
let st     = packed & 0xFFFFFFFF;
let nbytes = packed >> 32;
if st != CF_OK { klog_fault(st); next_turn; }

klog_bytes(tag, nbytes);                 // post-mortem anchor
tty_write(tag, nbytes);                  // user-visible anchor

if lc_status != LC_OK { emit_diag_chain; next_turn; }  // skip eval
```

The debugger / correlation harness (R225.M10.5 smoke tier) wires:

```
// Per-golden-row verification (pseudocode).
let line = golden_rows[i];               // "@fingerprint(\"check.i.<ok|fail-N>\")"
let st   = _cf_correlate(line.ptr, line.len, actual_recs[i], 64);
assert_eq!(st, CF_OK);
```

## 10 Where this is NOT

* NOT the ONLY fingerprint. The R229.M10 TurnFingerprint record
  carries its own hash over the RESULT BYTES; the two hashes serve
  different anchors (check outcome vs result bytes). Both land per
  turn.
* NOT a cryptographic MAC. FNV-1a 64 is a fast fingerprint, not a
  signature; an adversary with write access to the record can forge
  one. The P9 anchor is a FABRICATION defence, not a tamper defence.
* NOT a diagnostic payload. The 64-byte record carries only the
  check-outcome shape (OK or FAIL-N); the full R225.M7 DiagReport /
  R227.M4 LoadCheck LC_DIAG records remain the authoritative
  diagnostic surface and are emitted separately via the diag chain.
* NOT a persistent store. The 64-byte record is caller-scratched and
  discarded after klog / stdout emission. The R229.M5 History ring
  is the persistent per-session memory; CheckFingerprint is the
  per-emission anti-fabrication anchor.
* NOT a replacement for `_lc_check_script`. The orchestrator still
  runs the full HM elaborator pass; this module anchors its outcome.

## 11 File footprint

* `tools/user/libpdx-pds-parser/src/check_fingerprint.pdx` -- ~1050
  LOC including the mandatory header comment block.
* `design/shell/check-fingerprint.md` -- this file.
* `tools/user/libpdx-pds-parser/caps.decl` -- R225.M10 catalogue
  paragraph + error-band section at 0x6300..0x63FF.
* `tools/user/libpdx-pds-parser/src/lib.pdx` -- bump version 1.41.0 →
  1.42.0; add `LPX_PDS_PARSER_R225_M10_READY = 1`; append
  `src/check_fingerprint.pdx at R225.M10` to the module-filename
  comment; append `paideia-os#2691` to the upstream list; append
  `design/shell/check-fingerprint.md` to the design-docs cross-ref.
* `tools/user/libpdx-pds-parser/STATUS.md` -- add R225.M10 landing
  paragraph; bump Version to 1.42.0; add Wave 133 landings header;
  add R225.M10 checklist section; add error-band accounting row.
* `.plans/scratch/CHANGELOG-R225M10.md` -- per-primitive scratch
  (consolidated into `CHANGELOG.md` at Wave close).

## 12 Forward path

* **R225.M10.1** env-mask field. Add a `u32 env_mask` at
  `[record+0x38..+0x3C]` capturing the cap-row delta between the
  CHECK phase and the READ phase of the turn. The correlator gains
  the detection of mid-turn capability drift (a privilege escalation
  that the standard check-outcome hash does not notice).
* **R225.M10.2** diag-chain-head field. Add a `u32 diag_head_offset`
  at `[record+0x3C..+0x40]` so an auditor can locate the first
  LC_DIAG record in the chain emitted by the same turn without
  consulting the REPL's own state.
* **R225.M10.3** strict-mode hash-only correlator. A second entry
  point `_cf_correlate_strict(expected_tag, expected_len,
  lc_status, n_diags)` that RECOMPUTES the FNV from the
  reconstructed result-string bytes and compares to the hash parsed
  out of expected_tag's inner. Catches a tampered record where
  magic + turn_id + rendered_tag match but the hash field was
  overwritten.
* **R225.M10.4** rdtsc-skew sanity bound. A new entry point
  `_cf_correlate_sequence(records_ptr, n_records)` that rejects a
  sequence where any record's `timestamp_us` precedes the previous
  turn's.
* **R225.M10.5** Smoke-mode golden corpus. 200-turn session fixture
  under `smoke/check-fingerprint-m10.golden.txt` with one line per
  turn carrying the full `@fingerprint("...")` tag, consumed by
  `tools/verify-check-fingerprint-coverage.sh`.
* **R225.M10.6** 4-category outcome adapter. Instead of a single
  `lc_result_status` (OK/FAIL) with a count, admit a four-category
  tag (`LC_OK` / `LC_ERR_RANK_VIOLATION` / `LC_ERR_HM_FAILED` /
  `LC_ERR_IMPORT_FAILED`) and render as
  `check.<id>.<ok|rank-N|hm-N|import-N>` for finer diagnostic
  anchoring. The outcome string length is still bounded by the
  32-byte rendered_tag ceiling.

## 13 Related docs

* `design/foundations/project-invariants.md` -- P9 the authoritative
  invariant.
* `design/shell/turn-fingerprint.md` -- R229.M10 sibling (RESULT-side
  anchor).
* `design/shell/typecheck-at-load.md` -- R227.M4 LoadCheck umbrella;
  the orchestrator whose outcome is anchored here.
* `design/shell/diagnostic-reporting.md` -- R225.M7 DiagReport
  elaborator-tier diagnostic surface.
* `design/shell/repl-loop-scaffold.md` -- R229 umbrella.
* `design/debugger/anti-fabrication-anchors.md` (planned R30 doc) --
  the smoke-mode correlation harness umbrella.
* `.claude/CLAUDE.md` -- the operational directive that cites the
  P9 invariant across every softarch / debugger loop.

## 14 Open questions

* **CF-O1** Should `_cf_emit` accept the raw LC_* status code (0,
  0x5C00, 0x5C05, 0x5C06, 0x5C07, 0x5C08) and dispatch to a
  per-category rendered form (e.g. `check.<id>.rank-N` on
  `LC_ERR_RANK_VIOLATION`)? Decision at M10.6 after the orchestrator
  wire-up matures. Raw M10 collapses the LC_ERR_* set into a binary
  OK/FAIL for simplicity.
* **CF-O2** Should `_cf_correlate` return a bytes-written field
  packed in the high 32 bits on `CF_ERR_MISMATCH` so the caller can
  locate the exact byte offset of the first disagreement? Decision
  at M10.3 when the strict-mode correlator lands.
* **CF-O3** Should the 200-turn smoke harness run under the
  acceptance gate `bash tools/run-smoke.sh` (main-only) or under a
  dedicated `tools/verify-check-fingerprint-coverage.sh` loop?
  Decision at M10.5 when the harness lands.
