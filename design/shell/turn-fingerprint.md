# Per-turn wire fingerprint (R229.M10)

Issue: paideia-os#2728
Umbrella: paideia-os#2493 (R229 REPL evaluator)
Wave:  131
Lands: 2026-10-15

## 1 Why this exists

The paideia-os project invariants
(`design/foundations/project-invariants.md` P9) commit every REPL turn
to a verifiable anti-fabrication anchor: `@fingerprint("turn.<id>.<result-hash>")`.
The project rule exists because every agent-driven workflow in the
PaideiaOS ecosystem — the paideia-as compiler, the softarch
sub-agents, the debugger sub-agent, the smoke-mode correlation
harness — has at some point been observed to fabricate claimed
results. The feedback log
`feedback_workerbee_verify_claims.md` records the specific failure
mode (workerbee fabricates diff summaries and skips test discipline
while reporting success); `feedback_debugger_every_iteration.md`
codifies the lesson (green build ≠ verified diff). The P9 anchor is
the structural rebuttal: a turn whose claimed result does not match
`FNV-1a 64(result bytes)` of the actual emitted result is a lie, and
the correlation harness can prove it.

R229.M10 lands the parser-tier half of that anchor. The kernel-side
REPL driver (R229.M1) calls into this module after every turn, which:

1. Hashes the result bytes (FNV-1a 64, byte-for-byte identical to the
   five parser-family FNV leaves so cross-tool correlation is numeric).
2. Builds a 64-byte TurnFingerprint record carrying magic + turn_id +
   hash + rdtsc timestamp + pre-rendered ASCII tag + reserved slot.
3. Renders the external `@fingerprint("turn.<id>.<hash-hex>")` string
   that gets klogged + stdout-emitted.
4. Lets the debugger / correlation harness check that a claimed tag
   from an external log matches the record the shell actually emitted.

The 500-turn smoke acceptance (per the issue) is: `_tf_emit` fires 500
times in sequence, each turn producing a 64-byte record whose
`_tf_render_tag` output can be fed back through `_tf_correlate` with
the expected tag and get `TF_OK` on every one of 500 iterations. The
test harness itself lives at R229.M10.5 under
`smoke/turn-fingerprint-m10.golden.txt`; the parser-tier primitives
land here at raw M10.

## 2 Position in the substrate

```
TTY ISR -> _rl_tick (R229.M1) -> state := EVALUATE
     -> evaluator -> result bytes
     -> _tf_emit(turn_id, result_ptr, result_len, out, 64)  (THIS module)
            -> 64-byte TurnFingerprint record on caller scratch
     -> _tf_render_tag(record, out, out_cap)               (THIS module)
            -> `@fingerprint("turn.<id>.<hash-hex>")` ASCII string
     -> klog emission + stdout emission
     -> state := WRITING (R229.M9 Renderer dispatches the write)
     -> state := READING -> _rl_emit_prompt
```

Companion module on the debugger side:

```
<external claimed tag>  +  <record the shell emitted>
     -> _tf_correlate(expected_tag, expected_len, actual_record, 64)
            -> TF_OK (match) or TF_ERR_MISMATCH (lie)
```

## 3 TurnFingerprint record — 64 bytes

Record stride 64 = 2^6 so a future per-session multi-turn ring (one
row per turn, up to a bounded horizon) can index via `shl idx, 6` with
no 2-op `imul r, imm` dance (precedent: Wave 125 PipelineLambda
power-of-two record stride).

| Offset | Width | Field          | Meaning |
| ------ | ----- | -------------- | ------- |
| 0x00   | u32   | `magic`        | 'TFPR' (0x52504654 LE) — bytes T,F,P,R |
| 0x04   | u32   | `turn_id`      | 1-based turn counter from R229.M1 state |
| 0x08   | u64   | `result_hash`  | FNV-1a 64 of `result_ptr[0..result_len)` |
| 0x10   | u64   | `timestamp_us` | rdtsc sample at emit time (raw TSC) |
| 0x18   | u8[32]| `rendered_tag` | `turn.<id>.<hex>` ASCII, NUL-padded |
| 0x38   | u64   | reserved       | zero at M10; reserved for M10.1+ |

