# Per-script-load fingerprint (R227.M8)

Issue: paideia-os#2710
Umbrella: paideia-os#2491 (R227 pds container / loader)
Wave:  134
Lands: 2026-10-15

## 1 Why this exists

The paideia-os project invariants
(`design/foundations/project-invariants.md` P9) commit every pds script
load and every REPL turn to a verifiable anti-fabrication anchor.
R229.M10 TurnFingerprint (`turn-fingerprint.md`) lands the RESULT-side
anchor: every REPL turn emits `@fingerprint("turn.<id>.<hash-hex>")`.
R225.M10 CheckFingerprint (`check-fingerprint.md`) lands the
TYPECHECK-outcome anchor: every REPL turn emits
`@fingerprint("check.<id>.<ok|fail-N>")`. R227.M8 (THIS landing) lands
the LOAD-side anchor: every pds script load emits
`@fingerprint("pds.load.<script-hash-hex>")`.

The three anchors together form a chain the debugger can trace:

```
pds.load.<hash>  ->  check.<id>.<ok|fail-N>  ->  turn.<id>.<hash>
   (load)              (typecheck)                  (execute)
```

so a claimed turn result can be traced through its typechecker outcome
back to the exact script bytes that produced it. A tool-use log that
drops any one anchor leaves a hole the correlation harness detects as
P9 breakage.

The 5-script load acceptance (per the issue) is: `_lf_emit` fires 5
times in sequence (one per loaded script), each producing a 64-byte
record whose `_lf_render_tag` output can be fed back through
`_lf_correlate` with the expected tag and get `LF_OK` on every one of
5 iterations.

## 2 Position in the substrate

```
loader entry (R227.M1 kernel-side) -> script bytes
     -> script_hash = FNV-1a 64(script_bytes)  (caller computes)
     -> _lf_emit(script_hash, out, 64)          (THIS module)
            -> 64-byte LoadFingerprint record on caller scratch
     -> _lf_render_tag(record, out, out_cap)    (THIS module)
            -> `@fingerprint("pds.load.<hash-hex>")` ASCII string
     -> klog emission + stdout emission
     -> R227.M3 ImportResolve, R227.M4 LoadCheck, R227.M5 ModuleFunctor...
     -> R225.M10 CheckFingerprint emission (per-turn parallel anchor)
     -> R229.M10 TurnFingerprint emission (per-turn RESULT anchor)
```

Companion module on the debugger side:

```
<external claimed tag>  +  <record the loader emitted>
     -> _lf_correlate(expected_tag, expected_len, actual_record, 64)
            -> LF_OK (match) or LF_ERR_MISMATCH (lie)
```

## 3 LoadFingerprint record — 64 bytes

Record stride 64 = 2^6 so a future per-session multi-load ring (one
row per load, up to a bounded horizon) can index via `shl idx, 6`
with no 2-op `imul r, imm` dance (precedent: R229.M10 TurnFingerprint,
R225.M10 CheckFingerprint).

| Offset | Width  | Field          | Meaning |
| ------ | ------ | -------------- | ------- |
| 0x00   | u32    | `magic`        | 'LFPR' (0x5250464C LE) — bytes L,F,P,R |
| 0x04   | u32    | reserved       | zero at M8; reserved for M8.1 `load_mode` |
| 0x08   | u64    | `script_hash`  | FNV-1a 64 of script bytes (caller-supplied) |
| 0x10   | u64    | `timestamp_us` | rdtsc sample at emit time (raw TSC) |
| 0x18   | u8[32] | `rendered_tag` | `pds.load.<hex>` ASCII, NUL-padded |
| 0x38   | u64    | reserved       | zero at M8; reserved for M8.1+ |

The `rendered_tag` field format: `pds.load.` (9 bytes) + lowercase hex
of the full 64-bit `script_hash` (16 bytes) = 25 bytes exactly. NUL-
padded to 32 bytes (7 bytes pad). A reader walks from offset 0 until
the first NUL or offset 32, whichever first.

Fixed width (vs TurnFingerprint which carries a variable-width decimal
turn_id): the LoadFingerprint tag has no caller-visible counter, so no
decimal rendering is needed — every load's rendered_tag is exactly 25
bytes.

Why 64 bytes exactly:
* Power of two (`shl idx, 6` addressing for a future multi-load ring).
* Fits the fixed fields (magic + reserved + hash + timestamp = 24 B) +
  rendered_tag (32 B) + one reserved u64 for M8.1+ growth.
* Below the common x86_64 L1 cache line (64 B is one line exactly); a
  cold-cache read of a single record pulls exactly one line.
* Matches the TurnFingerprint and CheckFingerprint record stride so a
  cross-boundary comparison does not have to translate layouts.

Why caller-supplied script_hash (vs TurnFingerprint which inlines
FNV-1a 64):
* The loader already computes the hash at ingress — it is also used as
  the R227.M7 ScriptCache lookup key, so re-computing it inside this
  module would be redundant work on every load.
* The FNV-1a 64 algorithm is byte-for-byte identical to the parser-
  tier FNV family (`_cmd_sig_fnv1a64` R222.M2, `_fi_fnv1a64` R222.M3,
  `_cmdreg_fnv1a64` R222.M5, `_ws_schema_hash` R223.M5, the inlined
  FNV in `_h_append` R229.M5, `_tf_emit` R229.M10, `_cf_emit`
  R225.M10) so the caller may pick any of those sites to produce the
  hash and the numerical equality property is preserved.