The `rendered_tag` field format: `turn.` (5 bytes) + variable-width
decimal `turn_id` (1..10 bytes; no leading zeros) + `.` (1 byte) +
lowercase hex of the full 64-bit `result_hash` (16 bytes). Max
rendered width is 5 + 10 + 1 + 16 = 32 bytes exactly (u32 ceiling
turn_id). The field is NUL-padded past the live tail. A reader walks
from offset 0 until the first NUL or offset 32, whichever first.

Why 64 bytes exactly:
* Power of two (`shl idx, 6` addressing for a future multi-turn ring).
* Fits the four fixed fields (magic/turn_id/hash/timestamp = 24 B) +
  the rendered_tag (32 B) + one reserved u64 for M10.1+ growth.
* Below the common x86_64 L1 cache line (64 B is one line exactly); a
  cold-cache read of a single turn's record pulls exactly one line.
* Matches the 128-byte History row (R229.M5) halved — the two per-turn
  records are symmetric data-shape-wise.

Why FNV-1a 64:
* Byte-for-byte identical to the parser-tier FNV family
  (`_cmd_sig_fnv1a64` R222.M2, `_fi_fnv1a64` R222.M3,
  `_cmdreg_fnv1a64` R222.M5, `_ws_schema_hash` R223.M5, the inlined
  FNV in `_h_append` R229.M5). Hashing the result bytes with the
  SAME algorithm as every other parser-tier hash site means a cross-
  tool correlator comparing hashes gets numerical equality.
* Pure-leaf implementation (no state, no SIMD, no lookup table) so
  the hash call-site is cheap on every turn.
* 64-bit output gives 16 hex characters, which fits the 32-byte
  rendered_tag budget with room for a 10-digit turn_id.

Why raw TSC (not microseconds):
* Byte-for-byte reproducible across tools: a smoke-mode golden
  comparing two runs on the same machine gets numerical equality
  of the `timestamp_us` field (modulo the irreducible TSC drift,
  which the correlator can tolerate via an upper bound).
* The REPL driver (R229.M1) owns the TSC-to-microseconds conversion
  (R20.M3 calibration result); this module stores the raw sample.
* Avoids a nested CALL into the TSC calibrator from the parser-tier
  pure-leaf path.

## 4 Public API

### 4.1 `_tf_init() -> ()`

Bare `ret`. M10 holds NO .bss state. Entry exists for parallelism
with the parser-family init-hook convention (`_rd_init` R229.M9,
`_ha_init` R223.M6, `_ws_init` R223.M5, `_ds_init` R222.M8,
`_dm_init` R222.M6, `_cmdreg_init` R222.M5, `_st_init` R223.M7) so a
later M10.1+ landing that adds .bss (e.g. a per-session turn-counter
cache) does not break the API.

### 4.2 `_tf_emit(turn_id, result_ptr, result_len, out, out_cap) -> status`

Register map:

| Reg | Role |
| --- | ---- |
| rdi | `turn_id` (1-based; must fit u32) |
| rsi | `result_ptr` (may be 0 iff `result_len == 0`) |
| rdx | `result_len` (0..`TF_RESULT_MAX`=4096) |
| rcx | `out` (ptr to caller-owned 64-byte scratch) |
| r8  | `out_cap` (must be ≥ 64) |
| rax | `TF_OK` or `TF_ERR_*` |

Guards (in order):

1. `out != 0` else `TF_ERR_BAD_OUT` (0x6000).
2. `out_cap >= 64` else `TF_ERR_OUT_TOO_SMALL` (0x6001).
3. `result_len <= 4096` else `TF_ERR_RESULT_TOO_LARGE` (0x6003).
4. `result_len > 0 && result_ptr == 0` → `TF_ERR_BAD_RESULT` (0x6002).
5. `turn_id upper 32 bits != 0` → `TF_ERR_BAD_TURN_ID` (0x6004).

The upper-32-bits turn_id check stages `0xFFFFFFFF` via MOVABS into a
scratch register and compares register-to-register (direct
`cmp reg, imm32` with bit 31 set is sign-extension-unsafe per the
Wave 125 pdx-encoder-pitfalls lesson).

Side effects on success (writes 64 bytes to `out`):

| Offset | Store |
| ------ | ----- |
| +0  | `mov_d [out+0], 0x52504654` (magic 'TFPR') |
| +4  | `mov_d [out+4], turn_id_low32` |
| +8  | `mov [out+8], result_hash` |
| +16 | `mov [out+16], rdtsc_combined` |
| +24..+56 | zero-fill then ASCII render of `turn.<id>.<hex>` |
| +56 | `mov [out+56], 0` (reserved u64) |

The ASCII render pass:

1. Zero-fill 32 bytes at [out+24..+56] via four u64 stores.
2. Byte-store `turn.` (5 B) at [out+24..+29].
3. Decimal-render `turn_id` starting at [out+29] via greedy-subtract
   over the local `_tf_pow10` LUT with an `emit_flag` to suppress
   leading zeros. Edge case: `turn_id == 0` emits a single `0`
   (standard greedy-decimal convention).
4. Byte-store `.` at the running cursor.
5. Hex-render the 64-bit `result_hash` as 16 lowercase nibbles via
   unrolled `shr r, N; and r, 15; mov_b r, [_tf_hex_digits + r]`
   writes at the cursor.

Frame shape: 6 callee-save push (rbx=turn_id, rbp=result_ptr,
r12=result_len, r13=out, r14=out_cap, r15=hash). NO nested CALL (FNV
inlined; decimal + hex rendering unrolled) so no sub-rsp alignment
pad is required (precedent: R229.M5 `_h_append`).

### 4.3 `_tf_render_tag(record, out, out_cap) -> packed_u64`

Register map:

| Reg | Role |
| --- | ---- |
| rdi | `record` (ptr to 64-byte TurnFingerprint record) |
| rsi | `out` (ptr to caller-owned output buffer) |
| rdx | `out_cap` (must be ≥ `16 + inner_len`) |
| rax | `(bytes_written << 32) \| status` |

Guards (in order):

1. `record != 0` else `TF_ERR_BAD_RECORD` (0x6005).
2. `out != 0` else `TF_ERR_BAD_OUT` (0x6000).
3. `u32 at [record+0] == 0x52504654` else `TF_ERR_BAD_MAGIC` (0x6006).
4. `out_cap >= 16 + inner_len` else `TF_ERR_OUT_TOO_SMALL` (0x6001).

Flow:

1. Scan `record[+24..+56]` for the first NUL byte; `inner_len` ∈
   [0..32] is the live tag length.
2. Emit the 14-byte prefix `@fingerprint("` from `_tf_prefix` in
   .rodata.
3. Byte-copy `inner_len` bytes from `record[+24..+24+inner_len]` to
   `out[+14..+14+inner_len]`.
4. Emit the 2-byte suffix `")` at `out[+14+inner_len..+16+inner_len]`.
5. Return `((16 + inner_len) << 32) | TF_OK`.

Pure leaf; zero callee-save pushes; no stack frame; no nested CALL.

### 4.4 `_tf_correlate(expected_tag, expected_len, actual_record, record_len) -> status`

Register map:

| Reg | Role |
| --- | ---- |
| rdi | `expected_tag` (ptr to expected `@fingerprint("...")` ASCII) |
| rsi | `expected_len` (byte length; must be ≥ 16) |
| rdx | `actual_record` (ptr to 64-byte TurnFingerprint record) |
| rcx | `record_len` (= 64; defensive guard) |
| rax | `TF_OK` iff rendering would produce byte-identical output |

Guards (in order):

1. `record_len == 64` else `TF_ERR_BAD_LEN` (0x6008).
2. `actual_record != 0` else `TF_ERR_BAD_RECORD` (0x6005).
3. `expected_tag != 0` else `TF_ERR_BAD_EXPECTED` (0x6009).
4. `expected_len >= 16` else `TF_ERR_BAD_LEN`.
5. `u32 at [record+0] == 0x52504654` else `TF_ERR_BAD_MAGIC` (0x6006).