* The simplification lets `_lf_emit` be a 2-callee-save-push frame
  (vs TurnFingerprint's 6-push frame) — a measurable cost reduction
  on a hot path if the loader fires repeatedly (e.g. a cold boot
  under a `source` chain).

Why raw TSC (not microseconds):
* Byte-for-byte reproducible across tools: a smoke-mode golden
  comparing two runs on the same machine gets numerical equality of
  the `timestamp_us` field (modulo the irreducible TSC drift).
* The loader driver owns the TSC-to-microseconds conversion
  (R20.M3 calibration result); this module stores the raw sample.
* Avoids a nested CALL into the TSC calibrator from the parser-tier
  pure-leaf path.

## 4 Public API

### 4.1 `_lf_init() -> ()`

Bare `ret`. M8 holds NO .bss state. Entry exists for parallelism
with the parser-family init-hook convention (`_tf_init` R229.M10,
`_cf_init` R225.M10, `_rd_init` R229.M9, `_ha_init` R223.M6,
`_ws_init` R223.M5, `_ds_init` R222.M8, `_dm_init` R222.M6,
`_cmdreg_init` R222.M5, `_st_init` R223.M7) so a later M8.1+ landing
that adds .bss (e.g. a per-session load counter) does not break the
API.

### 4.2 `_lf_emit(script_hash, out, out_cap) -> status`

Register map:

| Reg | Role |
| --- | ---- |
| rdi | `script_hash` (FNV-1a 64 of script bytes; caller-computed) |
| rsi | `out` (ptr to caller-owned 64-byte scratch) |
| rdx | `out_cap` (must be ≥ 64) |
| rax | `LF_OK` or `LF_ERR_*` |

Guards (in order; both checked BEFORE pushes so an early-return avoids
the push/pop pair):

1. `out != 0` else `LF_ERR_BAD_OUT` (0x6800).
2. `out_cap >= 64` else `LF_ERR_OUT_TOO_SMALL` (0x6801).

Side effects on success (writes 64 bytes to `out`):

| Offset | Store |
| ------ | ----- |
| +0     | `mov_d [out+0], 0x5250464C` (magic 'LFPR') |
| +4     | `mov_d [out+4], 0` (reserved u32) |
| +8     | `mov [out+8], script_hash` |
| +16    | `mov [out+16], rdtsc_combined` |
| +24..+56 | zero-fill then ASCII render of `pds.load.<hex>` |
| +56    | `mov [out+56], 0` (reserved u64) |

The ASCII render pass:

1. Zero-fill 32 bytes at [out+24..+56] via four u64 stores (handles
   NUL-pad at [+49..+56]).
2. Byte-store `pds.load.` (9 B) at [out+24..+33] via nine
   `mov_b [rbp + <const disp>], rax` with disp 24..32 (imm8-safe).
3. Pre-stage the hex-table base via
   `lea r8, [rip + _lf_hex_digits]`.
4. Hex-render the 64-bit `script_hash` as 16 lowercase nibbles via
   unrolled `shr r, N; and r, 15; mov_b r, [r8 + r]` writes at
   [out+33..+49] (16 bytes). Each nibble position has a constant
   destination offset (33..48) so the byte stores use imm8 disp.

Frame shape: 2 callee-save push (rbx=script_hash, rbp=out). NO nested
CALL (hex rendering unrolled; no FNV loop) so no sub-rsp alignment pad
is required.

### 4.3 `_lf_render_tag(record, out, out_cap) -> packed_u64`

Register map:

| Reg | Role |
| --- | ---- |
| rdi | `record` (ptr to 64-byte LoadFingerprint record) |
| rsi | `out` (ptr to caller-owned output buffer) |
| rdx | `out_cap` (must be ≥ `16 + inner_len`; typical 41 B) |
| rax | `(bytes_written << 32) \| status` |

Guards (in order):

1. `record != 0` else `LF_ERR_BAD_RECORD` (0x6802).
2. `out != 0` else `LF_ERR_BAD_OUT` (0x6800).
3. `u32 at [record+0] == 0x5250464C` else `LF_ERR_BAD_MAGIC` (0x6803).
4. `out_cap >= 16 + inner_len` else `LF_ERR_OUT_TOO_SMALL` (0x6801).

Flow:

1. Scan `record[+24..+56]` for the first NUL byte; `inner_len` ∈
   [0..32] is the live tag length (25 under the standard M8 shape).
2. Emit the 14-byte prefix `@fingerprint("` from `_lf_prefix` in
   .rodata.
3. Byte-copy `inner_len` bytes from `record[+24..+24+inner_len]` to
   `out[+14..+14+inner_len]`.
4. Emit the 2-byte suffix `")` at `out[+14+inner_len..+16+inner_len]`.
5. Return `((16 + inner_len) << 32) | LF_OK`.

Pure leaf; zero callee-save pushes; no stack frame; no nested CALL.

### 4.4 `_lf_correlate(expected_tag, expected_len, actual_record, record_len) -> status`

Register map:

| Reg | Role |
| --- | ---- |
| rdi | `expected_tag` (ptr to expected `@fingerprint("...")` ASCII) |
| rsi | `expected_len` (byte length; must be ≥ 16) |
| rdx | `actual_record` (ptr to 64-byte LoadFingerprint record) |
| rcx | `record_len` (= 64; defensive guard) |
| rax | `LF_OK` iff rendering would produce byte-identical output |

Guards (in order):

1. `record_len == 64` else `LF_ERR_BAD_LEN` (0x6805).
2. `actual_record != 0` else `LF_ERR_BAD_RECORD` (0x6802).
3. `expected_tag != 0` else `LF_ERR_BAD_EXPECTED` (0x6806).
4. `expected_len >= 16` else `LF_ERR_BAD_LEN`.
5. `u32 at [record+0] == 0x5250464C` else `LF_ERR_BAD_MAGIC` (0x6803).

Flow (NO scratch stack buffer; the function compares in-place):

1. Verify `expected_tag[0..14]` matches `_lf_prefix[0..14]`
   (`@fingerprint("`). Mismatch → `LF_ERR_BAD_LEN` (missing wrapper).
2. Verify `expected_tag[expected_len - 2] == '"'` and
   `expected_tag[expected_len - 1] == ')'`. Mismatch →
   `LF_ERR_BAD_LEN`.
3. `inner_len = expected_len - 16`. Guard `inner_len <= 32` else
   `LF_ERR_MISMATCH` (0x6804) — the record's field only holds 32
   bytes.
4. Byte-compare `expected_tag[14..14+inner_len]` against
   `actual_record[24..24+inner_len]`. Any mismatch →
   `LF_ERR_MISMATCH`.
5. If `inner_len < 32`: verify `actual_record[24+inner_len] == 0` so
   the record's live tag is not LONGER than the expected inner.
6. Return `LF_OK`.

Pure leaf; zero callee-save pushes; no stack frame; no nested CALL.

## 5 Status-code namespace — 0x6800..0x68FF

Seven slots used at R227.M8:

| Code | Name | Meaning |
| ---- | ---- | ------- |
| 0 | `LF_OK` | success |
| 0x6800 | `LF_ERR_BAD_OUT` | `out == 0` on any entry |
| 0x6801 | `LF_ERR_OUT_TOO_SMALL` | `out_cap` below required width |
| 0x6802 | `LF_ERR_BAD_RECORD` | `record == 0` on render/correlate |
| 0x6803 | `LF_ERR_BAD_MAGIC` | magic at `record[+0]` != 'LFPR' LE |
| 0x6804 | `LF_ERR_MISMATCH` | correlate: tag ≠ record's rendered form |
| 0x6805 | `LF_ERR_BAD_LEN` | correlate: bad record_len / expected_len |
| 0x6806 | `LF_ERR_BAD_EXPECTED` | correlate: `expected_tag == 0` |

Slots 0x6807..0x68FF reserved for M8.1+ follow-ups:

* `LF_ERR_BAD_LOAD_MODE` (M8.1 load_mode field validator).
* `LF_ERR_BAD_SOURCE_KIND` (M8.2 source_kind discriminator).
* `LF_ERR_HASH_MISMATCH` (M8.3 strict-mode hash-only correlator).
* `LF_ERR_TIMESTAMP_SKEW` (M8.4 rdtsc-skew sanity bound).

### 5.1 Disjointness proof

Band 0x6800..0x68FF is disjoint from every landed parser-tier band:

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
0x6000..0x60FF  R229.M10 TurnFingerprint
0x6100..0x61FF  R225.M9 proptest_hm
0x6200..0x62FF  R227.M6 version_pragma
0x6300..0x63FF  R225.M10 check_fingerprint
0x6400..0x64FF  R226.M2 predicate_types
0x6500..0x65FF  R227.M7 script_cache
0x6600..0x66FF  held slack for sibling arms in-flight at this wave
0x6700..0x67FF  held slack for sibling arms in-flight at this wave
0x6800..0x68FF  R227.M8 LoadFingerprint   (THIS landing)
```

A downstream compound-error dispatcher can discriminate "load-
fingerprint faulted" from every other sibling satellite's failure
modes by `shr r, 8; cmp r, 0x68`.

## 6 Encoder discipline (absolute)

Standard parser-tier discipline (grep-confirmed clean against the
pdx-encoder-pitfalls memory):

* No `test rN, rN` — every zero-check uses `cmp reg, 0; je/jne`.
* No `and rN, imm64` — the one nibble mask `and rN, 15` fits imm8.
* No 2-op `imul r, imm` — M8 has no multiply at all (hash is
  caller-supplied, no FNV loop fires).
* No multiline `pub let = "..."` — every justification is one line.
* Module basename `LoadFingerprint` matches `load_fingerprint.pdx`.
* Labels prefixed `lf_` with per-function suffix (`lf_ini_`,
  `lf_em_`, `lf_rt_`, `lf_co_`). Grep-disjoint from every landed
  parser-tier prefix. Grep-confirmed virgin for `lf_` across
  `tools/user/libpdx-pds-parser/src/*.pdx`.
* `cmp` immediates all fit imm32 with bit 31 clear. No imm64
  constants at M8 (no FNV; the magic 0x5250464C is imm32).
* Byte loads via `xor rax, rax; mov_b rax, [base + idx * 1]`
  (FNV-family precedent).
* u32 stores via `mov_d [dst + disp], reg`.
* u64 stores via plain `mov [dst + disp], reg`.
* Byte stores at `[reg + const_disp]` with disp fitting imm8 use the
  `mov_b [reg + disp], byte` form directly (precedent:
  turn_fingerprint.pdx line 684). Byte stores at `[reg + reg + off]`
  compute the destination into a caller-save scratch first
  (precedent: history.pdx line 663).
* `_lf_init`, `_lf_render_tag`, `_lf_correlate` are PURE LEAVES with
  zero callee-save pushes. r11 is used freely.
* `_lf_emit` is a 2-callee-save-push frame with ZERO nested CALL;
  no sub-rsp alignment pad required.

## 7 Register plans

### 7.1 `_lf_emit` — 2-push frame

| Reg | Role after prologue |
| --- | ------------------- |
| rbx | `script_hash` (saved across rdtsc clobber) |
| rbp | `out` (saved; destination base for every store) |
| r8  | hex-table base (`_lf_hex_digits`; held across 16-unroll) |
| r9  | per-nibble scratch (nibble value 0..15) |
| r11 | per-nibble hex digit (byte load from hex table) |
| rax, rcx, rdx | freely clobbered; rdtsc clobbers rax + rdx |

### 7.2 `_lf_render_tag` — pure leaf

Pre-loop and scan: r8 (`&record[24]`), r9 (`inner_len`), r10
(`needed`), r11 (per-byte scratch), rax (i).

Prefix emit: rcx (`&_lf_prefix`), rax (i), r11 (byte), r8
(dst-address scratch; safe to clobber since inner copy re-derives).

Inner copy: r8 (`&record[24]` loop-held), rcx (`&out[14]` loop-held),
rax (i), r11 (byte), rdi (dst-address scratch; caller's record
pointer no longer needed because r8 carries the inner base).

Suffix emit: rcx (`&out[14+inner_len]`), rax (byte).

### 7.3 `_lf_correlate` — pure leaf

Prefix verify: r8 (`&_lf_prefix`), r9 (expected_tag), rax (i), r10
(expected byte), r11 (prefix byte).

Suffix verify: r8 (`expected_len - 2`), r9 (`&expected_tag[len-2]`),
r10 (byte).

Inner compare: r8 (inner_len), r9 (`&expected_tag[14]`), r10
(`&actual_record[24]`), rax (i), r11 (expected byte), rcx (actual
byte).

Trailing-NUL check: r11 (byte at `&record[24 + inner_len]`).

## 8 Acceptance

The 5-script load acceptance (per the issue):

1. Simulated loader pushes 5 synthetic script hashes through
   `_lf_emit(hash_i, scratch_i, 64)` for i = 1..5.
2. Each iteration also calls `_lf_render_tag(scratch_i, tag_i, 64)`
   and verifies the returned high-32 is 41 (16 + 25 = 41 for the
   standard load tag width).
3. Each iteration then feeds (tag_i, 41, scratch_i, 64) into
   `_lf_correlate` and asserts `LF_OK` on every one of the 5
   iterations.
4. A sixth iteration perturbs `scratch_3` (flips one bit in the
   hash field) and asserts `LF_ERR_MISMATCH`.

Fixture tier at raw M8 (seven negative cases + three positive):

| # | Fixture | Expected rax |
| - | ------- | ------------ |
| 1 | emit(0xDEADBEEFCAFEBABE, out, 64) | LF_OK; magic 'LFPR', hash = 0xDEADBEEFCAFEBABE, rendered_tag = "pds.load.deadbeefcafebabe" |
| 2 | emit(0, out, 64) | LF_OK; hash = 0, rendered_tag = "pds.load.0000000000000000" |
| 3 | emit(0xFFFFFFFFFFFFFFFF, out, 64) | LF_OK; hash = max u64, rendered_tag = "pds.load.ffffffffffffffff" |
| 4 | emit(any, 0, 64) | LF_ERR_BAD_OUT |
| 5 | emit(any, out, 63) | LF_ERR_OUT_TOO_SMALL |
| 6 | render_tag(0, out, 64) | LF_ERR_BAD_RECORD |
| 7 | render_tag(record_with_wrong_magic, out, 64) | LF_ERR_BAD_MAGIC |
| 8 | render_tag(record, 0, 64) | LF_ERR_BAD_OUT |
| 9 | render_tag(record, out, 40) with standard 25-B inner | LF_ERR_OUT_TOO_SMALL |
| 10 | correlate(expected_matching, 41, record, 64) | LF_OK |
| 11 | correlate(expected_bit_flipped, 41, record, 64) | LF_ERR_MISMATCH |
| 12 | correlate(expected, 41, 0, 64) | LF_ERR_BAD_RECORD |
| 13 | correlate(0, 41, record, 64) | LF_ERR_BAD_EXPECTED |

The full 5-script golden corpus lands at M8.5 under
`smoke/load-fingerprint-m8.golden.txt` with one line per load
carrying the full `@fingerprint("...")` tag; the smoke harness
`tools/verify-load-fingerprint-coverage.sh` iterates the golden and
asserts `_lf_correlate` passes for every row.

## 9 Consumer pattern

The pds loader (R227.M1 kernel-side; forward-path) wires the
fingerprint path as:

```
// Per-load hot path (pseudocode).
let script_hash = fnv1a_64(script_ptr, script_len);  // also serves
                                                     // ScriptCache
let rec         = alloca 64;
let tag         = alloca 64;
let status      = _lf_emit(script_hash, rec, 64);
if status != LF_OK { klog_fault(status); abort_load; }

let packed = _lf_render_tag(rec, tag, 64);
let st     = packed & 0xFFFFFFFF;
let nbytes = packed >> 32;
if st != LF_OK { klog_fault(st); abort_load; }

klog_bytes(tag, nbytes);                 // post-mortem anchor
tty_write(tag, nbytes);                  // user-visible anchor
```

The debugger / correlation harness (R227.M8.5 smoke tier) wires:

```
// Per-golden-row verification (pseudocode).
let line = golden_rows[i];               // "@fingerprint(\"pds.load.hash\")"
let st   = _lf_correlate(line.ptr, line.len, actual_recs[i], 64);
assert_eq!(st, LF_OK);
```

## 10 Where this is NOT

* NOT the ONLY fingerprint. The R229.M10 TurnFingerprint carries a
  per-TURN hash over the RESULT bytes; the R225.M10 CheckFingerprint
  carries a per-TURN hash over the TYPECHECK outcome. The three
  anchors serve the three stages of the pipeline.
* NOT a cryptographic MAC. FNV-1a 64 is a fast fingerprint, not a
  signature; an adversary with write access to the record can forge
  one. The P9 anchor is a FABRICATION defence, not a tamper defence.
* NOT a per-stage fingerprint. The hash covers the WHOLE script
  bytes at the load entry. A per-import or per-module fingerprint is
  a separate forward-path concern (M8.6+ ladder; R227.M3
  ImportResolve already anchors import graph nodes to their own
  hashes).
* NOT a persistent store. The 64-byte record is caller-scratched and
  discarded after klog / stdout emission. The R229.M5 History ring
  is the persistent per-session memory; LoadFingerprint is the
  per-emission anti-fabrication anchor.
* NOT a hash RECOMPUTER. The caller supplies the hash; this module
  does not re-walk the script bytes. Strict-mode recomputation lives
  at M8.3 (`_lf_correlate_strict`).

## 11 File footprint

* `tools/user/libpdx-pds-parser/src/load_fingerprint.pdx` — ~1050 LOC
  including the mandatory header comment block.
* `design/shell/load-fingerprint.md` — this file.
* `tools/user/libpdx-pds-parser/caps.decl` — R227.M8 catalogue
  paragraph + error-band section at 0x6800..0x68FF.
* `tools/user/libpdx-pds-parser/src/lib.pdx` — bump MINOR; add
  `LPX_PDS_PARSER_R227_M8_READY = 1`; append
  `src/load_fingerprint.pdx at R227.M8` to the module-filename
  comment; append `paideia-os#2710` to the upstream list; append
  `design/shell/load-fingerprint.md` to the design-docs cross-ref.
* `tools/user/libpdx-pds-parser/STATUS.md` — add R227.M8 landing
  paragraph; add Wave 134 landings header; add R227.M8 checklist
  section; add error-band accounting row.
* `.plans/scratch/CHANGELOG-R227M8.md` — per-primitive scratch
  (consolidated into `CHANGELOG.md` at Wave close).

## 12 Forward path

* **R227.M8.1** load_mode field. Add a `u32 load_mode` at
  `[record+0x04..+0x08]` discriminating interactive REPL load (0)
  from `source <path>` load (1) from `require <mod>` load (2) from
  `#import <mod>` load (3). The correlator gains detection of a
  load-mode drift that the hash alone does not reveal.
* **R227.M8.2** source_kind + script_bytes_len. Add u32 + u32 at
  `[record+0x38..+0x40]` carrying the hashed byte count AND the
  source kind (stdin/file/tty/net) so an auditor can cross-check
  without consulting the loader's state.
* **R227.M8.3** strict-mode hash-only correlator.
  `_lf_correlate_strict(expected_tag, expected_len, script_ptr,
  script_len)` RECOMPUTES the FNV and compares to the hash parsed
  out of expected_tag's inner. Catches a tampered record where
  magic + rendered_tag match but the hash field was overwritten.
* **R227.M8.4** rdtsc-skew sanity bound.
  `_lf_correlate_sequence(records_ptr, n_records)` rejects a
  sequence where any record's `timestamp_us` precedes the previous
  load's `timestamp_us`.
* **R227.M8.5** Smoke-mode golden corpus. 5-script load fixture
  under `smoke/load-fingerprint-m8.golden.txt` with one line per
  load carrying the full `@fingerprint("...")` tag, consumed by
  `tools/verify-load-fingerprint-coverage.sh`.
* **R227.M8.6** Per-import load fingerprint. When the loader
  recurses through R227.M3 ImportResolve into a transitive import,
  emit a child LoadFingerprint anchored to the ImportDirective's
  own hash. A chain of parent -> child fingerprints forms the
  dependency-order audit trail.

## 13 Related docs

* `design/foundations/project-invariants.md` — P9 the authoritative
  invariant.
* `design/shell/turn-fingerprint.md` — R229.M10 sibling anchor
  (RESULT side).
* `design/shell/check-fingerprint.md` — R225.M10 sibling anchor
  (TYPECHECK outcome side).
* `design/shell/script-cache.md` — R227.M7 sibling that shares the
  `script_hash` input.
* `design/shell/import-resolution-parser.md` — R227.M3 upstream in
  the loader pipeline; LoadFingerprint anchors the ENTRY-POINT
  script before ImportResolve starts walking the graph.
* `design/shell/typecheck-at-load.md` — R227.M4 downstream in the
  loader pipeline; LoadFingerprint lands BEFORE LoadCheck runs so
  a check-failure correlation includes the load anchor.
* `design/debugger/anti-fabrication-anchors.md` (planned R30 doc) —
  the smoke-mode correlation harness umbrella.
* `.claude/CLAUDE.md` — the operational directive that cites the
  P9 invariant across every softarch / debugger loop.

## 14 Open questions

* **LF-O1** Should the `rendered_tag` field include a trailing
  separator (e.g. `pds.load.<hash>.<n>` where `<n>` is a per-session
  load counter) so a reader can disambiguate repeated loads of the
  same script? Decision at M8.1 when load_mode lands — a load_mode
  byte already discriminates most of the repeated-load cases.
* **LF-O2** Should `_lf_correlate` return a bytes-written field
  packed in the high 32 bits on `LF_ERR_MISMATCH` so the caller can
  locate the exact byte offset of the first disagreement? Decision
  at M8.3 when the strict-mode correlator lands (same question as
  TF-O2 under TurnFingerprint).
* **LF-O3** Should the 5-script smoke harness run under the
  acceptance gate `bash tools/run-smoke.sh` (main-only) or under a
  dedicated `tools/verify-load-fingerprint-coverage.sh` loop?
  Decision at M8.5 after the first smoke-run readability review
  (same question as TF-O3).