Flow (NO scratch stack buffer; the function compares in-place):

1. Verify `expected_tag[0..14]` matches `_tf_prefix[0..14]`
   (`@fingerprint("`). Mismatch → `TF_ERR_BAD_LEN` (missing wrapper).
2. Verify `expected_tag[expected_len - 2] == '"'` and
   `expected_tag[expected_len - 1] == ')'`. Mismatch →
   `TF_ERR_BAD_LEN`.
3. `inner_len = expected_len - 16`. Guard `inner_len <= 32` else
   `TF_ERR_MISMATCH` (0x6007) — the record's field only holds 32
   bytes.
4. Byte-compare `expected_tag[14..14+inner_len]` against
   `actual_record[24..24+inner_len]`. Any mismatch →
   `TF_ERR_MISMATCH`.
5. If `inner_len < 32`: verify `actual_record[24+inner_len] == 0` so
   the record's live tag is not LONGER than the expected inner. A
   trailing non-NUL byte means the record carries more content than
   the expected tag claimed → `TF_ERR_MISMATCH`.
6. Return `TF_OK`.

Pure leaf; zero callee-save pushes; no stack frame; no nested CALL.

## 5 Status-code namespace — 0x6000..0x60FF

Ten slots used at R229.M10:

| Code | Name | Meaning |
| ---- | ---- | ------- |
| 0 | `TF_OK` | success |
| 0x6000 | `TF_ERR_BAD_OUT` | `out == 0` on any entry |
| 0x6001 | `TF_ERR_OUT_TOO_SMALL` | `out_cap` below required width |
| 0x6002 | `TF_ERR_BAD_RESULT` | `result_len > 0 && result_ptr == 0` |
| 0x6003 | `TF_ERR_RESULT_TOO_LARGE` | `result_len > 4096` |
| 0x6004 | `TF_ERR_BAD_TURN_ID` | `turn_id` upper 32 bits set |
| 0x6005 | `TF_ERR_BAD_RECORD` | `record == 0` on render/correlate |
| 0x6006 | `TF_ERR_BAD_MAGIC` | magic at `record[+0]` != 'TFPR' LE |
| 0x6007 | `TF_ERR_MISMATCH` | correlate: tag ≠ record's rendered form |
| 0x6008 | `TF_ERR_BAD_LEN` | correlate: bad record_len / expected_len |
| 0x6009 | `TF_ERR_BAD_EXPECTED` | correlate: `expected_tag == 0` |

Slots 0x600A..0x60FF reserved for M10.1+ follow-ups:

* `TF_ERR_BAD_ENV_MASK` (M10.1 env-mask field validator).
* `TF_ERR_HASH_MISMATCH` (M10.3 strict-mode hash-only correlator that
  recomputes FNV from the result bytes).
* `TF_ERR_TIMESTAMP_SKEW` (M10.4 rdtsc-skew sanity bound).

### 5.1 Disjointness proof

Band 0x6000..0x60FF is disjoint from every landed parser-tier band:

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
0x6000..0x60FF  R229.M10 TurnFingerprint   (THIS landing)
```

R229.M10 sits directly above the Wave 130 / 131 R227.M5
ModuleFunctor band (landed in the same wave). All adjacent bands
are claimed with no held reservations between R229.M10 and the
nearest neighbour below it.

A downstream compound-error dispatcher can discriminate
"turn-fingerprint faulted" from every other sibling satellite's
failure modes by `shr r, 8; cmp r, 0x60`.

## 6 Encoder discipline (absolute)

Standard parser-tier discipline (grep-confirmed clean against the
pdx-encoder-pitfalls memory):

* No `test rN, rN` — every zero-check uses `cmp reg, 0; je/jne`.
* No `and rN, imm64` — every mask is imm8 (0xFF, 15) or imm32.
* No 2-op `imul r, imm` — the FNV multiply uses the one-op
  `mul rcx` form (unsigned 64x64; distinct from the pitfall).
* No multiline `pub let = "..."` — every justification is a single
  line.
* Module basename `TurnFingerprint` matches `turn_fingerprint.pdx`.
* Labels prefixed `tf_` with per-function suffix (`tf_ini_`,
  `tf_em_`, `tf_rt_`, `tf_co_`). Grep-disjoint from every landed
  parser-tier prefix.
* `cmp` immediates all fit imm32 with bit 31 clear EXCEPT
  `0xFFFFFFFF` (turn_id upper-32 bound) which stages via MOVABS
  into a scratch register and compares register-to-register.
* Byte loads via `xor rax, rax; mov_b rax, [base + idx * 1]`
  (FNV-family precedent).
* u32 stores via `mov_d [dst + disp], reg`.
* u64 stores via plain `mov [dst + disp], reg`.
* Byte stores at a reg + reg address compute the destination into a
  caller-save scratch first (`mov r?, dst_base; add r?, idx;
  mov_b [r? + 0], byte`) to sidestep the
  `mov_b [reg + reg + off], reg` encoder gap (precedent:
  history.pdx line 663).
* `_tf_init`, `_tf_render_tag`, `_tf_correlate` are PURE LEAVES with
  zero callee-save pushes. r11 is used freely.
* `_tf_emit` is a 6-callee-save-push frame with ZERO nested CALL;
  no sub-rsp alignment pad required.

## 7 Register plans

### 7.1 `_tf_emit` — 6-push frame

| Reg | Role after prologue |
| --- | ------------------- |
| rbx | `turn_id` (saved input; low 32 are the record's turn_id field) |
| rbp | `result_ptr` (saved input; feeds the FNV loop via r8) |
| r12 | `result_len` (saved input; feeds the FNV loop via r9) |
| r13 | `out` (saved input; destination base for every store) |
| r14 | `out_cap` (saved input; guard reference) |
| r15 | `result_hash` (populated from rax after FNV completes) |

FNV scratch budget: rax (hash accumulator), rcx (prime, held across
loop), rdx (mul high half, clobbered), r8 (ptr base), r9 (len),
r10 (i), r11 (per-byte scratch).

Decimal-render scratch budget: rdi (working dividend; modifiable
copy of rbx), r8 (pow index 0..9), rcx (pow value), r9 (digit),
r10 (emit_flag), rdx (cursor), r11 (per-emission scratch), rsi
(pow table / dst-address scratch).

Hex-render scratch budget: rsi (hex table base; loop-held), r9
(nibble value), r11 (hex digit), r8 (dst-address scratch), rdx
(cursor; carried from decimal).

### 7.2 `_tf_render_tag` — pure leaf

Pre-loop and scan: r8 (`&record[24]`), r9 (`inner_len`), r10
(`needed`), r11 (per-byte scratch), rax (i).

Prefix emit: rcx (`&_tf_prefix`), rax (i), r11 (byte), r8
(dst-address scratch).

Inner copy: r8 (`&record[24]` loop-held), rcx (`&out[14]`
loop-held), rax (i), r11 (byte), rdi (dst-address scratch).

Suffix emit: rcx (`&out[14+inner_len]`), rax (byte).

### 7.3 `_tf_correlate` — pure leaf

Prefix verify: r8 (`&_tf_prefix`), r9 (expected_tag), rax (i), r10
(expected byte), r11 (prefix byte).

Suffix verify: r8 (`expected_len - 2`), r9 (`&expected_tag[len-2]`),
r10 (byte).

Inner compare: r8 (inner_len), r9 (`&expected_tag[14]`), r10
(`&actual_record[24]`), rax (i), r11 (expected byte), rcx (actual
byte).

Trailing-NUL check: r11 (byte at `&record[24 + inner_len]`).

## 8 Acceptance

The 500-turn smoke session (per the issue):

1. Simulated REPL driver pushes 500 synthetic result blobs through
   `_tf_emit(id, blob, blob_len, scratch, 64)` for id = 1..500.
2. Each iteration also calls `_tf_render_tag(scratch, tag_out, 64)`
   and verifies the returned high-32 is `16 + N` for the computed
   N = 5 + decimal_digits(id) + 1 + 16.
3. Each iteration then feeds (tag_out, len, scratch, 64) into
   `_tf_correlate` and asserts `TF_OK`.
4. A sixth iteration perturbs scratch (flips one bit in the hash
   field) and asserts `TF_ERR_MISMATCH`.

Fixture tier at raw M10 (nine negative cases + three positive):

| # | Fixture | Expected rax |
| - | ------- | ------------ |
| 1 | emit(1, "hello", 5, out, 64) | TF_OK; magic 'TFPR', turn_id = 1, hash = FNV-1a("hello") |
| 2 | emit(42, "", 0, out, 64) | TF_OK; hash = basis unchanged (zero-length) |
| 3 | emit(4294967295, blob, 1024, out, 64) | TF_OK (max u32 turn_id; 32-byte rendered_tag exactly) |
| 4 | emit(1, "hello", 5, 0, 64) | TF_ERR_BAD_OUT |
| 5 | emit(1, "hello", 5, out, 63) | TF_ERR_OUT_TOO_SMALL |
| 6 | emit(1, "hello", 5, out, 64) with result_len > 4096 | TF_ERR_RESULT_TOO_LARGE |
| 7 | emit(1, 0, 5, out, 64) | TF_ERR_BAD_RESULT |
| 8 | emit(0x1_0000_0000, "hello", 5, out, 64) | TF_ERR_BAD_TURN_ID |
| 9 | render_tag(0, out, 64) | TF_ERR_BAD_RECORD |
| 10 | render_tag(record_with_wrong_magic, out, 64) | TF_ERR_BAD_MAGIC |
| 11 | correlate(expected_matching, len, record, 64) | TF_OK |
| 12 | correlate(expected_bit_flipped, len, record, 64) | TF_ERR_MISMATCH |

The full 500-turn golden corpus lands at M10.5 under
`smoke/turn-fingerprint-m10.golden.txt` with one line per turn
carrying the full `@fingerprint("...")` tag; the smoke harness
`tools/verify-fingerprint-coverage.sh` iterates the golden and
asserts `_tf_correlate` passes for every row.

## 9 Consumer pattern

The REPL driver (R229.M1, kernel-side) wires the fingerprint path as:

```
// Per-turn hot path (pseudocode).
let rec    = alloca 64;
let tag    = alloca 64;
let status = _tf_emit(turn_id, result_ptr, result_len, rec, 64);
if status != TF_OK { klog_fault(status); next_turn; }

let packed = _tf_render_tag(rec, tag, 64);
let st     = packed & 0xFFFFFFFF;
let nbytes = packed >> 32;
if st != TF_OK { klog_fault(st); next_turn; }

klog_bytes(tag, nbytes);                 // post-mortem anchor
tty_write(tag, nbytes);                  // user-visible anchor
```

The debugger / correlation harness (R229.M10.5 smoke tier) wires:

```
// Per-golden-row verification (pseudocode).
let line = golden_rows[i];               // "@fingerprint(\"turn.i.hash\")"
let st   = _tf_correlate(line.ptr, line.len, actual_recs[i], 64);
assert_eq!(st, TF_OK);
```

## 10 Where this is NOT

* NOT the ONLY fingerprint. The R229.M5 History record carries its
  own cmd_hash FNV over the COMMAND TEXT; the two hashes serve
  different anchors (command vs result).
* NOT a cryptographic MAC. FNV-1a 64 is a fast fingerprint, not a
  signature; an adversary with write access to the record can forge
  one. The P9 anchor is a FABRICATION defence, not a tamper defence.
* NOT a per-stage fingerprint. The result bytes hashed here are the
  TURN's final result after all pipeline stages have executed. A
  per-stage fingerprint (one record per stage) is forward-path
  (M10.3+).
* NOT a persistent store. The 64-byte record is caller-scratched and
  discarded after klog / stdout emission. The R229.M5 History ring is
  the persistent per-session memory; TurnFingerprint is the
  per-emission anti-fabrication anchor.

## 11 File footprint

* `tools/user/libpdx-pds-parser/src/turn_fingerprint.pdx` — ~1050 LOC
  including the mandatory header comment block.
* `design/shell/turn-fingerprint.md` — this file.
* `tools/user/libpdx-pds-parser/caps.decl` — R229.M10 catalogue
  paragraph + error-band section at 0x6000..0x60FF.
* `tools/user/libpdx-pds-parser/src/lib.pdx` — bump version 1.36.0 →
  1.37.0; add `LPX_PDS_PARSER_R229_M10_READY = 1`; append
  `src/turn_fingerprint.pdx at R229.M10` to the module-filename
  comment; append `paideia-os#2728` to the upstream list;
  append `design/shell/turn-fingerprint.md` to the design-docs
  cross-ref.
* `tools/user/libpdx-pds-parser/STATUS.md` — add R229.M10 landing
  paragraph; bump Version to 1.37.0; add Wave 131 landings header;
  add R229.M10 checklist section; add error-band accounting row.
* `.plans/scratch/CHANGELOG-R229M10.md` — per-primitive scratch
  (consolidated into `CHANGELOG.md` at Wave close).

## 12 Forward path

* **R229.M10.1** env-mask field. Add a `u32 env_mask` at
  `[record+0x38..+0x3C]` capturing the cap-row delta between the
  READ and WRITE phases of the turn. The correlator gains the
  detection of mid-turn capability drift (a privilege escalation
  that the standard result-hash does not notice).
* **R229.M10.2** result-length field. Add a `u32 result_len_low` at
  `[record+0x3C..+0x40]` so an auditor can cross-check the hash
  input without consulting the REPL's own state. Detects mid-
  pipeline byte truncation that both ends agree on but which the
  result-hash alone cannot distinguish from a legitimately empty
  result.
* **R229.M10.3** strict-mode hash-only correlator. A second entry
  point `_tf_correlate_strict(expected_tag, expected_len,
  result_ptr, result_len)` that RECOMPUTES the FNV from the result
  bytes and compares to the hash parsed out of expected_tag's
  inner. Catches a tampered record where magic + turn_id +
  rendered_tag match but the hash field was overwritten.
* **R229.M10.4** rdtsc-skew sanity bound. A new entry point
  `_tf_correlate_sequence(records_ptr, n_records)` that rejects a
  sequence where any record's `timestamp_us` precedes the
  previous turn's `timestamp_us`.
* **R229.M10.5** Smoke-mode golden corpus. 500-turn session fixture
  under `smoke/turn-fingerprint-m10.golden.txt` with one line per
  turn carrying the full `@fingerprint("...")` tag, consumed by
  `tools/verify-fingerprint-coverage.sh`.

## 13 Related docs

* `design/foundations/project-invariants.md` — P9 the authoritative
  invariant.
* `design/shell/repl-loop-scaffold.md` — R229 umbrella.
* `design/shell/history-storage.md` — R229.M5 parallel per-turn
  record (COMMAND side).
* `design/shell/renderer-integration.md` — R229.M9 sibling WRITE-
  side satellite that emits the tag downstream.
* `design/debugger/anti-fabrication-anchors.md` (planned R30 doc) —
  the smoke-mode correlation harness umbrella.
* `.claude/CLAUDE.md` — the operational directive that cites the
  P9 invariant across every softarch / debugger loop.

## 14 Open questions

* **TF-O1** Should the `rendered_tag` field include the raw hash as
  decimal rather than hex to make it eyeball-visible against a
  decimal turn_id? Decision at M10.5 after the first smoke-run
  readability review.
* **TF-O2** Should `_tf_correlate` return a bytes-written field
  packed in the high 32 bits on `TF_ERR_MISMATCH` so the caller can
  locate the exact byte offset of the first disagreement? Decision
  at M10.3 when the strict-mode correlator lands.
* **TF-O3** Should the 500-turn smoke harness run under the
  acceptance gate `bash tools/run-smoke.sh` (main-only) or under a
  dedicated `tools/verify-fingerprint-coverage.sh` loop? Decision at
  M10.5 when the harness lands.
